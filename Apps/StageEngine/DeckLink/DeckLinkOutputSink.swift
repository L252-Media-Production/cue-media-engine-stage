import CoreVideo
import Engine
import Foundation

/// SDI output through one DeckLink connector, paced by the card's own clock (1080p59.94).
final class DeckLinkOutputSink: PacedOutputSink {
    let name: String
    let frameRate: Double

    private let bridge: DeckLinkOutputBridge
    let targetDepth: Int
    var bufferedFrames: Int { Int(bridge.counters().buffered) }

    /// DeckLink SDI outputs take YUV, not BGRA.
    var preferredFormat: OutputPixelFormat { .yuv8 }

    /// - Parameters:
    ///   - deviceIndex: position in the driver's device list (see `--list-decklink`).
    ///   - depth: frames queued on the card before playback starts and kept ahead of it.
    init(deviceIndex: Int, depth: Int) throws {
        bridge = try DeckLinkOutputBridge(deviceIndex: deviceIndex, depth: depth)
        targetDepth = depth
        name = "\(bridge.deviceName) (index \(deviceIndex), depth \(depth))"
        frameRate = bridge.frameRate
    }

    func start() throws {
        try bridge.startOutput()
    }

    func submit(_ frame: CVPixelBuffer) {
        _ = bridge.submitFrame(frame)
    }

    func stop() {
        bridge.stop()
    }

    func waitForRoom(timeoutMs: Int) -> Bool {
        bridge.waitForRoom(withTimeout: timeoutMs)
    }

    func resetStatistics() {
        bridge.resetStatistics()
    }

    func statusSummary() -> String {
        let c = bridge.counters()
        let low = c.minBuffered == UInt32.max ? "n/a" : "\(c.minBuffered)"
        return "card: scheduled=\(c.scheduled) completed=\(c.completed) late=\(c.displayedLate) "
            + "dropped=\(c.dropped) flushed=\(c.flushed) buffered=\(c.buffered) lowestBuffered=\(low)/\(targetDepth)"
    }
}
