import Foundation
import Observation
import SwiftUI
import StageKit

/// UI state shared by the operator view and the menu bar (not engine state): which service item is selected.
@MainActor
@Observable
final class OperatorUIState {
    var selection: Item.ID?
}

/// UserDefaults keys used through @AppStorage.
enum StorageKeys {
    /// `AppTheme.rawValue`.
    static let theme = "cueme.theme"
    /// `BottomTab.rawValue` of the selected bottom-panel tab.
    static let bottomTab = "cueme.operator.bottomTab"
}

enum AppTheme: String, CaseIterable {
    case dark, light

    /// An unknown saved value falls back to dark.
    static func resolve(_ raw: String) -> AppTheme { AppTheme(rawValue: raw) ?? .dark }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// Bottom-panel tabs, in menu order (View > Cmd-1 ... Cmd-5).
enum BottomTab: String, CaseIterable, Identifiable {
    case scripture = "Scripture"
    case media = "Media"
    case looks = "Looks"
    case audio = "Audio"
    case activities = "Activities"

    var id: Self { self }
    /// Scripture, Media and Looks are placeholders that cannot be opened yet.
    var isEnabled: Bool { self == .audio || self == .activities }

    /// The tab for a saved value: an unknown or disabled value falls back to Audio.
    static func resolve(_ raw: String) -> BottomTab {
        guard let tab = BottomTab(rawValue: raw), tab.isEnabled else { return .audio }
        return tab
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
    /// Cmd-1 ... Cmd-5 in `BottomTab.allCases` order.
    static func tab(_ tab: BottomTab) -> KeyboardShortcut {
        let n = (BottomTab.allCases.firstIndex(of: tab) ?? 0) + 1
        return KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
    }

    static var all: [KeyboardShortcut] {
        [goLive, nextSlide, previousSlide, clearSlide, clearAll, blackout, audioPlayPause, audioStop, audioFadeOut,
         skipNextTrigger] + BottomTab.allCases.map(tab)
    }

    /// Shortcuts without Command, Control or Option: these must never fire while text input has focus.
    static var unmodified: [KeyboardShortcut] {
        all.filter { $0.modifiers.intersection([.command, .control, .option]).isEmpty }
    }
}

/// What the Service menu offers for a state and a selection. Pure, so it is tested without the UI.
struct ServiceMenuModel {
    let state: StageState
    let selection: Item.ID?

    /// The selected service item, when it is still in the service.
    var goLiveItem: Item? { state.item(selection) }
    var goLiveCommand: Command? { goLiveItem.map { .go(itemID: $0.id, slideIndex: 0) } }

    var canNext: Bool { state.nextSlide != nil }
    /// StageState does not say whether there is a slide before the cursor; the engine refuses at the start.
    var canPrevious: Bool { !(state.service?.items.isEmpty ?? true) }

    var blackoutTitle: String { state.blackout ? "End Black Out" : "Black Out" }
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
