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

    init(deviceIndex: Int) throws {
        bridge = try DeckLinkInputBridge(deviceIndex: deviceIndex)
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
    private var lastSequence: UInt64 = 0
    private var cached: CVPixelBuffer?
    private var shown: UInt64 = 0
    private var repeated: UInt64 = 0
    private var skipped: UInt64 = 0

    func frame(at t: Double) -> CVPixelBuffer? {
        let sequence = bridge.latestSequence
        guard sequence != 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }
        shown += 1
        if sequence == lastSequence {
            repeated += 1
            return cached
        }
        if lastSequence != 0, sequence > lastSequence + 1 {
            skipped += sequence - lastSequence - 1
        }
        guard let packed = bridge.copyLatestFrame() else { return cached }
        lastSequence = sequence
        if let converted = unpacker.unpack(packed) { cached = converted }
        return cached
    }

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
        return "output frames=\(shown) repeated input frames=\(repeated) skipped input frames=\(skipped)"
    }

    var conversionSummary: String {
        String(format: "unpack: mean=%.3f ms max=%.3f ms", unpacker.meanMs, unpacker.maxMs)
    }

    var underruns: Int { 0 }
}
