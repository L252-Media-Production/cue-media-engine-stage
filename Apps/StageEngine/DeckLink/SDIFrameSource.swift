import CoreVideo
import Engine
import Foundation

/// A live SDI input (for example the IMAG camera feed) captured on one DeckLink connector.
///
/// The card delivers packed 4:2:2 frames; they are converted to BGRA on the GPU the first time the
/// render loop asks for each new frame (a frame that is shown twice is converted once).
final class SDIFrameSource: FrameSource {
    private let bridge: DeckLinkInputBridge
    private let unpacker: YUV422Unpacker

    var deviceName: String { bridge.deviceName }
    var framesCaptured: UInt64 { bridge.framesCaptured }

    init(deviceIndex: Int, buffer: Int = 2) throws {
        bridge = try DeckLinkInputBridge(deviceIndex: deviceIndex)
        self.buffer = max(1, buffer)
        self.unpacker = try YUV422Unpacker()
    }

    func start() {
        do {
            try bridge.start()
        } catch {
            print("SDI input failed to start: \(error.localizedDescription)")
        }
    }

    func stop() { bridge.stop() }

    private let lock = NSLock()
    private var primed = false
    private var cached: CVPixelBuffer?
    private var shown: UInt64 = 0
    private var repeated: UInt64 = 0
    private var skipped: UInt64 = 0
    private var queueSum: UInt64 = 0

    /// Captured frames are taken in order, one per output frame. The queue is kept near `buffer` frames
    /// deep: that depth absorbs the timing jitter between the capture clock and the render loop (taking
    /// "the newest frame" instead makes jitter show up as a repeated frame followed by a skipped one).
    /// A frame is repeated only when the queue runs empty and skipped only when it grows too deep, which
    /// happens when the two clocks drift apart.
    func frame(at t: Double) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if !primed {
            guard bridge.queuedFrames >= buffer else { return cached }
            primed = true
        }
        shown += 1

        // Too deep: the capture clock is running ahead. Drop the oldest frames.
        while bridge.queuedFrames > buffer + 1 {
            if bridge.dropOldestFrame() { skipped += 1 } else { break }
        }
        queueSum += UInt64(max(0, bridge.queuedFrames))

        guard let packed = bridge.popFrame() else {
            repeated += 1          // queue ran dry: show the last frame again
            return cached
        }
        if let converted = unpacker.unpack(packed) { cached = converted }
        return cached
    }

    /// Frames kept queued between capture and output (about 16.7 ms each).
    let buffer: Int

    /// One line about the capture: signal, format, frame counts.
    var captureSummary: String {
        let mode = bridge.detectedMode.isEmpty ? "no format detected" : bridge.detectedMode
        var text = "\(bridge.deviceName): \(mode), signal=\(bridge.signalPresent ? "yes" : "NO"), captured=\(bridge.framesCaptured) no-signal frames=\(bridge.framesNoSignal) rejected=\(bridge.framesRejected) format changes=\(bridge.formatChanges)"
        if bridge.unsupportedSignal { text += "  [UNSUPPORTED FORMAT: only 1920x1080 is handled]" }
        return text
    }

    /// How smoothly the capture reached the output: frames shown twice or never shown. With the source
    /// and the output on different clocks a repeat or a skip every so often is expected; the interval
    /// tells how far apart the two clocks run.
    var cadenceSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let mean = shown > 0 ? Double(queueSum) / Double(shown) : 0
        return String(format: "output frames=%llu repeated input frames=%llu skipped input frames=%llu (queue target %ld, mean depth %.2f, overflowed %llu)",
                      shown, repeated, skipped, buffer, mean, bridge.framesOverflowed)
    }

    var conversionSummary: String {
        String(format: "unpack: mean=%.3f ms max=%.3f ms", unpacker.meanMs, unpacker.maxMs)
    }

    var underruns: Int { 0 }
}
