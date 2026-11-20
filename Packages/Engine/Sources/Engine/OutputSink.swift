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
