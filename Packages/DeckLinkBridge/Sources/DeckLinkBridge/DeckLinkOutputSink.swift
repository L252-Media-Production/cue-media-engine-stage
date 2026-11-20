import CoreVideo
import Engine

/// SDI output through a Blackmagic DeckLink connector.
/// Stub: `start()` reports that the SDK wrapper is not built yet.
public final class DeckLinkOutputSink: OutputSink {
    public let name: String
    public let deviceIndex: Int
    public let connector: Int

    public init(deviceIndex: Int, connector: Int) {
        self.deviceIndex = deviceIndex
        self.connector = connector
        self.name = "DeckLink \(deviceIndex) / SDI \(connector)"
    }

    public func start() throws {
        throw OutputError.sdkNotInstalled("DeckLink wrapper not built. See docs/sdk-setup.md.")
    }

    public func submit(_ frame: CVPixelBuffer) {}
    public func stop() {}
}
