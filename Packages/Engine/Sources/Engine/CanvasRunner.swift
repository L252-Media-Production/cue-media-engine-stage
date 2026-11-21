import CoreVideo
import Foundation
import Metal

/// Canvas test: renders one large canvas, cuts a virtual screen out of it for every output, and sends
/// the screens to their SDI outputs. The first output sets the pace; the others follow it (they skip or
/// repeat a frame if their own clock drifts), like `SpikeRunner`.
public final class CanvasRunner: @unchecked Sendable {
    private let compositor: CanvasCompositor
    private let master: [CompositionLayer]
    private let screens: [ScreenComposition]
    private let sources: [FrameSource]
    private let sinks: [PacedOutputSink]

    /// Called on the render thread just before each frame is drawn (frame number, time in seconds).
    /// Use it to update text layers and other changing content.
    public var willRender: ((UInt32, Double) -> Void)?

    private let renderLoopTiming: FrameTimingLogger
    private let gpuStats = RunningStats()
    private let encodeStats = RunningStats()
    private let lock = NSLock()
    private var inFlight = false
    private var stopFlag = false
    private var skippedFrames = 0
    private var errors = 0
    private var followerSkips: [Int]
    private var followerRepeats: [Int]

    /// - Parameters:
    ///   - master: the master composition's layers, bottom to top (spans the whole canvas).
    ///   - screens: one composition per screen, each with its own output in `sinks` (same order);
    ///     the first output sets the pace.
    public init(canvasWidth: Int, canvasHeight: Int, master: [CompositionLayer],
                screens: [ScreenComposition], sinks: [PacedOutputSink]) throws {
        guard !sinks.isEmpty, screens.count == sinks.count else {
            throw CompositorError.pipelineFailed("Each screen needs exactly one output (\(screens.count) screens, \(sinks.count) outputs).")
        }
        for sink in sinks where sink.preferredFormat != .yuv8 {
            throw CompositorError.pipelineFailed("Canvas outputs must take 8-bit YUV frames.")
        }
        compositor = try CanvasCompositor(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                          screens: screens.map { $0.region })
        self.master = master
        self.screens = screens
        self.sinks = sinks

        // Every distinct video source, started once and stopped at the end.
        var seen = Set<ObjectIdentifier>()
        var found: [FrameSource] = []
        for layer in master + screens.flatMap({ $0.layers }) {
            if case .video(let source) = layer.content, seen.insert(ObjectIdentifier(source)).inserted {
                found.append(source)
            }
        }
        sources = found
        followerSkips = Array(repeating: 0, count: sinks.count)
        followerRepeats = Array(repeating: 0, count: sinks.count)
        renderLoopTiming = FrameTimingLogger(targetFPS: sinks[0].frameRate)
    }

    public var device: MTLDevice { compositor.device }

    public func run(seconds: Double, warmup: Double = 2.0, reportEvery: Double = 0) throws -> SpikeReport {
        for sink in sinks { try sink.start() }
        for source in sources { source.start() }
        setStop(false)

        let lead = sinks[0]
        let frameDuration = 1.0 / lead.frameRate
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            RealtimeThread.promoteCurrentThread()
            var n: UInt32 = 0
            while !stopRequested() {
                guard lead.waitForRoom(timeoutMs: 100) else { continue }
                if isInFlight() {
                    Thread.sleep(forTimeInterval: 0.0005)
                    continue
                }
                if renderFrame(number: n, time: Double(n) * frameDuration) {
                    renderLoopTiming.recordFrame()
                    n &+= 1
                } else {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            finished.signal()
        }
        thread.name = "stage.engine.canvas"
        thread.qualityOfService = .userInteractive
        thread.start()

        if warmup > 0 {
            Thread.sleep(forTimeInterval: warmup)
            renderLoopTiming.reset()
            gpuStats.reset()
            encodeStats.reset()
            for sink in sinks { sink.resetStatistics() }
            lock.lock()
            skippedFrames = 0
            errors = 0
            followerSkips = Array(repeating: 0, count: sinks.count)
            followerRepeats = Array(repeating: 0, count: sinks.count)
            lock.unlock()
        }
        if reportEvery > 0 {
            var elapsed = 0.0
            while elapsed < seconds {
                let step = min(reportEvery, seconds - elapsed)
                Thread.sleep(forTimeInterval: step)
                elapsed += step
                if elapsed < seconds { print("--- progress \(Int(elapsed)) s / \(Int(seconds)) s ---\n\(statusLines())") }
            }
        } else {
            Thread.sleep(forTimeInterval: seconds)
        }

        setStop(true)
        _ = finished.wait(timeout: .now() + 1.0)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, isInFlight() { Thread.sleep(forTimeInterval: 0.005) }

        let status = statusLines(separator: "\n             ")
        for sink in sinks { sink.stop() }
        for source in sources { source.stop() }

        let gpu = gpuStats.snapshot
        let encode = encodeStats.snapshot
        lock.lock()
        defer { lock.unlock() }
        return SpikeReport(output: nil, outputStatus: status,
                           renderLoop: renderLoopTiming.summary(),
                           gpuMeanMs: gpu.mean, gpuMaxMs: gpu.max,
                           encodeMeanMs: encode.mean, encodeMaxMs: encode.max,
                           skippedTicks: skippedFrames, videoUnderruns: sources.reduce(0) { $0 + $1.underruns },
                           renderErrors: errors, renderLoopLate: renderLoopTiming.lateEvents())
    }

    private func statusLines(separator: String = "\n") -> String {
        lock.lock()
        let skips = followerSkips, repeats = followerRepeats
        lock.unlock()
        var lines: [String] = []
        for (i, sink) in sinks.enumerated() {
            var line = "[screen \(i + 1): \(sink.name)] \(sink.statusSummary())"
            if i > 0 { line += " followerSkipped=\(skips[i]) followerRepeated=\(repeats[i])" }
            lines.append(line)
        }
        return lines.joined(separator: separator)
    }

    /// This frame's pictures for a list of layers (hidden layers and sources without a frame yet are skipped).
    private func resolve(_ layers: [CompositionLayer], time: Double) -> [CanvasLayerDraw] {
        var draws: [CanvasLayerDraw] = []
        for layer in layers where layer.isVisible {
            switch layer.content {
            case .pattern:
                draws.append(CanvasLayerDraw.pattern(opacity: layer.opacity))
            case .video(let source):
                guard let buffer = source.frame(at: time), let texture = compositor.makeTexture(from: buffer) else { continue }
                draws.append(CanvasLayerDraw(texture: texture,
                                             contentWidth: CVPixelBufferGetWidth(buffer),
                                             contentHeight: CVPixelBufferGetHeight(buffer),
                                             rect: layer.rect, opacity: layer.opacity, fit: layer.fit))
            case .text(let text):
                draws.append(CanvasLayerDraw(texture: text.layer, contentWidth: text.width, contentHeight: text.height,
                                             rect: layer.rect, opacity: layer.opacity, fit: layer.fit))
            }
        }
        return draws
    }

    private func setStop(_ value: Bool) { lock.lock(); stopFlag = value; lock.unlock() }
    private func stopRequested() -> Bool { lock.lock(); defer { lock.unlock() }; return stopFlag }
    private func isInFlight() -> Bool { lock.lock(); defer { lock.unlock() }; return inFlight }

    private func renderFrame(number: UInt32, time: Double) -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if inFlight { lock.unlock(); return false }
        inFlight = true
        lock.unlock()

        willRender?(number, time)
        let masterDraws = resolve(master, time: time)
        let screenDraws = screens.map { CanvasScreenDraw(showMaster: $0.showMaster, layers: resolve($0.layers, time: time)) }
        do {
            try compositor.render(master: masterDraws, screens: screenDraws, frameNumber: number, time: time) {
                [self] frames, gpuMs in
                gpuStats.add(gpuMs)
                for (i, sink) in sinks.enumerated() where i < frames.count {
                    if i == 0 {
                        sink.submit(frames[0])
                        continue
                    }
                    let buffered = sink.bufferedFrames
                    if buffered >= sink.targetDepth + 1 {
                        lock.lock(); followerSkips[i] += 1; lock.unlock()   // follower is ahead: drop
                    } else {
                        sink.submit(frames[i])
                        if buffered <= 1 && sink.targetDepth > 2 {
                            sink.submit(frames[i])                           // follower is running dry
                            lock.lock(); followerRepeats[i] += 1; lock.unlock()
                        }
                    }
                }
                lock.lock()
                inFlight = false
                lock.unlock()
            }
        } catch {
            lock.lock()
            inFlight = false
            errors += 1
            lock.unlock()
        }
        encodeStats.add(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000.0)
        return true
    }
}
