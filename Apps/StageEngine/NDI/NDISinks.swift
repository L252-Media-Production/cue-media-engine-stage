import CoreVideo
import Engine
import Foundation

/// NDI output. It sends the same packed YUV frames as the SDI outputs, with no conversion.
///
/// As a follower of a hardware output it is fed at that output's pace. On its own (`clocked`) NDI
/// rate-limits the render loop to 59.94 fps.
final class NDIOutputSink: PacedOutputSink {
    let name: String
    let frameRate: Double = 60000.0 / 1001.0
    let targetDepth = 4
    /// NDI has no output queue to measure, so it always reports a neutral level (no skips or repeats).
    var bufferedFrames: Int { targetDepth }
    var preferredFormat: OutputPixelFormat { .yuv8 }

    private let sender: NDISenderBridge

    init(name: String, clocked: Bool) throws {
        sender = try NDISenderBridge(name: name, clockVideo: clocked)
        self.name = "NDI \"\(name)\"" + (clocked ? " (clocked)" : "")
    }

    func start() throws {}

    func submit(_ frame: CVPixelBuffer) {
        _ = sender.sendPackedYUV(frame)
    }

    func stop() {
        sender.stop()
    }

    func waitForRoom(timeoutMs: Int) -> Bool { true }

    func resetStatistics() {
        sender.resetStatistics()
    }

    func statusSummary() -> String {
        "ndi: sent=\(sender.framesSent) connections=\(sender.connectionCount())"
    }
}

/// A live NDI source used as the video input (for example the IMAG camera feed).
final class NDIFrameSource: FrameSource {
    private let receiver: NDIReceiverBridge

    var sourceName: String { receiver.sourceName }
    var framesReceived: UInt64 { receiver.framesReceived }
    var resolution: String { "\(receiver.width)x\(receiver.height)" }

    init(sourceContaining text: String, waitSeconds: Double) throws {
        receiver = try NDIReceiverBridge(sourceNameContaining: text, waitSeconds: waitSeconds)
    }

    func start() { receiver.start() }
    func stop() { receiver.stop() }

    private let lock = NSLock()
    private var lastSequence: UInt64 = 0
    private var shown: UInt64 = 0
    private var repeated: UInt64 = 0
    private var skipped: UInt64 = 0

    func frame(at t: Double) -> CVPixelBuffer? {
        guard let frame = receiver.copyLatestFrame() else { return nil }
        let sequence = receiver.latestSequence
        lock.lock()
        shown += 1
        if sequence == lastSequence {
            repeated += 1            // the same input frame was shown again
        } else if lastSequence != 0, sequence > lastSequence + 1 {
            skipped += sequence - lastSequence - 1   // input frames that never reached the output
        }
        lastSequence = sequence
        lock.unlock()
        return frame
    }

    /// How smoothly the live input reached the output: frames shown twice or never shown (counts
    /// include the warm-up). Zero repeats and skips means every input frame was shown exactly once.
    var cadenceSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return "output frames=\(shown) repeated input frames=\(repeated) skipped input frames=\(skipped)"
    }

    var underruns: Int { 0 }
}
