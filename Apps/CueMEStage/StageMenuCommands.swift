import SwiftUI
import StageKit

/// The menu bar. Every live entry sends a `Command`; entries with nothing behind them yet are disabled.
/// Shortcuts come from `Shortcuts`; the unmodified ones are kept away from text input by `ShortcutGuard`.
struct StageMenuCommands: Commands {
    let store: StageStore
    let ui: OperatorUIState
    let studios: StudioController
    @AppStorage(StorageKeys.theme) private var themeRaw = AppTheme.fallback.rawValue
    @AppStorage(StorageKeys.bottomTab) private var bottomTabRaw = BottomTab.audio.rawValue

    private var model: ServiceMenuModel { ServiceMenuModel(state: store.state, selection: ui.selection, isModalOpen: ui.isModalOpen) }

    var body: some Commands {
        // Replacing the New group also removes the WindowGroup's New Window, so Cmd-N is New Studio only.
        CommandGroup(replacing: .newItem) {
            let file = FileMenuModel(hasStudio: studios.studios.studio != nil, isModalOpen: ui.isModalOpen)
            Button("New Studio…") { studios.newStudio() }
                .keyboardShortcut(Shortcuts.newStudio)
                .disabled(!file.canNew)
            Button("Open Studio…") { studios.chooseAndOpen() }
                .keyboardShortcut(Shortcuts.openStudio)
                .disabled(!file.canOpen)
            Menu("Open Recent") {
                let others = studios.recentMenuURLs
                if others.isEmpty {
                    Button("No Other Studios") {}.disabled(true)
                }
                ForEach(others, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { studios.open(url) }
                }
                Divider()
                Button("Clear Menu") { studios.recents.clear() }
                    .disabled(studios.recents.urls.isEmpty)
            }
            .disabled(!file.canOpen)
            Button("Close Studio") { studios.closeStudio() }
                .disabled(!file.canClose)
            Divider()
            Button("Import Studio…") { studios.chooseAndImportStudio() }
                .disabled(!file.canImportStudio)
            Button("Import Items…") { studios.chooseAndImportItems() }
                .disabled(!file.canImportItems)
            Button("Export Studio…") { studios.exportStudio() }
                .disabled(!file.canExport)
            Button("Export Selected Item…") {}
                .disabled(!file.canExportSelectedItem)
            Divider()
            Button("Relink Media…") { ui.showRelink = true }
                .disabled(!file.canRelink)
            Divider()
            Button("New Service") {}.disabled(true)
        }
        // A Studio saves itself (autosave), so there is no Save; the system's Save items are removed.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .printItem) {}

        // View menu (Enter Full Screen stays where the system puts it).
        CommandGroup(before: .toolbar) {
            Button("Operator") {}.disabled(true)
            Button("Editor") {}.disabled(true)
            Divider()
            Menu("Theme") {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Toggle(theme.title, isOn: Binding(
                        get: { AppTheme.resolve(themeRaw) == theme },
                        set: { if $0 { themeRaw = theme.rawValue } }
                    ))
                }
            }
            Divider()
            ForEach(BottomTab.allCases) { tab in
                Toggle(tab.rawValue, isOn: Binding(
                    get: { BottomTab.resolve(bottomTabRaw) == tab },
                    set: { if $0 { bottomTabRaw = tab.rawValue } }
                ))
                .keyboardShortcut(Shortcuts.tab(tab))
                .disabled(!tab.isEnabled)
            }
            Divider()
        }

        CommandMenu("Service") {
            let model = model
            Button("Go Live") { model.goLiveCommand.map(store.send) }
                .keyboardShortcut(Shortcuts.goLive)
                .disabled(model.goLiveCommand == nil)
            Button("Next Slide") { store.send(.next) }
                .keyboardShortcut(Shortcuts.nextSlide)
                .disabled(!model.canNext)
            Button("Previous Slide") { store.send(.previous) }
                .keyboardShortcut(Shortcuts.previousSlide)
                .disabled(!model.canPrevious)
            Divider()
            Menu("Clear") {
                Button("All") { store.send(.clear(.all)) }
                    .keyboardShortcut(Shortcuts.clearAll)
                Button("Slide") { store.send(.clear(.slide)) }
                    .keyboardShortcut(Shortcuts.clearSlide)
                Button("Media") {}.disabled(true) // no Command clears media yet
                Button("Audio") { store.send(.clear(.audio)) }
                Button("Message") { store.send(.clear(.messages)) }
            }
            Button(model.blackoutTitle) { store.send(model.blackoutCommand) }
                .keyboardShortcut(Shortcuts.blackout)
            Divider()
            Menu("Audio") {
                let toggle = model.audioToggle
                Button(toggle.title) { toggle.command.map(store.send) }
                    .keyboardShortcut(Shortcuts.audioPlayPause)
                    .disabled(toggle.command == nil)
                Button("Stop") { store.send(.stopAudio) }
                    .keyboardShortcut(Shortcuts.audioStop)
                    .disabled(!model.hasTrack)
                Button("Fade Out") { store.send(.fadeAudio(seconds: 3)) }
                    .keyboardShortcut(Shortcuts.audioFadeOut)
                    .disabled(!model.hasTrack)
                Button("Skip Next Trigger") { store.send(.skipNextTrigger) }
                    .keyboardShortcut(Shortcuts.skipNextTrigger)
                    .disabled(!model.canSkipTrigger)
            }
            Menu("Messages") {
                ForEach(store.state.messages) { message in
                    Toggle(message.text, isOn: Binding(
                        get: { model.isVisible(message) },
                        set: { _ in store.send(model.toggleCommand(message)) }
                    ))
                }
            }
            .disabled(!model.hasMessages)
            Divider()
            Button("Add Section…") {}.disabled(true)
            Button("Add Activity…") {}.disabled(true)
        }

        CommandMenu("Output") {
            Button("Output Setup…") { ui.showOutputSetup = true }
                .keyboardShortcut(Shortcuts.outputSetup)
            Button("Visuals…") {}
                .keyboardShortcut(Shortcuts.visuals)
                .disabled(true)
            Divider()
            Menu("Monitor") {
                ForEach(store.state.outputScreens) { screen in Button(screen.name) {} }
            }
            .disabled(true)
            Menu("Test Pattern") {
                let model = TestPatternMenuModel(state: store.state)
                ForEach(TestPattern.allCases, id: \.self) { pattern in
                    Menu(pattern.title) {
                        ForEach(Array(model.targets.enumerated()), id: \.offset) { _, entry in
                            Toggle(entry.title, isOn: Binding(
                                get: { model.isActive(entry.target, pattern) },
                                set: { _ in store.send(model.command(entry.target, pattern)) }
                            ))
                        }
                    }
                }
                Divider()
                Button("Off") { store.send(.hideTestPattern) }
                    .disabled(!model.canTurnOff)
            }
            Divider()
            Button("Restart Engine…") {}.disabled(true)
        }
    }
}
