import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

@MainActor
final class OperatorModelTests: XCTestCase {
    let lib = Library.sample
    var amazing: Item { lib.service.items[1] }
    var doxology: Item { lib.service.items[3] }
    var walkInID: MediaItem.ID { lib.media[0].id }

    private func state(_ commands: [Command], tick: Double = 0) async -> StageState {
        let client = MockStageClient(library: lib)
        for command in commands { await client.send(command) }
        if tick > 0 { await client.tick(seconds: tick) }
        return await client.currentState
    }

    // MARK: Service menu enablement

    func testGoLiveFollowsTheSelection() async {
        let s = await state([])
        XCTAssertNil(ServiceMenuModel(state: s, selection: nil).goLiveCommand)
        XCTAssertNil(ServiceMenuModel(state: s, selection: UUID()).goLiveCommand, "an item not in the service")
        XCTAssertEqual(ServiceMenuModel(state: s, selection: amazing.id).goLiveCommand, .go(itemID: amazing.id, slideIndex: 0))
        XCTAssertNil(ServiceMenuModel(state: StageState(), selection: amazing.id).goLiveCommand, "no service loaded")
    }

    func testNextPreviousAndBlackout() async {
        var m = ServiceMenuModel(state: await state([]), selection: nil)
        XCTAssertTrue(m.canNext)
        XCTAssertTrue(m.canPrevious)
        XCTAssertFalse(m.isBlackout, "Black Out, no checkmark")
        XCTAssertEqual(m.blackoutCommand, .blackout(true))

        m = ServiceMenuModel(state: await state([.go(itemID: doxology.id, slideIndex: 1), .blackout(true)]), selection: nil)
        XCTAssertFalse(m.canNext, "end of service")
        XCTAssertTrue(m.isBlackout, "the same title, with a checkmark")
        XCTAssertEqual(m.blackoutCommand, .blackout(false))

        m = ServiceMenuModel(state: StageState(), selection: nil)
        XCTAssertFalse(m.canNext)
        XCTAssertFalse(m.canPrevious)
    }

    func testAudioEntries() async {
        var m = ServiceMenuModel(state: await state([]), selection: nil)
        XCTAssertNil(m.audioToggle.command)
        XCTAssertFalse(m.hasTrack)
        XCTAssertFalse(m.canSkipTrigger)

        m = ServiceMenuModel(state: await state([.playAudio(mediaID: walkInID)]), selection: nil)
        XCTAssertEqual(m.audioToggle.title, "Pause")
        XCTAssertEqual(m.audioToggle.command, .pauseAudio)
        XCTAssertTrue(m.hasTrack)
        XCTAssertTrue(m.canSkipTrigger)

        m = ServiceMenuModel(state: await state([.playAudio(mediaID: walkInID), .pauseAudio]), selection: nil)
        XCTAssertEqual(m.audioToggle.title, "Resume")
        XCTAssertEqual(m.audioToggle.command, .resumeAudio)

        m = ServiceMenuModel(state: await state([.playAudio(mediaID: walkInID), .fadeAudio(seconds: 3)]), selection: nil)
        XCTAssertNil(m.audioToggle.command, "nothing to toggle while fading")
        XCTAssertTrue(m.hasTrack)
    }

    func testMessagesShowOnAllScreensThenHide() async {
        let message = lib.messages[0]
        var m = ServiceMenuModel(state: await state([]), selection: nil)
        XCTAssertTrue(m.hasMessages)
        XCTAssertFalse(m.isVisible(message))
        XCTAssertEqual(m.toggleCommand(message), .showMessage(message.id, screens: []))

        m = ServiceMenuModel(state: await state([.showMessage(message.id)]), selection: nil)
        XCTAssertTrue(m.isVisible(message))
        XCTAssertEqual(m.toggleCommand(message), .hideMessage(message.id))

        XCTAssertFalse(ServiceMenuModel(state: StageState(), selection: nil).hasMessages)
    }

    // MARK: Status chips

    func testEngineChipIsNeutralAtZeroAndAmberAboveIt() {
        let clean = EngineChipModel(counters: AudioCounters())
        XCTAssertFalse(clean.isAlert)
        XCTAssertTrue(clean.tooltip.hasPrefix("Engine counters clean"))

        for counters in [AudioCounters(droppedEnds: 1), AudioCounters(droppedFires: 1), AudioCounters(poolExhausted: 1)] {
            XCTAssertTrue(EngineChipModel(counters: counters).isAlert, "\(counters)")
        }
        let some = EngineChipModel(counters: AudioCounters(droppedEnds: 2, droppedFires: 0, poolExhausted: 5))
        XCTAssertEqual(some.tooltip, "Dropped ends: 2, Pool exhausted: 5")
    }

    func testAudioChipLabels() {
        XCTAssertEqual(AudioState.Transport.stopped.label, "Stopped")
        XCTAssertEqual(AudioState.Transport.playing.label, "Playing")
        XCTAssertEqual(AudioState.Transport.paused.label, "Paused")
        XCTAssertEqual(AudioState.Transport.fading.label, "Fading")
    }

    // MARK: Saved choices

    func testBottomTabFallsBackToAudio() {
        XCTAssertEqual(BottomTab.resolve("Audio"), .audio)
        XCTAssertEqual(BottomTab.resolve("Activities"), .audio, "disabled in v0.1")
        XCTAssertEqual(BottomTab.allCases.filter(\.isEnabled), [.audio], "only Audio opens in v0.1")
        XCTAssertEqual(BottomTab.resolve("Scripture"), .audio, "disabled")
        XCTAssertEqual(BottomTab.resolve("Media"), .audio, "disabled")
        XCTAssertEqual(BottomTab.resolve("Looks"), .audio, "disabled")
        XCTAssertEqual(BottomTab.resolve("nonsense"), .audio, "unknown")
        XCTAssertEqual(BottomTab.resolve(""), .audio)
    }

    func testThemeFallsBackToDark() {
        XCTAssertEqual(AppTheme.resolve("auto"), .auto)
        XCTAssertEqual(AppTheme.resolve("light"), .light, "a saved value from before Auto still works")
        XCTAssertEqual(AppTheme.resolve("dark"), .dark)
        XCTAssertEqual(AppTheme.resolve("sepia"), .dark)
        XCTAssertEqual(AppTheme.resolve(""), .dark)
        XCTAssertEqual(AppTheme.allCases.map(\.title), ["Auto", "Dark", "Light"], "menu order")
    }

    func testFreshInstallIsDark() {
        XCTAssertEqual(AppTheme.fallback, .dark, "the @AppStorage default of every theme reader")
    }

    // MARK: Modal sheets

    func testLiveEntriesAreOffWhileASheetIsOpen() async {
        let s = await state([.go(itemID: amazing.id, slideIndex: 0), .playAudio(mediaID: walkInID)])
        let open = ServiceMenuModel(state: s, selection: amazing.id, isModalOpen: true)
        XCTAssertNil(open.goLiveCommand, "Go Live off")
        XCTAssertFalse(open.canNext, "Next off")
        XCTAssertFalse(open.canPrevious, "Previous off")
        // Emergency entries stay on.
        XCTAssertEqual(open.blackoutCommand, .blackout(true))
        XCTAssertEqual(open.audioToggle.command, .pauseAudio)
        XCTAssertTrue(open.hasTrack, "Stop and Fade Out")

        let closed = ServiceMenuModel(state: s, selection: amazing.id, isModalOpen: false)
        XCTAssertNotNil(closed.goLiveCommand)
        XCTAssertTrue(closed.canNext)
        XCTAssertTrue(closed.canPrevious)
    }

    func testModalFlagFollowsTheSheet() {
        let ui = OperatorUIState()
        XCTAssertFalse(ui.isModalOpen)
        ui.showOutputSetup = true
        XCTAssertTrue(ui.isModalOpen)
    }

    // MARK: Shortcut table

    func testShortcutTable() {
        XCTAssertEqual(Shortcuts.blackout, KeyboardShortcut(".", modifiers: .command))
        XCTAssertEqual(Shortcuts.audioStop, KeyboardShortcut(".", modifiers: [.command, .option]))
        XCTAssertEqual(BottomTab.allCases.map { Shortcuts.tab($0).key.character }, ["1", "2", "3", "4", "5"])
        XCTAssertEqual(Set(Shortcuts.all).count, Shortcuts.all.count, "no shortcut is used twice")
        XCTAssertEqual(Shortcuts.unmodified, [Shortcuts.goLive, Shortcuts.nextSlide, Shortcuts.previousSlide])
        XCTAssertEqual(Shortcuts.outputSetup, KeyboardShortcut("o", modifiers: [.command, .shift]))
        XCTAssertEqual(Shortcuts.visuals, KeyboardShortcut("v", modifiers: [.command, .shift]))
        XCTAssertTrue(Shortcuts.all.contains(Shortcuts.outputSetup))
        XCTAssertTrue(Shortcuts.all.contains(Shortcuts.visuals))
    }

    // MARK: Right column: Clear row

    func testClearRowButtonsSendTheExistingCommands() async {
        // With every layer on air (an unlit button sends nothing: see ClearBlockTests).
        let model = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0), .playAudio(mediaID: walkInID),
                                                      .showMessage(lib.messages[0].id, screens: [])]))
        XCTAssertEqual(ClearButton.allCases.map(\.rawValue), ["All", "Slide", "Media", "Audio", "Message", "Black"], "board order")
        XCTAssertEqual(model.commands(.all), [.clear(.all), .clear(.audio)], "All also clears audio, .all first")
        XCTAssertEqual(model.commands(.slide), [.clear(.slide)])
        XCTAssertEqual(model.commands(.audio), [.clear(.audio)])
        XCTAssertEqual(model.commands(.message), [.clear(.messages)])
        XCTAssertEqual(model.commands(.media), [], "no media layer in v0.1")
        XCTAssertEqual(ClearButton.allCases.filter { !model.isEnabled($0) }, [.media])
        XCTAssertEqual(model.help(.media), "Media clear is not available in v0.1")
    }

    func testBlackIsTheGlobalBlackoutLikeTheMenu() async {
        for on in [false, true] {
            let s = await state(on ? [.blackout(true)] : [])
            let model = ClearRowModel(state: s)
            XCTAssertEqual(model.commands(.black), [ServiceMenuModel(state: s, selection: nil).blackoutCommand],
                           "the same command as Service > Black Out and Cmd-.")
            XCTAssertEqual(model.isBlack, on, "filled amber while on")
            XCTAssertTrue(model.isEnabled(.black))
        }
    }

    func testClearAllEmptiesSlideMessagesAndAudio() async {
        let message = lib.messages[0]
        let client = MockStageClient(library: lib)
        for command in [Command.go(itemID: amazing.id, slideIndex: 0), .showMessage(message.id, screens: []), .playAudio(mediaID: walkInID)] {
            await client.send(command)
        }
        var s = await client.currentState
        XCTAssertNotNil(s.primaryLive)
        XCTAssertFalse(s.visibleMessages.isEmpty)
        XCTAssertNotNil(s.audio.liveTrack)
        for command in ClearRowModel(state: s).commands(.all) { await client.send(command) }
        s = await client.currentState
        XCTAssertNil(s.primaryLive, "slide cleared")
        XCTAssertTrue(s.visibleMessages.isEmpty, "messages hidden")
        XCTAssertNil(s.audio.liveTrack, "audio cleared")
    }

    func testClearScopeIsAllScreensOnly() async {
        let s = await state([])
        let model = ClearRowModel(state: s)
        XCTAssertEqual(model.scopes.map(\.title), ["All screens", "Left", "Stage", "Right"], "All screens, then each output screen")
        XCTAssertEqual(model.scope, .allScreens)
        XCTAssertTrue(model.canPick(.allScreens))
        for screen in s.outputScreens {
            XCTAssertFalse(model.canPick(.screen(screen.screenID)), "\(screen.name): no per-screen Command in v0.1")
        }
        XCTAssertEqual(ClearRowModel.perScreenHelp, "Per-screen clear is not available in v0.1")
    }

    // MARK: Right column: monitor

    func testMonitorChoiceIsRememberedPerStudio() async throws {
        var s = await state([])
        let sunday = StudioInfo(id: UUID(), name: "Sunday"), youth = StudioInfo(id: UUID(), name: "Youth")
        let stage = try XCTUnwrap(s.outputScreens.first { $0.name == "Stage" })
        let right = try XCTUnwrap(s.outputScreens.first { $0.name == "Right" })

        s.studio = sunday
        XCTAssertEqual(MonitorChoice().screen(in: s)?.name, "Left", "nothing chosen: the first output screen")
        var choice = MonitorChoice().choosing(stage.screenID, for: sunday)
        s.studio = youth
        XCTAssertEqual(choice.screen(in: s)?.name, "Left", "another Studio keeps its own (none yet)")
        choice = choice.choosing(right.screenID, for: youth)

        // Stored as the app stores it, then read back (a relaunch, or another window).
        let suite = "cueme.tests.monitor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(choice.raw, forKey: StorageKeys.monitorScreens)
        let reread = MonitorChoice(raw: defaults.string(forKey: StorageKeys.monitorScreens) ?? "")
        s.studio = sunday
        XCTAssertEqual(reread.screen(in: s)?.name, "Stage")
        s.studio = youth
        XCTAssertEqual(reread.screen(in: s)?.name, "Right")

        // The chosen screen is gone (removed, or now an input): back to the first output screen.
        s.screens.removeAll { $0.screenID == right.screenID }
        XCTAssertEqual(reread.screen(in: s)?.name, "Left")
        XCTAssertEqual(MonitorChoice(raw: "not json").screen(in: s)?.name, "Left")
    }

    func testMonitorStatus() async throws {
        let live = await state([.go(itemID: amazing.id, slideIndex: 0)])
        let left = try XCTUnwrap(live.outputScreens.first)
        XCTAssertEqual(MonitorStatus.of(left, in: live), .live)
        let idle = await state([])
        XCTAssertEqual(MonitorStatus.of(try XCTUnwrap(idle.outputScreens.first), in: idle), .clear)
        let black = await state([.go(itemID: amazing.id, slideIndex: 0), .blackout(true)])
        XCTAssertEqual(MonitorStatus.of(try XCTUnwrap(black.outputScreens.first), in: black), .black)
    }

    func testOutputPickerGroupsByScreenType() async {
        let sections = OutputPickerModel(state: await state([])).sections
        XCTAssertEqual(sections.map(\.title), ["AUDIENCE", "STAGE"])
        XCTAssertEqual(sections.map { $0.screens.map(\.name) }, [["Left", "Right"], ["Stage"]], "no input screen")
    }

    // MARK: Status bar

    func testOutputsCountAndDropped() async throws {
        let client = MockStageClient(library: lib)
        var s = await client.currentState
        let assigned = s.outputScreens.filter { s.connectorID(for: $0.screenID) != nil }.count
        XCTAssertGreaterThan(assigned, 0, "the sample rig assigns its screens")
        var model = OutputsStatusModel(state: s)
        XCTAssertEqual(model.text, "Outputs \(assigned) / \(assigned)")
        XCTAssertEqual(model.level, .ok)
        XCTAssertEqual(model.dropped, 0)

        let first = try XCTUnwrap(s.outputs.first), second = try XCTUnwrap(s.outputs.dropFirst().first)
        await client.simulateOutput(first.outputID, health: .offline, droppedFrames: 3)
        await client.simulateOutput(second.outputID, health: .degraded, droppedFrames: 4)
        s = await client.currentState
        model = OutputsStatusModel(state: s)
        XCTAssertEqual(model.text, "Outputs \(assigned - 1) / \(assigned)", "an offline output is not connected")
        XCTAssertEqual(model.level, .degraded)
        XCTAssertEqual(model.dropped, 7, "sum over every output")

        s.assignments = s.assignments.map { OutputAssignment(screenID: $0.screenID, connectorID: nil) }
        model = OutputsStatusModel(state: s)
        XCTAssertEqual(model.text, "Outputs 0 / 0")
        XCTAssertNil(model.level, "neutral: nothing assigned on this Mac")
    }

    func testOutputsCountIgnoresUnavailableConnectors() async throws {
        var s = await state([])
        let connector = try XCTUnwrap(s.outputScreens.compactMap { s.connectorID(for: $0.screenID) }.first)
        let expected = OutputsStatusModel(state: s).expected
        s.connectors = s.connectors.map { var c = $0; if c.id == connector { c.available = false }; return c }
        XCTAssertEqual(OutputsStatusModel(state: s).connected, expected - 1)
        s.connectors.removeAll()
        XCTAssertEqual(OutputsStatusModel(state: s).connected, 0)
        XCTAssertEqual(OutputsStatusModel(state: s).level, .offline)
    }

    func testRightColumnTabsAndSizes() {
        XCTAssertEqual(SideTab.allCases.map(\.rawValue), ["Audio", "Message", "Timer"], "Main.dc.html L993")
        XCTAssertEqual(SideTab.resolve("Message"), .message)
        XCTAssertEqual(SideTab.resolve("Timer"), .audio, "disabled in v0.1")
        XCTAssertEqual(SideTab.resolve("nonsense"), .audio)
        XCTAssertEqual(BottomTab.allCases.map(\.rawValue), ["Scripture", "Media", "Looks", "Audio", "Activities"], "Main.dc.html L999")
        XCTAssertEqual(OperatorLayout.rightColumnWidth, 360)
        XCTAssertEqual(OperatorLayout.bottomPanelHeight, 330)
        XCTAssertEqual(OperatorLayout.statusBarHeight, 28)
    }
}
