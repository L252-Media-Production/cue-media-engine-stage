import SwiftUI

@main
struct CueMEStageApp: App {
    // TODO(ipc): swap the mock for the StageEngine IPC client once it exists. Nothing else changes.
    @State private var store = StageStore.mock()

    init() {
        // Before any view reads ThemeTokens (which also registers on first use, so the order is safe either way).
        BundledFonts.registerOnce()
    }

    var body: some Scene {
        WindowGroup("CueME Stage") {
            OperatorView(store: store)
                .modifier(Themed())
                .frame(minWidth: 1000, minHeight: 620)
        }
        .commands {
            StageMenuCommands(store: store)
        }
    }
}
