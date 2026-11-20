import CoreVideo
import Foundation

public struct SpikeReport: CustomStringConvertible {
    /// Frame timing measured at the output sink (only for sinks that record it, such as the test sink).
    public var output: FrameTimingSummary?
    /// Status from a hardware-paced output (late and dropped frames counted by the card).
    public var outputStatus: String = ""
    public var renderLoop: FrameTimingSummary
    public var gpuMeanMs: Double
    public var gpuMaxMs: Double
    public var encodeMeanMs: Double
    public var encodeMaxMs: Double
    public var skippedTicks: Int
    public var videoUnderruns: Int
    public var renderErrors: Int
    /// Late frames in the render loop: (ms since measurement started, interval ms).
    public var renderLoopLate: [(atMs: Double, intervalMs: Double)] = []

    public var description: String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        let lateLines = renderLoopLate.prefix(15)
            .map { "  at \(f($0.atMs / 1000)) s: \(f($0.intervalMs)) ms" }
            .joined(separator: "\n")
        let outputLine = output.map { "output     : \($0)\n" } ?? ""
        let statusLine = outputStatus.isEmpty ? "" : "output     : \(outputStatus)\n"
        return """
        \(outputLine)\(statusLine)render loop: \(renderLoop)
        gpu        : mean=\(f(gpuMeanMs))ms max=\(f(gpuMaxMs))ms
        cpu encode : mean=\(f(encodeMeanMs))ms max=\(f(encodeMaxMs))ms
        skipped ticks=\(skippedTicks) video underruns=\(videoUnderruns) render errors=\(renderErrors)
        late render-loop frames (first 15 of \(renderLoopLate.count)):
        \(lateLines.isEmpty ? "  none" : lateLines)
        """
    }
}

/// The engine spike: a looping background video with a text layer on top, composited on the GPU
/// at a fixed rate and sent to an output sink. Measures timing so we can see whether the loop holds.
public final class SpikeRunner: @unchecked Sendable {
    private let compositor: Compositor
    private let video: VideoLoopSource
    private let text: TextLayer
    private let output: OutputSink
    /// Further hardware outputs that follow the first one (it sets the pace; these drop or repeat
    /// a frame when their own clocks drift).
    private let followers: [PacedOutputSink]
    private var followerSkips: [Int]
    private var followerRepeats: [Int]
    private let targetFPS: Double
    private let maxInFlight = 3

    private let renderLoopTiming: FrameTimingLogger
    private let gpuStats = RunningStats()
    private let encodeStats = RunningStats()
    private let lock = NSLock()
    private var inFlight = 0
    private var skipped = 0
    private var errors = 0

    public init(videoURL: URL, output: OutputSink, followers: [PacedOutputSink] = [],
                width: Int = 1920, height: Int = 1080, targetFPS: Double = 60) async throws {
        let compositor = try Compositor(width: width, height: height, outputFormat: output.preferredFormat)
        for follower in followers where follower.preferredFormat != output.preferredFormat {
            throw CompositorError.pipelineFailed("All outputs must use the same pixel format for now.")
        }
        let text = try TextLayer(device: compositor.device, width: width, height: height)
        let video = try await VideoLoopSource.open(url: videoURL)
        self.compositor = compositor
        self.text = text
        self.video = video
        self.output = output
        self.followers = followers
        self.followerSkips = Array(repeating: 0, count: followers.count)
        self.followerRepeats = Array(repeating: 0, count: followers.count)
        self.targetFPS = targetFPS
        self.renderLoopTiming = FrameTimingLogger(targetFPS: targetFPS)
    }

    /// Run for `seconds` of measurement, after an unmeasured `warmup`, then stop and return the
    /// timing report. Blocks the calling thread.
    ///
    /// With a `PacedOutputSink` the render loop is paced by the output's own clock and video time
    /// is counted in output frames. Otherwise a 60 Hz software timer drives it.
    public func run(seconds: Double, warmup: Double = 2.0, reportEvery: Double = 0) throws -> SpikeReport {
        try output.start()
        for follower in followers { try follower.start() }
        video.start()
        setStop(false)

        var timer: DispatchSourceTimer?
        let loopFinished = DispatchSemaphore(value: 0)

        if let paced = output as? PacedOutputSink {
            let frameDuration = 1.0 / paced.frameRate
            let thread = Thread { [self] in
                var n = 0
                while !stopRequested() {
                    guard paced.waitForRoom(timeoutMs: 100) else { continue }
                    // One frame at a time: wait until the previous one has reached the card.
                    if inFlightCount() > 0 {
                        Thread.sleep(forTimeInterval: 0.0005)
                        continue
                    }
                    if renderFrame(at: Double(n) * frameDuration) {
                        renderLoopTiming.recordFrame()
                        n += 1
                    } else {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                loopFinished.signal()
            }
            thread.name = "stage.engine.render"
            thread.qualityOfService = .userInteractive
            thread.start()
        } else {
            let startNanos = DispatchTime.now().uptimeNanoseconds
            let queue = DispatchQueue(label: "stage.engine.render", qos: .userInteractive)
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = Int(1_000_000_000.0 / targetFPS)
            source.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .nanoseconds(0))
            source.setEventHandler { [self] in
                renderLoopTiming.recordFrame()
                let t = Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000.0
                if !renderFrame(at: t) {
                    lock.lock()
                    skipped += 1
                    lock.unlock()
                }
            }
            source.resume()
            timer = source
        }

        if warmup > 0 {
            Thread.sleep(forTimeInterval: warmup)
            renderLoopTiming.reset()
            (output as? NullOutputSink)?.timing.reset()
            gpuStats.reset()
            encodeStats.reset()
            (output as? PacedOutputSink)?.resetStatistics()
            for follower in followers { follower.resetStatistics() }
            lock.lock()
            skipped = 0
            errors = 0
            followerSkips = Array(repeating: 0, count: followers.count)
            followerRepeats = Array(repeating: 0, count: followers.count)
            lock.unlock()
        }
        if reportEvery > 0 {
            // Long runs: print progress so a crash or a problem hours in still leaves a record.
            var elapsed = 0.0
            while elapsed < seconds {
                let step = min(reportEvery, seconds - elapsed)
                Thread.sleep(forTimeInterval: step)
                elapsed += step
                if elapsed < seconds { print("--- progress \(Int(elapsed)) s / \(Int(seconds)) s ---\n\(progressLines())") }
            }
        } else {
            Thread.sleep(forTimeInterval: seconds)
        }

        setStop(true)
        timer?.cancel()
        if output is PacedOutputSink { _ = loopFinished.wait(timeout: .now() + 1.0) }

        // Let frames already on the GPU finish.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock()
            let pending = inFlight
            lock.unlock()
            if pending == 0 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let status = progressLines(separator: "\n             ")
        for follower in followers { follower.stop() }
        output.stop()
        video.stop()

        let gpu = gpuStats.snapshot
        let encode = encodeStats.snapshot
        lock.lock()
        defer { lock.unlock() }
        return SpikeReport(output: (output as? NullOutputSink)?.timing.summary(),
                           outputStatus: status,
                           renderLoop: renderLoopTiming.summary(),
                           gpuMeanMs: gpu.mean, gpuMaxMs: gpu.max,
                           encodeMeanMs: encode.mean, encodeMaxMs: encode.max,
                           skippedTicks: skipped, videoUnderruns: video.underruns,
                           renderErrors: errors, renderLoopLate: renderLoopTiming.lateEvents())
    }

    /// One status line per hardware output (card counters, follower skips and repeats).
    private func progressLines(separator: String = "\n") -> String {
        var lines: [String] = []
        if let paced = output as? PacedOutputSink { lines.append("[\(paced.name)] \(paced.statusSummary())") }
        lock.lock()
        let skips = followerSkips, repeats = followerRepeats
        lock.unlock()
        for (i, follower) in followers.enumerated() {
            lines.append("[\(follower.name)] \(follower.statusSummary()) followerSkipped=\(skips[i]) followerRepeated=\(repeats[i])")
        }
        return lines.joined(separator: separator)
    }

    private var stopFlag = false

    private func setStop(_ value: Bool) {
        lock.lock()
        stopFlag = value
        lock.unlock()
    }

    private func inFlightCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    private func stopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopFlag
    }

    /// Render one frame for video time `t` and hand it to the output when the GPU finishes.
    /// Returns false (and renders nothing) when too many frames are already on the GPU.
    private func renderFrame(at t: Double) -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let busy = inFlight >= maxInFlight
        if !busy { inFlight += 1 }
        lock.unlock()
        if busy { return false }

        var layers: [LayerDraw] = []
        if let buffer = video.frame(at: t), let texture = compositor.makeTexture(from: buffer) {
            layers.append(LayerDraw(texture: texture))
        }
        text.update([
            TextLine(text: "CueME Stage engine spike", fontSize: 96, centerYFromTop: 440),
            TextLine(text: "t = \(Int(t)) s    \(String(format: "%.2f", (output as? PacedOutputSink)?.frameRate ?? targetFPS)) fps", fontSize: 44, centerYFromTop: 560),
            TextLine(text: output.name, fontSize: 32, centerYFromTop: 640),
        ])
        layers.append(LayerDraw(texture: text.layer))

        do {
            try compositor.render(layers) { [self] frame, gpuMs in
                gpuStats.add(gpuMs)
                output.submit(frame)
                for (i, follower) in followers.enumerated() {
                    let buffered = follower.bufferedFrames
                    if buffered >= follower.targetDepth + 1 {
                        lock.lock(); followerSkips[i] += 1; lock.unlock() // follower is ahead: drop
                    } else {
                        follower.submit(frame)
                        if buffered <= 1 && follower.targetDepth > 2 {
                            follower.submit(frame) // follower is running dry: repeat once
                            lock.lock(); followerRepeats[i] += 1; lock.unlock()
                        }
                    }
                }
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }
        } catch {
            lock.lock()
            inFlight -= 1
            errors += 1
            lock.unlock()
        }
        encodeStats.add(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000.0)
        return true
    }
}
