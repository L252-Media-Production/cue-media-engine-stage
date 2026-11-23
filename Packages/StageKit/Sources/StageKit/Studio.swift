import Foundation

// A Studio is a saved, reopenable set of show data: a package folder `<Name>.stg` (see docs/studio-file-format.md).
// This file holds the models only. Reading and writing the folder is the app's job; `StudioCodec` turns a Studio
// into the package's files (path -> bytes) and back.

public enum StudioFormat {
    public static let format = "cueme-stage-studio"
    /// The newest format this build reads and the one it writes.
    public static let currentVersion = 1
    public static let packageExtension = "stg"
    public static let bundleExtension = "stgbundle"
    public static let itemExtension = "stgitem"
}

/// manifest.json.
public struct StudioManifest: Codable, Sendable, Hashable {
    public var format: String
    public var formatVersion: Int
    /// Stable for the life of the Studio. Output assignments on a machine are keyed by it; a copy gets a new one.
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    /// The CueME Stage version that last wrote the Studio.
    public var appVersion: String
    /// The service that opens with the Studio; nil = the first service by name.
    public var activeServiceID: Service.ID?

    public init(id: UUID = UUID(), name: String, created: Date, modified: Date? = nil, appVersion: String,
                activeServiceID: Service.ID? = nil, formatVersion: Int = StudioFormat.currentVersion) {
        self.format = StudioFormat.format
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified ?? created
        self.appVersion = appVersion
        self.activeServiceID = activeServiceID
    }
}

/// One entry of media.json. The file itself is never inside the Studio; it lives in a media folder of the machine
/// and is found again by `sha256`, then by file name and size (see the relink scanner).
public struct MediaIndexEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: MediaItem.ID
    public var name: String
    public var kind: MediaItem.Kind
    public var duration: Double?
    /// Bytes; nil until the file has been seen.
    public var size: Int64?
    /// Lowercase hex; nil until the file has been hashed.
    public var sha256: String?
    /// Where the file was last found on any machine. A hint, never a key.
    public var lastKnownPath: String?

    public init(id: MediaItem.ID, name: String, kind: MediaItem.Kind, duration: Double? = nil, size: Int64? = nil,
                sha256: String? = nil, lastKnownPath: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.duration = duration
        self.size = size
        self.sha256 = sha256
        self.lastKnownPath = lastKnownPath
    }

    /// The file name used for the name + size fallback: the last path component of `lastKnownPath`, else `name`.
    public var fileName: String {
        guard let path = lastKnownPath, !path.isEmpty else { return name }
        return (path as NSString).lastPathComponent
    }
}

/// A screen as the Studio keeps it: identity, name and layout. No connector: which connector drives a screen is a
/// property of the machine, not of the show.
public struct StudioScreen: Codable, Sendable, Hashable, Identifiable {
    public var id: Screen.ID
    public var name: String
    public var setup: ScreenSetup

    public init(id: Screen.ID = UUID(), name: String, setup: ScreenSetup) {
        self.id = id
        self.name = name
        self.setup = setup
    }
}

/// collections.json: a named collection of slide-bearing library items (songs now; presentations and announcements
/// later). Media is never in a collection. A song names its collection (`Song.collectionID`), so it is in at most one.
public struct StudioCollection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The look the collection's items use; nil = the default. Not editable until Looks exist in the editor.
    public var lookID: Look.ID?

    public init(id: UUID = UUID(), name: String, lookID: Look.ID? = nil) {
        self.id = id
        self.name = name
        self.lookID = lookID
    }
}

/// A header row in a service's item list ("Pre-service", "Worship"). Stored in the service's file under `sections`,
/// never in `Service.items`, so the engine's item order (and its cursor) is not touched by adding one.
public struct ServiceSection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// The item the header sits above. nil, or an item no longer in the service: the header goes to the end.
    public var firstItemID: Item.ID?

    public init(id: UUID = UUID(), name: String, firstItemID: Item.ID? = nil) {
        self.id = id
        self.name = name
        self.firstItemID = firstItemID
    }
}

/// library/<id>.json: one library item. Only songs exist so far; "presentation" is reserved for UI-3b.
public struct LibraryItemFile: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case song }
    public var kind: Kind
    public var song: Song?

    public init(song: Song) {
        self.kind = .song
        self.song = song
    }
}

/// lock.json: who has the Studio open. A warning, never a block.
public struct StudioLock: Codable, Sendable, Hashable {
    /// Stable per install (kept in the machine folder).
    public var machineID: UUID
    public var machineName: String
    public var pid: Int32
    public var openedAt: Date
    public var appVersion: String

    public init(machineID: UUID, machineName: String, pid: Int32, openedAt: Date, appVersion: String) {
        self.machineID = machineID
        self.machineName = machineName
        self.pid = pid
        self.openedAt = openedAt
        self.appVersion = appVersion
    }
}

/// The show data of a Studio, as loaded from its package.
public struct Studio: Sendable, Hashable {
    public var manifest: StudioManifest
    /// library/ (one file each).
    public var songs: [Song]
    /// services/ (one file each).
    public var services: [Service]
    /// audio.json, keyed by `MediaItem.id`.
    public var audioSettings: [MediaItem.ID: AudioSettings]
    /// media.json.
    public var media: [MediaIndexEntry]
    public var looks: [Look]
    public var screens: [StudioScreen]
    public var timers: [StageTimer]
    public var messages: [Message]
    /// collections.json, in display order. Written only when there is at least one.
    public var collections: [StudioCollection]
    /// Section headers per service, in the service's file (`sections`). A service without sections has no entry.
    public var sections: [Service.ID: [ServiceSection]]

    public init(manifest: StudioManifest, songs: [Song] = [], services: [Service] = [], audioSettings: [MediaItem.ID: AudioSettings] = [:],
                media: [MediaIndexEntry] = [], looks: [Look] = [], screens: [StudioScreen] = [], timers: [StageTimer] = [], messages: [Message] = [],
                collections: [StudioCollection] = [], sections: [Service.ID: [ServiceSection]] = [:]) {
        self.manifest = manifest
        self.songs = songs
        self.services = services
        self.audioSettings = audioSettings
        self.media = media
        self.looks = looks
        self.screens = screens
        self.timers = timers
        self.messages = messages
        self.collections = collections
        self.sections = sections.filter { !$0.value.isEmpty }
    }

    public var id: UUID { manifest.id }
    public var name: String { manifest.name }

    /// Songs and services in file order (by id), as a load returns them. Lists stored in one file keep their order.
    public func normalized() -> Studio {
        var copy = self
        copy.songs.sort { $0.id.uuidString < $1.id.uuidString }
        copy.services.sort { $0.id.uuidString < $1.id.uuidString }
        copy.sections = copy.sections.filter { !$0.value.isEmpty }
        return copy
    }

    /// The section headers of a service, in order (empty when it has none).
    public func sections(of service: Service.ID) -> [ServiceSection] { sections[service] ?? [] }

    /// Replaces a service's section headers; an empty list removes the entry (so the file stays as it was).
    public mutating func setSections(_ list: [ServiceSection], of service: Service.ID) {
        sections[service] = list.isEmpty ? nil : list
    }

    /// The service that opens with the Studio.
    public var activeService: Service? {
        services.first { $0.id == manifest.activeServiceID }
            ?? services.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }.first
    }

    /// What the engine (or the mock) loads. Screens carry their layout; no connector assignments.
    public func library() -> Library {
        Library(
            service: activeService ?? Service(name: "No service", items: []),
            songs: songs,
            media: media.map { MediaItem(id: $0.id, name: $0.name, kind: $0.kind, location: $0.lastKnownPath ?? "", duration: $0.duration) },
            audioSettings: audioSettings,
            looks: looks,
            messages: messages,
            timers: timers,
            screens: screens.map {
                Screen(id: $0.id, name: $0.name, type: $0.setup.type, x: $0.setup.canvas.x, y: $0.setup.canvas.y,
                       width: $0.setup.canvas.width, height: $0.setup.canvas.height)
            },
            screenSetups: Dictionary(screens.map { ($0.id, $0.setup) }, uniquingKeysWith: { first, _ in first })
        )
    }

    /// A new Studio seeded from a library (first launch seeds from `Library.sample`). Output records and screen
    /// connectors are not carried over: they belong to the machine.
    public init(seededFrom library: Library, id: UUID = UUID(), name: String, now: Date, appVersion: String) {
        self.init(
            manifest: StudioManifest(id: id, name: name, created: now, appVersion: appVersion, activeServiceID: library.service.id),
            songs: library.songs,
            services: [library.service],
            audioSettings: library.audioSettings,
            media: library.media.map {
                MediaIndexEntry(id: $0.id, name: $0.name, kind: $0.kind, duration: $0.duration, lastKnownPath: $0.location.isEmpty ? nil : $0.location)
            },
            looks: library.looks,
            screens: library.screens.map { screen in
                StudioScreen(id: screen.id, name: screen.name, setup: library.screenSetups[screen.id] ?? ScreenSetup(
                    type: screen.type, onCanvas: screen.type == .audience,
                    canvas: CanvasRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height)
                ))
            },
            timers: library.timers,
            messages: library.messages
        )
    }

    /// Problems that do not stop a load but should be fixed: duplicate ids, references to things that are not in
    /// the Studio, invalid screen setups. Empty for a healthy Studio.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        func duplicates<T: Identifiable>(_ list: [T], _ what: String) where T.ID == UUID {
            var seen: Set<UUID> = []
            for item in list where !seen.insert(item.id).inserted { issues.append("duplicate \(what) id \(item.id)") }
        }
        duplicates(songs, "song")
        duplicates(services, "service")
        duplicates(media, "media")
        duplicates(looks, "look")
        duplicates(screens, "screen")
        duplicates(timers, "timer")
        duplicates(messages, "message")
        duplicates(collections, "collection")

        let collectionIDs = Set(collections.map(\.id))
        for song in songs {
            if let c = song.collectionID, !collectionIDs.contains(c) { issues.append("song \(song.title) is in an unknown collection") }
        }
        let serviceIDs = Set(services.map(\.id))
        for id in sections.keys where !serviceIDs.contains(id) { issues.append("sections for unknown service \(id)") }

        let songIDs = Set(songs.map(\.id)), mediaIDs = Set(media.map(\.id))
        for service in services {
            for item in service.items {
                switch item.content {
                case let .song(id) where !songIDs.contains(id): issues.append("\(service.name): \(item.title) refers to a missing song")
                case let .media(id) where !mediaIDs.contains(id): issues.append("\(service.name): \(item.title) refers to missing media")
                default: break
                }
            }
        }
        for id in audioSettings.keys where !mediaIDs.contains(id) { issues.append("audio settings for unknown media \(id)") }
        for look in looks {
            if let bg = look.backgroundMediaID, !mediaIDs.contains(bg) { issues.append("look \(look.name) uses unknown media") }
        }
        for screen in screens {
            if let reason = screen.setup.invalidReason { issues.append("screen \(screen.name): \(reason)") }
        }
        if let active = manifest.activeServiceID, !services.contains(where: { $0.id == active }) {
            issues.append("the active service is not in the Studio")
        }
        return issues
    }
}

public enum StudioError: Error, Equatable, LocalizedError {
    /// No manifest, or not a CueME Stage Studio.
    case notAStudio(String)
    case tooNew(found: Int, supported: Int)
    case noMigration(from: Int)
    case badFile(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .notAStudio(reason): "This is not a CueME Stage Studio (\(reason))."
        case let .tooNew(found, supported):
            "This Studio was made by a newer CueME Stage (file format \(found); this version reads up to \(supported)). Update CueME Stage to open it."
        case let .noMigration(from): "This Studio uses file format \(from), which this version cannot convert."
        case let .badFile(path, reason): "The Studio file \(path) could not be read: \(reason)."
        }
    }
}
