@testable import AudioCore
import Darwin
import XCTest

/// The fixed deck pool: handles with generations, recycling, exhaustion, the counters, and that nothing grows.
final class AudioCorePoolTests: XCTestCase {
    private let rate = 1000

    private func plan(length: Double = 1, end: TrackEnd = .followPlayMode) -> TrackPlan {
        TrackPlan(trim: Trim(), policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), fileLength: length, end: end, sampleRate: rate)
    }

    private func heapBlocks() -> Int {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        return Int(s.blocks_in_use)
    }

    func testTenThousandStartsDoNotGrowThePool() {
        var m = Mixer(sampleRate: rate)
        let capacity = m.poolCapacity
        let before = m.storageCapacities
        var lastEnd: Int64 = 0
        for _ in 0..<10_000 {
            let id = m.start(plan())
            XCTAssertTrue(id.isValid)
            m.advance(frames: 1000)
            for e in m.ended { lastEnd = e.frame }
        }
        XCTAssertEqual(m.poolCapacity, capacity)
        XCTAssertEqual(m.storageCapacities.slots, before.slots)
        XCTAssertEqual(m.storageCapacities.ended, before.ended)
        XCTAssertEqual(m.counters, EngineCounters())
        XCTAssertLessThanOrEqual(m.decks.count, capacity)
        XCTAssertEqual(lastEnd, 10_000_000)
    }

    func testTenThousandTrackStartsByThePlayerDoNotGrowThePool() {
        let tracks = (0..<3).map { PlaylistTrack(id: TrackID($0), lengthSeconds: 1) }
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: tracks, mode: .loopPlaylist)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0),
            random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: rate))
        let before = p.mixer.storageCapacities
        p.play(TrackPosition(playlist: 0, track: 0))
        for _ in 0..<10_000 { p.advance(frames: 1000) }       // 10,000 one-second tracks
        XCTAssertEqual(p.mixer.storageCapacities.slots, before.slots)
        XCTAssertEqual(p.mixer.poolCapacity, Mixer.defaultPoolCapacity)
        XCTAssertEqual(p.counters, EngineCounters())
        XCTAssertEqual(p.current?.position.track, 10_000 % 3)
        XCTAssertLessThanOrEqual(p.mixer.decks.count, Mixer.defaultPoolCapacity)
    }

    func testStartingAndAdvancingAllocateNothing() {
        var m = Mixer(sampleRate: rate)
        let long = plan(), short = plan(length: 0.5)
        func round() {
            for _ in 0..<1000 {
                m.start(long)
                m.startOnTop(short)
                m.start(long, crossfadeMs: 100)
                m.advance(frames: 700)
                m.advance(frames: 700)
            }
        }
        round()                                  // warm-up: every slot and every path used once (runtime caches fill here)
        var deltas = [Int]()
        for _ in 0..<3 {
            let before = heapBlocks()
            round()
            deltas.append(heapBlocks() - before)
        }
        XCTAssertEqual(deltas, [0, 0, 0], "heap blocks in use changed while starting and advancing decks")
    }

    func testAStaleHandleIsRefused() {
        var m = Mixer(sampleRate: rate, poolCapacity: 2)
        let a = m.start(plan(length: 1))
        m.advance(frames: 1000)                              // a ended; its slot is still readable
        XCTAssertEqual(m.deck(a)?.isPlaying, false)
        XCTAssertEqual(m.ended.first?.deck, a)
        let b = m.start(plan(length: 5))
        let c = m.start(plan(length: 5))                     // b was cut by this start; the slot of a was reused by b
        XCTAssertNotEqual(a, b)
        XCTAssertNil(m.deck(a), "a's slot now holds another deck")
        XCTAssertNil(m.gain(of: a))
        m.seek(a, toSeconds: 3)                              // refused: must not move b or c
        m.finishCurrentPass(of: a)
        XCTAssertEqual(m.deck(c)?.playback?.endFrame, 1000 + 5000)
        XCTAssertNotNil(m.deck(b))
        XCTAssertNil(m.deck(.none))
        XCTAssertFalse(DeckID.none.isValid)
    }

    func testTheOldestEndedSlotIsRecycledFirst() {
        var m = Mixer(sampleRate: rate, poolCapacity: 2)
        let a = m.startOnTop(plan(length: 1))
        let b = m.startOnTop(plan(length: 2))
        m.advance(frames: 2000)                              // a ended at 1000, b at 2000
        let c = m.startOnTop(plan(length: 5))
        XCTAssertNil(m.deck(a), "a ended first: its slot is reused")
        XCTAssertNotNil(m.deck(b))
        XCTAssertTrue(c.isValid)
    }

    func testAFullPoolRefusesAStartAndCountsItWithoutChangingAnything() {
        var m = Mixer(sampleRate: rate, poolCapacity: 2)
        let a = m.startOnTop(plan(length: 10))
        let b = m.startOnTop(plan(length: 10))
        let live = m.live?.id
        let refused = m.startOnTop(plan())
        XCTAssertFalse(refused.isValid)
        XCTAssertEqual(m.counters.poolExhausted, 1)
        // A crossfade needs a slot besides the decks that keep playing; when it cannot start it must not fade them either.
        let refusedTrack = m.start(plan(), crossfadeMs: 500)
        XCTAssertFalse(refusedTrack.isValid)
        XCTAssertEqual(m.counters.poolExhausted, 2)
        XCTAssertEqual(m.deck(a)?.isPlaying, true)
        XCTAssertEqual(m.deck(b)?.isPlaying, true)
        XCTAssertEqual(m.live?.id, live)
        XCTAssertEqual(m.playingCount, 2)
        XCTAssertNil(m.deck(a)?.fade, "no fade was started on a deck by the refused crossfade")
        // A cut always finds a slot: it removes the decks that play.
        XCTAssertTrue(m.start(plan()).isValid)
        XCTAssertEqual(m.playingCount, 1)
        XCTAssertEqual(m.counters.poolExhausted, 2)
        // As soon as one ends, a start works again.
        m.advance(frames: 10_000)
        XCTAssertTrue(m.start(plan(), crossfadeMs: 500).isValid)
        XCTAssertEqual(m.counters.poolExhausted, 2)
    }

    func testAPlayerWhosePoolIsFullKeepsPlayingAndDoesNotCrash() {
        struct Ready: TargetReadiness { func state(of target: TrackID) -> TargetState { .ready(lengthSeconds: 100) } }
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 0.5, target: TrackID(9)))
        list.add(Trigger(id: TriggerID(1), atSeconds: 1.5, target: TrackID(9)))
        let tracks = [PlaylistTrack(id: TrackID(0), lengthSeconds: 50, triggers: list), PlaylistTrack(id: TrackID(1), lengthSeconds: 50)]
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: tracks, mode: .loopPlaylist)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0),
            random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: rate, poolCapacity: 2), readiness: Ready())
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1000)                              // the track and a voice (100 s) on top: both slots hold a deck that plays
        XCTAssertEqual(p.mixer.playingCount, 2)
        XCTAssertFalse(p.play(TrackPosition(playlist: 0, track: 1), crossfadeMs: 500), "a crossfade has no slot to fade into")
        XCTAssertEqual(p.current?.position.track, 0, "the track that played keeps playing")
        XCTAssertEqual(p.counters.poolExhausted, 1)
        XCTAssertEqual(p.mixer.playingCount, 2, "nothing was faded or stopped by the refused start")
        XCTAssertTrue(p.play(TrackPosition(playlist: 0, track: 1)), "a cut always finds a slot")
    }

    func testEndsThatDoNotFitAreCountedAndKeepCounting() {
        var m = Mixer(sampleRate: rate, poolCapacity: 64)
        for _ in 0..<40 { m.startOnTop(plan(length: 1)) }
        m.advance(frames: 1000)
        XCTAssertEqual(m.ended.count, Mixer.eventCapacity)
        XCTAssertEqual(m.droppedEnds, 8)
        XCTAssertEqual(m.counters.droppedEnds, 8)
        for _ in 0..<40 { m.startOnTop(plan(length: 1)) }
        m.advance(frames: 1000)
        XCTAssertEqual(m.droppedEnds, 8, "per call")
        XCTAssertEqual(m.counters.droppedEnds, 16, "cumulative")
    }

    func testTheEndedRecordCarriesTheLastGain() {
        var m = Mixer(sampleRate: rate)
        let cut = m.start(plan(length: 1))
        m.advance(frames: 1000)
        XCTAssertEqual(m.ended.first?.lastGain ?? -1, 1, accuracy: 1e-12, "a track that plays to its end plays its last frame at full level")
        XCTAssertEqual(m.gain(of: cut), 0, "an ended deck is silent")

        var t = Trim()
        t.outPoint = 1
        t.fadeOutMs = 500
        let faded = TrackPlan(trim: t, policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), fileLength: 10, sampleRate: rate)
        m.start(faded)
        m.advance(frames: 1000)
        XCTAssertEqual(m.ended.first?.lastGain ?? -1, 0, accuracy: 0.01, "an out-fade reaches 0 at B: the last frame is (almost) silent")
    }

    func testCrossfadesTriggersAndLoopsStayInsideThePool() {
        var window = Trim()
        window.outPoint = 6
        var list = TriggerList()
        list.add(Trigger(id: TriggerID(0), atSeconds: 1, target: TrackID(100)))
        list.add(Trigger(id: TriggerID(1), atSeconds: 4, target: TrackID(100)))
        let tracks = [
            PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: window, end: .loop, triggers: list),
            PlaylistTrack(id: TrackID(1), lengthSeconds: 8, triggers: list),
            PlaylistTrack(id: TrackID(2), lengthSeconds: 8, end: .twice, triggers: list),
        ]
        struct Ready: TargetReadiness { func state(of target: TrackID) -> TargetState { .ready(lengthSeconds: 3) } }
        var p = PlaylistPlayer(
            playlists: [Playlist(tracks: tracks, mode: .loopPlaylist)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0),
            random: SeededRandomSource(seed: 3), mixer: Mixer(sampleRate: rate), readiness: Ready())
        var maxPlaying = 0
        p.play(TrackPosition(playlist: 0, track: 0))
        for second in 0..<600 {
            if second % 7 == 0 { p.play(TrackPosition(playlist: 0, track: (second / 7) % 3), crossfadeMs: second % 2 == 0 ? 2000 : 0) }
            for _ in 0..<10 {
                p.advance(frames: 100)
                maxPlaying = max(maxPlaying, p.mixer.playingCount)
            }
        }
        XCTAssertEqual(p.counters, EngineCounters())
        // The old track and the voice on top fade out together while the new track plays and fires its own voice: four at once, the most this run reaches.
        XCTAssertEqual(maxPlaying, 4)
        XCTAssertLessThan(maxPlaying, p.mixer.poolCapacity)
    }
}
