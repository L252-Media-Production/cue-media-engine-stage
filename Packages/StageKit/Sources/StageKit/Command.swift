import Foundation

/// Version of the `Command` wire format. Bump it whenever a case is added, removed or changes shape.
public let commandVersion = 4

/// Everything the operator UI can ask the engine to do. Views never call an engine directly; every control
/// sends one of these through a `StageClient`.
public enum Command: Codable, Sendable, Hashable {
    public enum ClearTarget: String, Codable, Sendable {
        /// Live slide text on every screen.
        case slide
        /// Overlay messages.
        case messages
        /// Everything above (audio is not touched; use `clear(.audio)` or `stopAudio`).
        case all
        /// All audio: the live track and any voice-over on top. The engine may fade it out by the track's own
        /// fade-out; the mock stops it at once. Not part of `.all`.
        case audio
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
    /// Show a message on `screens`; an empty list means every screen. Showing a message that is already visible
    /// replaces the screens it is on.
    case showMessage(Message.ID, screens: [Screen.ID] = [])
    case hideMessage(Message.ID)
    case startTimer(StageTimer.ID)
    case stopTimer(StageTimer.ID)
    case resetTimer(StageTimer.ID)

    // Audio
    /// Start a track. `options` override the track's stored settings for this run only.
    case playAudio(mediaID: MediaItem.ID, options: AudioPlayOptions = AudioPlayOptions())
    case pauseAudio
    case resumeAudio
    case stopAudio
    /// Fade the live track out over `seconds`, then stop.
    case fadeAudio(seconds: Double)
    /// Seek the live track to `seconds` in the FILE.
    case seekAudio(seconds: Double)
    case skipNextTrigger

    // Output setup
    /// Send `screen` out of `connector` (in from it, for an input screen); nil unassigns. Refused when the connector
    /// is unknown, unavailable, of the wrong direction, or already used by another screen.
    case assignScreen(Screen.ID, connector: Connector.ID?)
    case setScreenSetup(Screen.ID, ScreenSetup)
    /// Replace what the target outputs show with a test pattern. The live slide is not changed.
    case showTestPattern(TestPatternTarget, TestPattern)
    case hideTestPattern

    // Studios
    /// Load the Studio with this id: everything live stops and its show data, screens and this machine's output
    /// assignments replace the current ones. (The engine will resolve the id itself; the mock is given a source.)
    case openStudio(UUID)
    /// Unload the Studio: nothing live, no service, no screens.
    case closeStudio
    /// The open Studio's show data changed on disk (items imported, media relinked): take the new content without
    /// stopping anything live.
    case reloadStudio(UUID)
}

/// Per-run overrides for `Command.playAudio`. Every field is optional: nil keeps the track's own setting.
public struct AudioPlayOptions: Codable, Sendable, Hashable {
    /// What happens when a pass of the track is over (docs/audio-spec-1.md, "End actions and pass counts").
    public enum EndAction: String, Codable, Sendable, CaseIterable {
        /// One pass, then the playlist play mode decides.
        case `default`
        /// Two passes, then as `default`.
        case once
        /// Passes without end.
        case loop
        /// One pass, then the run stops whatever the play mode is.
        case stop
    }

    /// Level of the track in percent, 0...100.
    public var volumePercent: Double?
    /// Fade-in at the start, seconds (>= 0; 0 = cut).
    public var fadeInSeconds: Double?
    /// nil is the same as `.default`.
    public var endAction: EndAction?

    public init(volumePercent: Double? = nil, fadeInSeconds: Double? = nil, endAction: EndAction? = nil) {
        self.volumePercent = volumePercent
        self.fadeInSeconds = fadeInSeconds
        self.endAction = endAction
    }

    /// The reason these options are refused, or nil when they are valid.
    public var invalidReason: String? {
        if let v = volumePercent, !(0...100).contains(v) { return "volume must be 0-100 %" }
        if let f = fadeInSeconds, !(f >= 0 && f.isFinite) { return "fade-in must be >= 0 s" }
        return nil
    }
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
