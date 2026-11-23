import Foundation
import Observation
import SwiftUI
import StageKit

/// UI state shared by the operator view and the menu bar (not engine state): which service item is selected and
/// which sheet is open.
@MainActor
@Observable
final class OperatorUIState {
    var selection: Item.ID?
    var showOutputSetup = false
    var showRelink = false
    /// The New collection dialog (a sheet).
    var showNewCollection = false
    /// The Section popover under "+ Add ▾".
    var showAddSection = false

    /// True while any sheet, dialog or popover of the app is open. While it is, Go Live, Next and Previous are off in
    /// the menu and `ShortcutGuard` keeps Return and the arrows away from the menu. A new sheet's flag must be added
    /// here. (Dialogs shown from inside a sheet, such as Output Setup's "Apply your changes?", are covered by the
    /// sheet.) Editor windows are not modal: they are separate windows, and `ShortcutGuard` keeps show keys out of them.
    var isModalOpen: Bool { showOutputSetup || showRelink || showNewCollection || showAddSection }
}

/// UserDefaults keys used through @AppStorage.
enum StorageKeys {
    /// `AppTheme.rawValue`.
    static let theme = "cueme.theme"
    /// `BottomTab.rawValue` of the selected bottom-panel tab.
    static let bottomTab = "cueme.operator.bottomTab"
    /// `OutputSetupTab.rawValue` of the Output Setup sheet.
    static let outputSetupTab = "cueme.outputSetup.tab"
    /// `Screen.ID.uuidString` of the screen selected in Output Setup.
    static let outputSetupScreen = "cueme.outputSetup.screen"
    /// Path of the last opened Studio package; reopened at launch.
    static let lastStudio = "cueme.studio.last"
    /// `MonitorChoice.raw`: the output screen the right-column monitor shows, per Studio, on this machine.
    static let monitorScreens = "cueme.operator.monitorScreens"
    /// `SideTab.rawValue` of the right column's Audio / Message / Timer tabs.
    static let sideTab = "cueme.operator.sideTab"
    /// Panel sizes in points (`PanelSizes`), on this machine only.
    static let servicePanelWidth = "cueme.layout.servicePanelWidth"
    static let rightColumnWidth = "cueme.layout.rightColumnWidth"
    static let bottomPanelHeight = "cueme.layout.bottomPanelHeight"
}

/// View > Theme. A fresh install is dark (the `@AppStorage` default); Auto follows the system appearance.
enum AppTheme: String, CaseIterable {
    case auto, dark, light

    /// A fresh install (the `@AppStorage` default) and an unknown saved value both get this.
    static let fallback = AppTheme.dark

    static func resolve(_ raw: String) -> AppTheme { AppTheme(rawValue: raw) ?? fallback }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Bottom-panel tabs, in menu order (View > Cmd-1 ... Cmd-5).
enum BottomTab: String, CaseIterable, Identifiable {
    case scripture = "Scripture"
    case media = "Media"
    case looks = "Looks"
    case audio = "Audio"
    case activities = "Activities"

    var id: Self { self }
    /// Only Audio in v0.1. Scripture, Media, Looks and Activities are placeholders that cannot be opened yet (their tabs
    /// and View > Cmd-1/2/3/5 are disabled).
    var isEnabled: Bool { self == .audio }

    /// The tab for a saved value: an unknown or disabled value falls back to Audio.
    static func resolve(_ raw: String) -> BottomTab {
        guard let tab = BottomTab(rawValue: raw), tab.isEnabled else { return .audio }
        return tab
    }
}

/// The right column's tabs under the Clear row (Main.dc.html L993: Audio, Message, Timer).
enum SideTab: String, CaseIterable, Identifiable {
    case audio = "Audio"
    case message = "Message"
    case timer = "Timer"

    var id: Self { self }
    /// Timer is off in v0.1: StageState has no timer list to show (only the ids of running ones).
    var isEnabled: Bool { self != .timer }

    /// The tab for a saved value: an unknown or disabled value falls back to Audio.
    static func resolve(_ raw: String) -> SideTab {
        guard let tab = SideTab(rawValue: raw), tab.isEnabled else { return .audio }
        return tab
    }
}

/// Which output screen the right column's single monitor shows. Kept per Studio on this machine: one JSON map
/// `[Studio id: screen id]` in UserDefaults (`StorageKeys.monitorScreens`), so every window shows the same choice and
/// each Studio keeps its own. A choice whose screen is gone falls back to the Studio's first output screen.
struct MonitorChoice: Equatable {
    /// The stored JSON; "" when nothing was chosen yet.
    var raw: String

    init(raw: String = "") { self.raw = raw }

    /// The map key for a Studio; one shared key while no Studio is open (the mock).
    static func key(_ studio: StudioInfo?) -> String { studio?.id.uuidString ?? "none" }

    private var map: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
    }

    /// The screen the monitor shows for this state: the stored one when it is still an output screen, else the first.
    func screenID(in state: StageState) -> Screen.ID? {
        let screens = state.outputScreens
        if let stored = map[Self.key(state.studio)].flatMap(UUID.init(uuidString:)),
           screens.contains(where: { $0.screenID == stored }) {
            return stored
        }
        return screens.first?.screenID
    }

    func screen(in state: StageState) -> ScreenState? {
        let id = screenID(in: state)
        return state.outputScreens.first { $0.screenID == id }
    }

    /// This choice with `screenID` picked for the state's Studio; the other Studios' choices are kept.
    func choosing(_ screenID: Screen.ID, for studio: StudioInfo?) -> MonitorChoice {
        var map = map
        map[Self.key(studio)] = screenID.uuidString
        let data = (try? JSONEncoder().encode(map)) ?? Data()
        return MonitorChoice(raw: String(decoding: data, as: UTF8.self))
    }
}

/// The status chip and border of a monitor (Main.dc.html L963 `stat`): LIVE red, BLACK amber, CLEAR and TEST grey/amber.
enum MonitorStatus: String {
    case live = "LIVE"
    case black = "BLACK"
    case clear = "CLEAR"
    case test = "TEST"

    /// Blackout is global in v0.1 (`Command.blackout`), so it blacks every screen and the monitor says so.
    static func of(_ screen: ScreenState, in state: StageState) -> MonitorStatus {
        if TestPatternMenuModel(state: state).pattern(on: screen.screenID) != nil { return .test }
        if state.blackout { return .black }
        return screen.live == nil ? .clear : .live
    }
}

/// The output picker's menu (Main.dc.html L951 `menuRows`): the Studio's output screens under their type, then
/// Output Setup….
struct OutputPickerModel {
    let state: StageState

    /// Non-empty groups in the board's order. A screen without a setup is listed as Audience.
    var sections: [(title: String, screens: [ScreenState])] {
        let order: [(ScreenType, String)] = [(.audience, "AUDIENCE"), (.stage, "STAGE"), (.announcements, "ANNOUNCEMENTS"), (.speaker, "SPEAKER")]
        return order.compactMap { type, title in
            let screens = state.outputScreens.filter { (state.screenSetups[$0.screenID]?.type ?? .audience) == type }
            return screens.isEmpty ? nil : (title, screens)
        }
    }
}

/// What the Clear row picks: every screen, or one. Only every screen can be picked in v0.1.
enum ClearScope: Hashable {
    case allScreens
    case screen(Screen.ID)
}

/// The six Clear buttons (Main.dc.html L975).
enum ClearButton: String, CaseIterable, Identifiable {
    case all = "All"
    case slide = "Slide"
    case media = "Media"
    case audio = "Audio"
    case message = "Message"
    case black = "Black"

    var id: Self { self }
}

/// The Clear row under Previous / Next: a scope picker and six buttons. Pure, so it is tested without the UI.
///
/// Uses the existing Commands only. `Command.clear` and `Command.blackout` act on every screen, so the scope is always
/// All screens; the per-screen entries are listed but cannot be picked. There is no media layer, so Media is off.
struct ClearRowModel {
    let state: StageState

    static let perScreenHelp = "Per-screen clear is not available in v0.1"
    static let mediaHelp = "Media clear is not available in v0.1"

    /// "All screens" first, then each output screen (Main.dc.html L980 `scopeNames`).
    var scopes: [(scope: ClearScope, title: String)] {
        [(.allScreens, "All screens")] + state.outputScreens.map { (.screen($0.screenID), $0.name) }
    }

    var scope: ClearScope { .allScreens }
    func canPick(_ scope: ClearScope) -> Bool { scope == .allScreens }

    /// What a press sends, in order. All clears audio too (the board's All), and `.all` leaves audio alone, so it is
    /// `.all` then `.audio`. Black toggles the global blackout, as Service > Black Out and Cmd-. do.
    func commands(_ button: ClearButton) -> [Command] {
        switch button {
        case .all: [.clear(.all), .clear(.audio)]
        case .slide: [.clear(.slide)]
        case .media: []
        case .audio: [.clear(.audio)]
        case .message: [.clear(.messages)]
        case .black: [.blackout(!state.blackout)]
        }
    }

    func isEnabled(_ button: ClearButton) -> Bool { button != .media }

    /// Black is the one button with a state: filled amber while blackout is on.
    var isBlack: Bool { state.blackout }

    func help(_ button: ClearButton) -> String {
        switch button {
        case .all: "Clear slide, messages and audio on all screens"
        case .slide: "Clear the slide on all screens"
        case .media: Self.mediaHelp
        case .audio: "Stop audio"
        case .message: "Hide all messages"
        case .black: state.blackout ? "Blackout is on. Click to end it (Cmd-.)" : "Black out the outputs (Cmd-.)"
        }
    }
}

/// The status bar's "Outputs n / m" and "Dropped n" (Main.dc.html L682, L685). Machine data only: the output screens
/// this Mac drives (this machine's assignments), the connectors the engine reports, and their output health.
struct OutputsStatusModel {
    let state: StageState

    /// Output screens of this Studio assigned to a connector on this machine.
    private var assigned: [(screen: ScreenState, connector: Connector.ID)] {
        state.outputScreens.compactMap { screen in state.connectorID(for: screen.screenID).map { (screen, $0) } }
    }

    private func health(_ connector: Connector.ID) -> OutputStatus.Health {
        guard let found = state.connector(connector), found.available else { return .offline }
        return state.outputs.first { $0.connectorID == connector }?.health ?? .ok
    }

    var expected: Int { assigned.count }
    /// Assigned screens whose connector is present, available and not offline.
    var connected: Int { assigned.filter { health($0.connector) != .offline }.count }
    var text: String { "Outputs \(connected) / \(expected)" }

    /// nil (neutral) when nothing is assigned; offline when none is connected; degraded when some are missing or any
    /// reports degraded; ok otherwise.
    var level: OutputStatus.Health? {
        guard expected > 0 else { return nil }
        if connected == 0 { return .offline }
        if connected < expected || assigned.contains(where: { health($0.connector) == .degraded }) { return .degraded }
        return .ok
    }

    /// Sum of every output's dropped frames.
    var dropped: Int { state.outputs.reduce(0) { $0 + $1.droppedFrames } }

    var tooltip: String {
        guard expected > 0 else {
            return "No screen of this Studio is assigned to a connector on this Mac (Output > Output Setup…)"
        }
        return assigned.map { entry in
            let name = state.connector(entry.connector)?.label ?? entry.connector
            let status = state.outputs.first { $0.connectorID == entry.connector }
            let dropped = status.map { $0.droppedFrames > 0 ? ", \($0.droppedFrames) dropped" : "" } ?? ""
            return "\(entry.screen.name) → \(name): \(health(entry.connector).rawValue)\(dropped)"
        }.joined(separator: "\n")
    }
}

/// Every keyboard shortcut of the menu bar, in one place. `ShortcutGuard` keeps the unmodified ones away from text
/// input, so a new unmodified shortcut must be added here to be covered.
enum Shortcuts {
    static let goLive = KeyboardShortcut(.return, modifiers: [])
    static let nextSlide = KeyboardShortcut(.rightArrow, modifiers: [])
    static let previousSlide = KeyboardShortcut(.leftArrow, modifiers: [])
    static let clearSlide = KeyboardShortcut(.delete, modifiers: .command)
    static let clearAll = KeyboardShortcut(.delete, modifiers: [.command, .shift])
    static let blackout = KeyboardShortcut(".", modifiers: .command)
    static let audioPlayPause = KeyboardShortcut("p", modifiers: [.command, .option])
    static let audioStop = KeyboardShortcut(".", modifiers: [.command, .option])
    static let audioFadeOut = KeyboardShortcut("f", modifiers: [.command, .option])
    static let skipNextTrigger = KeyboardShortcut("s", modifiers: [.command, .option])
    static let outputSetup = KeyboardShortcut("o", modifiers: [.command, .shift])
    static let visuals = KeyboardShortcut("v", modifiers: [.command, .shift])
    /// File > New Studio… and Open Studio…. The File menu's New group is replaced, so the WindowGroup's own
    /// New Window (Cmd-N) is gone and nothing else uses these.
    static let newStudio = KeyboardShortcut("n", modifiers: .command)
    static let openStudio = KeyboardShortcut("o", modifiers: .command)
    /// File > Close Window (the system's Close is removed with the Save group).
    static let closeWindow = KeyboardShortcut("w", modifiers: .command)
    /// File > New Collection… (MenuBar.dc.html `file`).
    static let newCollection = KeyboardShortcut("n", modifiers: [.command, .shift])
    /// File > New Song… (MenuBar.dc.html `file`).
    static let newSong = KeyboardShortcut("n", modifiers: [.command, .option])
    /// Edit > Edit Selected Item… (MenuBarRef.dc.html, Edit).
    static let editSelectedItem = KeyboardShortcut("e", modifiers: .command)
    /// Edit > Undo and Redo (the system's, replaced so a Song editor can take them).
    static let undo = KeyboardShortcut("z", modifiers: .command)
    static let redo = KeyboardShortcut("z", modifiers: [.command, .shift])
    /// Cmd-1 ... Cmd-5 in `BottomTab.allCases` order.
    static func tab(_ tab: BottomTab) -> KeyboardShortcut {
        let n = (BottomTab.allCases.firstIndex(of: tab) ?? 0) + 1
        return KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
    }

    static var all: [KeyboardShortcut] {
        [goLive, nextSlide, previousSlide, clearSlide, clearAll, blackout, audioPlayPause, audioStop, audioFadeOut,
         skipNextTrigger, outputSetup, visuals, newStudio, openStudio, closeWindow, newCollection, newSong, editSelectedItem, undo, redo] + BottomTab.allCases.map(tab)
    }

    /// Show shortcuts that are also standard text-editing keys. Checked against Cmd-Left/Right/Up/Down, Cmd-A, Cmd-Z,
    /// Cmd-C/V/X, Cmd-Delete and Option-Delete: only Clear Slide (Cmd-Delete, "delete to start of line") and Clear All
    /// (Shift-Cmd-Delete, its shifted form) collide. Black Out (Cmd-.) and the Option-Cmd audio keys are emergency
    /// stops, not text keys. `ShortcutGuard` keeps these away from the menu while text has focus outside the operator
    /// window.
    static var textEditingCollisions: [KeyboardShortcut] { [clearSlide, clearAll] }

    /// Shortcuts without Command, Control or Option: these must never fire while text input has focus.
    static var unmodified: [KeyboardShortcut] {
        all.filter { $0.modifiers.intersection([.command, .control, .option]).isEmpty }
    }
}

/// What the Service menu offers for a state and a selection. Pure, so it is tested without the UI.
///
/// While a sheet or dialog is open (`isModalOpen`), Go Live, Next and Previous are off, so nothing is taken live
/// behind the sheet. Black Out, the audio emergency entries (Pause/Resume, Stop, Fade Out) and Clear stay on.
struct ServiceMenuModel {
    let state: StageState
    let selection: Item.ID?
    var isModalOpen = false

    /// The selected service item, when it is still in the service.
    var goLiveItem: Item? { state.item(selection) }
    var goLiveCommand: Command? {
        guard !isModalOpen else { return nil }
        return goLiveItem.map { .go(itemID: $0.id, slideIndex: 0) }
    }

    var canNext: Bool { !isModalOpen && state.nextSlide != nil }
    /// StageState does not say whether there is a slide before the cursor; the engine refuses at the start.
    var canPrevious: Bool { !isModalOpen && !(state.service?.items.isEmpty ?? true) }

    /// Service > Black Out keeps its title and shows a checkmark while on (MenuBar.dc.html `service`; Main.dc.html L1231).
    var isBlackout: Bool { state.blackout }
    var blackoutCommand: Command { .blackout(!state.blackout) }

    /// Pause while playing, Resume while paused; nothing to toggle otherwise.
    var audioToggle: (title: String, command: Command?) {
        switch state.audio.transport {
        case .playing: ("Pause", .pauseAudio)
        case .paused: ("Resume", .resumeAudio)
        case .stopped, .fading: ("Play/Pause", nil)
        }
    }

    var hasTrack: Bool { state.audio.liveTrack != nil }
    var canSkipTrigger: Bool { state.audio.nextTrigger != nil }
    var hasMessages: Bool { !state.messages.isEmpty }

    func isVisible(_ message: Message) -> Bool { state.visibleMessages.contains(message.id) }
    /// Show on every screen, or hide.
    func toggleCommand(_ message: Message) -> Command {
        isVisible(message) ? .hideMessage(message.id) : .showMessage(message.id, screens: [])
    }
}

/// What the File menu's Studio entries allow. While a sheet or dialog is open nothing switches, creates, closes,
/// imports or exports a Studio (as Go Live is off then).
struct FileMenuModel {
    let hasStudio: Bool
    let isModalOpen: Bool
    /// The song of the selected service row, when it is a song.
    var selectedSong: Song.ID? = nil

    var canNew: Bool { !isModalOpen }
    var canOpen: Bool { !isModalOpen }
    var canClose: Bool { hasStudio && !isModalOpen }
    var canImportStudio: Bool { !isModalOpen }
    var canImportItems: Bool { hasStudio && !isModalOpen }
    var canExport: Bool { hasStudio && !isModalOpen }
    var canRelink: Bool { hasStudio && !isModalOpen }
    var canNewCollection: Bool { hasStudio && !isModalOpen }
    /// Not while a sheet is open: the sheet is the key window, and closing under it is not wanted.
    var canCloseWindow: Bool { !isModalOpen }
    /// Songs only for now (presentations and announcements come with their editors).
    var canExportSelectedItem: Bool { hasStudio && !isModalOpen && selectedSong != nil }
    /// File > New Song… and Edit > Edit Selected Item… open an editor window (not modal).
    var canNewSong: Bool { hasStudio && !isModalOpen }
    var canEditSelectedItem: Bool { hasStudio && !isModalOpen && selectedSong != nil }
}

/// The status-bar "Engine" chip: neutral while every audio counter is 0, amber when any is above 0.
struct EngineChipModel {
    let counters: AudioCounters

    var isAlert: Bool { !counters.isClean }

    var tooltip: String {
        let raised = [
            ("Dropped ends", counters.droppedEnds),
            ("Dropped fires", counters.droppedFires),
            ("Pool exhausted", counters.poolExhausted),
        ].filter { $0.1 > 0 }
        guard !raised.isEmpty else { return "Engine counters clean: no dropped ends, dropped fires or pool exhaustion" }
        return raised.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    }
}

extension AudioState.Transport {
    /// "Stopped", "Playing", "Paused" or "Fading".
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}
