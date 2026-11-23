import XCTest
@testable import StageKit

final class OutputWarningTests: XCTestCase {
    let connectors = MockStageClient.sampleConnectors
    let left = UUID(), right = UUID(), stage = UUID()

    private func setups(onCanvas: [UUID]) -> [Screen.ID: ScreenSetup] {
        var result: [Screen.ID: ScreenSetup] = [stage: ScreenSetup(type: .stage)]
        for id in [left, right] { result[id] = ScreenSetup(type: .audience, onCanvas: onCanvas.contains(id)) }
        return result
    }

    private func warnings(_ pairs: [(UUID, String?)], onCanvas: [UUID], connectors: [Connector]? = nil) -> [OutputWarning] {
        outputWarnings(
            connectors: connectors ?? self.connectors,
            assignments: pairs.map { OutputAssignment(screenID: $0.0, connectorID: $0.1) },
            screenSetups: setups(onCanvas: onCanvas)
        )
    }

    func testCanvasOnOneCardIsFine() {
        XCTAssertEqual(warnings([(left, "decklink-A-1"), (right, "decklink-A-2"), (stage, "decklink-B-1")], onCanvas: [left, right]), [],
                       "the stage display is off the canvas, so card B for it is fine")
        XCTAssertEqual(warnings([(left, "decklink-B-1"), (right, "decklink-B-3")], onCanvas: [left, right]), [])
        XCTAssertEqual(warnings([(left, nil), (right, nil)], onCanvas: [left, right]), [], "unassigned raises nothing")
    }

    func testCanvasOnTwoCardsWarnsNamingTheScreens() {
        XCTAssertEqual(warnings([(left, "decklink-A-1"), (stage, "decklink-A-2"), (right, "decklink-B-1")], onCanvas: [left, right]),
                       [.canvasSpansCards([left, right])])
        XCTAssertEqual(warnings([(left, "decklink-A-1"), (right, "decklink-B-1")], onCanvas: [left]), [],
                       "Right is off the canvas")
    }

    func testCanvasOnDisplayOrNDIWarns() {
        XCTAssertEqual(warnings([(left, "decklink-A-1"), (right, "display-1")], onCanvas: [left, right]), [.canvasOnNonSDI(right)])
        XCTAssertEqual(warnings([(left, "ndi-out-1"), (right, "decklink-A-1")], onCanvas: [left, right]), [.canvasOnNonSDI(left)])
        XCTAssertEqual(warnings([(stage, "ndi-out-2"), (left, "display-1")], onCanvas: []), [], "off the canvas: fine")
    }

    func testUnavailableOrMissingConnectorWarns() {
        var list = connectors
        list[1].available = false // decklink-A-2
        XCTAssertEqual(warnings([(left, "decklink-A-1"), (right, "decklink-A-2"), (stage, "gone")], onCanvas: [left, right], connectors: list),
                       [.connectorUnavailable(right), .connectorUnavailable(stage)])
    }

    func testAllWarningsTogether() {
        XCTAssertEqual(
            warnings([(left, "decklink-A-1"), (right, "decklink-B-2"), (stage, "nope")], onCanvas: [left, right]),
            [.canvasSpansCards([left, right]), .connectorUnavailable(stage)]
        )
    }
}

final class MockOutputTests: XCTestCase {
    let lib = Library.sample
    var left: Screen { lib.screens[0] }
    var stage: Screen { lib.screens[1] }
    var right: Screen { lib.screens[2] }
    var imag: Screen { lib.screens[3] }

    private func rejections(_ client: MockStageClient, _ commands: [Command]) async -> [String] {
        let events = await client.events()
        for command in commands { await client.send(command) }
        await client.send(.blackout(true)) // a known last event, so the loop below ends
        var reasons: [String] = []
        for await event in events {
            if case let .commandRejected(_, reason) = event { reasons.append(reason) }
            if case .blackoutChanged = event { break }
        }
        return reasons
    }

    func testMockReportsTheRigAndDefaultAssignments() async {
        let state = await MockStageClient(library: lib).currentState
        XCTAssertEqual(state.connectors.filter { $0.kind.isSDI }.count, 8, "two Duo 2 cards, 4 SDI each")
        XCTAssertEqual(Set(state.connectors.compactMap(\.cardID)), ["decklink-A", "decklink-B"])
        XCTAssertEqual(state.connectors.filter { $0.kind == .sdiIn }.map(\.id), ["decklink-B-4"])
        XCTAssertEqual(state.connectors.filter { $0.kind == .ndiOut }.count, 2)
        XCTAssertEqual(state.connectors.filter { $0.kind == .display }.count, 1)
        XCTAssertEqual(state.looks, lib.looks)

        XCTAssertEqual(state.assignments.map(\.screenID), lib.screens.map(\.id))
        XCTAssertEqual(state.assignments.map(\.connectorID), ["decklink-A-1", "decklink-A-2", "decklink-A-3", "decklink-B-4"])
        XCTAssertEqual(state.screenSetups[left.id], ScreenSetup(type: .audience, onCanvas: true))
        XCTAssertEqual(state.screenSetups[right.id]?.canvas.x, 1920)
        XCTAssertEqual(state.screenSetups[stage.id]?.onCanvas, false)
        XCTAssertEqual(state.screenSetups[imag.id]?.type, .input)
        XCTAssertEqual(state.outputWarnings, [])
        XCTAssertNil(state.testPattern)
    }

    func testAssignAndUnassign() async {
        let client = MockStageClient(library: lib)
        let reasons = await rejections(client, [
            .assignScreen(right.id, connector: "decklink-B-1"),
            .assignScreen(stage.id, connector: nil),
            .assignScreen(stage.id, connector: "decklink-A-2"), // free again
        ])
        XCTAssertEqual(reasons, [])
        let state = await client.currentState
        XCTAssertEqual(state.connectorID(for: right.id), "decklink-B-1")
        XCTAssertEqual(state.connectorID(for: stage.id), "decklink-A-2")
        XCTAssertEqual(state.outputWarnings, [.canvasSpansCards([left.id, right.id])])
    }

    func testMockRefusesBadAssignments() async {
        let client = MockStageClient(library: lib)
        await client.simulateConnector("decklink-A-4", available: false)
        let reasons = await rejections(client, [
            .assignScreen(right.id, connector: "decklink-A-1"),  // Left has it: two screens on one connector
            .assignScreen(right.id, connector: "decklink-A-4"),  // unavailable
            .assignScreen(right.id, connector: "no-such-port"),  // the app may not invent connectors
            .assignScreen(right.id, connector: "decklink-B-4"),  // an input
            .assignScreen(imag.id, connector: "decklink-B-1"),   // IMAG on an output
            .assignScreen(UUID(), connector: "decklink-B-1"),
        ])
        XCTAssertEqual(reasons, [
            "SDI 1 is already used by Left", "SDI 4 is not available", "unknown connector",
            "SDI 4 In is not an output", "SDI 1 is not an input", "unknown screen",
        ])
        let state = await client.currentState
        XCTAssertEqual(state.connectorID(for: right.id), "decklink-A-3", "unchanged")
        XCTAssertEqual(state.connectorID(for: imag.id), "decklink-B-4")
        XCTAssertEqual(state.connectors.count, MockStageClient.sampleConnectors.count)
    }

    func testUnavailableConnectorRaisesAWarning() async {
        let client = MockStageClient(library: lib)
        await client.simulateConnector("decklink-A-2", available: false)
        let state = await client.currentState
        XCTAssertEqual(state.outputWarnings, [.connectorUnavailable(stage.id)])
    }

    func testSetScreenSetup() async {
        let client = MockStageClient(library: lib)
        let look = lib.looks[1].id
        let portrait = ScreenSetup(type: .audience, lookID: look, onCanvas: true,
                                   canvas: CanvasRect(x: 3840, y: 0, width: 1080, height: 1920), rotation: .right)
        let reasons = await rejections(client, [
            .setScreenSetup(right.id, portrait),
            .setScreenSetup(right.id, ScreenSetup(type: .audience, lookID: UUID())),
            .setScreenSetup(right.id, ScreenSetup(type: .audience, canvas: CanvasRect(width: 0))),
            .setScreenSetup(stage.id, ScreenSetup(type: .stage, onCanvas: true)),
            .setScreenSetup(stage.id, ScreenSetup(type: .input)), // still on an SDI output
            .setScreenSetup(UUID(), portrait),
        ])
        XCTAssertEqual(reasons, [
            "unknown look", "canvas size must be above 0", "only audience screens can be on the canvas",
            "unassign SDI 2 before changing the screen's direction", "unknown screen",
        ])
        let state = await client.currentState
        XCTAssertEqual(state.screenSetups[right.id], portrait)
        XCTAssertEqual(state.screenSetups[stage.id]?.type, .stage)
    }

    func testTestPatternSetAndClearLeavesTheLiveSlide() async {
        let client = MockStageClient(library: lib)
        let song = lib.service.items[1]
        await client.send(.go(itemID: song.id, slideIndex: 1))
        let events = await client.events()

        await client.send(.showTestPattern(.all, .bars))
        var state = await client.currentState
        XCTAssertEqual(state.testPattern, ActiveTestPattern(target: .all, pattern: .bars))
        XCTAssertEqual(state.primaryLive?.slideIndex, 1, "the pattern does not change the live slide")

        await client.send(.showTestPattern(.screen(stage.id), .grid))
        state = await client.currentState
        XCTAssertEqual(state.testPattern, ActiveTestPattern(target: .screen(stage.id), pattern: .grid))
        XCTAssertTrue(state.testPattern!.covers(stage.id))
        XCTAssertFalse(state.testPattern!.covers(left.id))

        await client.send(.showTestPattern(.screen(imag.id), .bars)) // refused: an input
        await client.send(.hideTestPattern)
        state = await client.currentState
        XCTAssertNil(state.testPattern)
        XCTAssertEqual(state.primaryLive?.slideIndex, 1)
        await client.send(.hideTestPattern) // refused: nothing running

        var iterator = events.makeAsyncIterator()
        var seen: [StageEvent] = []
        for _ in 0..<5 { if let e = await iterator.next() { seen.append(e) } }
        XCTAssertEqual(seen, [
            .testPatternChanged(ActiveTestPattern(target: .all, pattern: .bars)),
            .testPatternChanged(ActiveTestPattern(target: .screen(stage.id), pattern: .grid)),
            .commandRejected(.showTestPattern(.screen(imag.id), .bars), reason: "not an output screen"),
            .testPatternChanged(nil),
            .commandRejected(.hideTestPattern, reason: "no test pattern running"),
        ])
    }

    func testOutputChipsFollowAssignmentsAndKeepHealth() async {
        let client = MockStageClient(library: lib)
        var state = await client.currentState
        let stageChip = state.outputs[1]
        XCTAssertEqual(stageChip.connectorID, "decklink-A-2")
        await client.simulateOutput(stageChip.outputID, health: .degraded, droppedFrames: 3)

        await client.send(.assignScreen(right.id, connector: nil))
        await client.send(.assignScreen(left.id, connector: "ndi-out-1"))
        state = await client.currentState
        XCTAssertEqual(state.outputs.map(\.name), ["NDI CueME Main", "SDI 2 (A)"])
        XCTAssertEqual(state.outputs[1].health, .degraded, "health stays with the connector")
        XCTAssertEqual(state.outputs[1].outputID, stageChip.outputID)

        await client.simulateConnector("decklink-A-2", available: false)
        state = await client.currentState
        XCTAssertEqual(state.outputs[1].health, .offline)

        let unassigned = await MockStageClient(library: lib, assignments: []).currentState
        XCTAssertEqual(unassigned.outputs, [], "no assignments, no chips")
    }
}
