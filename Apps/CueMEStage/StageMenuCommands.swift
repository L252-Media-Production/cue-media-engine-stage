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
    @AppStorage(StorageKeys.sideTab) private var sideTabRaw = SideTab.audio.rawValue
    @AppStorage(StorageKeys.monitorScreens) private var monitorRaw = ""
    @Environment(\.openWindow) private var openWindow
    /// The Song editor of the key window, if it is one: Undo and Redo go to it.
    @FocusedValue(\.songEditor) private var editor

    private var selectedSong: Song.ID? { studios.song(for: store.state.item(ui.selection))?.id }
    private var fileModel: FileMenuModel {
        FileMenuModel(hasStudio: studios.studios.studio != nil, isModalOpen: ui.isModalOpen, selectedSong: selectedSong)
    }

    private func openEditor(_ song: Song.ID) { SongEditorScene.open(song, studios: studios, with: openWindow) }

    private var model: ServiceMenuModel { ServiceMenuModel(state: store.state, selection: ui.selection, isModalOpen: ui.isModalOpen) }

    var body: some Commands {
        // Replacing the New group also removes the WindowGroup's New Window, so Cmd-N is New Studio only.
        CommandGroup(replacing: .newItem) {
            let file = fileModel
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
            // MenuBar.dc.html `file`: the New group comes first, then Import, then Close Window.
            Button("New Service…") {}.disabled(true)
            Button("New Collection…") { ui.showNewCollection = true }
                .keyboardShortcut(Shortcuts.newCollection)
                .disabled(!file.canNewCollection)
            Button("New Song…") { if let id = studios.newSong() { openEditor(id) } }
                .keyboardShortcut(Shortcuts.newSong)
                .disabled(!file.canNewSong)
            Divider()
            Button("Import Studio…") { studios.chooseAndImportStudio() }
                .disabled(!file.canImportStudio)
            Button("Import Items…") { studios.chooseAndImportItems() }
                .disabled(!file.canImportItems)
            Button("Export Studio…") { studios.exportStudio() }
                .disabled(!file.canExport)
            Button("Export Selected Item…") { if let id = file.selectedSong { studios.exportSong(id) } }
                .disabled(!file.canExportSelectedItem)
            Divider()
            Button("Relink Media…") { ui.showRelink = true }
                .disabled(!file.canRelink)
            Divider()
            // Replacing the Save group (below) also drops the system Close, so Close Window is here, last
            // (MenuBar.dc.html `file`). It closes the operator window only; nothing live stops, and the Dock icon opens
            // the window again (AppDelegate).
            Button("Close Window") { (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil) }
                .keyboardShortcut(Shortcuts.closeWindow)
                .disabled(!file.canCloseWindow)
        }
        // Undo and Redo: in a Song editor they undo its edits (never show control); elsewhere they go to the focused
        // text field as usual.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if let editor { editor.undo() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            .keyboardShortcut(Shortcuts.undo)
            .disabled(editor.map { !$0.canUndo } ?? false)
            Button("Redo") {
                if let editor { editor.redo() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            .keyboardShortcut(Shortcuts.redo)
            .disabled(editor.map { !$0.canRedo } ?? false)
        }
        // Edit > Edit Selected Item… last (MenuBarRef.dc.html, Edit).
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Edit Selected Item…") { if let id = fileModel.selectedSong { openEditor(id) } }
                .keyboardShortcut(Shortcuts.editSelectedItem)
                .disabled(!fileModel.canEditSelectedItem)
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
            // Panel sizes are this machine's (PanelSizes); the defaults are the mockup's.
            Button("Reset Panel Sizes") { PanelSizes.resetAll(in: .standard) }
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
            // The right column's tabs (Main.dc.html L1229); they only pick the tab.
            ForEach(SideTab.allCases) { tab in
                Toggle(tab.menuTitle, isOn: Binding(
                    get: { SideTab.resolve(sideTabRaw) == tab },
                    set: { if $0 { sideTabRaw = tab.rawValue } }
                ))
                .keyboardShortcut(Shortcuts.sideTab(tab))
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
                // Fades out over 2 s, then stops (ClearAudio); Stop Playback is the instant stop.
                Button("Audio") { ClearAudio.commands(store.state).forEach(store.send) }
                    .disabled(ClearAudio.commands(store.state).isEmpty)
                Button("Message") { store.send(.clear(.messages)) }
            }
            Toggle("Black Out", isOn: Binding(get: { model.isBlackout }, set: { _ in store.send(model.blackoutCommand) }))
                .keyboardShortcut(Shortcuts.blackout)
            Divider()
            Menu("Audio") {
                let toggle = model.audioToggle
                Button(toggle.title) { toggle.command.map(store.send) }
                    .keyboardShortcut(Shortcuts.audioPlayPause)
                    .disabled(toggle.command == nil)
                Button("Stop Playback") { store.send(.stopAudio) }
                    .keyboardShortcut(Shortcuts.audioStop)
                    .disabled(!model.hasTrack)
                Button("Fade Out") { store.send(.fadeAudio(seconds: 3)) }
                    .keyboardShortcut(Shortcuts.audioFadeOut)
                    .disabled(!model.hasTrack)
                Button("Skip Next Trigger") { store.send(.skipNextTrigger) }
                    .keyboardShortcut(Shortcuts.skipNextTrigger)
                    .disabled(!model.canSkipTrigger)
            }
            // Main.dc.html L1233: Hide All Messages and Stop All Timers; then one toggle per saved message.
            Menu("Messages") {
                Button("Hide All Messages") { store.send(model.hideAllMessagesCommand) }
                    .disabled(!model.canHideAllMessages)
                Button("Stop All Timers") { model.stopAllTimersCommands.forEach(store.send) }
                    .disabled(!model.canStopAllTimers)
                if model.hasMessages {
                    Divider()
                    ForEach(store.state.messages) { message in
                        Toggle(message.text, isOn: Binding(
                            get: { model.isVisible(message) },
                            set: { _ in store.send(model.toggleCommand(message)) }
                        ))
                    }
                }
            }
            Divider()
            Button("Add Section…") { ui.showAddSection = true }
                .disabled(studios.studios.studio == nil || store.state.service == nil || ui.isModalOpen)
            Button("Add Activity…") {}.disabled(true)
        }

        CommandMenu("Output") {
            Button("Output Setup…") { ui.showOutputSetup = true }
                .keyboardShortcut(Shortcuts.outputSetup)
            Button("Visuals…") {}
                .keyboardShortcut(Shortcuts.visuals)
                .disabled(true)
            Divider()
            // The right column's monitor; the same per-Studio choice as its output picker.
            Menu("Monitor") {
                let state = store.state
                let choice = MonitorChoice(raw: monitorRaw)
                ForEach(state.outputScreens) { screen in
                    Toggle(screen.name, isOn: Binding(
                        get: { choice.screenID(in: state) == screen.screenID },
                        set: { _ in monitorRaw = choice.choosing(screen.screenID, for: state.studio).raw }
                    ))
                }
            }
            .disabled(store.state.outputScreens.isEmpty)
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
