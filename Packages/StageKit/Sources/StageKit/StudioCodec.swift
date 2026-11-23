import Foundation

/// Turns a `Studio` into the files of its package and back. Pure: the app reads and writes the folder.
///
/// Files are keyed by their path inside the package, with "/" separators ("manifest.json", "library/<id>.json").
/// lock.json and cache/ are not show data and never pass through here.
public enum StudioCodec {
    public typealias Files = [String: Data]
    /// Rewrites the files of format version N into version N + 1 (keyed by N). Runs before anything is decoded.
    public typealias Migration = @Sendable (inout Files) throws -> Void

    /// Migrations shipped with this build. Version 1 is the first format, so there are none yet.
    public static let migrations: [Int: Migration] = [:]

    public static let manifestPath = "manifest.json"
    public static let lockPath = "lock.json"
    public static let cacheFolder = "cache"
    static let libraryFolder = "library"
    static let servicesFolder = "services"
    static let audioPath = "audio.json"
    static let mediaPath = "media.json"
    static let looksPath = "looks.json"
    static let screensPath = "screens.json"
    static let timersPath = "timers.json"
    static let messagesPath = "messages.json"
    static let collectionsPath = "collections.json"

    /// A service file: the `Service` itself plus, only when the service has any, its `sections`. Without sections the
    /// bytes are exactly what `Service` alone writes, so a Studio from before sections writes back unchanged.
    private struct ServiceFile: Encodable {
        let service: Service
        let sections: [ServiceSection]?
        enum Keys: String, CodingKey { case sections }

        func encode(to encoder: Encoder) throws {
            try service.encode(to: encoder)
            guard let sections, !sections.isEmpty else { return }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(sections, forKey: .sections)
        }
    }

    private struct ServiceSectionsProbe: Decodable {
        var sections: [ServiceSection]?
    }

    /// Pretty-printed, sorted keys, ISO-8601 dates with milliseconds: stable output that diffs well in git.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter(fractional: true).string(from: date))
        }
        return encoder
    }

    /// Reads ISO-8601 dates with or without fractional seconds.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = isoFormatter(fractional: true).date(from: text) ?? isoFormatter(fractional: false).date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(text)")
        }
        return decoder
    }

    private static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    // MARK: Encode

    public static func encode(_ studio: Studio) throws -> Files {
        let encoder = makeEncoder()
        var files: Files = [:]
        files[manifestPath] = try encoder.encode(studio.manifest)
        for song in studio.songs {
            files["\(libraryFolder)/\(song.id.uuidString).json"] = try encoder.encode(LibraryItemFile(song: song))
        }
        for service in studio.services {
            files["\(servicesFolder)/\(service.id.uuidString).json"] = try encoder.encode(ServiceFile(service: service, sections: studio.sections[service.id]))
        }
        files[audioPath] = try encoder.encode(Dictionary(uniqueKeysWithValues: studio.audioSettings.map { ($0.key.uuidString, $0.value) }))
        files[mediaPath] = try encoder.encode(studio.media)
        files[looksPath] = try encoder.encode(studio.looks)
        files[screensPath] = try encoder.encode(studio.screens)
        files[timersPath] = try encoder.encode(studio.timers)
        files[messagesPath] = try encoder.encode(studio.messages)
        if !studio.collections.isEmpty { files[collectionsPath] = try encoder.encode(studio.collections) }
        return files
    }

    // MARK: Decode

    private struct VersionProbe: Decodable {
        var format: String?
        var formatVersion: Int?
    }

    /// Reads only the format and version of a manifest, and refuses a file that is not a Studio or is too new.
    /// Call it before touching anything else (import does).
    @discardableResult
    public static func checkManifest(_ data: Data?) throws -> Int {
        guard let data else { throw StudioError.notAStudio("no manifest.json") }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            throw StudioError.notAStudio("manifest.json is not valid JSON")
        }
        guard probe.format == StudioFormat.format else { throw StudioError.notAStudio("unknown format \(probe.format ?? "none")") }
        guard let version = probe.formatVersion else { throw StudioError.notAStudio("no formatVersion") }
        guard version <= StudioFormat.currentVersion else {
            throw StudioError.tooNew(found: version, supported: StudioFormat.currentVersion)
        }
        return version
    }

    /// Checks the manifest, runs the migrations from its version up to the current one, then decodes every file.
    /// Missing list files count as empty. Songs and services come back sorted by id (see `Studio.normalized`).
    public static func decode(_ input: Files, migrations: [Int: Migration] = StudioCodec.migrations) throws -> Studio {
        var files = input
        var version = try checkManifest(files[manifestPath])
        while version < StudioFormat.currentVersion {
            guard let step = migrations[version] else { throw StudioError.noMigration(from: version) }
            try step(&files)
            version += 1
        }

        let decoder = makeDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            guard let data = files[path] else { throw StudioError.badFile(path: path, reason: "missing") }
            do { return try decoder.decode(type, from: data) } catch {
                throw StudioError.badFile(path: path, reason: String(describing: error))
            }
        }
        func list<T: Decodable>(_ type: [T].Type, _ path: String) throws -> [T] {
            files[path] == nil ? [] : try decode(type, path)
        }

        var manifest = try decode(StudioManifest.self, manifestPath)
        manifest.formatVersion = StudioFormat.currentVersion

        var songs: [Song] = []
        var services: [Service] = []
        var sections: [Service.ID: [ServiceSection]] = [:]
        for path in files.keys.sorted() {
            if path.hasPrefix("\(libraryFolder)/"), path.hasSuffix(".json") {
                let file = try decode(LibraryItemFile.self, path)
                guard let song = file.song else { throw StudioError.badFile(path: path, reason: "no song") }
                songs.append(song)
            } else if path.hasPrefix("\(servicesFolder)/"), path.hasSuffix(".json") {
                let service = try decode(Service.self, path)
                services.append(service)
                if let list = try decode(ServiceSectionsProbe.self, path).sections, !list.isEmpty { sections[service.id] = list }
            }
        }

        var audio: [MediaItem.ID: AudioSettings] = [:]
        if files[audioPath] != nil {
            for (key, settings) in try decode([String: AudioSettings].self, audioPath) {
                guard let id = UUID(uuidString: key) else { throw StudioError.badFile(path: audioPath, reason: "key \(key) is not an id") }
                audio[id] = settings
            }
        }

        return Studio(
            manifest: manifest,
            songs: songs,
            services: services,
            audioSettings: audio,
            media: try list([MediaIndexEntry].self, mediaPath),
            looks: try list([Look].self, looksPath),
            screens: try list([StudioScreen].self, screensPath),
            timers: try list([StageTimer].self, timersPath),
            messages: try list([Message].self, messagesPath),
            collections: try list([StudioCollection].self, collectionsPath),
            sections: sections
        ).normalized()
    }

    /// True for the paths this codec owns (the files `encode` writes). Anything else in the package (lock.json,
    /// cache/, Finder files) is left alone by a save.
    public static func isShowDataPath(_ path: String) -> Bool {
        if [manifestPath, audioPath, mediaPath, looksPath, screensPath, timersPath, messagesPath, collectionsPath].contains(path) { return true }
        let parts = path.split(separator: "/")
        return parts.count == 2 && (parts[0] == libraryFolder || parts[0] == servicesFolder) && path.hasSuffix(".json")
    }
}
