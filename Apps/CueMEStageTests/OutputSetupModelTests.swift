import XCTest
import StageKit
@testable import CueMEStage

final class OutputSetupModelTests: XCTestCase {
    let lib = Library.sample
    var left: Screen.ID { lib.screens[0].id }
    var stage: Screen.ID { lib.screens[1].id }
    var right: Screen.ID { lib.screens[2].id }
    var imag: Screen.ID { lib.screens[3].id }

    private func state(_ commands: [Command] = []) async -> StageState {
        let client = MockStageClient(library: lib)
        for command in commands { await client.send(command) }
        return await client.currentState
    }

    /// Sends `commands` to a fresh mock and returns its state, as Apply would.
    private func applied(_ draft: OutputSetupDraft, to state: StageState) async -> StageState {
        await self.state(draft.commands(in: state))
    }

    func testEmptyDraftFollowsTheEngine() async {
        let s = await state()
        let draft = OutputSetupDraft()
        XCTAssertFalse(draft.hasEdits(in: s))
        XCTAssertEqual(draft.commands(in: s), [])
        XCTAssertEqual(draft.connectorID(right, in: s), "decklink-A-3")
        XCTAssertEqual(draft.warnings(in: s), [])
    }

    func testEditBackToTheEngineValueIsNoEdit() async {
        let s = await state()
        var draft = OutputSetupDraft()
        draft.assign("decklink-B-1", to: right, in: s)
        XCTAssertTrue(draft.hasEdits(in: s))
        draft.assign("decklink-A-3", to: right, in: s)
        XCTAssertFalse(draft.hasEdits(in: s))

        var setup = s.screenSetups[right]!
        setup.rotation = .right
        draft.set(setup, for: right, in: s)
        XCTAssertEqual(draft.commands(in: s), [.setScreenSetup(right, setup)])
        setup.rotation = .none
        draft.set(setup, for: right, in: s)
        XCTAssertFalse(draft.hasEdits(in: s))
    }

    func testDraftWarnsBeforeApplyNamingScreensAndCards() async {
        let s = await state()
        var draft = OutputSetupDraft()
        draft.assign("decklink-B-1", to: right, in: s)
        XCTAssertEqual(draft.warnings(in: s), [.canvasSpansCards([left, right])])
        let text = draft.warningTexts(in: s).first ?? ""
        for part in ["Left", "Right", "DeckLink Duo 2 (A)", "DeckLink Duo 2 (B)"] {
            XCTAssertTrue(text.contains(part), "\(part) in \(text)")
        }
        XCTAssertEqual(s.outputWarnings, [], "nothing sent yet")

        draft.assign("display-1", to: right, in: s)
        XCTAssertEqual(draft.warnings(in: s), [.canvasOnNonSDI(right)])
        XCTAssertTrue(draft.warningTexts(in: s)[0].contains("Display 1 (HDMI)"))
    }

    func testSwapIsOrderedSoTheEngineAcceptsIt() async {
        let s = await state()
        var draft = OutputSetupDraft()
        draft.assign("decklink-A-2", to: left, in: s)  // Stage's
        draft.assign("decklink-A-1", to: stage, in: s) // Left's
        XCTAssertEqual(draft.commands(in: s), [
            .assignScreen(left, connector: nil), .assignScreen(stage, connector: nil),
            .assignScreen(left, connector: "decklink-A-2"), .assignScreen(stage, connector: "decklink-A-1"),
        ])
        let after = await applied(draft, to: s)
        XCTAssertEqual(after.connectorID(for: left), "decklink-A-2")
        XCTAssertEqual(after.connectorID(for: stage), "decklink-A-1")
        XCTAssertFalse(draft.hasEdits(in: after), "the engine now matches the draft")
    }

    func testUnassignAndSetupApply() async {
        let s = await state()
        var draft = OutputSetupDraft()
        draft.assign(nil, to: stage, in: s)
        var setup = s.screenSetups[right]!
        setup.lookID = lib.looks[1].id
        setup.canvas = CanvasRect(x: 1920, y: 0, width: 1080, height: 1920)
        draft.set(setup, for: right, in: s)
        let after = await applied(draft, to: s)
        XCTAssertNil(after.connectorID(for: stage))
        XCTAssertEqual(after.screenSetups[right], setup)
    }

    func testConnectorChoicesOnlyFromTheEngineAndFree() async {
        let client = MockStageClient(library: lib)
        await client.simulateConnector("decklink-A-4", available: false)
        let s = await client.currentState
        var draft = OutputSetupDraft()
        draft.assign("decklink-B-1", to: stage, in: s)

        let choices = draft.connectorChoices(for: right, in: s).map(\.id)
        XCTAssertEqual(choices, ["decklink-A-2", "decklink-A-3", "decklink-B-2", "decklink-B-3", "ndi-out-1", "ndi-out-2", "display-1"],
                       "own connector, A-2 freed by the draft; no unavailable A-4, no input, nothing taken")
        XCTAssertEqual(draft.connectorChoices(for: imag, in: s).map(\.id), ["decklink-B-4"], "inputs only")
        XCTAssertTrue(Set(choices).isSubset(of: Set(s.connectors.map(\.id))))
    }

    func testSheetTabFallsBackToScreens() {
        XCTAssertEqual(OutputSetupTab.resolve("Screens"), .screens)
        XCTAssertEqual(OutputSetupTab.resolve("Slices"), .screens, "disabled in v0.1")
        XCTAssertEqual(OutputSetupTab.resolve("x"), .screens)
    }

    func testScreenGroupsByType() {
        XCTAssertEqual(ScreenType.allCases.map(\.groupTitle), ["Audience", "Stage", "Announcements", "Speaker displays", "Inputs"])
    }

    // MARK: Test pattern menu and chip

    func testTestPatternMenu() async {
        var m = TestPatternMenuModel(state: await state())
        XCTAssertEqual(m.targets.map(\.title), ["All Screens", "Left", "Stage", "Right"], "no input screens")
        XCTAssertFalse(m.canTurnOff)
        XCTAssertNil(m.description)
        XCTAssertEqual(m.command(.all, .bars), .showTestPattern(.all, .bars))

        m = TestPatternMenuModel(state: await state([.showTestPattern(.screen(stage), .grid)]))
        XCTAssertTrue(m.isActive(.screen(stage), .grid))
        XCTAssertFalse(m.isActive(.all, .grid))
        XCTAssertEqual(m.command(.screen(stage), .grid), .hideTestPattern, "choosing the checked entry turns it off")
        XCTAssertEqual(m.command(.all, .bars), .showTestPattern(.all, .bars))
        XCTAssertTrue(m.canTurnOff)
        XCTAssertEqual(m.description, "Grid on Stage")
        XCTAssertEqual(m.pattern(on: stage), .grid)
        XCTAssertNil(m.pattern(on: left))
    }

    func testMonitorsShowThePatternButLiveStaysTrue() async {
        let song = lib.service.items[1]
        let s = await state([.go(itemID: song.id, slideIndex: 0), .showTestPattern(.all, .bars)])
        let m = TestPatternMenuModel(state: s)
        XCTAssertEqual(m.description, "Bars on all screens")
        XCTAssertTrue(s.outputScreens.allSatisfy { m.pattern(on: $0.screenID) == .bars })
        XCTAssertEqual(s.primaryLive?.itemID, song.id, "the live slide is unchanged under the pattern")
        XCTAssertTrue(ServiceMenuModel(state: s, selection: nil).canNext)
    }
}
