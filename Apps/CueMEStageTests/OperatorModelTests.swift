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
        XCTAssertEqual(m.blackoutTitle, "Black Out")
        XCTAssertEqual(m.blackoutCommand, .blackout(true))

        m = ServiceMenuModel(state: await state([.go(itemID: doxology.id, slideIndex: 1), .blackout(true)]), selection: nil)
        XCTAssertFalse(m.canNext, "end of service")
        XCTAssertEqual(m.blackoutTitle, "End Black Out")
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
        XCTAssertEqual(BottomTab.resolve("Activities"), .activities)
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

    func testThemeColourSchemes() {
        XCTAssertNil(AppTheme.auto.colorScheme, "Auto forces nothing, so the system appearance applies")
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
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
}
