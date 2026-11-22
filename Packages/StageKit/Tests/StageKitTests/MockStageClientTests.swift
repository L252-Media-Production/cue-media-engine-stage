import XCTest
@testable import StageKit

final class MockStageClientTests: XCTestCase {
    let lib = Library.sample
    var amazing: Item { lib.service.items[1] }
    var doxology: Item { lib.service.items[3] }
    var walkInItem: Item { lib.service.items[0] }
    var walkInID: MediaItem.ID {
        guard case let .media(id) = walkInItem.content else { fatalError("sample changed") }
        return id
    }
    var walkInTriggers: [TriggerPoint] { lib.audioSettings[walkInID]!.triggers }

    func testInitialStateMirrorsLibrary() async {
        let client = MockStageClient(library: lib)
        let state = await client.currentState
        XCTAssertEqual(state.service, lib.service)
        XCTAssertEqual(state.screens.map(\.screenID), lib.screens.map(\.id))
        XCTAssertEqual(state.outputs.map(\.outputID), lib.outputs.map(\.id))
        XCTAssertTrue(state.outputs.allSatisfy { $0.health == .ok })
        XCTAssertNil(state.primaryLive)
        XCTAssertEqual(state.audio, AudioState())
    }

    func testGoPutsSlideLiveOnEveryScreen() async {
        let client = MockStageClient(library: lib)
        await client.send(.go(itemID: amazing.id, slideIndex: 1))
        let state = await client.currentState
        XCTAssertEqual(state.screens.count, 2)
        for screen in state.screens {
            XCTAssertEqual(screen.live?.itemID, amazing.id)
            XCTAssertEqual(screen.live?.slideIndex, 1)
            XCTAssertEqual(screen.live?.label, "Verse 2")
        }
    }

    func testNextAndPreviousCrossItemsAndSkipItemsWithoutSlides() async {
        let client = MockStageClient(library: lib)
        // Nothing live: Next starts at the first slide of the first song (the walk-in track has no slides).
        await client.send(.next)
        var live = await client.currentState.primaryLive
        XCTAssertEqual(live?.itemID, amazing.id)
        XCTAssertEqual(live?.slideIndex, 0)

        await client.send(.go(itemID: amazing.id, slideIndex: 2))
        await client.send(.next) // past the blank item, into Doxology
        live = await client.currentState.primaryLive
        XCTAssertEqual(live?.itemID, doxology.id)
        XCTAssertEqual(live?.slideIndex, 0)

        await client.send(.previous) // back to the last slide of Amazing Grace
        live = await client.currentState.primaryLive
        XCTAssertEqual(live?.itemID, amazing.id)
        XCTAssertEqual(live?.slideIndex, 2)
    }

    func testNextAtEndOfServiceIsRejectedAndKeepsSlide() async {
        let client = MockStageClient(library: lib)
        let events = await client.events()
        await client.send(.go(itemID: doxology.id, slideIndex: 1))
        await client.send(.next)
        let live = await client.currentState.primaryLive
        XCTAssertEqual(live?.itemID, doxology.id)
        XCTAssertEqual(live?.slideIndex, 1)

        var iterator = events.makeAsyncIterator()
        _ = await iterator.next() // slideLive
        let rejected = await iterator.next()
        XCTAssertEqual(rejected, .commandRejected(.next, reason: "end of service"))
    }

    func testGoToMissingSlideIsRejected() async {
        let client = MockStageClient(library: lib)
        let events = await client.events()
        await client.send(.go(itemID: amazing.id, slideIndex: 9))
        let state = await client.currentState
        XCTAssertNil(state.primaryLive)
        var iterator = events.makeAsyncIterator()
        guard case .commandRejected = await iterator.next() else { return XCTFail("expected a rejection") }
    }

    func testClearKeepsCursorSoNextContinues() async {
        let client = MockStageClient(library: lib)
        await client.send(.go(itemID: amazing.id, slideIndex: 0))
        await client.send(.clear(.slide))
        var state = await client.currentState
        XCTAssertTrue(state.screens.allSatisfy { $0.live == nil })
        await client.send(.next)
        state = await client.currentState
        XCTAssertEqual(state.primaryLive?.slideIndex, 1)
    }

    func testBlackoutMessagesTimersAndLooks() async {
        let client = MockStageClient(library: lib)
        let message = lib.messages[0].id
        let timer = lib.timers[0].id
        let look = lib.looks[1].id

        await client.send(.blackout(true))
        await client.send(.showMessage(message))
        await client.send(.showMessage(message))
        await client.send(.startTimer(timer))
        await client.send(.applyLook(look))
        var state = await client.currentState
        XCTAssertTrue(state.blackout)
        XCTAssertEqual(state.visibleMessages, [message])
        XCTAssertEqual(state.runningTimers, [timer])
        XCTAssertEqual(state.activeLook, look)

        await client.send(.clear(.all))
        await client.send(.stopTimer(timer))
        await client.send(.blackout(false))
        state = await client.currentState
        XCTAssertFalse(state.blackout)
        XCTAssertEqual(state.visibleMessages, [])
        XCTAssertEqual(state.runningTimers, [])
    }

    func testPlayStartsAtTrimInWithFirstTriggerNext() async {
        let client = MockStageClient(library: lib)
        await client.send(.go(itemID: walkInItem.id, slideIndex: 0)) // Go on a media item plays it
        let audio = await client.currentState.audio
        XCTAssertEqual(audio.liveTrack, walkInID)
        XCTAssertEqual(audio.transport, .playing)
        XCTAssertEqual(audio.position, 2)
        XCTAssertEqual(audio.nextTrigger?.triggerID, walkInTriggers[0].id)
    }

    func testTriggerFiresDucksAndReleases() async {
        let client = MockStageClient(library: lib)
        let events = await client.events()
        await client.send(.playAudio(mediaID: walkInID))
        await client.tick(seconds: 28.5) // 2 → 30.5, crosses the point at 30
        var audio = await client.currentState.audio
        XCTAssertTrue(audio.voicePlaying)
        XCTAssertEqual(audio.duckingReductionDB, MockStageClient.fakeDuckingDB)
        XCTAssertEqual(audio.nextTrigger?.triggerID, walkInTriggers[1].id)

        await client.tick(seconds: 6) // the 6 s voice ends
        audio = await client.currentState.audio
        XCTAssertFalse(audio.voicePlaying)
        XCTAssertEqual(audio.duckingReductionDB, 0)

        var iterator = events.makeAsyncIterator()
        let started = await iterator.next()
        let fired = await iterator.next()
        XCTAssertEqual(started, .audioStarted(mediaID: walkInID))
        XCTAssertEqual(fired, .triggerFired(triggerID: walkInTriggers[0].id, voiceMediaID: walkInTriggers[0].voiceMediaID))
    }

    func testSkipNextTriggerAndSeekBackRearms() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: walkInID))
        await client.send(.skipNextTrigger)
        var audio = await client.currentState.audio
        XCTAssertEqual(audio.nextTrigger?.triggerID, walkInTriggers[1].id)

        await client.tick(seconds: 30)
        audio = await client.currentState.audio
        XCTAssertFalse(audio.voicePlaying)

        await client.send(.seekAudio(seconds: 10))
        audio = await client.currentState.audio
        XCTAssertEqual(audio.position, 10)
        XCTAssertEqual(audio.nextTrigger?.triggerID, walkInTriggers[0].id)
    }

    func testPauseResumeFadeAndEndOfTrack() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: walkInID))
        await client.send(.pauseAudio)
        await client.tick(seconds: 10)
        var audio = await client.currentState.audio
        XCTAssertEqual(audio.transport, .paused)
        XCTAssertEqual(audio.position, 2)

        await client.send(.resumeAudio)
        await client.send(.fadeAudio(seconds: 3))
        await client.tick(seconds: 1)
        audio = await client.currentState.audio
        XCTAssertEqual(audio.transport, .fading)
        await client.tick(seconds: 2)
        audio = await client.currentState.audio
        XCTAssertEqual(audio.transport, .stopped)
        XCTAssertNil(audio.liveTrack)

        await client.send(.playAudio(mediaID: walkInID))
        await client.send(.seekAudio(seconds: 500)) // held to trim Out
        audio = await client.currentState.audio
        XCTAssertEqual(audio.position, 170)
        await client.tick(seconds: 0.1)
        audio = await client.currentState.audio
        XCTAssertNil(audio.liveTrack)
    }

    func testPlayingUnknownMediaIsRejected() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: UUID()))
        let audio = await client.currentState.audio
        XCTAssertNil(audio.liveTrack)
    }

    func testCountersSurviveNewTrackAndOutputsCanDegrade() async {
        let client = MockStageClient(library: lib)
        await client.simulateCounters(AudioCounters(droppedEnds: 1, droppedFires: 2, poolExhausted: 3))
        await client.send(.playAudio(mediaID: walkInID))
        await client.send(.stopAudio)
        await client.simulateOutput(lib.outputs[1].id, health: .offline, droppedFrames: 12)
        let state = await client.currentState
        XCTAssertEqual(state.audio.counters, AudioCounters(droppedEnds: 1, droppedFires: 2, poolExhausted: 3))
        XCTAssertEqual(state.outputs[1].health, .offline)
        XCTAssertEqual(state.outputs[1].droppedFrames, 12)
    }

    func testStateStreamYieldsCurrentThenChanges() async {
        let client = MockStageClient(library: lib)
        let stream = await client.states()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNil(first?.primaryLive)
        await client.send(.go(itemID: amazing.id, slideIndex: 0))
        let second = await iterator.next()
        XCTAssertEqual(second?.primaryLive?.itemID, amazing.id)
    }
}
