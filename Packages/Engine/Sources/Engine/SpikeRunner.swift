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
    private let targetFPS: Double
    private let maxInFlight = 3

    private let renderLoopTiming: FrameTimingLogger
    private let gpuStats = RunningStats()
    private let encodeStats = RunningStats()
    private let lock = NSLock()
    private var inFlight = 0
    private var skipped = 0
    private var errors = 0

    public init(videoURL: URL, output: OutputSink, width: Int = 1920, height: Int = 1080,
                targetFPS: Double = 60) async throws {
        let compositor = try Compositor(width: width, height: height)
        let text = try TextLayer(device: compositor.device, width: width, height: height)
        let video = try await VideoLoopSource.open(url: videoURL)
        self.compositor = compositor
        self.text = text
        self.video = video
        self.output = output
        self.targetFPS = targetFPS
        self.renderLoopTiming = FrameTimingLogger(targetFPS: targetFPS)
    }

    /// Run for `seconds` of measurement, after an unmeasured `warmup`, then stop and return the
    /// timing report. Blocks the calling thread.
    ///
    /// With a `PacedOutputSink` the render loop is paced by the output's own clock and video time
    /// is counted in output frames. Otherwise a 60 Hz software timer drives it.
    public func run(seconds: Double, warmup: Double = 2.0) throws -> SpikeReport {
        try output.start()
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
                    renderLoopTiming.recordFrame()
                    if renderFrame(at: Double(n) * frameDuration) { n += 1 } else {
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
            lock.lock()
            skipped = 0
            errors = 0
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: seconds)

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

        let status = (output as? PacedOutputSink)?.statusSummary() ?? ""
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

    private var stopFlag = false

    private func setStop(_ value: Bool) {
        lock.lock()
        stopFlag = value
        lock.unlock()
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
