import CoreVideo

/// A destination for finished frames: an SDI connector, an NDI sender,
/// a display, or a test sink. The compositor knows only this protocol.
public protocol OutputSink: AnyObject {
    /// Human-readable name, for logs and the output-setup UI.
    var name: String { get }

    /// Open the device and begin scheduled playback.
    func start() throws

    /// Hand one composited frame to the output. Must not block the render loop.
    func submit(_ frame: CVPixelBuffer)

    /// Stop playback and release the device.
    func stop()

    /// The pixel layout this output wants. The compositor produces it directly.
    var preferredFormat: OutputPixelFormat { get }
}

public extension OutputSink {
    var preferredFormat: OutputPixelFormat { .bgra }
}

public enum OutputError: Error, Equatable {
    /// The vendor SDK (DeckLink, NDI) is not installed in `vendor/`.
    case sdkNotInstalled(String)
    case deviceNotFound(String)
    case unsupportedMode(String)
}

/// Discards frames but records timing. Used to measure the render loop with no hardware.
public final class NullOutputSink: OutputSink {
    public let name: String
    public let timing: FrameTimingLogger

    public init(name: String = "null", targetFPS: Double = 60) {
        self.name = name
        self.timing = FrameTimingLogger(targetFPS: targetFPS)
    }

    public func start() throws { timing.reset() }
    public func submit(_ frame: CVPixelBuffer) { timing.recordFrame() }
    public func stop() {}
}

/// An output with its own hardware clock (for example an SDI card). The render loop is paced by
/// the output instead of a software timer, so the two can never drift apart.
public protocol PacedOutputSink: OutputSink {
    /// Frames per second of the output's own clock (59.94 for 1080p59.94).
    var frameRate: Double { get }

    /// Block until the output can take another frame, or until the timeout passes.
    /// Returns false on timeout or when the output has stopped.
    func waitForRoom(timeoutMs: Int) -> Bool

    /// Frames currently queued on the output, ahead of what it is showing.
    var bufferedFrames: Int { get }

    /// How many frames the output tries to keep queued.
    var targetDepth: Int { get }

    /// Zero the output's counters (called after warm-up so startup is not counted).
    func resetStatistics()

    /// Short human-readable status for the report (late and dropped counters, queue depth).
    func statusSummary() -> String
}
