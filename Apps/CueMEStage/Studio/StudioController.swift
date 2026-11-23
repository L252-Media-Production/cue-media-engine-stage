import Foundation
import Observation
import StageKit

/// The mock's view of the Studios the app has read: `openStudio(id)` and `reloadStudio(id)` look them up here.
/// (A real engine will read the package itself.)
final class StudioCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var studios: [UUID: MockStageClient.LoadedStudio] = [:]

    func put(_ studio: MockStageClient.LoadedStudio) { lock.withLock { studios[studio.info.id] = studio } }
    func get(_ id: UUID) -> MockStageClient.LoadedStudio? { lock.withLock { studios[id] } }

    var source: MockStageClient.StudioSource { { [weak self] id in self?.get(id) } }
}

/// Everything File > Studio does: opening (with the lock and the switching warning), creating, closing, import and
/// export, relink, and keeping the engine, the Studio and this machine's output assignments in step.
@MainActor
@Observable
final class StudioController {
    let studios: StudioStore
    let stage: StageStore
    @ObservationIgnored let catalog: StudioCatalog
    @ObservationIgnored let defaults: UserDefaults
    /// Where new Studios go (~/Documents/CueME Stage in the app, a temp folder in tests).
    @ObservationIgnored let documentsFolder: URL
    @ObservationIgnored var dialogs: StudioDialogs

    /// A non-blocking message (a missing last Studio, an import summary). Save failures come from `studios.notice`.
    var notice: String?
    var relinkReport: RelinkReport?
    var isScanning = false

    @ObservationIgnored private var savedAssignments: [OutputAssignment]?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(studios: StudioStore, stage: StageStore, catalog: StudioCatalog, defaults: UserDefaults, documentsFolder: URL, dialogs: StudioDialogs) {
        self.studios = studios
        self.stage = stage
        self.catalog = catalog
        self.defaults = defaults
        self.documentsFolder = documentsFolder
        self.dialogs = dialogs
        stage.onState = { [weak self] state in self?.absorb(state) }
    }

    var title: String { studios.studio?.name ?? "No Studio" }
    var recents: RecentStudios { RecentStudios(defaults: defaults) }
    private var machine: MachinePaths { studios.environment.machine }
    private var outputs: MachineOutputs { MachineOutputs(paths: machine) }
    /// The current notice to show, save failures first.
    var visibleNotice: String? { studios.notice ?? notice }

    // MARK: Launch

    /// Reopens the last Studio; if there is none, or it is gone, opens (or creates) ~/Documents/CueME Stage/Studio.stg
    /// seeded from the sample data.
    func launch() {
        if let last = defaults.string(forKey: StorageKeys.lastStudio) {
            let url = URL(fileURLWithPath: last, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                if open(url, checkLive: false) { return }
            } else {
                notice = "The last Studio was not found at \(last). Opened the default Studio instead."
            }
        }
        openDefaultStudio()
    }

    func openDefaultStudio() {
        let url = documentsFolder.appendingPathComponent("Studio.\(StudioFormat.packageExtension)", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = open(url, checkLive: false)
            return
        }
        do {
            try FileManager.default.createDirectory(at: documentsFolder, withIntermediateDirectories: true)
            let studio = Studio(seededFrom: .sample, name: "Studio", now: studios.environment.now(), appVersion: studios.environment.appVersion)
            try studios.create(studio, at: url)
            didOpen()
        } catch {
            notice = "The default Studio could not be created: \(error.localizedDescription)"
        }
    }

    // MARK: Open, new, close

    /// Asks before replacing what is live. True = go ahead.
    func confirmLeaving(_ action: String) -> Bool {
        guard studios.studio != nil, let live = LiveSummary.text(stage.state) else { return true }
        return dialogs.confirmSwitch(live: live, action: action)
    }

    /// Opens a Studio: the switching warning when something is live, then the lock check. True when it opened.
    @discardableResult
    func open(_ url: URL, checkLive: Bool = true) -> Bool {
        if studios.url?.standardizedFileURL == url.standardizedFileURL { return true }
        if checkLive, !confirmLeaving("Switch Studio") { return false }
        let pending: StudioStore.PendingOpen
        do { pending = try studios.prepareOpen(url) } catch {
            dialogs.showError("“\(url.deletingPathExtension().lastPathComponent)” could not be opened", error)
            return false
        }
        switch pending.lock {
        case .free, .ours, .stale:
            studios.open(pending)
        case let .held(lock, sameMachine):
            switch dialogs.lockChoice(message: StudioLocking.warning(studioName: pending.studio.name, lock: lock, sameMachine: sameMachine)) {
            case .cancel: return false
            case .openAnyway: studios.open(pending)
            case .openCopy:
                do { try studios.openCopy(of: pending) } catch {
                    dialogs.showError("A copy could not be made", error)
                    return false
                }
            }
        }
        didOpen()
        return true
    }

    func chooseAndOpen() {
        guard let url = dialogs.chooseFile(title: "Open Studio", types: [.cuemeStudio], directory: documentsFolder) else { return }
        open(url)
    }

    /// File > New Studio…: one empty service and the standard screens (new ids), saved where the operator says.
    func newStudio() {
        guard let chosen = dialogs.chooseSave(title: "New Studio", name: "Untitled Studio", type: .cuemeStudio, directory: documentsFolder) else { return }
        createNewStudio(at: chosen)
    }

    func createNewStudio(at chosen: URL) {
        guard confirmLeaving("Switch Studio") else { return }
        let name = chosen.deletingPathExtension().lastPathComponent
        let url = StudioLocations.unusedPackageURL(named: name, in: chosen.deletingLastPathComponent())
        let studio = Studio.blank(name: url.deletingPathExtension().lastPathComponent, now: studios.environment.now(), appVersion: studios.environment.appVersion)
        do {
            try studios.create(studio, at: url)
            didOpen()
        } catch {
            dialogs.showError("The Studio could not be created", error)
        }
    }

    func closeStudio() {
        guard studios.studio != nil, confirmLeaving("Close Studio") else { return }
        stage.send(.closeStudio)
        studios.close()
        savedAssignments = nil
    }

    /// Saves and releases the lock (quit).
    func shutdown() {
        scanTask?.cancel()
        studios.close()
    }

    /// After a Studio opened in the store: hand it to the engine with this machine's assignments, remember it.
    private func didOpen() {
        guard let studio = studios.studio, let url = studios.url else { return }
        let assignments = outputs.assignments(studio: studio.id, screens: studio.screens.map(\.id))
        savedAssignments = assignments
        relinkReport = nil
        catalog.put(.init(info: StudioInfo(id: studio.id, name: studio.name), library: studio.library(), assignments: assignments))
        stage.send(.openStudio(studio.id))
        recents.add(url)
        defaults.set(url.standardizedFileURL.path, forKey: StorageKeys.lastStudio)
    }

    /// The Studio's show data changed here: give the engine the new content without stopping anything.
    private func reloadEngine() {
        guard let studio = studios.studio else { return }
        catalog.put(.init(info: StudioInfo(id: studio.id, name: studio.name), library: studio.library(),
                          assignments: savedAssignments ?? []))
        stage.send(.reloadStudio(studio.id))
    }

    // MARK: Engine state back into the Studio and the machine

    /// Screen layouts changed in Output Setup go into the Studio (screens.json); connector assignments go to this
    /// machine (outputs.json). Only for the Studio the engine has loaded.
    func absorb(_ state: StageState) {
        guard let studio = studios.studio, state.studio?.id == studio.id else { return }
        if state.assignments != savedAssignments {
            do {
                try outputs.save(studio: studio.id, assignments: state.assignments)
                savedAssignments = state.assignments
            } catch {
                notice = "Output assignments could not be saved on this Mac: \(error.localizedDescription)"
            }
        }
        if studio.screens.contains(where: { screen in state.screenSetups[screen.id].map { $0 != screen.setup } ?? false }) {
            studios.update { s in
                for i in s.screens.indices { if let setup = state.screenSetups[s.screens[i].id] { s.screens[i].setup = setup } }
            }
        }
    }

    // MARK: Export and import

    func exportStudio() {
        guard let studio = studios.studio, let url = studios.url else { return }
        guard let target = dialogs.chooseSave(title: "Export Studio", name: "\(studio.name).\(StudioFormat.bundleExtension)",
                                              type: .cuemeStudioBundle, directory: nil) else { return }
        studios.saveNow()
        do {
            try StudioBundle.export(StudioPackage(url: url), to: target)
            notice = "Exported “\(studio.name)” to \(target.lastPathComponent) (no media, no cache)."
        } catch {
            dialogs.showError("The Studio could not be exported", error)
        }
    }

    func chooseAndImportStudio() {
        guard let url = dialogs.chooseFile(title: "Import Studio", types: [.cuemeStudioBundle], directory: nil) else { return }
        importStudio(url)
    }

    func importStudio(_ bundle: URL) {
        let name = bundle.deletingPathExtension().lastPathComponent
        do {
            try StudioBundle.inspect(bundle) // refuse a bad bundle before asking anything
        } catch {
            dialogs.showError("“\(name)” could not be imported", error)
            return
        }
        switch studios.studio == nil ? .openAsNew : dialogs.bundleImportChoice(name: name) {
        case .cancel: return
        case .openAsNew:
            guard confirmLeaving("Switch Studio") else { return }
            do {
                let url = try StudioBundle.importAsNew(bundle, into: documentsFolder, idsInUse: Set([studios.studio?.id].compactMap { $0 }),
                                                       now: studios.environment.now())
                open(url, checkLive: false)
            } catch {
                dialogs.showError("“\(name)” could not be imported", error)
            }
        case .replaceCurrent:
            guard confirmLeaving("Replace Studio") else { return }
            do {
                try studios.replaceContents(withBundle: bundle)
                didOpen()
            } catch {
                dialogs.showError("“\(name)” could not be imported", error)
            }
        }
    }

    func chooseAndImportItems() {
        guard let url = dialogs.chooseFile(title: "Import Items", types: [.cuemeItems], directory: nil) else { return }
        importItems(url)
    }

    func importItems(_ url: URL) {
        guard let current = studios.studio else { return }
        let imported: StudioItemImport
        do { imported = try StudioItemImporter.read(url) } catch {
            dialogs.showError("“\(url.lastPathComponent)” could not be imported", error)
            return
        }
        var remaining = StudioItemImporter.clashes(imported, in: current).count
        var forAll: ItemClashChoice?
        var studio = current
        let result = StudioItemImporter.apply(imported, to: &studio) { item in
            remaining -= 1
            if let forAll { return forAll }
            let (choice, all) = dialogs.clashChoice(for: item, remaining: remaining)
            if all { forAll = choice }
            return choice
        }
        studios.update { $0 = studio }
        reloadEngine()
        notice = Self.summary(result)
    }

    static func summary(_ r: ItemImportResult) -> String {
        var parts: [String] = []
        if !r.added.isEmpty { parts.append("\(r.added.count) added") }
        if !r.replaced.isEmpty { parts.append("\(r.replaced.count) replaced") }
        if !r.keptBoth.isEmpty { parts.append("\(r.keptBoth.count) kept as copies") }
        if !r.skipped.isEmpty { parts.append("\(r.skipped.count) skipped") }
        if !r.mediaAdded.isEmpty { parts.append("\(r.mediaAdded.count) media reference\(r.mediaAdded.count == 1 ? "" : "s") added") }
        var text = "Imported items: " + (parts.isEmpty ? "nothing new" : parts.joined(separator: ", ")) + "."
        if !r.notRead.isEmpty { text += " Not read: " + r.notRead.joined(separator: "; ") + "." }
        return text
    }

    // MARK: Media

    var mediaFolders: [URL] { MediaFolders(paths: machine).load() }

    func addMediaFolder() {
        guard let folder = dialogs.chooseFolder(title: "Add Media Folder") else { return }
        do { try MediaFolders(paths: machine).add(folder) } catch { dialogs.showError("The folder could not be added", error) }
    }

    func removeMediaFolder(_ folder: URL) { try? MediaFolders(paths: machine).remove(folder) }

    /// Scans the media folders in the background; found and relinked entries update the Studio's index.
    func relink() {
        guard let index = studios.studio?.media, let id = studios.studio?.id else { return }
        scanTask?.cancel()
        isScanning = true
        let folders = mediaFolders, machine = machine
        scanTask = Task { [weak self] in
            let result = try? await RelinkScanner.run(index: index, folders: folders, machine: machine)
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            guard let report = result, self.studios.studio?.id == id else { return }
            self.relinkReport = report
            self.studios.update { $0.media = report.index }
            self.reloadEngine()
        }
    }

    func cancelRelink() {
        scanTask?.cancel()
        isScanning = false
    }
}

extension Studio {
    /// A new, empty Studio: one empty service, a Default look, and the standard screens (two audience screens on
    /// the canvas, a stage display, the IMAG input) with new ids.
    static func blank(name: String, now: Date, appVersion: String) -> Studio {
        let service = Service(name: "Service", items: [])
        let sample = Studio(seededFrom: .sample, name: name, now: now, appVersion: appVersion)
        return Studio(
            manifest: StudioManifest(name: name, created: now, appVersion: appVersion, activeServiceID: service.id),
            services: [service],
            looks: [Look(name: "Default")],
            screens: sample.screens.map { StudioScreen(name: $0.name, setup: $0.setup) }
        )
    }
}
