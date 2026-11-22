import Foundation

/// The slide currently live on a screen. Carries its text so a view never has to look content up.
public struct LiveSlide: Codable, Sendable, Hashable {
    public var itemID: Item.ID
    public var slideIndex: Int
    public var slideID: Slide.ID
    public var label: String
    public var lines: [String]

    public init(itemID: Item.ID, slideIndex: Int, slideID: Slide.ID, label: String, lines: [String]) {
        self.itemID = itemID
        self.slideIndex = slideIndex
        self.slideID = slideID
        self.label = label
        self.lines = lines
    }
}

public struct ScreenState: Codable, Sendable, Hashable, Identifiable {
    public var id: Screen.ID { screenID }
    public var screenID: Screen.ID
    public var name: String
    public var live: LiveSlide?

    public init(screenID: Screen.ID, name: String, live: LiveSlide? = nil) {
        self.screenID = screenID
        self.name = name
        self.live = live
    }
}

/// Monotonic engine counters (see docs/audio-engine-realtime.md). None should ever be non-zero in a normal show.
public struct AudioCounters: Codable, Sendable, Hashable {
    public var droppedEnds: Int
    public var droppedFires: Int
    public var poolExhausted: Int

    public init(droppedEnds: Int = 0, droppedFires: Int = 0, poolExhausted: Int = 0) {
        self.droppedEnds = droppedEnds
        self.droppedFires = droppedFires
        self.poolExhausted = poolExhausted
    }

    public var isClean: Bool { droppedEnds == 0 && droppedFires == 0 && poolExhausted == 0 }
}

public struct NextTrigger: Codable, Sendable, Hashable {
    public var triggerID: TriggerPoint.ID
    /// Position in the FILE, seconds.
    public var at: Double
    public var voiceMediaID: MediaItem.ID

    public init(triggerID: TriggerPoint.ID, at: Double, voiceMediaID: MediaItem.ID) {
        self.triggerID = triggerID
        self.at = at
        self.voiceMediaID = voiceMediaID
    }
}

/// Audio as the operator sees it. Deliberately small: no decks, gains or curves.
public struct AudioState: Codable, Sendable, Hashable {
    public enum Transport: String, Codable, Sendable { case stopped, playing, paused, fading }

    public var liveTrack: MediaItem.ID?
    public var transport: Transport
    /// Playhead of the live track, seconds in the FILE.
    public var position: Double
    public var voicePlaying: Bool
    /// Current sidechain reduction applied to the background, in dB (>= 0).
    public var duckingReductionDB: Double
    public var nextTrigger: NextTrigger?
    public var counters: AudioCounters

    public init(
        liveTrack: MediaItem.ID? = nil, transport: Transport = .stopped, position: Double = 0, voicePlaying: Bool = false,
        duckingReductionDB: Double = 0, nextTrigger: NextTrigger? = nil, counters: AudioCounters = AudioCounters()
    ) {
        self.liveTrack = liveTrack
        self.transport = transport
        self.position = position
        self.voicePlaying = voicePlaying
        self.duckingReductionDB = duckingReductionDB
        self.nextTrigger = nextTrigger
        self.counters = counters
    }
}

public struct OutputStatus: Codable, Sendable, Hashable, Identifiable {
    public enum Health: String, Codable, Sendable { case ok, degraded, offline }

    public var id: Output.ID { outputID }
    public var outputID: Output.ID
    public var name: String
    public var health: Health
    public var droppedFrames: Int

    public init(outputID: Output.ID, name: String, health: Health = .ok, droppedFrames: Int = 0) {
        self.outputID = outputID
        self.name = name
        self.health = health
        self.droppedFrames = droppedFrames
    }
}

/// A full snapshot of what is live. Views render this and nothing else.
public struct StageState: Codable, Sendable, Hashable {
    /// The loaded service, so the operator can pick items (read-only here; editing goes through commands).
    public var service: Service?
    public var screens: [ScreenState]
    public var blackout: Bool
    public var activeLook: Look.ID?
    public var visibleMessages: [Message.ID]
    public var runningTimers: [StageKit.Timer.ID]
    public var audio: AudioState
    public var outputs: [OutputStatus]

    public init(
        service: Service? = nil, screens: [ScreenState] = [], blackout: Bool = false, activeLook: Look.ID? = nil,
        visibleMessages: [Message.ID] = [], runningTimers: [StageKit.Timer.ID] = [], audio: AudioState = AudioState(),
        outputs: [OutputStatus] = []
    ) {
        self.service = service
        self.screens = screens
        self.blackout = blackout
        self.activeLook = activeLook
        self.visibleMessages = visibleMessages
        self.runningTimers = runningTimers
        self.audio = audio
        self.outputs = outputs
    }

    /// The live slide on the first screen (all screens take the same slide in v0).
    public var primaryLive: LiveSlide? { screens.first?.live }
}

/// Something that happened, for logs, toasts and status flashes. State changes are also in the next snapshot.
public enum StageEvent: Codable, Sendable, Hashable {
    case commandRejected(Command, reason: String)
    case slideLive(LiveSlide)
    case cleared(Command.ClearTarget)
    case blackoutChanged(Bool)
    case audioStarted(mediaID: MediaItem.ID)
    case audioEnded(mediaID: MediaItem.ID)
    case triggerFired(triggerID: TriggerPoint.ID, voiceMediaID: MediaItem.ID)
    case triggerSkipped(triggerID: TriggerPoint.ID)
    case countersChanged(AudioCounters)
    case outputHealthChanged(OutputStatus)
}
