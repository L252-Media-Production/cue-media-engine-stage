import SwiftUI

@main
struct CueMEStageApp: App {
    // TODO(ipc): swap the mock for the StageEngine IPC client once it exists. Nothing else changes.
    @State private var store = StageStore.mock()
    @State private var ui = OperatorUIState()
    init() {
        // Before any view reads ThemeTokens (which also registers on first use, so the order is safe either way).
        BundledFonts.registerOnce()
        ShortcutGuard.install()
        // Before the first window exists, so a saved Dark never flashes light; then on every change of the setting.
        ThemeAppearance.applyStored()
        ThemeAppearance.startFollowingDefaults()
    }

    var body: some Scene {
        WindowGroup("CueME Stage") {
            // The theme is applied through NSApp.appearance (ThemeAppearance), not preferredColorScheme: SwiftUI on
            // macOS does not refresh an open window when a forced scheme is removed, so Auto would not follow the
            // system. `Themed` reads the resulting colour scheme.
            OperatorView(store: store, ui: ui)
                .modifier(Themed())
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands {
            StageMenuCommands(store: store, ui: ui)
        }
    }
}
