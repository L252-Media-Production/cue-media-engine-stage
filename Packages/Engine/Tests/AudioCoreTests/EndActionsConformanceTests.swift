import XCTest

/// end_actions.json: a 2 s track alone on a playlist in play mode `stop`.
/// The end time is compared with `ideal_ended_at_s` within the case's `tolerance_s`, never with the measured `ended_at_s`
/// (it includes the 50 ms tick of the Python player and the 0.25 s sampling grid of the scenario).
final class EndActionsConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<EndActionsCases> { try FixtureLoader.load("end_actions") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "end_actions", known: [
            "track_2s_end_default", "track_2s_end_once", "track_2s_end_loop", "track_2s_end_stop",
            "once_switched_off_in_pass_1", "loop_switched_off_in_pass_2", "end_action_cycle",
        ])
    }

    func testTrack2sEndDefault() throws { try check(\.track2sEndDefault, "track_2s_end_default", .default, switchedAt: nil) }
    func testTrack2sEndOnce() throws { try check(\.track2sEndOnce, "track_2s_end_once", .once, switchedAt: nil) }
    func testTrack2sEndLoop() throws { try check(\.track2sEndLoop, "track_2s_end_loop", .loop, switchedAt: nil) }
    func testTrack2sEndStop() throws { try check(\.track2sEndStop, "track_2s_end_stop", .stop, switchedAt: nil) }
    /// "end action set back to default at 1.0 s" (the case text; the JSON has no field for it).
    func testOnceSwitchedOffInPass1() throws { try check(\.onceSwitchedOffInPass1, "once_switched_off_in_pass_1", .once, switchedAt: 1.0) }
    /// "end action set back to default at 3.0 s (pass 2 running)".
    func testLoopSwitchedOffInPass2() throws { try check(\.loopSwitchedOffInPass2, "loop_switched_off_in_pass_2", .loop, switchedAt: 3.0) }

    func testEndActionCycle() throws {
        let sequence = try fixture().cases.endActionCycle.sequence
        for (i, pair) in zip(sequence, sequence.dropFirst()).enumerated() {
            guard let from = EndAction(rawValue: pair.0), let to = EndAction(rawValue: pair.1) else {
                return XCTFail("end_action_cycle: unknown end action in \(pair)")
            }
            let next = try subject.nextEndAction(after: from)
            XCTAssertEqual(next, to, "end_action_cycle step \(i): after \(from)")
        }
    }

    private func check(
        _ path: KeyPath<EndActionsCases, EndActionsCases.EndCase>, _ name: String, _ action: EndAction, switchedAt: Double?
    ) throws {
        let f = try fixture()
        let c = f.cases[keyPath: path]
        let scenario = EndActionScenario(trackLengthS: 2, endAction: action, switchedToDefaultAtS: switchedAt)

        if let start = c.deckAtStart {
            let d = try subject.endActionDeckStart(action)
            XCTAssertEqual(d.passes, start.passes, "\(name) deck_at_start passes")
            XCTAssertEqual(d.loop, start.loop, "\(name) deck_at_start loop")
        }
        for row in c.rows {
            let s = try subject.endActionState(scenario, atS: row.tS)
            XCTAssertEqual(s.live, row.live, "\(name) t=\(row.tS) live")
            XCTAssertEqual(s.passNo, row.passNo, "\(name) t=\(row.tS) pass_no")
            assertClose(s.remainingS, row.remainingS, tolerance: f.tolerance, "\(name) t=\(row.tS) remaining_s")
        }
        let end = try subject.endActionEndTimeS(scenario)
        assertClose(end, c.idealEndedAtS, tolerance: c.toleranceS, "\(name) ideal_ended_at_s")
    }
}
