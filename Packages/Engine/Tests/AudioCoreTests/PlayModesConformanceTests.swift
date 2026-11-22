import XCTest

/// play_modes.json. The playlists, the one under test and every input come from the cases' `scenario`; track indices are in the playlist under test.
/// Shuffle: only the listed properties are checked, never a sequence (it depends on the Python version and its seed).
final class PlayModesConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<PlayModesCases> { try FixtureLoader.load("play_modes") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "play_modes")
    }

    /// Track count of each playlist, in the order of the file (A = 0, B = 1), and the index of the playlist under test.
    private func playlists(_ s: Scenario) throws -> (trackCounts: [Int], underTest: Int) {
        let lists = try s.object("playlists")
        let counts = try lists.keys.map { try lists.strings($0).count }
        let underTest = try s.int("playlist_under_test")
        guard counts.indices.contains(underTest) else {
            throw FixtureReadError(file: s.file, caseName: s.caseName, message: "scenario.playlist_under_test \(underTest) is not one of the \(counts.count) playlists")
        }
        return (counts, underTest)
    }

    func testAfterATrackEnds() throws {
        let fc = try fixtureCase("play_modes", "after_a_track_ends")
        let s = try fc.scenario()
        let (trackCounts, underTest) = try playlists(s)
        let modes: [PlayMode] = try s.strings("play_modes").map { try s.named($0, at: "play_modes") }
        let actions: [EndAction] = try s.strings("end_actions").map { try s.named($0, at: "end_actions") }
        let tracks = try s.ints("from_tracks")
        let rows = try fixture().cases.afterATrackEnds.rows

        // The rows are exactly the combinations the scenario lists.
        let expectedKeys = Set(modes.flatMap { m in actions.flatMap { a in tracks.map { "\(m.rawValue)|\(a.rawValue)|\($0)" } } })
        XCTAssertEqual(Set(rows.map { "\($0.mode)|\($0.endAction)|\($0.track)" }), expectedKeys, "after_a_track_ends: rows differ from play_modes x end_actions x from_tracks")
        XCTAssertEqual(rows.count, expectedKeys.count, "after_a_track_ends: duplicate rows")

        for row in rows {
            let what = "after_a_track_ends mode=\(row.mode) end_action=\(row.endAction) track=\(row.track)"
            let mode: PlayMode = try s.named(row.mode, at: "row mode")
            let action: EndAction = try s.named(row.endAction, at: "row end_action")
            let got = try subject.successor(mode: mode, endAction: action, playlistTrackCounts: trackCounts, from: (underTest, row.track))
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
        let fc = try fixtureCase("play_modes", "next_in_order")
        let s = try fc.scenario()
        let (trackCounts, underTest) = try playlists(s)
        for row in try fixture().cases.nextInOrder.rows {
            let what = "next_in_order '\(row.mode)'"
            // The row label names the inputs: `row_inputs` holds the play mode and the end action of any track that has its own.
            let input = try s.row("row_inputs", label: row.mode)
            let mode: PlayMode = try input.named("play_mode")
            var looping = Set<Int>()
            for key in input.keys where key.hasPrefix("end_action_of_track_") {
                guard let index = Int(key.dropFirst("end_action_of_track_".count)) else {
                    throw FixtureReadError(file: s.file, caseName: s.caseName, message: "\(input.path).\(key): the track number is not a number")
                }
                let action: EndAction = try input.named(key)
                if action == .loop { looping.insert(index) }
            }
            XCTAssertEqual(row.fromTrack.count, row.nextInOrder.count, "\(what): from_track and next_in_order differ in length")
            for (track, expected) in zip(row.fromTrack, row.nextInOrder) {
                let got = try subject.nextInOrder(mode: mode, fromTrack: track, trackCount: trackCounts[underTest], loopingTracks: looping)
                XCTAssertEqual(got, expected, "\(what) from track \(track)")
            }
        }
    }

    private struct ShuffleSetup {
        var trackCount: Int
        var start: Int
        var sequenceDraws: Int
        var fairShareDraws: Int
        /// The number of draws one track may get out of `fairShareDraws` (`fair_share_range`).
        var fairShare: ClosedRange<Int>
    }

    private func shuffleSetup() throws -> ShuffleSetup {
        let s = try fixtureCase("play_modes", "shuffle_bag").scenario()
        let (counts, underTest) = try playlists(s)
        let range = try s.ints("fair_share_range")
        guard range.count == 2, range[0] <= range[1] else {
            throw FixtureReadError(file: s.file, caseName: s.caseName, message: "scenario.fair_share_range should be [low, high], it is \(range)")
        }
        return ShuffleSetup(
            trackCount: counts[underTest], start: try s.int("start_track"),
            sequenceDraws: try s.int("draws_for_sequence"), fairShareDraws: try s.int("draws_for_fair_share"), fairShare: range[0]...range[1])
    }

    /// The properties that can be seen from a series of draws on the playlist, starting after the start track.
    func testShuffleBagDrawProperties() throws {
        let bag = try fixture().cases.shuffleBag
        let setup = try shuffleSetup()
        let sequence = try subject.shuffleDraws(trackCount: setup.trackCount, startTrack: setup.start, count: setup.sequenceDraws)
        XCTAssertEqual(sequence.count, setup.sequenceDraws, "shuffle_bag: number of draws")

        let neverTwice = zip([setup.start] + sequence, sequence).allSatisfy { $0 != $1 }
        XCTAssertEqual(neverTwice, bag.neverTheSameTrackTwiceInARow, "shuffle_bag never_the_same_track_twice_in_a_row")

        let inPlaylist = sequence.allSatisfy { (0..<setup.trackCount).contains($0) }
        XCTAssertEqual(inPlaylist, bag.everyDrawIsATrackOfThePlaylist, "shuffle_bag every_draw_is_a_track_of_the_playlist")

        // The first round, from the start track, is a permutation of all the other tracks.
        let others = Set(0..<setup.trackCount).subtracting([setup.start])
        let round = sequence.prefix(others.count)
        let firstRound = round.count == others.count && Set(round) == others
        XCTAssertEqual(firstRound, bag.firstRoundFromTrack0IsAPermutationOfTracks1And2, "shuffle_bag first_round_from_track_0_is_a_permutation_of_tracks_1_and_2")

        let many = try subject.shuffleDraws(trackCount: setup.trackCount, startTrack: setup.start, count: setup.fairShareDraws)
        let range = setup.fairShare
        let counts = (0..<setup.trackCount).map { t in many.filter { $0 == t }.count }
        let fair = counts.allSatisfy { range.contains($0) }
        XCTAssertEqual(fair, bag.eachTrackGetsAFairShareOf300Draws60To140, "shuffle_bag each_track_gets_a_fair_share_of_300_draws_60_to_140 (counts \(counts))")
    }

    func testShuffleBagTracksLeftAfterOneDraw() throws {
        let bag = try fixture().cases.shuffleBag
        let setup = try shuffleSetup()
        let left = try subject.shuffleTracksLeftAfterOneDraw(trackCount: setup.trackCount, startTrack: setup.start)
        XCTAssertEqual(left, bag.tracksLeftInTheRoundAfterOneDrawFromTrack0, "shuffle_bag tracks_left_in_the_round_after_one_draw_from_track_0")
    }

    func testShuffleBagChangingTheModeForgetsTheRound() throws {
        let bag = try fixture().cases.shuffleBag
        let forgets = try subject.shuffleForgetsRoundOnModeChange()
        XCTAssertEqual(forgets, bag.changingTheModeForgetsTheRound, "shuffle_bag changing_the_mode_forgets_the_round")
    }
}
