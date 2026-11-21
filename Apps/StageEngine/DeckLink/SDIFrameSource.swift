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
    private var waitSumMs = 0.0
    private var waitMaxMs = 0.0
    private var waitCount = 0

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
            // Frames that piled up before the first render tick would otherwise stay in the queue for
            // good (the drift trim below only acts above buffer + 1). Start at exactly `buffer` frames.
            while bridge.queuedFrames > buffer {
                if !bridge.dropOldestFrame() { break }
            }
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
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let waitMs = Double(nowNanos &- bridge.lastPopArrivalNanos) / 1_000_000.0
        recordStamp(packed, arrivalNanos: bridge.lastPopArrivalNanos, nowNanos: nowNanos)
        waitSumMs += waitMs
        waitMaxMs = max(waitMaxMs, waitMs)
        waitCount += 1
        if let converted = unpacker.unpack(packed) { cached = converted }
        return cached
    }

    private var stampCount = 0
    private var stampMissing = 0
    private var loopSumMs = 0.0, loopMinMs = Double.infinity, loopMaxMs = 0.0
    private var totalSumMs = 0.0, totalMaxMs = 0.0

    /// Reads the clock stamp that `--canvas` draws (16 blocks at the bottom left of the first screen:
    /// white = 1) from the packed frame. Block centre x = 36 + 48 k, y = 1080 - 112 = 968; luma of an
    /// even pixel is byte 1 of its 4-byte "Cb Y0 Cr Y1" group. Gives the time from the source rendering
    /// the frame to this frame arriving here (loop) and to it being rendered here (total).
    private func recordStamp(_ packed: CVPixelBuffer, arrivalNanos: UInt64, nowNanos: UInt64) {
        CVPixelBufferLockBaseAddress(packed, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(packed, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(packed) else { return }
        let row = base.advanced(by: 968 * CVPixelBufferGetBytesPerRow(packed)).assumingMemoryBound(to: UInt8.self)
        var stamp: UInt32 = 0
        var bright = 0, dark = 0
        for k in 0..<16 {
            let luma = row[((36 + 48 * k) / 2) * 4 + 1]
            if luma > 126 { stamp |= 1 << UInt32(15 - k); bright += 1 } else if luma < 70 { dark += 1 }
        }
        if bright + dark != 16 { stampMissing += 1; return }       // some block was neither black nor white
        func ms(_ nanos: UInt64) -> Double { Double((nanos / 1_000_000) & 0xFFFF) }
        let loop = (ms(arrivalNanos) - Double(stamp) + 65536).truncatingRemainder(dividingBy: 65536)
        let total = (ms(nowNanos) - Double(stamp) + 65536).truncatingRemainder(dividingBy: 65536)
        guard total < 5000 else { stampMissing += 1; return }      // not a stamp from this clock
        stampCount += 1
        loopSumMs += loop; loopMinMs = min(loopMinMs, loop); loopMaxMs = max(loopMaxMs, loop)
        totalSumMs += total; totalMaxMs = max(totalMaxMs, total)
    }

    /// Latency read from the source's clock stamp. Empty when the source has none.
    var stampSummary: String {
        lock.lock()
        defer { lock.unlock() }
        guard stampCount > 0 else { return "no clock stamp seen (the source must be a --canvas run on this Mac); frames without a stamp: \(stampMissing)" }
        let n = Double(stampCount)
        return String(format: "source render to capture arrival: mean=%.1f min=%.1f max=%.1f ms; source render to render here: mean=%.1f max=%.1f ms (%d frames, %d without stamp)",
                      loopSumMs / n, loopMinMs, loopMaxMs, totalSumMs / n, totalMaxMs, stampCount, stampMissing)
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
        lock.lock()
        defer { lock.unlock() }
        let wait = waitCount > 0 ? waitSumMs / Double(waitCount) : 0
        return String(format: "unpack: mean=%.3f ms max=%.3f ms; waited in capture queue: mean=%.1f ms max=%.1f ms (arrival to render)",
                      unpacker.meanMs, unpacker.maxMs, wait, waitMaxMs)
    }

    var underruns: Int { 0 }
}
