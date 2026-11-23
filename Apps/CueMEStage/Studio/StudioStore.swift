import Foundation
import Observation
import StageKit

/// The open Studio: loads it, keeps the lock, and saves it. Changes go through `update`; autosave writes only the
/// files that changed, about a second after the last change, and on close. A failed save is shown as a notice and
/// retried; it never throws out of here.
@MainActor
@Observable
final class StudioStore {
    struct Environment {
        var machine: MachinePaths
        var identity: MachineIdentity
        var appVersion: String
        var now: () -> Date = Date.init
        var debounce: Duration = .seconds(1)
        var retry: Duration = .seconds(5)
        var isProcessRunning: (Int32) -> Bool = StudioLocking.processIsRunning
        var pid: Int32 = ProcessInfo.processInfo.processIdentifier

        static func standard(appVersion: String) -> Environment {
            let machine = MachinePaths.standard
            return Environment(machine: machine, identity: .loadOrCreate(machine), appVersion: appVersion)
        }

        var locking: StudioLocking {
            StudioLocking(identity: identity, pid: pid, appVersion: appVersion, isProcessRunning: isProcessRunning)
        }
    }

    /// A Studio read from disk but not opened yet: the caller decides on the lock first.
    struct PendingOpen {
        let package: StudioPackage
        let studio: Studio
        let files: StudioCodec.Files
        let lock: LockAssessment
    }

    let environment: Environment
    private(set) var package: StudioPackage?
    private(set) var studio: Studio?
    /// A non-blocking message for the operator (save failed, Studio missing, ...). nil when there is nothing to say.
    var notice: String?
    /// Paths written by the last successful save (tests and diagnostics).
    private(set) var lastWrite: [String] = []
    private(set) var saveCount = 0

    @ObservationIgnored private var saved: StudioCodec.Files = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    var url: URL? { package?.url }
    var hasUnsavedChanges: Bool {
        guard let studio, let files = try? StudioCodec.encode(studio) else { return false }
        return files.keys.contains { $0 != StudioCodec.manifestPath && files[$0] != saved[$0] }
            || Set(saved.keys) != Set(files.keys)
    }

    // MARK: Open and close

    /// Reads and checks a Studio and its lock. Nothing is changed on disk.
    func prepareOpen(_ url: URL) throws -> PendingOpen {
        let package = StudioPackage(url: url)
        let (studio, files) = try package.read()
        return PendingOpen(package: package, studio: studio, files: files, lock: environment.locking.assess(environment.locking.read(package)))
    }

    /// Opens a prepared Studio: closes the current one (saving it), takes the lock and starts tracking changes.
    /// Call it for a free, own or stale lock, or after the operator chose Open Anyway.
    func open(_ pending: PendingOpen) {
        close()
        let locking = environment.locking
        do { try locking.acquire(pending.package, now: environment.now()) } catch {
            notice = "Could not write the lock of “\(pending.studio.name)”: \(error.localizedDescription)"
        }
        package = pending.package
        studio = pending.studio
        saved = pending.files
    }

    /// Open a Copy: a new package next to the original, with a new id, opened instead.
    func openCopy(of pending: PendingOpen) throws {
        let copy = try pending.package.makeCopy(now: environment.now(), appVersion: environment.appVersion)
        open(try prepareOpen(copy))
    }

    /// Creates a Studio package at `url` and opens it.
    func create(_ studio: Studio, at url: URL) throws {
        _ = try StudioPackage.create(studio, at: url)
        open(try prepareOpen(url))
    }

    /// Saves (now), gives back the lock and forgets the Studio. Safe to call with nothing open.
    func close() {
        saveTask?.cancel()
        saveTask = nil
        guard let package else { return }
        saveNow()
        environment.locking.release(package)
        self.package = nil
        studio = nil
        saved = [:]
    }

    // MARK: Changes and saving

    /// Changes the Studio and schedules an autosave.
    func update(_ change: (inout Studio) -> Void) {
        guard var studio else { return }
        change(&studio)
        guard studio != self.studio else { return }
        self.studio = studio
        scheduleSave(after: environment.debounce)
    }

    private func scheduleSave(after delay: Duration) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the changed files now. On failure: a notice, and another try after `environment.retry`.
    @discardableResult
    func saveNow() -> Bool {
        guard let package, var studio else { return true }
        do {
            var files = try StudioCodec.encode(studio)
            let dataChanged = files.keys.contains { $0 != StudioCodec.manifestPath && files[$0] != saved[$0] }
                || saved.keys.contains { files[$0] == nil && StudioCodec.isShowDataPath($0) }
            if dataChanged {
                studio.manifest.modified = environment.now()
                studio.manifest.appVersion = environment.appVersion
                files[StudioCodec.manifestPath] = try StudioCodec.makeEncoder().encode(studio.manifest)
            }
            lastWrite = try package.write(files, previous: saved)
            saved = files
            self.studio = studio
            saveCount += 1
            if notice?.hasPrefix(Self.saveFailedPrefix) == true { notice = nil }
            return true
        } catch {
            notice = "\(Self.saveFailedPrefix) “\(studio.name)”: \(error.localizedDescription). Retrying."
            scheduleSave(after: environment.retry)
            return false
        }
    }

    static let saveFailedPrefix = "Could not save"
}
