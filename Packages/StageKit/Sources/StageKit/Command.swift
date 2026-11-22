import Foundation

/// Version of the `Command` wire format. Bump it whenever a case is added, removed or changes shape.
public let commandVersion = 1

/// Everything the operator UI can ask the engine to do. Views never call an engine directly; every control
/// sends one of these through a `StageClient`.
public enum Command: Codable, Sendable, Hashable {
    public enum ClearTarget: String, Codable, Sendable {
        /// Live slide text on every screen.
        case slide
        /// Overlay messages.
        case messages
        /// Everything above (audio is not touched; use `stopAudio`).
        case all
    }

    // Slides
    /// Take slide `slideIndex` of `itemID` live on every screen.
    case go(itemID: Item.ID, slideIndex: Int)
    /// Next slide (moves to the next item's first slide at the end of an item).
    case next
    /// Previous slide (moves to the previous item's last slide at the start of an item).
    case previous
    case clear(ClearTarget)
    case blackout(Bool)

    // Looks, messages and timers
    case applyLook(Look.ID)
    case showMessage(Message.ID)
    case hideMessage(Message.ID)
    case startTimer(StageKit.Timer.ID)
    case stopTimer(StageKit.Timer.ID)
    case resetTimer(StageKit.Timer.ID)

    // Audio
    case playAudio(mediaID: MediaItem.ID)
    case pauseAudio
    case resumeAudio
    case stopAudio
    /// Fade the live track out over `seconds`, then stop.
    case fadeAudio(seconds: Double)
    /// Seek the live track to `seconds` in the FILE.
    case seekAudio(seconds: Double)
    case skipNextTrigger
}

/// A command as sent over the wire: the version travels with it so the engine can refuse a mismatch.
public struct CommandEnvelope: Codable, Sendable, Hashable {
    public var version: Int
    public var command: Command

    public init(_ command: Command, version: Int = commandVersion) {
        self.version = version
        self.command = command
    }
}
