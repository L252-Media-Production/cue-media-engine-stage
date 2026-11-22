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

// MARK: trigger boundary rules (docs/audio-spec-1.md, "Trigger points")

extension AudioCoreTriggerTests {
    private struct Ready: TargetReadiness {
        func state(of target: TrackID) -> TargetState { .ready(lengthSeconds: 8) }
    }

    private func twoTracks(pool: Int = Mixer.defaultPoolCapacity, triggers: [(Double, Bool)] = [(2, false)], end: TrackEnd = .followPlayMode, trim: Trim = Trim(), ducking: any DuckingHook = NoDucking())
        -> PlaylistPlayer<SeededRandomSource> {
        var list = TriggerList()
        for (n, t) in triggers.enumerated() { list.add(Trigger(id: TriggerID(n), atSeconds: t.0, target: TrackID(100), once: t.1)) }
        let tracks = [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: trim, end: end, triggers: list), PlaylistTrack(id: TrackID(1), lengthSeconds: 30)]
        return PlaylistPlayer(
            playlists: [Playlist(tracks: tracks, mode: .stop)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1),
            mixer: Mixer(sampleRate: 1000, poolCapacity: pool), readiness: Ready(), ducking: ducking)
    }

    func testACrossfadeFadesTheVoiceOutWithTheOthersAndTheHookHearsItsEndThen() {
        let rec = Recorder()
        var p = twoTracks(ducking: rec)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 4000)                                   // the voice (8 s) started at 2 s
        let voice = p.topDeck!
        p.play(TrackPosition(playlist: 0, track: 1), crossfadeMs: 1000)
        XCTAssertEqual(p.topDeck, voice, "the voice is still on top while it fades out")
        XCTAssertTrue(rec.ended.isEmpty, "not ended yet")
        p.advance(frames: 500)
        XCTAssertEqual(p.mixer.gain(of: voice)!, EqualPower.rampDown(x: 0.5), accuracy: 1e-12)
        p.advance(frames: 500)
        XCTAssertEqual(rec.ended.map(\.1), [5000], "ended at the exact frame its fade ended (4 s + 1 s)")
        XCTAssertNil(p.topDeck)
        XCTAssertEqual(p.mixer.playingCount, 1, "only the new track is left")
    }

    func testACutRemovesTheVoiceAtOnceAndTheNewTrackIsAlone() {
        let rec = Recorder()
        var p = twoTracks(ducking: rec)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 4000)
        p.play(TrackPosition(playlist: 0, track: 1))
        XCTAssertNil(p.topDeck)
        XCTAssertEqual(rec.ended.map(\.1), [4000])
        XCTAssertEqual(p.mixer.playingCount, 1)
        XCTAssertEqual(p.mixer.gain(of: p.current!.deck), 1)
    }

    func testAPointOfTheNewTrackReachedWhileTheOldVoiceFadesIsSkipped() {
        var p = twoTracks(triggers: [(2, false)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 4000)
        p.play(TrackPosition(playlist: 0, track: 0), crossfadeMs: 3000)    // the same track again: its point at 2 s comes 2 s in, the old voice fades until 3 s in
        p.advance(frames: 2500)
        XCTAssertEqual(p.mixer.decks.filter(\.isTop).count, 1, "no second voice while the first one fades")
    }

    func testACrossfadeWithAFullPoolIsRefusedAndTheVoiceKeepsPlaying() {
        var p = twoTracks(pool: 2)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 3000)                                   // the track and its voice fill both slots
        XCTAssertFalse(p.play(TrackPosition(playlist: 0, track: 1), crossfadeMs: 1000))
        XCTAssertEqual(p.counters.poolExhausted, 1)
        XCTAssertNotNil(p.topDeck)
        XCTAssertEqual(p.mixer.deck(p.topDeck!)?.fade == nil, true, "the refused crossfade faded nothing")
        XCTAssertTrue(p.play(TrackPosition(playlist: 0, track: 1)), "a cut still works and frees both slots")
        XCTAssertNil(p.topDeck)
    }

    func testTheFadingVoiceHoldsAnOutgoingSlotUntilItEnds() {
        var p = twoTracks(pool: 3)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 3000)
        XCTAssertTrue(p.play(TrackPosition(playlist: 0, track: 1), crossfadeMs: 2000))    // old track, voice, new track: three slots
        XCTAssertEqual(p.mixer.playingCount, 3)
        XCTAssertFalse(p.play(TrackPosition(playlist: 0, track: 0), crossfadeMs: 2000), "a fourth deck does not fit")
        p.advance(frames: 2000)
        XCTAssertEqual(p.mixer.playingCount, 1)
        XCTAssertTrue(p.play(TrackPosition(playlist: 0, track: 0), crossfadeMs: 2000), "the slots are free again")
    }

    func testTheVoiceLevelIsAPlainVolumeFromThePercentage() {
        for (pct, level) in [(100.0, 1.0), (60, 0.6), (25, 0.25), (0, 0), (150, 1), (-5, 0)] {
            var list = TriggerList()
            list.add(Trigger(id: TriggerID(0), atSeconds: 1, target: TrackID(100)))
            var p = PlaylistPlayer(
                playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, triggers: list)], mode: .stop)],
                policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Ready(),
                settings: TriggerSettings(topTrackPercent: pct))
            p.play(TrackPosition(playlist: 0, track: 0))
            p.advance(frames: 1000)
            XCTAssertEqual(p.mixer.gain(of: p.topDeck!)!, level, accuracy: 1e-12, "\(pct) %: no fade-in, a plain volume from the first frame")
        }
    }

    /// The frame the only point of a track (In 2 s, Out 4 s) fires at, nil when it does not, for a start at `offset`; 1 ms frames, 1 s of play.
    private func fireFrame(at: Double, offset: Double = 0, windowed: Bool = true) -> Int64? {
        var trim = Trim()
        trim.inPoint = 2
        if windowed { trim.outPoint = 4 }
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: at, target: TrackID(100)))
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: trim, triggers: list)], mode: .stop)],
            policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Ready())
        p.play(TrackPosition(playlist: 0, track: 0), offsetSeconds: offset)
        var fired = p.fired.map(\.frame)
        for _ in 0..<100 { p.advance(frames: 7); fired += p.fired.map(\.frame) }
        return fired.first
    }

    func testAPointIsKeptTo1msAndEligibleFromAMinusAMicrosecond() {
        XCTAssertEqual(Trigger(id: TriggerID(0), atSeconds: 2.0004, target: TrackID(1)).atSeconds, 2.0)
        XCTAssertEqual(Trigger(id: TriggerID(0), atSeconds: 2.0006, target: TrackID(1)).atSeconds, 2.001)
        XCTAssertNil(fireFrame(at: 1.999), "1 ms before A never fires")
        XCTAssertEqual(fireFrame(at: 2.0), 0, "a point at A fires on the first frame")
        XCTAssertEqual(fireFrame(at: 2.001), 1)
        XCTAssertEqual(fireFrame(at: 2.049), 49)
        XCTAssertNil(fireFrame(at: 4.0), "a point at B never fires (the run is too short to reach it anyway: B is 2 s in)")
        XCTAssertEqual(fireFrame(at: 2.5), 500)
    }

    func testAPointAtBOrBeyondNeverFiresEvenWhenReached() {
        var trim = Trim()
        trim.outPoint = 1
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 1.0, target: TrackID(100), once: false))
        list.add(Trigger(id: TriggerID(1), atSeconds: 0.999, target: TrackID(100)))
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: trim, end: .loop, triggers: list)], mode: .stop)],
            policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Ready())
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 5000)
        let starts = p.mixer.decks.filter(\.isTop).compactMap { $0.playback?.startFrame }
        XCTAssertEqual(starts.first, 999, "only the point 1 ms before B")
        XCTAssertFalse(starts.contains(1000))
    }

    func testAStartPartWayInHasBehindItDoneAndAStartExactlyOnAFiresFromA() {
        XCTAssertEqual(fireFrame(at: 2.0, offset: 0, windowed: false), 0)
        XCTAssertEqual(fireFrame(at: 2.02, offset: 0, windowed: false), 20)
        XCTAssertEqual(fireFrame(at: 2.0, offset: 2.0, windowed: false), 0, "a start exactly on A is a start at A")
        XCTAssertEqual(fireFrame(at: 2.055, offset: 2.0, windowed: false), 55)
        XCTAssertNil(fireFrame(at: 2.0, offset: 2.05, windowed: false), "behind the start: never")
        XCTAssertNil(fireFrame(at: 2.02, offset: 2.05, windowed: false), "behind the start: never, though the start is within 0.06 s of A")
        XCTAssertEqual(fireFrame(at: 2.1, offset: 2.05, windowed: false), 50, "ahead: when the playhead reaches it")
        XCTAssertNil(fireFrame(at: 2.0, offset: 2.061, windowed: false))
        XCTAssertEqual(fireFrame(at: 2.3, offset: 2.061, windowed: false), 239)
        XCTAssertNil(fireFrame(at: 2.1, offset: 2.2, windowed: false))
    }

    // MARK: once = first pass, not first time

    /// A once point at 1 s of a looping 6 s window, with a seek back to 0 at `seekAt` s; the frames it fires at over 14 s, for a given step size.
    /// A 3 s voice-over, as in the fixtures: over before a seek at 4.5 s.
    private struct Short: TargetReadiness { func state(of target: TrackID) -> TargetState { .ready(lengthSeconds: 3) } }

    private func onceRun(seekAt: Double?, step: Int64) -> [Int64] {
        var trim = Trim()
        trim.outPoint = 6
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 1, target: TrackID(100), once: true))
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: trim, end: .loop, triggers: list)], mode: .stop)],
            policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Short())
        p.play(TrackPosition(playlist: 0, track: 0))
        var t: Int64 = 0
        let seekFrame = seekAt.map { Int64($0 * 1000) }
        var fires = p.fired.map(\.frame)
        while t < 14_000 {
            var s = min(step, 14_000 - t)
            if let sf = seekFrame, t < sf { s = min(s, sf - t) }
            p.advance(frames: s)
            fires += p.fired.map(\.frame)
            t += s
            if t == seekFrame { p.seekLive(toSeconds: 0); fires += p.fired.map(\.frame) }
        }
        return fires
    }

    func testOnceMeansFirstPassAndTheResultDoesNotDependOnTheStep() {
        for step: Int64 in [14_000, 1, 7, 480, 2400] {
            XCTAssertEqual(onceRun(seekAt: nil, step: step), [1000], "step \(step): fires in pass 1 only")
            XCTAssertEqual(onceRun(seekAt: 4.5, step: step), [1000, 5500], "step \(step): a seek back inside pass 1 re-arms it")
            XCTAssertEqual(onceRun(seekAt: 7.5, step: step), [1000], "step \(step): pass 2 has begun: the point stays dead, the seek does not bring it back")
        }
    }

    func testASeekOverAOncePointAndBackLeavesItUnspent() {
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 10, target: TrackID(100), once: true))
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 120, triggers: list)], mode: .stop)],
            policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Short())
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2000)
        p.seekLive(toSeconds: 20)
        p.advance(frames: 2000)
        p.seekLive(toSeconds: 5)
        p.advance(frames: 6000)
        XCTAssertEqual(p.mixer.decks.filter(\.isTop).compactMap { $0.playback?.startFrame }, [9000])
    }
}
