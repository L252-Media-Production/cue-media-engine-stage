import Foundation
import StageKit

/// The machine folder: ~/Library/Application Support/CueMEStage/Machine/. Holds what belongs to this Mac, not to a
/// show: its identity, which connector drives which screen, the media folders and the hash cache. Shared by all
/// Studios. Tests use a temp folder.
struct MachinePaths {
    let root: URL

    static var standard: MachinePaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MachinePaths(root: support.appendingPathComponent("CueMEStage/Machine", isDirectory: true))
    }

    var identity: URL { root.appendingPathComponent("machine.json") }
    var outputs: URL { root.appendingPathComponent("outputs.json") }
    var mediaFolders: URL { root.appendingPathComponent("media-folders.json") }
    var hashCache: URL { root.appendingPathComponent("hash-cache.json") }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StudioCodec.makeDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(value), to: url)
    }
}

/// This install: a UUID made once and kept in machine.json, and the Mac's name.
struct MachineIdentity: Equatable, Sendable {
    var id: UUID
    var name: String

    private struct File: Codable { var id: UUID }

    static func loadOrCreate(_ paths: MachinePaths, name: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName) -> MachineIdentity {
        if let file = paths.load(File.self, from: paths.identity) { return MachineIdentity(id: file.id, name: name) }
        let id = UUID()
        try? paths.save(File(id: id), to: paths.identity)
        return MachineIdentity(id: id, name: name)
    }
}

/// outputs.json: which connector drives which screen, on this machine. Keyed by Studio id, then screen id, so two
/// Studios (a copy, an imported bundle) never share or fight over assignments, and a Studio opened here for the first
/// time has none: its screens show Unassigned. Nothing is guessed.
struct MachineOutputs {
    private struct File: Codable {
        var version = 1
        /// studio id -> screen id -> connector id.
        var studios: [String: [String: String]] = [:]
    }

    let paths: MachinePaths

    /// One entry per screen, in `screens` order; nil where this machine has no assignment.
    func assignments(studio: UUID, screens: [Screen.ID]) -> [OutputAssignment] {
        let stored = paths.load(File.self, from: paths.outputs)?.studios[studio.uuidString] ?? [:]
        return screens.map { OutputAssignment(screenID: $0, connectorID: stored[$0.uuidString]) }
    }

    func save(studio: UUID, assignments: [OutputAssignment]) throws {
        var file = paths.load(File.self, from: paths.outputs) ?? File()
        var map: [String: String] = [:]
        for a in assignments { if let c = a.connectorID { map[a.screenID.uuidString] = c } }
        guard file.studios[studio.uuidString] ?? [:] != map else { return }
        file.studios[studio.uuidString] = map.isEmpty ? nil : map
        try paths.save(file, to: paths.outputs)
    }
}

/// media-folders.json: the folders this machine keeps media in. Shared by every Studio; a file in two Studios'
/// folders is the same file, never a copy.
struct MediaFolders {
    let paths: MachinePaths

    func load() -> [URL] {
        (paths.load([String].self, from: paths.mediaFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func add(_ folder: URL) throws {
        var list = (paths.load([String].self, from: paths.mediaFolders) ?? [])
        let path = folder.standardizedFileURL.path
        guard !list.contains(path) else { return }
        list.append(path)
        try paths.save(list, to: paths.mediaFolders)
    }

    func remove(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        try paths.save((paths.load([String].self, from: paths.mediaFolders) ?? []).filter { $0 != path }, to: paths.mediaFolders)
    }
}

/// hash-cache.json: SHA-256 by path + size + modification time, so a rescan only hashes new or changed files.
struct HashCache: Codable, Equatable, Sendable {
    var entries: [String: String] = [:]

    static func key(path: String, size: Int64, modified: Date) -> String {
        "\(path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    static func load(_ paths: MachinePaths) -> HashCache { paths.load(HashCache.self, from: paths.hashCache) ?? HashCache() }
    func save(_ paths: MachinePaths) throws { try paths.save(self, to: paths.hashCache) }
}
