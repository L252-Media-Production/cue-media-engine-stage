import Foundation
import StageKit
import SystemConfiguration

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

/// This install: a UUID and the Mac's name, made once and kept in machine.json.
///
/// The name goes into lock.json inside Studios, so it is the computer name ("Mac Studio"), or the host name without
/// its domain; never a fully qualified host name. Nothing here touches DNS: no `Host.current()` and no
/// `ProcessInfo.hostName` (which took 2.7 s cold on the test Mac). A stored name is used as is, so a launch reads one
/// small file and asks nothing.
struct MachineIdentity: Equatable, Sendable {
    var id: UUID
    var name: String

    private struct File: Codable { var id: UUID; var name: String? }

    /// Where a new name comes from. Closures, so nothing is looked up unless a name has to be made.
    struct NameSource {
        var computerName: () -> String?
        var hostName: () -> String?

        static let system = NameSource(computerName: MachineIdentity.systemComputerName, hostName: MachineIdentity.posixHostName)
    }

    static func loadOrCreate(_ paths: MachinePaths, names: NameSource = .system) -> MachineIdentity {
        let file = paths.load(File.self, from: paths.identity)
        if let file, let stored = file.name, !stored.isEmpty {
            let name = safeName(stored)
            if name != stored { try? paths.save(File(id: file.id, name: name), to: paths.identity) } // an older qualified name
            return MachineIdentity(id: file.id, name: name)
        }
        let identity = MachineIdentity(id: file?.id ?? UUID(), name: makeName(names))
        try? paths.save(File(id: identity.id, name: identity.name), to: paths.identity)
        return identity
    }

    /// The computer name; else the host name without its domain; else "This Mac". Either way never a qualified host
    /// name (some Macs have their computer name set to one).
    static func makeName(_ names: NameSource) -> String {
        if let computer = names.computerName()?.trimmingCharacters(in: .whitespaces), !computer.isEmpty { return safeName(computer) }
        if let host = names.hostName().map(shortHostName), !host.isEmpty { return host }
        return "This Mac"
    }

    /// A name that looks like a host name (dots, no spaces) loses its domain: "jc-mbp.example.com" -> "jc-mbp".
    /// A real computer name with dots and spaces ("J.C.'s Mac") is kept.
    static func safeName(_ name: String) -> String {
        guard name.contains("."), !name.contains(" ") else { return name }
        let short = shortHostName(name)
        return short.isEmpty ? name : short
    }

    /// "jc-mbp.example.com" -> "jc-mbp"; also drops a trailing ".local".
    static func shortHostName(_ host: String) -> String {
        String(host.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }

    /// The name set in System Settings > General > Sharing (configd; no DNS).
    static func systemComputerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    /// gethostname(3): the kernel's host name, a local call (no DNS).
    static func posixHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
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
