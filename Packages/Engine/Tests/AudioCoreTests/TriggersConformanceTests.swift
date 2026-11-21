import XCTest

/// triggers.json. Fire times are compared with `ideal_fires` within `tolerance_s`, never with `fires` (the Python measurement includes its 50 ms tick).
///
/// The JSON holds the triggers and the trim of each case but not the rest of the scenario. That comes from generate.py (read-only):
/// the main track is 120 s, `vo.wav` 3 s and `vo2.wav` 8 s, and each case runs for a fixed time, with an end action of loop or a seek where noted.
final class TriggersConformanceTests: FixtureTestCase {
    private struct Setup {
        var runForS: Double
        var loop = false
        var seek: (atS: Double, toS: Double)?
    }

    private static let setups: [String: Setup] = [
        "simple": Setup(runForS: 14),
        "two_in_order": Setup(runForS: 25),
        "disabled": Setup(runForS: 8),
        "trim_in_after_trigger": Setup(runForS: 6),
        "trim_out_before_trigger": Setup(runForS: 10),
        "trigger_inside_trim": Setup(runForS: 10),
        "seek_over_does_not_fire": Setup(runForS: 14, seek: (1.0, 20.0)),
        "seek_back_rearms": Setup(runForS: 26, seek: (14.0, 2.0)),
        "loop_fires_every_pass": Setup(runForS: 14, loop: true),
        "once_flag": Setup(runForS: 14, loop: true),
        "top_already_playing_skips": Setup(runForS: 14),
    ]

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "triggers", known: Set(Self.setups.keys))
    }

    func testSimple() throws { try run("simple") }
    func testTwoInOrder() throws { try run("two_in_order") }
    func testDisabled() throws { try run("disabled") }
    func testTrimInAfterTrigger() throws { try run("trim_in_after_trigger") }
    func testTrimOutBeforeTrigger() throws { try run("trim_out_before_trigger") }
    func testTriggerInsideTrim() throws { try run("trigger_inside_trim") }
    func testSeekOverDoesNotFire() throws { try run("seek_over_does_not_fire") }
    func testSeekBackRearms() throws { try run("seek_back_rearms") }
    func testLoopFiresEveryPass() throws { try run("loop_fires_every_pass") }
    func testOnceFlag() throws { try run("once_flag") }
    func testTopAlreadyPlayingSkips() throws { try run("top_already_playing_skips") }

    private func run(_ name: String) throws {
        let f: Fixture<InfoFilteredDictionary<TriggerCase>> = try FixtureLoader.load("triggers")
        let c = try XCTUnwrap(f.cases.values[name], "triggers.json has no case \(name)")
        let setup = try XCTUnwrap(Self.setups[name], "no setup for case \(name): add it to the harness")

        let scenario = TriggerScenario(
            triggers: c.triggers, trim: c.trim, fileDurationS: 120,
            voiceOverLengthsS: ["vo.wav": 3, "vo2.wav": 8],
            loop: setup.loop, seek: setup.seek, runForS: setup.runForS
        )
        let fires = try subject.triggerFireTimes(scenario).sorted { $0.tS < $1.tS }
        XCTAssertEqual(fires.count, c.idealFires.count, "\(name): number of fires (got \(fires.map(\.tS)), ideal \(c.idealFires.map(\.tS)))")
        for (i, pair) in zip(fires, c.idealFires).enumerated() {
            assertClose(pair.0.tS, pair.1.tS, tolerance: c.toleranceS, "\(name) fire \(i) time")
            XCTAssertEqual(pair.0.file, pair.1.file, "\(name) fire \(i) file")
        }
    }
}
