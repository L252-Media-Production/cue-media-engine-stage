import Foundation

/// Any JSON value. Carries an item's `data` in a .stgitem file without knowing its kind.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    /// Any Codable value as JSON.
    public init<T: Encodable>(encoding value: T) throws {
        self = try StudioCodec.makeDecoder().decode(JSONValue.self, from: StudioCodec.makeEncoder().encode(value))
    }

    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try StudioCodec.makeDecoder().decode(type, from: StudioCodec.makeEncoder().encode(self))
    }
}

/// A library item that can travel in a .stgitem file.
public enum StudioItemPayload: Sendable, Hashable {
    case song(Song)
    case message(Message)
    case timer(StageTimer)
    case look(Look)

    public var kind: String {
        switch self {
        case .song: "song"
        case .message: "message"
        case .timer: "timer"
        case .look: "look"
        }
    }

    public var id: UUID {
        switch self {
        case let .song(v): v.id
        case let .message(v): v.id
        case let .timer(v): v.id
        case let .look(v): v.id
        }
    }

    public var name: String {
        switch self {
        case let .song(v): v.title
        case let .message(v): v.text
        case let .timer(v): v.name
        case let .look(v): v.name
        }
    }

    /// The same item under another id (Keep both).
    public func withID(_ id: UUID) -> StudioItemPayload {
        switch self {
        case var .song(v): v.id = id; return .song(v)
        case var .message(v): v.id = id; return .message(v)
        case var .timer(v): v.id = id; return .timer(v)
        case var .look(v): v.id = id; return .look(v)
        }
    }

    /// Media the item needs (a look's background; a song's audio track and background).
    public var mediaIDs: [MediaItem.ID] {
        switch self {
        case let .look(look): [look.backgroundMediaID].compactMap { $0 }
        case let .song(song): [song.audioTrackID, song.backgroundID].compactMap { $0 }
        case .message, .timer: []
        }
    }

    func data() throws -> JSONValue {
        switch self {
        case let .song(v): try JSONValue(encoding: v)
        case let .message(v): try JSONValue(encoding: v)
        case let .timer(v): try JSONValue(encoding: v)
        case let .look(v): try JSONValue(encoding: v)
        }
    }
}

/// A .stgitem file: one or more library items as ONE JSON file (see docs/studio-file-format.md).
public struct StudioItemFile: Codable, Sendable, Hashable {
    public static let format = "cueme-stage-item"
    public static let currentVersion = 1
    /// Header kinds; "collection" when the items are of more than one kind.
    public static let headerKinds: Set<String> = ["song", "presentation", "message", "timer", "look", "collection"]

    public struct MediaRef: Codable, Sendable, Hashable {
        public var id: MediaItem.ID
        public var name: String
        public var size: Int64?
        public var sha256: String?
        /// Not in the minimal header; written so an import can add the index entry with the right kind.
        public var kind: MediaItem.Kind?

        public init(id: MediaItem.ID, name: String, size: Int64? = nil, sha256: String? = nil, kind: MediaItem.Kind? = nil) {
            self.id = id
            self.name = name
            self.size = size
            self.sha256 = sha256
            self.kind = kind
        }
    }

    public struct Entry: Codable, Sendable, Hashable {
        public var kind: String
        public var id: UUID
        public var name: String
        public var data: JSONValue

        public init(kind: String, id: UUID, name: String, data: JSONValue) {
            self.kind = kind
            self.id = id
            self.name = name
            self.data = data
        }
    }

    public var format: String
    public var formatVersion: Int
    public var kind: String
    public var exported: Date
    public var appVersion: String
    public var mediaRefs: [MediaRef]
    public var items: [Entry]
}

/// The result of reading a .stgitem file.
public struct StudioItemImport: Sendable, Hashable {
    public struct Skipped: Sendable, Hashable {
        public var kind: String
        public var id: UUID
        public var name: String
        public var reason: String
    }

    public var items: [StudioItemPayload]
    public var mediaRefs: [StudioItemFile.MediaRef]
    /// Items not read (unknown kind, bad data). Reported, never fatal.
    public var skipped: [Skipped]
}

public enum StudioItemError: Error, Equatable, LocalizedError {
    case notAnItemFile(String)
    case tooNew(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .notAnItemFile(reason): "This is not a CueME Stage item file (\(reason))."
        case let .tooNew(found, supported):
            "This item file was made by a newer CueME Stage (format \(found); this version reads up to \(supported)). Update CueME Stage to import it."
        }
    }
}

/// Writes and reads .stgitem files. One reader: the header is checked first, then every item goes to the decoder
/// registered for its kind. An unknown kind is skipped and reported.
public struct StudioItemCodec: Sendable {
    public typealias ItemDecoder = @Sendable (JSONValue) throws -> StudioItemPayload

    public var registry: [String: ItemDecoder]

    public init(registry: [String: ItemDecoder] = StudioItemCodec.defaultRegistry) {
        self.registry = registry
    }

    public static let defaultRegistry: [String: ItemDecoder] = [
        "song": { .song(try $0.decode(as: Song.self)) },
        "message": { .message(try $0.decode(as: Message.self)) },
        "timer": { .timer(try $0.decode(as: StageTimer.self)) },
        "look": { .look(try $0.decode(as: Look.self)) },
    ]

    /// `media` is the Studio's index: the refs of the items' media are taken from it.
    public static func encode(_ items: [StudioItemPayload], media: [MediaIndexEntry], appVersion: String, exported: Date) throws -> Data {
        let kinds = Set(items.map(\.kind))
        let wanted = Set(items.flatMap(\.mediaIDs))
        let file = StudioItemFile(
            format: StudioItemFile.format,
            formatVersion: StudioItemFile.currentVersion,
            kind: kinds.count == 1 ? kinds.first! : "collection",
            exported: exported,
            appVersion: appVersion,
            mediaRefs: media.filter { wanted.contains($0.id) }.map {
                StudioItemFile.MediaRef(id: $0.id, name: $0.name, size: $0.size, sha256: $0.sha256, kind: $0.kind)
            },
            items: try items.map { StudioItemFile.Entry(kind: $0.kind, id: $0.id, name: $0.name, data: try $0.data()) }
        )
        return try StudioCodec.makeEncoder().encode(file)
    }

    public func decode(_ data: Data) throws -> StudioItemImport {
        struct Probe: Decodable { var format: String?; var formatVersion: Int?; var kind: String? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { throw StudioItemError.notAnItemFile("not JSON") }
        guard probe.format == StudioItemFile.format else { throw StudioItemError.notAnItemFile("unknown format \(probe.format ?? "none")") }
        guard let version = probe.formatVersion, version >= 1 else { throw StudioItemError.notAnItemFile("no formatVersion") }
        guard version <= StudioItemFile.currentVersion else {
            throw StudioItemError.tooNew(found: version, supported: StudioItemFile.currentVersion)
        }
        guard let kind = probe.kind, StudioItemFile.headerKinds.contains(kind) else {
            throw StudioItemError.notAnItemFile("unknown kind \(probe.kind ?? "none")")
        }
        let file: StudioItemFile
        do { file = try StudioCodec.makeDecoder().decode(StudioItemFile.self, from: data) } catch {
            throw StudioItemError.notAnItemFile("bad header: \(error)")
        }

        var items: [StudioItemPayload] = []
        var skipped: [StudioItemImport.Skipped] = []
        for entry in file.items {
            guard let decoder = registry[entry.kind] else {
                skipped.append(.init(kind: entry.kind, id: entry.id, name: entry.name, reason: "unknown kind \(entry.kind)"))
                continue
            }
            do {
                let payload = try decoder(entry.data)
                guard payload.id == entry.id else {
                    skipped.append(.init(kind: entry.kind, id: entry.id, name: entry.name, reason: "id does not match its data"))
                    continue
                }
                items.append(payload)
            } catch {
                skipped.append(.init(kind: entry.kind, id: entry.id, name: entry.name, reason: "bad data: \(error)"))
            }
        }
        return StudioItemImport(items: items, mediaRefs: file.mediaRefs, skipped: skipped)
    }
}
