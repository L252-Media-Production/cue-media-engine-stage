import AppKit
import SwiftUI
import StageKit

@main
struct CueMEStageApp: App {
    /// First of all: a second copy hands over to the running one and quits here. Stored properties are initialised in
    /// order and before `init`, so this runs before the delegate below (and with it the store, any Studio or lock file)
    /// is created.
    private let singleInstance: Void = SingleInstance.enforce()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    init() {
        LaunchTiming.mark("App.init start")
        defer { LaunchTiming.mark("App.init end") }
        // Before any view reads ThemeTokens (which also registers on first use, so the order is safe either way).
        LaunchTiming.measure("BundledFonts.registerOnce") { BundledFonts.registerOnce() }
        LaunchTiming.measure("ShortcutGuard.install") { ShortcutGuard.install() }
        // Before the first window exists, so a saved Dark never flashes light; then on every change of the setting.
        LaunchTiming.measure("ThemeAppearance") {
            ThemeAppearance.applyStored()
            ThemeAppearance.startFollowingDefaults()
        }
    }

    var body: some Scene {
        WindowGroup("CueME Stage") {
            // The theme is applied through NSApp.appearance (ThemeAppearance), not preferredColorScheme: SwiftUI on
            // macOS does not refresh an open window when a forced scheme is removed, so Auto would not follow the
            // system. `Themed` reads the resulting colour scheme.
            OperatorView(store: app.store, ui: app.ui, studios: app.studios)
                .modifier(Themed())
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { LaunchTiming.markFirstWindow() }
        }
        .commands {
            StageMenuCommands(store: app.store, ui: app.ui, studios: app.studios)
        }

        // The Song editor: its own window, one per song (opening a song that has one brings it to the front).
        WindowGroup("Song Editor", id: SongEditorScene.id, for: SongEditorTarget.self) { $target in
            if let target {
                SongEditorView(model: app.editors.model(for: target, controller: app.studios)) {
                    app.editors.close(target)
                }
                .modifier(Themed())
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commandsRemoved()
    }
}

enum SongEditorScene {
    static let id = "song-editor"
}

/// Owns the engine client, the UI state and the Studio controller, opens the last Studio at launch, routes files
/// opened from the Finder (.stg opens, .stgbundle imports, .stgitem imports items), and saves on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let ui = OperatorUIState()
    var editors: SongEditorRegistry { studios.editors }
    let store: StageStore
    let studios: StudioController
    private var launched = false
    private var pending: [URL] = []

    /// Under XCTest the app is only a test host: no Studio is opened and nothing is written to Documents or the
    /// real machine folder.
    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    override init() {
        LaunchTiming.mark("AppDelegate.init start")
        defer { LaunchTiming.mark("AppDelegate.init end") }
        // TODO(ipc): swap the mock for the StageEngine IPC client once it exists. Nothing else changes.
        let catalog = StudioCatalog()
        let store = StageStore.mock(library: .empty, studios: catalog)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let environment: StudioStore.Environment
        let documents: URL
        if Self.isTestHost {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cueme-testhost-\(UUID().uuidString)", isDirectory: true)
            let machine = MachinePaths(root: temp.appendingPathComponent("Machine", isDirectory: true))
            environment = StudioStore.Environment(machine: machine, identity: MachineIdentity(id: UUID(), name: "Test host"), appVersion: version)
            documents = temp
        } else {
            environment = LaunchTiming.measure("StudioStore.Environment.standard") { .standard(appVersion: version) }
            documents = StudioLocations.defaultFolder
        }
        self.store = store
        self.studios = StudioController(
            studios: StudioStore(environment: environment), stage: store, catalog: catalog,
            defaults: .standard, documentsFolder: documents, dialogs: AppKitStudioDialogs()
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        guard !Self.isTestHost else { return }
        LaunchTiming.mark("did finish launching")
        // A Studio double-clicked to launch the app opens instead of the last one.
        if let studio = pending.first(where: { $0.pathExtension == StudioFormat.packageExtension }) {
            if !studios.open(studio, checkLive: false) { studios.launch() }
        } else {
            LaunchTiming.measure("StudioController.launch") { studios.launch() }
        }
        let rest = pending.filter { $0.pathExtension != StudioFormat.packageExtension }
        pending = []
        handle(rest)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { handle(urls) } else { pending += urls }
    }

    private func handle(_ urls: [URL]) {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case StudioFormat.packageExtension: studios.open(url)
            case StudioFormat.bundleExtension: studios.importStudio(url)
            case StudioFormat.itemExtension: studios.importItems(url)
            default: break
            }
        }
    }

    /// Quitting while live asks first (QuitDialog.dc.html); Cancel keeps everything running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminateReply(studios)
    }

    static func terminateReply(_ studios: StudioController) -> NSApplication.TerminateReply {
        studios.shouldQuit() ? .terminateNow : .terminateCancel
    }

    /// File > Close Window closes the operator window only: the engine, the open Studio and anything live keep running,
    /// and clicking the Dock icon opens the window again on the same state (the store, UI state and Studio live here).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        studios.shutdown()
    }
}
