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
    /// Overlay messages visible on this screen, in the order they were shown.
    public var messages: [Message.ID]

    public init(screenID: Screen.ID, name: String, live: LiveSlide? = nil, messages: [Message.ID] = []) {
        self.screenID = screenID
        self.name = name
        self.live = live
        self.messages = messages
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
    /// Current sidechain reduction applied to the background, in dB. Always >= 0 and never -0: any value at or
    /// below zero (or NaN) is stored as 0. Use `duckingText` to show it.
    public var duckingReductionDB: Double {
        didSet { duckingReductionDB = Self.normalisedReduction(duckingReductionDB) }
    }
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
        self.duckingReductionDB = Self.normalisedReduction(duckingReductionDB)
        self.nextTrigger = nextTrigger
        self.counters = counters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liveTrack: try c.decodeIfPresent(MediaItem.ID.self, forKey: .liveTrack),
            transport: try c.decode(Transport.self, forKey: .transport),
            position: try c.decode(Double.self, forKey: .position),
            voicePlaying: try c.decode(Bool.self, forKey: .voicePlaying),
            duckingReductionDB: try c.decode(Double.self, forKey: .duckingReductionDB),
            nextTrigger: try c.decodeIfPresent(NextTrigger.self, forKey: .nextTrigger),
            counters: try c.decode(AudioCounters.self, forKey: .counters)
        )
    }

    /// A reduction as the operator reads it: "0.0 dB" when nothing is ducked, otherwise "-8.0 dB". Never "-0.0 dB",
    /// also for a reduction that rounds to zero.
    public var duckingText: String {
        let rounded = (Self.normalisedReduction(duckingReductionDB) * 10).rounded() / 10
        return rounded == 0 ? "0.0 dB" : String(format: "-%.1f dB", rounded)
    }

    static func normalisedReduction(_ db: Double) -> Double {
        // `db > 0` is false for -0, 0 and NaN; `+ 0` would keep the sign of -0, so return a literal 0.
        db > 0 ? db : 0
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

/// Which Studio the engine has loaded.
public struct StudioInfo: Codable, Sendable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A full snapshot of what is live. Views render this and nothing else.
public struct StageState: Codable, Sendable, Hashable {
    /// The loaded service, so the operator can pick items (read-only here; editing goes through commands).
    public var service: Service?
    /// The slides of every slide-based item in `service`, keyed by `Item.ID`, so the operator can see and pick them
    /// without the library. Items without slides (media, blank) have no entry.
    public var slides: [Item.ID: [Slide]]
    public var screens: [ScreenState]
    /// The slide `Command.next` would take live now (nil at the end of the service). Follows the engine's cursor,
    /// so after a clear it is still the slide after the one that was cleared.
    public var nextSlide: LiveSlide?
    public var blackout: Bool
    public var activeLook: Look.ID?
    /// The saved messages of the show, so the operator can pick one to show or hide.
    public var messages: [Message]
    public var visibleMessages: [Message.ID]
    public var runningTimers: [StageTimer.ID]
    public var audio: AudioState
    public var outputs: [OutputStatus]
    /// The looks of the show, so a screen's look can be picked.
    public var looks: [Look]
    /// Every connector the engine has, as it reports them. The app never adds, removes or edits one.
    public var connectors: [Connector]
    /// One entry per screen, in `screens` order.
    public var assignments: [OutputAssignment]
    /// Keyed by `Screen.ID`; every screen has one.
    public var screenSetups: [Screen.ID: ScreenSetup]
    /// The test pattern being sent, or nil.
    public var testPattern: ActiveTestPattern?
    /// The loaded Studio; nil when none is open.
    public var studio: StudioInfo?

    public init(
        service: Service? = nil, slides: [Item.ID: [Slide]] = [:], screens: [ScreenState] = [], nextSlide: LiveSlide? = nil,
        blackout: Bool = false, activeLook: Look.ID? = nil,
        messages: [Message] = [], visibleMessages: [Message.ID] = [], runningTimers: [StageTimer.ID] = [], audio: AudioState = AudioState(),
        outputs: [OutputStatus] = [], looks: [Look] = [], connectors: [Connector] = [], assignments: [OutputAssignment] = [],
        screenSetups: [Screen.ID: ScreenSetup] = [:], testPattern: ActiveTestPattern? = nil
    ) {
        self.service = service
        self.slides = slides
        self.screens = screens
        self.nextSlide = nextSlide
        self.blackout = blackout
        self.activeLook = activeLook
        self.messages = messages
        self.visibleMessages = visibleMessages
        self.runningTimers = runningTimers
        self.audio = audio
        self.outputs = outputs
        self.looks = looks
        self.connectors = connectors
        self.assignments = assignments
        self.screenSetups = screenSetups
        self.testPattern = testPattern
    }

    /// The live slide on the first output screen (all screens take the same slide in v0).
    public var primaryLive: LiveSlide? { outputScreens.first?.live }

    /// The screens that send a picture out (every type but `.input`). A screen without a setup counts as output.
    public var outputScreens: [ScreenState] { screens.filter { screenSetups[$0.screenID]?.type.isInput != true } }

    public func connectorID(for screenID: Screen.ID) -> Connector.ID? {
        assignments.first { $0.screenID == screenID }?.connectorID
    }

    public func connector(_ id: Connector.ID?) -> Connector? {
        guard let id else { return nil }
        return connectors.first { $0.id == id }
    }

    /// `outputWarnings` for this state.
    public var outputWarnings: [OutputWarning] {
        StageKit.outputWarnings(connectors: connectors, assignments: assignments, screenSetups: screenSetups)
    }
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
    case testPatternChanged(ActiveTestPattern?)
    case studioOpened(StudioInfo)
    case studioClosed(StudioInfo)
}
