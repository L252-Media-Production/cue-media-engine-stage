import Darwin
import Foundation
import StageKit

/// What a Studio's lock.json says about opening it here.
enum LockAssessment: Equatable {
    /// No lock (or an unreadable one).
    case free
    /// This process holds it.
    case ours
    /// This machine, but the process is gone: replaced silently.
    case stale(StudioLock)
    /// Another running CueME Stage on this machine, or another machine: warn, with Open Anyway / Open a Copy / Cancel.
    case held(StudioLock, sameMachine: Bool)

    var needsWarning: Bool { if case .held = self { true } else { false } }
}

/// Reads, judges, takes and gives back a Studio's lock. A lock warns; it never blocks.
struct StudioLocking {
    var identity: MachineIdentity
    var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    var appVersion: String
    var isProcessRunning: (Int32) -> Bool = StudioLocking.processIsRunning

    static func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func read(_ package: StudioPackage) -> StudioLock? {
        guard let data = try? Data(contentsOf: package.lockURL) else { return nil }
        return try? StudioCodec.makeDecoder().decode(StudioLock.self, from: data)
    }

    func assess(_ lock: StudioLock?) -> LockAssessment {
        guard let lock else { return .free }
        guard lock.machineID == identity.id else { return .held(lock, sameMachine: false) }
        if lock.pid == pid { return .ours }
        return isProcessRunning(lock.pid) ? .held(lock, sameMachine: true) : .stale(lock)
    }

    func ourLock(now: Date) -> StudioLock {
        StudioLock(machineID: identity.id, machineName: MachineIdentity.safeName(identity.name), pid: pid, openedAt: now, appVersion: appVersion)
    }

    /// Writes our lock (replacing whatever was there: call it only for free, ours, stale, or after Open Anyway).
    func acquire(_ package: StudioPackage, now: Date) throws {
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(ourLock(now: now)), to: package.lockURL)
    }

    /// Removes the lock only if it is still ours. Another machine's lock is never deleted here.
    func release(_ package: StudioPackage) {
        guard let lock = read(package), lock.machineID == identity.id, lock.pid == pid else { return }
        try? FileManager.default.removeItem(at: package.lockURL)
    }

    /// The warning text: who has it and since when.
    static func warning(studioName: String, lock: StudioLock, sameMachine: Bool) -> String {
        let since = lock.openedAt.formatted(date: .abbreviated, time: .shortened)
        let who = sameMachine
            ? "another CueME Stage on this Mac (process \(lock.pid))"
            : "\(lock.machineName)"
        return "“\(studioName)” is open in \(who) since \(since). Opening it here too can lose changes made there."
    }
}

/// File > Open Recent: the last 10 Studios, newest first, in UserDefaults.
struct RecentStudios {
    static let key = "cueme.studio.recent"
    static let limit = 10
    let defaults: UserDefaults

    var urls: [URL] { (defaults.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var list = (defaults.stringArray(forKey: Self.key) ?? []).filter { $0 != path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    /// File > Open Recent: the recent Studios except the one open now (a menu entry that does nothing is noise).
    func menuURLs(excluding open: URL?) -> [URL] {
        let current = open.map(StudioController.samePathKey)
        return urls.filter { StudioController.samePathKey($0) != current }
    }
}
