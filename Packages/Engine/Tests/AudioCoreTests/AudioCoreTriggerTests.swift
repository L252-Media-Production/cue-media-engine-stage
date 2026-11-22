import AudioCore
import XCTest

/// Properties of trigger points that do not come from a fixture. A 1000 Hz clock keeps the frame numbers readable.
final class AudioCoreTriggerTests: XCTestCase {
    private let rate = 1000

    private struct Targets: TargetReadiness {
        var states: [TrackID: TargetState]
        func state(of target: TrackID) -> TargetState { states[target] ?? .missing }
    }

    /// Records what the ducking slice will be told.
    private final class Recorder: DuckingHook {
        var started: [(Deck.ID, Deck.ID?, Int64)] = []
        var ended: [(Deck.ID, Int64)] = []
        func voiceStarted(_ voice: Deck.ID, over background: Deck.ID?, atFrame frame: Int64) { started.append((voice, background, frame)) }
        func voiceEnded(_ voice: Deck.ID, atFrame frame: Int64) { ended.append((voice, frame)) }
    }

    private func make(
        length: Double = 120, trim: Trim = Trim(), end: TrackEnd = .followPlayMode, triggers: [(Double, Int, Bool)], ready: [TrackID: TargetState]? = nil,
        ducking: any DuckingHook = NoDucking(), settings: TriggerSettings = TriggerSettings()
    ) -> PlaylistPlayer<SeededRandomSource> {
        var list = TriggerList()
        for (n, t) in triggers.enumerated() { list.add(Trigger(id: TriggerID(n), atSeconds: t.0, target: TrackID(t.1), once: t.2)) }
        let track = PlaylistTrack(id: TrackID(0), lengthSeconds: length, trim: trim, end: end, triggers: list)
        let states = ready ?? [TrackID(1): .ready(lengthSeconds: 3), TrackID(2): .ready(lengthSeconds: 8)]
        return PlaylistPlayer(
            playlists: [Playlist(tracks: [track], mode: .stop)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0),
            random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: rate), readiness: Targets(states: states), ducking: ducking, settings: settings)
    }

    private func fireFrames(_ p: PlaylistPlayer<SeededRandomSource>) -> [Int64] {
        p.mixer.decks.filter(\.isTop).compactMap { $0.playback?.startFrame }
    }

    private func run(step: Int64, total: Int64 = 30_000, _ build: () -> PlaylistPlayer<SeededRandomSource>) -> [Int64] {
        var p = build()
        p.play(TrackPosition(playlist: 0, track: 0))
        var left = total
        while left > 0 { let s = min(step, left); p.advance(frames: s); left -= s }
        return fireFrames(p)
    }

    func testFiresAtTheExactFrameWhateverTheStepSize() {
        // A looping 6 s window with two points, one of them once: fires at exact frames in every pass. The 8 s voice started at 4.5 s is still on top at 7 s, so the
        // point at 1 s of pass 2 is skipped (not queued); the point at 1 s of the later passes fires.
        var trim = Trim()
        trim.outPoint = 6
        let build = { self.make(length: 60, trim: trim, end: .loop, triggers: [(1, 1, false), (4.5, 2, true)]) }
        let reference = run(step: 30_000, build)
        XCTAssertEqual(reference, [1000, 4500, 13_000, 19_000, 25_000])
        for step: Int64 in [1, 7, 480, 2400, 50] { XCTAssertEqual(run(step: step, build), reference, "step \(step)") }
    }

    func testStepSizeDoesNotChangeASeekRun() {
        func go(step: Int64) -> [Int64] {
            var p = make(triggers: [(10, 1, false)])
            p.play(TrackPosition(playlist: 0, track: 0))
            var t: Int64 = 0
            while t < 26_000 {
                if t == 14_000 { p.seekLive(toSeconds: 2) }
                let s = min(step, 26_000 - t, t < 14_000 ? 14_000 - t : .max)
                p.advance(frames: s)
                t += s
            }
            return fireFrames(p)
        }
        XCTAssertEqual(go(step: 26_000), [10_000, 22_000])
        for step: Int64 in [1, 480, 2400] { XCTAssertEqual(go(step: step), [10_000, 22_000], "step \(step)") }
    }

    func testAPointAtTheInPointFiresOnTheFirstFrame() {
        var trim = Trim()
        trim.inPoint = 6
        XCTAssertEqual(run(step: 100, { make(trim: trim, triggers: [(6, 1, false)]) }), [0])
    }

    func testAResumedStartHasEverythingBehindItDone() {
        var p = make(triggers: [(10, 1, false), (20, 2, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.seekLive(toSeconds: 10)         // exactly on the point: behind us, not fired
        p.advance(frames: 11_000)
        XCTAssertEqual(fireFrames(p), [10_000], "only the point at 20 s, 10 s after the seek (play frame 10000)")
    }

    func testTheVoiceIsADeckOnTopAndEndsAtItsOwnFrame() {
        let rec = Recorder()
        var p = make(triggers: [(2, 1, false)], ducking: rec)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2000)
        let voice = p.mixer.decks[1]
        XCTAssertTrue(voice.isTop)
        XCTAssertEqual(p.mixer.deck(p.current!.deck)?.isPlaying, true, "the track keeps playing under the voice")
        XCTAssertEqual(p.mixer.live?.id, voice.id, "the live role is the voice")
        XCTAssertEqual(rec.started.map(\.0), [voice.id])
        XCTAssertEqual(rec.started.map(\.1), [p.current?.deck])
        XCTAssertEqual(rec.started.map(\.2), [2000])
        XCTAssertEqual(voice.playback?.plan.fadeInFrames, 0, "no fade-in")
        p.advance(frames: 10_000)
        XCTAssertEqual(rec.ended.map(\.1), [5000], "ended at its exact frame (2 s + 3 s)")
        XCTAssertEqual(p.mixer.live?.id, p.current?.deck, "the live role goes back to the track under it")
        XCTAssertNil(p.topDeck)
    }

    func testStartingANewTrackRemovesTheVoiceAndTellsTheHook() {
        let rec = Recorder()
        var p = make(triggers: [(1, 2, false)], ducking: rec)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 3000)
        p.play(TrackPosition(playlist: 0, track: 0))
        XCTAssertEqual(rec.ended.map(\.1), [3000])
    }

    func testATargetThatIsLoadingWaitsAndFiresWhenReady() {
        // Not a clock: the answer is read at every event and at the start of each advance, so a target that becomes ready starts at that call's first frame.
        final class Switch: TargetReadiness {
            var ready = false
            func state(of target: TrackID) -> TargetState { ready ? .ready(lengthSeconds: 3) : .loading }
        }
        let gate = Switch()
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 1, target: TrackID(1)))
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, triggers: list)], mode: .stop)],
            policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: rate), readiness: gate)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 5000)
        XCTAssertTrue(fireFrames(p).isEmpty)
        XCTAssertNotEqual(p.watch.due, 0, "waiting")
        gate.ready = true
        p.advance(frames: 100)
        XCTAssertEqual(fireFrames(p), [5000])
        XCTAssertEqual(p.watch.due, 0)
    }

    func testAWaitingPointIsGivenUpAfterTheLimitAndNeverFiresLate() {
        var p = make(triggers: [(1, 5, false)], ready: [TrackID(5): .loading], settings: TriggerSettings(armed: true, waitLimitSeconds: 2))
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2500)
        XCTAssertNotEqual(p.watch.due, 0, "waiting after 1.5 s")
        p.advance(frames: 1000)
        XCTAssertEqual(p.watch.due, 0, "given up after the limit")
        XCTAssertTrue(fireFrames(p).isEmpty)
    }

    func testAMissingTargetIsGivenUpAtOnce() {
        var p = make(triggers: [(1, 9, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1500)
        XCTAssertEqual(p.watch.due, 0)
        XCTAssertTrue(fireFrames(p).isEmpty)
    }

    func testDisarmedAndSkippedPointsNeverFire() {
        var off = make(triggers: [(1, 1, false)], settings: TriggerSettings(armed: false))
        off.play(TrackPosition(playlist: 0, track: 0))
        off.advance(frames: 3000)
        XCTAssertTrue(fireFrames(off).isEmpty)

        var p = make(triggers: [(1, 1, false), (5, 1, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        XCTAssertEqual(p.skipNextTrigger(), TriggerID(0))
        p.advance(frames: 7000)
        XCTAssertEqual(fireFrames(p), [5000], "the skipped point is passed over, the next one fires")
    }

    func testSwitchingAPointOffWhileItWaitsDropsIt() {
        var p = make(triggers: [(1, 5, false)], ready: [TrackID(5): .loading])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1500)
        XCTAssertNotEqual(p.watch.due, 0)
        p.setTrigger(TriggerID(0), enabled: false, ofTrack: TrackID(0), inPlaylist: 0)
        p.advance(frames: 100)
        XCTAssertEqual(p.watch.due, 0)
    }

    func testAddingAPointWhilePlayingKeepsWhatWasDone() {
        var p = make(triggers: [(2, 1, false), (8, 1, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 3000)                                            // the point at 2 s fired
        p.addTrigger(Trigger(id: TriggerID(7), atSeconds: 1, target: TrackID(1)), toTrack: TrackID(0), inPlaylist: 0)   // sorts first
        p.advance(frames: 9000)
        XCTAssertEqual(fireFrames(p), [2000, 8000], "the point at 2 s is not fired again; the new one at 1 s is behind the playhead")
    }

    func testTheListIsSortedAndFullRefusesAndCounts() {
        var list = TriggerList()
        for i in 0..<TriggerList.capacity { XCTAssertTrue(list.add(Trigger(id: TriggerID(i), atSeconds: Double(TriggerList.capacity - i), target: TrackID(1)))) }
        XCTAssertEqual(list.items.map(\.atSeconds), (1...TriggerList.capacity).map(Double.init))
        XCTAssertFalse(list.add(Trigger(id: TriggerID(999), atSeconds: 0.5, target: TrackID(1))))
        XCTAssertEqual(list.overflowCount, 1)
        XCTAssertEqual(list.items.count, TriggerList.capacity)
    }

    func testPointsAtTheSameTimeKeepTheOrderTheyWereAddedIn() {
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(1), atSeconds: 5, target: TrackID(1)))
        list.add(Trigger(id: TriggerID(2), atSeconds: 5, target: TrackID(2)))
        list.add(Trigger(id: TriggerID(3), atSeconds: 4, target: TrackID(1)))
        XCTAssertEqual(list.items.map(\.id.raw), [3, 1, 2])
    }

    func testASeekWhileAVoicePlaysIsIgnored() {
        var p = make(triggers: [(1, 2, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2000)
        XCTAssertFalse(p.seekLive(toSeconds: 50))
        XCTAssertEqual(p.mixer.deck(p.current!.deck)?.playback?.filePositionFrames(at: p.mixer.transport.playFrame), 2000)
    }

    func testASeekIsHeldToTheWindowAndKeepsALoopLooping() {
        var trim = Trim()
        trim.outPoint = 6
        var p = make(length: 60, trim: trim, end: .loop, triggers: [])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1000)
        p.seekLive(toSeconds: 59)                      // past B: held to B - 0.3 s
        let id = p.current!.deck
        XCTAssertEqual(p.mixer.deck(id)?.playback?.filePositionFrames(at: p.mixer.transport.playFrame), 5700)
        p.advance(frames: 300 + 6000)                  // wraps at B, and again: the loop is still running
        XCTAssertEqual(p.mixer.deck(id)?.isPlaying, true)
        XCTAssertEqual(p.mixer.deck(id)?.playback?.filePositionFrames(at: p.mixer.transport.playFrame), 0)
    }

    func testPauseHoldsEveryTrigger() {
        var p = make(triggers: [(1, 1, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 500)
        p.pause()
        p.advance(frames: 60_000)
        XCTAssertTrue(fireFrames(p).isEmpty)
        p.resume()
        p.advance(frames: 600)
        XCTAssertEqual(fireFrames(p), [1000], "play time 1.0 s, whatever the wall clock did")
    }

    func testAFiredEventNamesThePointTheTargetAndTheFrame() {
        var p = make(triggers: [(1, 2, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1500)
        XCTAssertEqual(p.fired.map(\.trigger), [TriggerID(0)])
        XCTAssertEqual(p.fired.map(\.target), [TrackID(2)])
        XCTAssertEqual(p.fired.map(\.frame), [1000])
    }
}
