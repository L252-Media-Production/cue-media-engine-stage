import AudioCore
import XCTest

/// Properties of playlists, play modes and the auto-advance that do not come from a fixture. A 1000 Hz clock keeps the frame numbers readable.
final class AudioCorePlaylistTests: XCTestCase {
    private let rate = 1000
    private let policy = TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0)

    private func tracks(_ n: Int, base: Int = 0, length: Double = 2) -> [PlaylistTrack] {
        (0..<n).map { PlaylistTrack(id: TrackID(base + $0), lengthSeconds: length) }
    }

    private func player(_ lists: [Playlist], seed: UInt64 = 1) -> PlaylistPlayer<SeededRandomSource> {
        PlaylistPlayer(playlists: lists, policy: policy, random: SeededRandomSource(seed: seed), mixer: Mixer(sampleRate: rate))
    }

    func testTheNextTrackStartsAtTheExactFrameTheLastOneEnded() {
        var p = player([Playlist(tracks: tracks(3), mode: .loopPlaylist)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 5000)                       // one big step over two ends
        XCTAssertEqual(p.current?.position, TrackPosition(playlist: 0, track: 2))
        let starts = p.mixer.decks.map { $0.playback?.startFrame }
        XCTAssertEqual(starts, [0, 2000, 4000], "no gap and no overshoot, however big the step")
    }

    func testTheStepSizeOfTheCallerDoesNotChangeTheChain() {
        func run(step: Int64) -> [Int64?] {
            var p = player([Playlist(tracks: tracks(3), mode: .loopPlaylist)])
            p.play(TrackPosition(playlist: 0, track: 0))
            var left: Int64 = 9000
            while left > 0 { let s = min(step, left); p.advance(frames: s); left -= s }
            return p.mixer.decks.map { $0.playback?.startFrame }
        }
        XCTAssertEqual(run(step: 1), run(step: 9000))
        XCTAssertEqual(run(step: 333), run(step: 9000))
    }

    func testStopLeavesNothingPlaying() {
        var p = player([Playlist(tracks: tracks(2), mode: .stop)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2500)
        XCTAssertNil(p.current)
        XCTAssertNil(p.mixer.live)
    }

    func testNextPlaylistGoesOnToTheNextListAndDoesNotWrapAfterTheLast() {
        var p = player([Playlist(tracks: tracks(1), mode: .nextPlaylist), Playlist(tracks: tracks(1, base: 10), mode: .nextPlaylist)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 2000)
        XCTAssertEqual(p.current?.position, TrackPosition(playlist: 1, track: 0))
        p.advance(frames: 2000)
        XCTAssertNil(p.current, "nothing follows the last track of the last playlist")
    }

    func testNextPlaylistSkipsAnEmptyList() {
        var lists = [Playlist(tracks: tracks(1), mode: .nextPlaylist), Playlist(tracks: [], mode: .nextPlaylist), Playlist(tracks: tracks(1, base: 20), mode: .nextPlaylist)]
        var random = SeededRandomSource(seed: 1)
        XCTAssertEqual(PlayOrder.successor(after: TrackPosition(playlist: 0, track: 0), in: &lists, using: &random), .track(TrackPosition(playlist: 2, track: 0)))
    }

    func testAStopTrackEndsTheRunInEveryMode() {
        for mode in PlaylistMode.allCases {
            var lists = [Playlist(tracks: tracks(3), mode: mode)]
            lists[0].tracks[1].end = .stop
            var random = SeededRandomSource(seed: 3)
            XCTAssertEqual(PlayOrder.successor(after: TrackPosition(playlist: 0, track: 1), in: &lists, using: &random), .stopped, "\(mode)")
        }
    }

    func testSwitchingToLoopRestartsTheTrackAtTheEndOfTheRunningPass() {
        var p = player([Playlist(tracks: tracks(2), mode: .stop)])
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1000)
        p.setEnd(.loop, ofTrack: TrackID(0), inPlaylist: 0)
        p.advance(frames: 1000)
        XCTAssertEqual(p.mixer.decks.count, 2)
        XCTAssertEqual(p.mixer.decks[1].playback?.startFrame, 2000)
        XCTAssertEqual(p.current?.position, TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 20_000)
        XCTAssertEqual(p.mixer.decks.count, 2, "the restarted track loops: no further deck")
    }

    func testATrackRemovedWhilePlayingStopsTheAdvanceInsteadOfCrashing() {
        var p = player([Playlist(tracks: tracks(2), mode: .loopPlaylist)])
        p.play(TrackPosition(playlist: 0, track: 0))
        XCTAssertFalse(p.play(TrackPosition(playlist: 0, track: 9)))
        XCTAssertFalse(p.play(TrackPosition(playlist: 4, track: 0)))
    }

    // MARK: shuffle

    func testTheSameSeedGivesTheSameDraws() {
        func draws(_ seed: UInt64) -> [Int] {
            var lists = [Playlist(tracks: tracks(5), mode: .shuffle)]
            var random = SeededRandomSource(seed: seed)
            var cur = 0
            return (0..<40).map { _ in
                guard case .track(let t) = PlayOrder.successor(after: TrackPosition(playlist: 0, track: cur), in: &lists, using: &random) else { return -1 }
                cur = t.track
                return cur
            }
        }
        XCTAssertEqual(draws(9), draws(9))
        XCTAssertNotEqual(draws(9), draws(10))
    }

    func testEveryRoundPlaysEveryTrackOnceAndNeverRepeatsAcrossRounds() {
        var lists = [Playlist(tracks: tracks(4), mode: .shuffle)]
        var random = SeededRandomSource(seed: 5)
        var cur = 0
        var seq = [Int]()
        for _ in 0..<80 {
            guard case .track(let t) = PlayOrder.successor(after: TrackPosition(playlist: 0, track: cur), in: &lists, using: &random) else { return XCTFail("no draw") }
            seq.append(t.track)
            cur = t.track
        }
        XCTAssertTrue(zip(seq, seq.dropFirst()).allSatisfy { $0 != $1 }, "never the same track twice in a row")
        // A refill takes every track except the one just played, so a round is 3 draws of 4 tracks: each distinct, and none the track that ended the round before.
        for start in stride(from: 0, to: seq.count - 3, by: 3) {
            let round = seq[start..<(start + 3)]
            XCTAssertEqual(Set(round).count, 3, "round at \(start)")
            if start > 0 { XCTAssertFalse(round.contains(seq[start - 1]), "round at \(start) repeats the track that ended the round before") }
        }
    }

    func testAPlaylistOfOneTrackShufflesToItself() {
        var lists = [Playlist(tracks: tracks(1), mode: .shuffle)]
        var random = SeededRandomSource(seed: 1)
        XCTAssertEqual(PlayOrder.successor(after: TrackPosition(playlist: 0, track: 0), in: &lists, using: &random), .track(TrackPosition(playlist: 0, track: 0)))
    }

    func testATrackRemovedFromThePlaylistLeavesTheBag() {
        var list = Playlist(tracks: tracks(4), mode: .shuffle)
        var random = SeededRandomSource(seed: 2)
        _ = list.drawShuffle(after: TrackID(0), using: &random)
        let drawnLater = list.bag.remaining
        XCTAssertEqual(drawnLater.count, 2)
        list.tracks.removeAll { $0.id == drawnLater[0] }
        let next = list.drawShuffle(after: TrackID(0), using: &random)
        XCTAssertNotNil(next)
        XCTAssertTrue(list.tracks.indices.contains(next!), "a draw is always a track of the playlist")
    }

    func testTheSeededSourceCoversItsRangeEvenly() {
        var random = SeededRandomSource(seed: 42)
        var counts = [Int](repeating: 0, count: 5)
        for _ in 0..<5000 { counts[random.next(below: 5)] += 1 }
        XCTAssertTrue(counts.allSatisfy { (800...1200).contains($0) }, "\(counts)")
    }
}
