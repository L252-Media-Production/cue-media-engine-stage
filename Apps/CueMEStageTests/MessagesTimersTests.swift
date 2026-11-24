import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The right-column Message and Timer tabs and their editors (MainMessages, MessageEditor, MessageEditorStyle,
/// MainTimers, TimerEditor, TimerEditorTo boards): lit states from the state only, the Commands sent, editor
/// validation, the controls that cannot be used yet, and the menus.
final class MessagesTimersModelTests: XCTestCase {
    let a = Message(text: "Please be seated")
    let b = Message(text: "Prayer next")
    let countdown = StageTimer(name: "Countdown", mode: .countdown, duration: 300)
    let clock = StageTimer(name: "Service clock", mode: .countUp)

    // MARK: Message tab

    func testMessageRowsAreLitFromVisibleMessagesOnly() {
        let state = StageState(messages: [a, b], visibleMessages: [b.id])
        let model = MessagesPanelModel(messages: [a, b], state: state, hasStudio: true)
        XCTAssertFalse(model.isShowing(a))
        XCTAssertTrue(model.isShowing(b))
        XCTAssertEqual(model.liveNote, "1 live")
        XCTAssertTrue(model.canHideAll)
        // A Studio copy that differs from the state's does not matter: only the id is looked up.
        let edited = Message(id: b.id, text: "Edited")
        XCTAssertTrue(MessagesPanelModel(messages: [edited], state: state, hasStudio: true).isShowing(edited))
    }

    func testMessageCommands() {
        let state = StageState(messages: [a, b], visibleMessages: [b.id])
        let model = MessagesPanelModel(messages: [a, b], state: state, hasStudio: true)
        XCTAssertEqual(model.toggleCommand(a), .showMessage(a.id, screens: []), "every screen")
        XCTAssertEqual(model.toggleCommand(b), .hideMessage(b.id), "hides this one only")
        XCTAssertEqual(model.hideAllCommand, .clear(.messages))
    }

    func testNothingShowingAndNoStudio() {
        let model = MessagesPanelModel(messages: [], state: StageState(), hasStudio: false)
        XCTAssertEqual(model.liveNote, "0 live")
        XCTAssertFalse(model.canHideAll)
        XCTAssertFalse(model.canAdd)
    }

    func testAShowingMessageCannotBeDeleted() {
        let model = MessagesPanelModel(messages: [a, b], state: StageState(visibleMessages: [a.id]), hasStudio: true)
        XCTAssertFalse(model.canDelete(a))
        XCTAssertTrue(model.canDelete(b))
        XCTAssertFalse(MessagesPanelModel.deleteBlockedHelp.isEmpty)
    }

    // MARK: Timer tab

    func testTimerRowsAreLitFromRunningTimersOnly() {
        let state = StageState(runningTimers: [countdown.id])
        let model = TimersPanelModel(timers: [countdown, clock], state: state, hasStudio: true)
        XCTAssertTrue(model.isRunning(countdown))
        XCTAssertFalse(model.isRunning(clock))
        XCTAssertEqual(model.runningNote, "1 running")
        XCTAssertTrue(model.canStopAll)
        XCTAssertFalse(model.canDelete(countdown))
        XCTAssertTrue(model.canDelete(clock))
    }

    func testTimerCommands() {
        let model = TimersPanelModel(timers: [countdown, clock], state: StageState(runningTimers: [countdown.id]), hasStudio: true)
        XCTAssertEqual(model.toggleCommand(countdown), .stopTimer(countdown.id))
        XCTAssertEqual(model.toggleCommand(clock), .startTimer(clock.id))
        XCTAssertEqual(model.resetCommand(clock), .resetTimer(clock.id))
        XCTAssertEqual(model.stopAllCommands, [.stopTimer(countdown.id)])
        XCTAssertEqual(TimersPanelModel(timers: [], state: StageState(), hasStudio: true).stopAllCommands, [])
    }

    func testTimerTextIsFromTheModelAndTheTimeIsADash() {
        XCTAssertEqual(TimersPanelModel.modeLine(countdown), "Count down from 5:00")
        XCTAssertEqual(TimersPanelModel.modeLine(StageTimer(name: "Prayer", mode: .countdown, duration: 600)), "Count down from 10:00")
        XCTAssertEqual(TimersPanelModel.modeLine(clock), "Count up from 0:00")
        XCTAssertEqual(TimersPanelModel.clock(3725), "62:05")
        XCTAssertEqual(TimersPanelModel.timeText, "—", "nothing reports the time yet")
        XCTAssertFalse(TimersPanelModel.overrunHelp.isEmpty)
    }

    // MARK: Message editor

    func testMessageEditorNewAndEdit() {
        var new = MessageEditorModel(target: .new, messages: [a])
        XCTAssertTrue(new.isNew)
        XCTAssertEqual(new.title, "New message")
        XCTAssertFalse(new.canSave)
        XCTAssertEqual(new.invalidReason, "Type the message")
        new.text = "   \n "
        XCTAssertFalse(new.canSave, "blank text is not a message")
        new.text = "  Wrap up in 2 min \n"
        XCTAssertTrue(new.canSave)
        XCTAssertEqual(new.message.text, "Wrap up in 2 min")
        XCTAssertNotEqual(new.message.id, a.id)
        XCTAssertEqual(new.message.id, new.message.id, "one id for the editor's life")

        var edit = MessageEditorModel(target: .edit(a.id), messages: [a, b])
        XCTAssertEqual(edit.title, "Edit message")
        XCTAssertEqual(edit.text, a.text)
        edit.text = "Please stand"
        XCTAssertEqual(edit.message, Message(id: a.id, text: "Please stand"))
    }

    func testMessageEditorControlsWithoutAField() {
        XCTAssertEqual(MessageEditorModel.styles, ["Top banner", "Bottom banner", "Full-screen takeover", "Scrolling ticker"])
        XCTAssertEqual(MessageEditorModel.durations, ["Until hidden", "10 s", "30 s", "1 min"])
        XCTAssertEqual(MessageEditorModel.durations.filter(MessageEditorModel.isDurationAvailable), ["Until hidden"])
        for help in [MessageEditorModel.styleHelp, MessageEditorModel.durationHelp, MessageEditorModel.flashHelp,
                     MessageEditorModel.sendToHelp, MessageEditorModel.editTemplatesHelp] {
            XCTAssertTrue(help.contains("v0.1"), help)
        }
        XCTAssertEqual(MessageEditorModel.summary(screenCount: 3), "3 screens · Until hidden")
        XCTAssertEqual(MessageEditorModel.summary(screenCount: 1), "1 screen · Until hidden")
        XCTAssertEqual(MessageEditorModel.typeLabel(.speaker), "Speaker display")
    }

    // MARK: Timer editor

    func testTimerEditorNew() {
        var model = TimerEditorModel(target: .new, timers: [])
        XCTAssertEqual(model.title, "New timer")
        XCTAssertEqual(model.kind, .countDownFrom)
        XCTAssertEqual(model.previewText, "05:00", "the board's default length")
        XCTAssertEqual(model.invalidReason, "Name the timer")
        model.name = "Announcements"
        XCTAssertTrue(model.canSave)
        model.minutes = 0
        model.seconds = 0
        XCTAssertEqual(model.invalidReason, "A countdown needs a length above 0:00")
        model.choose(.countUp)
        XCTAssertTrue(model.canSave, "a count-up timer needs no length")
        XCTAssertEqual(model.fieldLabel, "STARTS AT")
        XCTAssertFalse(model.fieldsEditable)
        XCTAssertFalse(model.showsOverrun)
        XCTAssertEqual(model.timer.mode, .countUp)
    }

    func testTimerEditorEditKeepsIdAndLength() {
        var model = TimerEditorModel(target: .edit(countdown.id), timers: [clock, countdown])
        XCTAssertEqual(model.title, "Edit timer")
        XCTAssertEqual(model.name, "Countdown")
        XCTAssertEqual(model.minutes, 5)
        XCTAssertEqual(model.seconds, 0)
        model.stepSeconds(true)
        XCTAssertEqual(model.timer, StageTimer(id: countdown.id, name: "Countdown", mode: .countdown, duration: 305))
        let long = StageTimer(name: "Long", mode: .countdown, duration: 150 * 60 + 7)
        let longModel = TimerEditorModel(target: .edit(long.id), timers: [long])
        XCTAssertEqual(longModel.maxMinutes, 150)
        XCTAssertEqual(longModel.timer.duration, long.duration, "an imported long timer is not cut to 99 minutes")
    }

    func testTimerEditorStepsWrapLikeTheBoard() {
        var model = TimerEditorModel(target: .new, timers: [])
        model.minutes = 99
        model.stepMinutes(true)
        XCTAssertEqual(model.minutes, 0)
        model.stepMinutes(false)
        XCTAssertEqual(model.minutes, 99)
        model.seconds = 55
        model.stepSeconds(true)
        XCTAssertEqual(model.seconds, 0)
        model.stepSeconds(false)
        XCTAssertEqual(model.seconds, 55)
        model.seconds = 7
        model.stepSeconds(true)
        XCTAssertEqual(model.seconds, 10, "snaps to the 5-second grid")
        model.seconds = 7
        model.stepSeconds(false)
        XCTAssertEqual(model.seconds, 5)
    }

    func testCountDownToTimeCannotBeChosen() {
        XCTAssertEqual(TimerKind.allCases.map(\.rawValue), ["Count down from", "Count down to time", "Count up"])
        XCTAssertFalse(TimerKind.countDownTo.isAvailable)
        XCTAssertTrue(TimerKind.countDownTo.help.contains("time-of-day"))
        var model = TimerEditorModel(target: .new, timers: [])
        model.choose(.countDownTo)
        XCTAssertEqual(model.kind, .countDownFrom, "unchanged")
    }

    // MARK: Menus and shortcuts

    func testMessagesMenuEntries() {
        let state = StageState(messages: [a, b], visibleMessages: [a.id], runningTimers: [countdown.id, clock.id])
        let model = ServiceMenuModel(state: state, selection: nil)
        XCTAssertTrue(model.canHideAllMessages)
        XCTAssertEqual(model.hideAllMessagesCommand, .clear(.messages))
        XCTAssertTrue(model.canStopAllTimers)
        XCTAssertEqual(model.stopAllTimersCommands, [.stopTimer(countdown.id), .stopTimer(clock.id)])
        let idle = ServiceMenuModel(state: StageState(messages: [a]), selection: nil)
        XCTAssertFalse(idle.canHideAllMessages)
        XCTAssertFalse(idle.canStopAllTimers)
    }

    func testRightColumnTabShortcuts() {
        XCTAssertEqual(SideTab.allCases.map(Shortcuts.sideTab), [
            KeyboardShortcut("1", modifiers: [.command, .option]),
            KeyboardShortcut("2", modifiers: [.command, .option]),
            KeyboardShortcut("3", modifiers: [.command, .option]),
        ], "Main.dc.html L1229")
        XCTAssertEqual(SideTab.allCases.map(\.menuTitle), ["Audio (right column)", "Message", "Timer"])
        for tab in SideTab.allCases { XCTAssertTrue(Shortcuts.all.contains(Shortcuts.sideTab(tab))) }
        XCTAssertEqual(Set(Shortcuts.all).count, Shortcuts.all.count, "no shortcut used twice")
        XCTAssertFalse(Shortcuts.unmodified.contains(Shortcuts.sideTab(.message)))
        XCTAssertFalse(Shortcuts.textEditingCollisions.contains(Shortcuts.sideTab(.timer)))
        XCTAssertEqual(SideTab.resolve("Timer"), .timer)
    }

    @MainActor
    func testTheEditorsAreModal() {
        let ui = OperatorUIState()
        XCTAssertFalse(ui.isModalOpen)
        ui.messageEditor = .new
        XCTAssertTrue(ui.isModalOpen)
        ui.messageEditor = nil
        ui.timerEditor = .edit(UUID())
        XCTAssertTrue(ui.isModalOpen)
        XCTAssertFalse(ServiceMenuModel(state: StageState(), selection: nil, isModalOpen: ui.isModalOpen).canNext)
    }
}

/// Saving, deleting, showing and starting through the Studio and the mock engine.
@MainActor
final class MessagesTimersStudioTests: StudioEditTestCase {
    func testSaveAddsAMessageTheEngineCanShow() async {
        await launch()
        let before = controller.studios.saveCount
        var editor = MessageEditorModel(target: .new, messages: studio.messages)
        editor.text = "Please silence your phones"
        let message = editor.message
        // "Save and show": save (sends reloadStudio), then show, through the one ordered queue.
        controller.saveMessage(message)
        stage.send(.showMessage(message.id, screens: []))
        await until("showing") { [self] in stage.state.visibleMessages == [message.id] }
        XCTAssertEqual(studio.messages.last, message)
        let written = await saved(after: before)
        XCTAssertEqual(Set(written), ["messages.json", "manifest.json"], "only messages.json (and the manifest)")
        let model = MessagesPanelModel(messages: studio.messages, state: stage.state, hasStudio: true)
        XCTAssertTrue(model.isShowing(message))
        XCTAssertEqual(model.toggleCommand(message), .hideMessage(message.id))
    }

    func testEditingAShowingMessageDoesNotChangeWhatIsShown() async {
        await launch()
        let original = studio.messages[0]
        stage.send(.showMessage(original.id, screens: []))
        await until("showing") { [self] in stage.state.visibleMessages == [original.id] }
        controller.saveMessage(Message(id: original.id, text: "Edited while showing"))
        stage.send(.next) // something after the reload, to know the reload was applied
        await until("reloaded") { [self] in stage.state.primaryLive != nil }
        XCTAssertEqual(studio.messages[0].text, "Edited while showing", "the Studio has the edit")
        XCTAssertEqual(stage.state.messages.first { $0.id == original.id }?.text, original.text, "the screens keep the shown text")
        XCTAssertEqual(stage.state.visibleMessages, [original.id], "still showing")
        stage.send(.showMessage(original.id, screens: []))
        await until("shown again") { [self] in stage.state.messages.first { $0.id == original.id }?.text == "Edited while showing" }
    }

    func testDeleteMessageAndTimer() async {
        await launch()
        let message = studio.messages[0], timer = studio.timers[0]
        controller.deleteMessage(message.id)
        controller.deleteTimer(timer.id)
        XCTAssertEqual(studio.messages, [])
        XCTAssertEqual(studio.timers, [])
        await until("the engine has it") { [self] in stage.state.messages.isEmpty }
    }

    func testSaveTimerThenStartStopAll() async {
        await launch()
        var editor = TimerEditorModel(target: .new, timers: studio.timers)
        editor.name = "Prayer"
        editor.minutes = 10
        let timer = editor.timer
        controller.saveTimer(timer)
        XCTAssertEqual(studio.timers.last, timer)
        let model = TimersPanelModel(timers: studio.timers, state: stage.state, hasStudio: true)
        stage.send(model.toggleCommand(timer))
        stage.send(model.toggleCommand(studio.timers[0]))
        await until("both running") { [self] in Set(stage.state.runningTimers) == Set(studio.timers.map(\.id)) }
        let running = TimersPanelModel(timers: studio.timers, state: stage.state, hasStudio: true)
        XCTAssertTrue(studio.timers.allSatisfy(running.isRunning))
        XCTAssertEqual(running.runningNote, "2 running")
        ServiceMenuModel(state: stage.state, selection: nil).stopAllTimersCommands.forEach(stage.send)
        await until("all stopped") { [self] in stage.state.runningTimers.isEmpty }

        var edit = TimerEditorModel(target: .edit(timer.id), timers: studio.timers)
        edit.choose(.countUp)
        controller.saveTimer(edit.timer)
        XCTAssertEqual(studio.timers.last?.mode, .countUp)
        XCTAssertEqual(studio.timers.count, 2, "replaced, not added")
    }
}
