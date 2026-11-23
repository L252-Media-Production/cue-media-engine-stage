import SwiftUI

@main
struct CueMEStageApp: App {
    // TODO(ipc): swap the mock for the StageEngine IPC client once it exists. Nothing else changes.
    @State private var store = StageStore.mock()
    @State private var ui = OperatorUIState()
    @AppStorage(StorageKeys.theme) private var themeRaw = AppTheme.fallback.rawValue

    init() {
        // Before any view reads ThemeTokens (which also registers on first use, so the order is safe either way).
        BundledFonts.registerOnce()
        ShortcutGuard.install()
    }

    var body: some Scene {
        WindowGroup("CueME Stage") {
            OperatorView(store: store, ui: ui)
                .preferredColorScheme(AppTheme.resolve(themeRaw).colorScheme)
                .modifier(Themed())
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            StageMenuCommands(store: store, ui: ui)
        }
    }
}
