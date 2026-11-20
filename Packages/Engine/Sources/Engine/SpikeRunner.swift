import CoreVideo
import Foundation

public struct SpikeReport: CustomStringConvertible {
    public var output: FrameTimingSummary
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
        return """
        output     : \(output)
        render loop: \(renderLoop)
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
    public func run(seconds: Double, warmup: Double = 2.0) throws -> SpikeReport {
        try output.start()
        video.start()

        let startNanos = DispatchTime.now().uptimeNanoseconds
        let queue = DispatchQueue(label: "stage.engine.render", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = Int(1_000_000_000.0 / targetFPS)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .nanoseconds(0))
        timer.setEventHandler { [self] in tick(startNanos: startNanos) }
        timer.resume()

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
        timer.cancel()

        // Let frames already on the GPU finish.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock()
            let pending = inFlight
            lock.unlock()
            if pending == 0 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        output.stop()
        video.stop()

        let gpu = gpuStats.snapshot
        let encode = encodeStats.snapshot
        lock.lock()
        defer { lock.unlock() }
        let outputSummary = (output as? NullOutputSink)?.timing.summary()
            ?? FrameTimingSummary(frames: gpu.count, targetMs: 1000 / targetFPS, meanMs: 0,
                                  p99Ms: 0, maxMs: 0, lateFrames: 0)
        return SpikeReport(output: outputSummary, renderLoop: renderLoopTiming.summary(),
                           gpuMeanMs: gpu.mean, gpuMaxMs: gpu.max,
                           encodeMeanMs: encode.mean, encodeMaxMs: encode.max,
                           skippedTicks: skipped, videoUnderruns: video.underruns,
                           renderErrors: errors, renderLoopLate: renderLoopTiming.lateEvents())
    }

    private func tick(startNanos: UInt64) {
        renderLoopTiming.recordFrame()
        let tickStart = DispatchTime.now().uptimeNanoseconds
        let t = Double(tickStart &- startNanos) / 1_000_000_000.0

        lock.lock()
        let busy = inFlight >= maxInFlight
        if busy { skipped += 1 } else { inFlight += 1 }
        lock.unlock()
        if busy { return }

        var layers: [LayerDraw] = []
        if let buffer = video.frame(at: t), let texture = compositor.makeTexture(from: buffer) {
            layers.append(LayerDraw(texture: texture))
        }
        text.update([
            TextLine(text: "CueME Stage engine spike", fontSize: 96, centerYFromTop: 480),
            TextLine(text: "t = \(Int(t)) s    target \(Int(targetFPS)) fps", fontSize: 44, centerYFromTop: 600),
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
        encodeStats.add(Double(DispatchTime.now().uptimeNanoseconds &- tickStart) / 1_000_000.0)
    }
}
