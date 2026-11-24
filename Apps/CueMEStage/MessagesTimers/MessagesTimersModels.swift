import Foundation
import StageKit

/// What an editor sheet edits: a new item, or the saved one with this id.
enum ItemEditorTarget: Identifiable, Equatable, Hashable {
    case new
    case edit(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(id): id.uuidString
        }
    }
}

// MARK: Message tab

/// The right-column Message tab (Main.dc.html L625, board MainMessages.dc.html). The list is the Studio's saved messages;
/// what is showing comes from `StageState.visibleMessages` only.
struct MessagesPanelModel {
    /// The open Studio's messages (empty without a Studio).
    let messages: [Message]
    let state: StageState
    let hasStudio: Bool

    func isShowing(_ message: Message) -> Bool { state.visibleMessages.contains(message.id) }

    /// "n live": every visible message, also one no longer in the Studio.
    var liveNote: String { "\(state.visibleMessages.count) live" }
    var canHideAll: Bool { !state.visibleMessages.isEmpty }
    var hideAllCommand: Command { .clear(.messages) }

    /// Show on every screen (`showMessage(id, screens: [])`), or hide this one (`hideMessage`).
    func toggleCommand(_ message: Message) -> Command {
        isShowing(message) ? .hideMessage(message.id) : .showMessage(message.id, screens: [])
    }

    var canAdd: Bool { hasStudio }
    /// A message on air is hidden first; deleting never takes anything off the screens.
    func canDelete(_ message: Message) -> Bool { !isShowing(message) }

    static let destination = "All screens"
    static let addHelp = "New message"
    static let noStudioHelp = "Open a Studio to add messages"
    static let deleteBlockedHelp = "Hide the message before deleting it"
    static let footnote = "Several messages can be live at once. In v0.1 each goes to every screen."
}

// MARK: Timer tab

/// The right-column Timer tab (Main.dc.html L647, board MainTimers.dc.html). The list is the Studio's timers; what runs
/// comes from `StageState.runningTimers` only. Neither the state nor the model has a timer's current time, so the time
/// is a dash.
struct TimersPanelModel {
    let timers: [StageTimer]
    let state: StageState
    let hasStudio: Bool

    func isRunning(_ timer: StageTimer) -> Bool { state.runningTimers.contains(timer.id) }

    var runningNote: String { "\(state.runningTimers.count) running" }
    var canStopAll: Bool { !state.runningTimers.isEmpty }
    var stopAllCommands: [Command] { state.runningTimers.map(Command.stopTimer) }

    /// ▶ starts, ❚❚ stops (the board's Start / Pause; the Command is `stopTimer`).
    func toggleCommand(_ timer: StageTimer) -> Command { isRunning(timer) ? .stopTimer(timer.id) : .startTimer(timer.id) }
    /// The board's Restart.
    func resetCommand(_ timer: StageTimer) -> Command { .resetTimer(timer.id) }

    var canAdd: Bool { hasStudio }
    func canDelete(_ timer: StageTimer) -> Bool { !isRunning(timer) }

    /// "Count down from 5:00" or "Count up from 0:00" (the board's row sub-line).
    static func modeLine(_ timer: StageTimer) -> String {
        switch timer.mode {
        case .countdown: "Count down from \(clock(timer.duration))"
        case .countUp: "Count up from 0:00"
        }
    }

    /// Minutes and seconds, minutes not padded: 300 → "5:00", 3725 → "62:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The time a timer shows now. The engine does not report it yet.
    static let timeText = "—"
    static let timeHelp = "The engine does not report a timer's time yet"
    static let overrunHelp = "Overrun is not available in v0.1: a timer has no overrun setting"
    static let deleteBlockedHelp = "Stop the timer before deleting it"
    static let noStudioHelp = "Open a Studio to add timers"
}

// MARK: Message editor

/// The message editor sheet (MessageEditor.dc.html; Style menu MessageEditorStyle.dc.html). A `Message` has only its
/// text, so MESSAGE is the one field; STYLE, SHOW FOR (other than "Until hidden"), Flash when shown and SEND TO are
/// drawn but cannot be changed.
struct MessageEditorModel {
    let target: ItemEditorTarget
    let original: Message?
    let id: Message.ID
    var text: String

    init(target: ItemEditorTarget, messages: [Message]) {
        self.target = target
        if case let .edit(id) = target, let message = messages.first(where: { $0.id == id }) {
            original = message
            self.id = id
            text = message.text
        } else {
            original = nil
            id = UUID()
            text = ""
        }
    }

    var isNew: Bool { original == nil }
    var title: String { isNew ? "New message" : "Edit message" }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedText.isEmpty }
    /// Why Save is off, or nil.
    var invalidReason: String? { canSave ? nil : "Type the message" }

    var message: Message { Message(id: id, text: trimmedText) }

    /// The board's styles. None can be chosen: a message has no style field.
    static let styles = ["Top banner", "Bottom banner", "Full-screen takeover", "Scrolling ticker"]
    static let styleTitle = "—"
    static let styleHelp = "Message styles are not available in v0.1: a message has no style yet"
    static let editTemplatesHelp = "Message templates are not available in v0.1"

    /// SHOW FOR. A message shows until it is hidden; the others need a duration field a message does not have.
    static let durations = ["Until hidden", "10 s", "30 s", "1 min"]
    static let durationHelp = "In v0.1 a message shows until it is hidden: a message has no duration"
    static func isDurationAvailable(_ duration: String) -> Bool { duration == durations[0] }

    static let flashHelp = "Flash when shown is not available in v0.1"
    static let sendToHelp = "In v0.1 every message goes to every output screen: a message has no screen list"

    /// Footer: "3 screens · Until hidden" (the board adds the style, which a message does not have).
    static func summary(screenCount: Int) -> String {
        "\(screenCount) \(screenCount == 1 ? "screen" : "screens") · \(durations[0])"
    }

    /// Shown when editing a message that is on air.
    static let showingNote = "Showing now. The screens keep the shown text until you show it again."

    static func typeLabel(_ type: ScreenType?) -> String {
        switch type {
        case .audience?, nil: "Audience"
        case .stage?: "Stage"
        case .announcements?: "Announcements"
        case .speaker?: "Speaker display"
        case .input?: "Input"
        }
    }
}

// MARK: Timer editor

/// The board's three timer types. "Count down to time" needs a time of day, which `StageTimer` does not have.
enum TimerKind: String, CaseIterable, Identifiable {
    case countDownFrom = "Count down from"
    case countDownTo = "Count down to time"
    case countUp = "Count up"

    var id: Self { self }
    var isAvailable: Bool { self != .countDownTo }
    var help: String {
        isAvailable ? "" : "Count down to time is not available in v0.1: a timer has no time-of-day field"
    }
}

/// The timer editor sheet (TimerEditor.dc.html; TimerEditorTo.dc.html is the disabled third type). Fields are what
/// `StageTimer` has: name, mode (count down or up) and the countdown length.
struct TimerEditorModel {
    let target: ItemEditorTarget
    let original: StageTimer?
    let id: StageTimer.ID
    var name: String
    var kind: TimerKind
    var minutes: Int
    var seconds: Int
    /// 99, or more when an imported timer is longer, so editing never shortens it.
    let maxMinutes: Int

    init(target: ItemEditorTarget, timers: [StageTimer]) {
        self.target = target
        let timer: StageTimer? = if case let .edit(id) = target { timers.first { $0.id == id } } else { nil }
        original = timer
        id = timer?.id ?? UUID()
        name = timer?.name ?? ""
        kind = timer?.mode == .countUp ? .countUp : .countDownFrom
        let total = max(0, Int((timer?.duration ?? 300).rounded()))
        minutes = total / 60
        seconds = total % 60
        maxMinutes = max(99, minutes)
    }

    var isNew: Bool { original == nil }
    var title: String { isNew ? "New timer" : "Edit timer" }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var duration: Double { Double(minutes * 60 + seconds) }

    var invalidReason: String? {
        if trimmedName.isEmpty { return "Name the timer" }
        if kind == .countDownFrom && duration <= 0 { return "A countdown needs a length above 0:00" }
        return nil
    }

    var canSave: Bool { invalidReason == nil }

    mutating func choose(_ kind: TimerKind) {
        guard kind.isAvailable else { return }
        self.kind = kind
    }

    /// The board's arrows: minutes by 1 (0...max), seconds by 5 (0...55), both wrapping.
    mutating func stepMinutes(_ up: Bool) {
        minutes = up ? (minutes >= maxMinutes ? 0 : minutes + 1) : (minutes <= 0 ? maxMinutes : minutes - 1)
    }

    mutating func stepSeconds(_ up: Bool) {
        let snapped = seconds - seconds % 5
        seconds = up ? (snapped + 5 > 55 ? 0 : snapped + 5) : (seconds % 5 != 0 ? snapped : (snapped - 5 < 0 ? 55 : snapped - 5))
    }

    /// Count up has no start value of its own: it always starts at 00:00.
    var fieldsEditable: Bool { kind == .countDownFrom }
    var fieldLabel: String { kind == .countUp ? "STARTS AT" : "MINUTES : SECONDS" }
    var shownMinutes: Int { kind == .countUp ? 0 : minutes }
    var shownSeconds: Int { kind == .countUp ? 0 : seconds }
    var previewText: String { String(format: "%02d:%02d", shownMinutes, shownSeconds) }
    /// The Overrun row is there for countdowns (disabled: no field).
    var showsOverrun: Bool { kind != .countUp }

    /// A count-up timer keeps the length it had, so switching back to a countdown restores it.
    var timer: StageTimer {
        StageTimer(id: id, name: trimmedName, mode: kind == .countUp ? .countUp : .countdown, duration: duration)
    }
}
