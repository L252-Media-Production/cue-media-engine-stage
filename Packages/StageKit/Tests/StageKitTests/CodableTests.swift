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

    func testEveryCommandRoundTrips() throws {
        let id = UUID()
        let commands: [Command] = [
            .go(itemID: id, slideIndex: 3), .next, .previous,
            .clear(.slide), .clear(.messages), .clear(.all), .blackout(true), .blackout(false),
            .applyLook(id), .showMessage(id), .hideMessage(id), .startTimer(id), .stopTimer(id), .resetTimer(id),
            .playAudio(mediaID: id), .pauseAudio, .resumeAudio, .stopAudio, .fadeAudio(seconds: 2.5),
            .seekAudio(seconds: 42.25), .skipNextTrigger,
        ]
        for command in commands {
            try roundTrip(command)
            try roundTrip(CommandEnvelope(command))
        }
    }

    func testEnvelopeCarriesVersion() throws {
        let data = try JSONEncoder().encode(CommandEnvelope(.next))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, commandVersion)
    }

    func testStateAndEventsRoundTrip() async throws {
        let client = MockStageClient()
        let lib = await client.library
        await client.send(.go(itemID: lib.service.items[1].id, slideIndex: 0))
        await client.send(.playAudio(mediaID: lib.media[0].id))
        await client.tick(seconds: 29)
        await client.simulateCounters(AudioCounters(droppedEnds: 1, droppedFires: 0, poolExhausted: 2))
        let state = await client.currentState
        XCTAssertTrue(state.audio.voicePlaying)
        try roundTrip(state)

        let live = try XCTUnwrap(state.primaryLive)
        let events: [StageEvent] = [
            .commandRejected(.next, reason: "end of service"), .slideLive(live), .cleared(.all), .blackoutChanged(true),
            .audioStarted(mediaID: lib.media[0].id), .audioEnded(mediaID: lib.media[0].id),
            .triggerFired(triggerID: UUID(), voiceMediaID: lib.media[1].id), .triggerSkipped(triggerID: UUID()),
            .countersChanged(state.audio.counters), .outputHealthChanged(state.outputs[0]),
        ]
        for event in events { try roundTrip(event) }
    }
}
