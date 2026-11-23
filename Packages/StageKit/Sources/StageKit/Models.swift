import Foundation

// Content models. Everything is a value type, Codable and Sendable, identified by a stable UUID.

/// One slide of a song (or of any slide-based item).
public struct Slide: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Short operator label, e.g. "Verse 1" or "Chorus".
    public var label: String
    public var lines: [String]

    public init(id: UUID = UUID(), label: String, lines: [String]) {
        self.id = id
        self.label = label
        self.lines = lines
    }
}

/// A song. Every field after `slides` is optional and left out of the JSON while nil, so a song written before they
/// existed reads and writes back byte for byte (see docs/studio-file-format.md, "Songs").
public struct Song: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var author: String?
    public var slides: [Slide]
    /// The one collection the song belongs to (`StudioCollection.id`); nil = none.
    public var collectionID: UUID?

    public init(id: UUID = UUID(), title: String, author: String? = nil, slides: [Slide], collectionID: UUID? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.slides = slides
        self.collectionID = collectionID
    }
}

/// A media file (audio or video). The `id` is the identity: per-track settings are keyed by it
/// (see `AudioSettings.mediaID`), never by `location`, so moving or relinking the file keeps them.
public struct MediaItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case audio, video, image }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Where the file currently is. Informational only; never used as a key.
    public var location: String
    /// Length of the file in seconds, when known.
    public var duration: Double?

    public init(id: UUID = UUID(), name: String, kind: Kind, location: String, duration: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.duration = duration
    }
}

/// A voice-over fired when the live track's playhead crosses `at` (seconds in the FILE).
public struct TriggerPoint: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var at: Double
    public var voiceMediaID: MediaItem.ID
    public var once: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), at: Double, voiceMediaID: MediaItem.ID, once: Bool = false, enabled: Bool = true) {
        self.id = id
        self.at = at
        self.voiceMediaID = voiceMediaID
        self.once = once
        self.enabled = enabled
    }
}

/// Per-track audio settings. Hangs off `MediaItem.id`, never a path.
public struct AudioSettings: Codable, Sendable, Identifiable, Hashable {
    public var id: MediaItem.ID { mediaID }
    public var mediaID: MediaItem.ID
    /// Trim window `[trimIn, trimOut)` in seconds; nil = start / end of the file.
    public var trimIn: Double?
    public var trimOut: Double?
    public var levelDB: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Level of this track when played on top (voice-over), in percent.
    public var topTrackPct: Double
    public var triggers: [TriggerPoint]

    public init(
        mediaID: MediaItem.ID, trimIn: Double? = nil, trimOut: Double? = nil, levelDB: Double = 0,
        fadeIn: Double = 0, fadeOut: Double = 0, topTrackPct: Double = 100, triggers: [TriggerPoint] = []
    ) {
        self.mediaID = mediaID
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.levelDB = levelDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.topTrackPct = topTrackPct
        self.triggers = triggers
    }
}

/// One entry in a service (show / playlist).
public struct Item: Codable, Sendable, Identifiable, Hashable {
    public enum Content: Codable, Sendable, Hashable {
        case song(Song.ID)
        case media(MediaItem.ID)
        case blank
    }

    public var id: UUID
    public var title: String
    public var content: Content
    /// Number of slides the operator can step through (songs); 0 for media and blank items.
    public var slideCount: Int

    public init(id: UUID = UUID(), title: String, content: Content, slideCount: Int = 0) {
        self.id = id
        self.title = title
        self.content = content
        self.slideCount = slideCount
    }
}

public struct Service: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var items: [Item]

    public init(id: UUID = UUID(), name: String, items: [Item]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

/// A named visual style (background, text style) applied to the output.
public struct Look: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var backgroundMediaID: MediaItem.ID?
    public var fontName: String?
    public var fontSize: Double?

    public init(id: UUID = UUID(), name: String, backgroundMediaID: MediaItem.ID? = nil, fontName: String? = nil, fontSize: Double? = nil) {
        self.id = id
        self.name = name
        self.backgroundMediaID = backgroundMediaID
        self.fontName = fontName
        self.fontSize = fontSize
    }
}

/// An overlay message (e.g. "Parking lot B: lights on").
public struct Message: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// A countdown or count-up timer. Called `StageTimer` (not `Timer`) so it never clashes with `Foundation.Timer`.
public struct StageTimer: Codable, Sendable, Identifiable, Hashable {
    public enum Mode: String, Codable, Sendable { case countdown, countUp }

    public var id: UUID
    public var name: String
    public var mode: Mode
    /// Countdown length in seconds (ignored for count-up).
    public var duration: Double

    public init(id: UUID = UUID(), name: String, mode: Mode, duration: Double = 0) {
        self.id = id
        self.name = name
        self.mode = mode
        self.duration = duration
    }
}

/// A screen of the show: a rectangle of the canvas (audience), a stage display, or an input (IMAG). The rect is the
/// screen's starting canvas position; the live setup is `StageState.screenSetups`.
public struct Screen: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var type: ScreenType
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var outputID: Output.ID?

    public init(id: UUID = UUID(), name: String, type: ScreenType, x: Int = 0, y: Int = 0, width: Int = 1920, height: Int = 1080, outputID: Output.ID? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.outputID = outputID
    }
}

/// A physical or network output (SDI port, NDI sender).
public struct Output: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case sdi, ndi }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// DeckLink device index for SDI, sender name for NDI.
    public var address: String

    public init(id: UUID = UUID(), name: String, kind: Kind, address: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.address = address
    }
}

/// Everything a show file holds. The engine (or the mock) resolves command ids against it.
public struct Library: Codable, Sendable, Hashable {
    public var service: Service
    public var songs: [Song]
    public var media: [MediaItem]
    /// Keyed by `MediaItem.id`.
    public var audioSettings: [MediaItem.ID: AudioSettings]
    public var looks: [Look]
    public var messages: [Message]
    public var timers: [StageTimer]
    public var screens: [Screen]
    public var outputs: [Output]
    /// Layouts by screen (look, canvas, rotation). A screen without one starts from its own type and rect.
    public var screenSetups: [Screen.ID: ScreenSetup]

    public init(
        service: Service, songs: [Song] = [], media: [MediaItem] = [], audioSettings: [MediaItem.ID: AudioSettings] = [:],
        looks: [Look] = [], messages: [Message] = [], timers: [StageTimer] = [], screens: [Screen] = [], outputs: [Output] = [],
        screenSetups: [Screen.ID: ScreenSetup] = [:]
    ) {
        self.service = service
        self.songs = songs
        self.media = media
        self.audioSettings = audioSettings
        self.looks = looks
        self.messages = messages
        self.timers = timers
        self.screens = screens
        self.outputs = outputs
        self.screenSetups = screenSetups
    }

    /// Nothing loaded: no service, no screens.
    public static let empty = Library(service: Service(name: "No Studio", items: []))

    public func song(_ id: Song.ID) -> Song? { songs.first { $0.id == id } }
    public func mediaItem(_ id: MediaItem.ID) -> MediaItem? { media.first { $0.id == id } }
}
