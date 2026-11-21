import XCTest

/// end_actions.json: one track alone on a playlist; its length, play mode, end action and sampling times come from the case's `scenario`.
/// The end time is compared with `ideal_ended_at_s` within the case's `tolerance_s`, never with the measured `ended_at_s`
/// (it includes the 50 ms tick of the Python player and the sampling grid of the scenario).
final class EndActionsConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<EndActionsCases> { try FixtureLoader.load("end_actions") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "end_actions")
    }

    func testTrack2sEndDefault() throws { try check(\.track2sEndDefault, "track_2s_end_default") }
    func testTrack2sEndOnce() throws { try check(\.track2sEndOnce, "track_2s_end_once") }
    func testTrack2sEndLoop() throws { try check(\.track2sEndLoop, "track_2s_end_loop") }
    func testTrack2sEndStop() throws { try check(\.track2sEndStop, "track_2s_end_stop") }
    func testOnceSwitchedOffInPass1() throws { try check(\.onceSwitchedOffInPass1, "once_switched_off_in_pass_1") }
    func testLoopSwitchedOffInPass2() throws { try check(\.loopSwitchedOffInPass2, "loop_switched_off_in_pass_2") }

    func testEndActionCycle() throws {
        _ = try fixtureCase("end_actions", "end_action_cycle").scenario()
        let sequence = try fixture().cases.endActionCycle.sequence
        for (i, pair) in zip(sequence, sequence.dropFirst()).enumerated() {
            guard let from = EndAction(rawValue: pair.0), let to = EndAction(rawValue: pair.1) else {
                return XCTFail("end_action_cycle: unknown end action in \(pair)")
            }
            let next = try subject.nextEndAction(after: from)
            XCTAssertEqual(next, to, "end_action_cycle step \(i): after \(from)")
        }
    }

    private func scenarioOf(_ s: Scenario) throws -> EndActionScenario {
        let playlist = try s.strings("playlist")
        guard let first = playlist.first, playlist.count == 1 else {
            throw FixtureReadError(file: s.file, caseName: s.caseName, message: "scenario.playlist should hold one track, it holds \(playlist)")
        }
        var switchOff: EndActionScenario.Switch?
        if s.has("switch_off_to") || s.has("switch_off_at_s") {
            switchOff = .init(to: try s.named("switch_off_to"), atS: try s.double("switch_off_at_s"))
        }
        return EndActionScenario(
            trackLengthS: try s.number("library_s", named: first),
            playMode: try s.named("play_mode"),
            endAction: try s.named("end_action"),
            switchOff: switchOff)
    }

    private func check(_ path: KeyPath<EndActionsCases, EndActionsCases.EndCase>, _ name: String) throws {
        let fc = try fixtureCase("end_actions", name)
        let s = try fc.scenario()
        let c = try fixture().cases[keyPath: path]
        let scenario = try scenarioOf(s)

        if let start = c.deckAtStart {
            let d = try subject.endActionDeckStart(scenario.endAction)
            XCTAssertEqual(d.passes, start.passes, "\(name) deck_at_start passes")
            XCTAssertEqual(d.loop, start.loop, "\(name) deck_at_start loop")
        }
        // Every row is at a time the scenario samples. (The two "switched off" cases list 0.0 and 9.0 in rows_at_s but hold no rows there:
        // the fixture's rows cover only part of the list, so the rows, not the list, decide which times are asked.)
        let times = try s.doubles("rows_at_s")
        XCTAssertEqual(Set(c.rows.map(\.tS)).subtracting(times), [], "\(name): rows at times that are not in the scenario's rows_at_s")
        for row in c.rows {
            let t = row.tS
            let state = try subject.endActionState(scenario, atS: t)
            XCTAssertEqual(state.live, row.live, "\(name) t=\(t) live")
            XCTAssertEqual(state.passNo, row.passNo, "\(name) t=\(t) pass_no")
            assertClose(state.remainingS, row.remainingS, in: fc, "t=\(t) remaining_s")
        }
        let end = try subject.endActionEndTimeS(scenario)
        assertClose(end, c.idealEndedAtS, tolerance: c.toleranceS, "\(name) ideal_ended_at_s")
    }
}
