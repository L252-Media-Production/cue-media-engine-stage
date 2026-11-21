import XCTest

/// play_modes.json. Playlist A has 3 tracks, B has 2; track indices are in playlist 0.
/// Shuffle: only the listed properties are checked, never a sequence (it depends on the Python version and its seed).
final class PlayModesConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<PlayModesCases> { try FixtureLoader.load("play_modes") }
    private let trackCounts = [3, 2]

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "play_modes", known: ["after_a_track_ends", "next_in_order", "shuffle_bag"])
    }

    func testAfterATrackEnds() throws {
        for row in try fixture().cases.afterATrackEnds.rows {
            let what = "after_a_track_ends mode=\(row.mode) end_action=\(row.endAction) track=\(row.track)"
            guard let mode = PlayMode(rawValue: row.mode), let action = EndAction(rawValue: row.endAction) else {
                XCTFail("\(what): unknown mode or end action")
                continue
            }
            let got = try subject.successor(mode: mode, endAction: action, playlistTrackCounts: trackCounts, from: (0, row.track))
            switch row.after {
            case .stopped:
                XCTAssertEqual(got, .stopped, what)
            case .same:
                XCTAssertEqual(got, .same, what)
            case .track(let playlist, let track):
                XCTAssertEqual(got, .track(playlist: playlist, track: track), what)
            case .anyOtherTrackOfPlaylist(let playlist):
                // Shuffle: the draw itself is free; it must be another track of the same playlist.
                guard case .track(let p, let t) = got else {
                    XCTFail("\(what): expected a track of playlist \(playlist), got \(got)")
                    continue
                }
                XCTAssertEqual(p, playlist, "\(what) playlist")
                XCTAssertTrue((0..<trackCounts[playlist]).contains(t), "\(what): track \(t) is not in the playlist")
                XCTAssertNotEqual(t, row.track, "\(what): drew the same track again")
            }
        }
    }

    func testNextInOrder() throws {
        for row in try fixture().cases.nextInOrder.rows {
            let what = "next_in_order '\(row.mode)'"
            // The third row has no `from_track` and its mode and loop flag are written in the label: "stop, track 1 set to loop".
            let mode: PlayMode
            var looping = Set<Int>()
            if let m = PlayMode(rawValue: row.mode) {
                mode = m
            } else if row.mode == "stop, track 1 set to loop" {
                mode = .stop
                looping = [1]
            } else {
                XCTFail("\(what): unknown mode: add it to the harness")
                continue
            }
            let from = row.fromTrack ?? [0, 1, 2]
            XCTAssertEqual(from.count, row.nextInOrder.count, "\(what): from_track and next_in_order differ in length")
            for (track, expected) in zip(from, row.nextInOrder) {
                let got = try subject.nextInOrder(mode: mode, fromTrack: track, trackCount: 3, loopingTracks: looping)
                XCTAssertEqual(got, expected, "\(what) from track \(track)")
            }
        }
    }

    /// The properties that can be seen from a series of draws on a playlist of 3 tracks, starting after track 0.
    func testShuffleBagDrawProperties() throws {
        let bag = try fixture().cases.shuffleBag
        let start = 0
        let draws = try subject.shuffleDraws(trackCount: 3, startTrack: start, count: 300)
        XCTAssertEqual(draws.count, 300, "shuffle_bag: number of draws")

        let neverTwice = zip([start] + draws, draws).allSatisfy { $0 != $1 }
        XCTAssertEqual(neverTwice, bag.neverTheSameTrackTwiceInARow, "shuffle_bag never_the_same_track_twice_in_a_row")

        let inPlaylist = draws.allSatisfy { (0..<3).contains($0) }
        XCTAssertEqual(inPlaylist, bag.everyDrawIsATrackOfThePlaylist, "shuffle_bag every_draw_is_a_track_of_the_playlist")

        let firstRound = draws.count >= 2 && Set(draws[0..<2]) == [1, 2]
        XCTAssertEqual(firstRound, bag.firstRoundFromTrack0IsAPermutationOfTracks1And2, "shuffle_bag first_round_from_track_0_is_a_permutation_of_tracks_1_and_2")

        let counts = (0..<3).map { t in draws.filter { $0 == t }.count }
        let fair = counts.allSatisfy { (60...140).contains($0) }
        XCTAssertEqual(fair, bag.eachTrackGetsAFairShareOf300Draws60To140, "shuffle_bag each_track_gets_a_fair_share_of_300_draws_60_to_140 (counts \(counts))")
    }

    func testShuffleBagTracksLeftAfterOneDraw() throws {
        let bag = try fixture().cases.shuffleBag
        let left = try subject.shuffleTracksLeftAfterOneDraw(trackCount: 3, startTrack: 0)
        XCTAssertEqual(left, bag.tracksLeftInTheRoundAfterOneDrawFromTrack0, "shuffle_bag tracks_left_in_the_round_after_one_draw_from_track_0")
    }

    func testShuffleBagChangingTheModeForgetsTheRound() throws {
        let bag = try fixture().cases.shuffleBag
        let forgets = try subject.shuffleForgetsRoundOnModeChange()
        XCTAssertEqual(forgets, bag.changingTheModeForgetsTheRound, "shuffle_bag changing_the_mode_forgets_the_round")
    }
}
