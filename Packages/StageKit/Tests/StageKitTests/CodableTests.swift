import XCTest
@testable import StageKit

final class CodableTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testModelsRoundTrip() throws {
        let lib = Library.sample
        try roundTrip(lib)
        try roundTrip(lib.service)
        for item in lib.service.items { try roundTrip(item) }
        for song in lib.songs { try roundTrip(song) }
        try roundTrip(lib.songs[0].slides[0])
        for media in lib.media { try roundTrip(media) }
        for settings in lib.audioSettings.values { try roundTrip(settings) }
        try roundTrip(lib.looks)
        try roundTrip(lib.messages)
        try roundTrip(lib.timers)
        try roundTrip(lib.screens)
        try roundTrip(lib.outputs)
    }

    func testOutputModelsRoundTrip() throws {
        for connector in MockStageClient.sampleConnectors { try roundTrip(connector) }
        try roundTrip(OutputAssignment(screenID: UUID(), connectorID: "ndi-out-1"))
        try roundTrip(OutputAssignment(screenID: UUID(), connectorID: nil))
        for type in ScreenType.allCases {
            for rotation in ScreenRotation.allCases {
                try roundTrip(ScreenSetup(type: type, lookID: UUID(), onCanvas: true, canvas: CanvasRect(x: -10, y: 5, width: 1080, height: 1920), rotation: rotation))
            }
        }
        for pattern in TestPattern.allCases {
            try roundTrip(ActiveTestPattern(target: .all, pattern: pattern))
            try roundTrip(ActiveTestPattern(target: .screen(UUID()), pattern: pattern))
        }
        let id = UUID()
        for warning: OutputWarning in [.canvasSpansCards([id, UUID()]), .canvasOnNonSDI(id), .connectorUnavailable(id)] {
            try roundTrip(warning)
        }
        XCTAssertEqual(ScreenRotation.allCases.map(\.rawValue), [0, 90, 180, 270])
    }

    func testEveryCommandRoundTrips() throws {
        let id = UUID()
        let commands: [Command] = [
            .go(itemID: id, slideIndex: 3), .next, .previous,
            .clear(.slide), .clear(.messages), .clear(.all), .clear(.audio), .blackout(true), .blackout(false),
            .applyLook(id), .showMessage(id), .showMessage(id, screens: [UUID(), UUID()]), .hideMessage(id),
            .startTimer(id), .stopTimer(id), .resetTimer(id),
            .playAudio(mediaID: id),
            .playAudio(mediaID: id, options: AudioPlayOptions(volumePercent: 80, fadeInSeconds: 1.5, endAction: .loop)),
            .playAudio(mediaID: id, options: AudioPlayOptions(endAction: .once)),
            .pauseAudio, .resumeAudio, .stopAudio, .fadeAudio(seconds: 2.5),
            .seekAudio(seconds: 42.25), .skipNextTrigger,
            .assignScreen(id, connector: "decklink-A-1"), .assignScreen(id, connector: nil),
            .setScreenSetup(id, ScreenSetup(type: .audience, lookID: UUID(), onCanvas: true,
                                            canvas: CanvasRect(x: 1920, y: 0, width: 1080, height: 1920), rotation: .right)),
            .setScreenSetup(id, ScreenSetup(type: .speaker)),
            .showTestPattern(.all, .bars), .showTestPattern(.screen(id), .grid), .hideTestPattern,
            .openStudio(id), .closeStudio, .reloadStudio(id),
        ]
        for command in commands {
            try roundTrip(command)
            try roundTrip(CommandEnvelope(command))
        }
    }

    func testEnvelopeCarriesVersion() throws {
        XCTAssertEqual(commandVersion, 4)
        let data = try JSONEncoder().encode(CommandEnvelope(.next))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, commandVersion)
    }

    func testAudioPlayOptionsAreAllOptional() throws {
        let empty = try JSONDecoder().decode(AudioPlayOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AudioPlayOptions())
        let full = try JSONDecoder().decode(
            AudioPlayOptions.self, from: Data(#"{"volumePercent":50,"fadeInSeconds":2,"endAction":"stop"}"#.utf8)
        )
        XCTAssertEqual(full, AudioPlayOptions(volumePercent: 50, fadeInSeconds: 2, endAction: .stop))
        XCTAssertEqual(AudioPlayOptions.EndAction.allCases.map(\.rawValue), ["default", "once", "loop", "stop"])
    }

    func testDuckingNeverNegativeZero() throws {
        var audio = AudioState(duckingReductionDB: -0.0)
        XCTAssertEqual(audio.duckingReductionDB.sign, .plus)
        XCTAssertEqual(audio.duckingText, "0.0 dB")
        audio.duckingReductionDB = -0.0
        XCTAssertEqual(audio.duckingReductionDB.sign, .plus)
        audio.duckingReductionDB = -3
        XCTAssertEqual(audio.duckingReductionDB, 0)
        audio.duckingReductionDB = .nan
        XCTAssertEqual(audio.duckingReductionDB, 0)
        audio.duckingReductionDB = 0.04 // rounds to zero
        XCTAssertEqual(audio.duckingText, "0.0 dB")
        audio.duckingReductionDB = 8
        XCTAssertEqual(audio.duckingText, "-8.0 dB")

        // A snapshot from the wire with -0 (or a negative value) is normalised on decode too.
        var json = String(decoding: try JSONEncoder().encode(AudioState()), as: UTF8.self)
        json = json.replacingOccurrences(of: #""duckingReductionDB":0"#, with: #""duckingReductionDB":-0.0"#)
        XCTAssertTrue(json.contains("-0.0"))
        let decoded = try JSONDecoder().decode(AudioState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.duckingReductionDB.sign, .plus)
        XCTAssertEqual(decoded.duckingText, "0.0 dB")
    }

    func testStateAndEventsRoundTrip() async throws {
        let client = MockStageClient()
        let lib = await client.library
        await client.send(.go(itemID: lib.service.items[1].id, slideIndex: 0))
        await client.send(.playAudio(mediaID: lib.media[0].id))
        await client.tick(seconds: 29)
        await client.simulateCounters(AudioCounters(droppedEnds: 1, droppedFires: 0, poolExhausted: 2))
        await client.send(.showTestPattern(.all, .bars))
        let state = await client.currentState
        XCTAssertTrue(state.audio.voicePlaying)
        XCTAssertFalse(state.connectors.isEmpty)
        XCTAssertEqual(state.screenSetups.count, lib.screens.count)
        XCTAssertNotNil(state.testPattern)
        try roundTrip(state)

        let live = try XCTUnwrap(state.primaryLive)
        let events: [StageEvent] = [
            .commandRejected(.next, reason: "end of service"), .slideLive(live), .cleared(.all), .blackoutChanged(true),
            .audioStarted(mediaID: lib.media[0].id), .audioEnded(mediaID: lib.media[0].id),
            .triggerFired(triggerID: UUID(), voiceMediaID: lib.media[1].id), .triggerSkipped(triggerID: UUID()),
            .countersChanged(state.audio.counters), .outputHealthChanged(state.outputs[0]),
            .testPatternChanged(ActiveTestPattern(target: .screen(UUID()), pattern: .grid)), .testPatternChanged(nil),
            .studioOpened(StudioInfo(id: UUID(), name: "Sunday")), .studioClosed(StudioInfo(id: UUID(), name: "Sunday")),
        ]
        for event in events { try roundTrip(event) }
    }
}
