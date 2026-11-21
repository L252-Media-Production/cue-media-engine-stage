import XCTest

/// triggers.json. Fire times are compared with `ideal_fires` within `tolerance_s`, never with `fires` (the Python measurement includes its 50 ms tick).
/// Everything the scenario needs (track and voice-over lengths, end action, trim, seek, triggers, run time) comes from the case's `scenario`.
final class TriggersConformanceTests: FixtureTestCase {
    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "triggers")
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
        let s = try fixtureCase("triggers", name).scenario()

        let triggers: [TriggerCase.Point] = try s.decode("triggers")
        let trim: TrimFields = try s.decode("trim")
        XCTAssertEqual(triggers, c.triggers, "\(name): triggers of the case and of its scenario differ")
        XCTAssertEqual(trim, c.trim, "\(name): trim of the case and of its scenario differ")
        let mainLength = try s.double("main_track_length_s")
        XCTAssertEqual(try s.number("library_s", named: try s.string("main_track")), mainLength, "\(name): main_track_length_s is not the main track's library length")
        var seek: (atS: Double, toS: Double)?
        if let o = try s.optionalObject("seek") { seek = (try o.double("at_s"), try o.double("to_s")) }

        let scenario = TriggerScenario(
            triggers: triggers, trim: trim, fileDurationS: mainLength,
            voiceOverLengthsS: Dictionary(uniqueKeysWithValues: try s.numbersByName("voice_over_lengths_s").map { ($0.name, $0.value) }),
            endAction: try s.named("end_action"), seek: seek, runForS: try s.double("run_s")
        )
        let fires = try subject.triggerFireTimes(scenario).sorted { $0.tS < $1.tS }
        XCTAssertEqual(fires.count, c.idealFires.count, "\(name): number of fires (got \(fires.map(\.tS)), ideal \(c.idealFires.map(\.tS)))")
        for (i, pair) in zip(fires, c.idealFires).enumerated() {
            assertClose(pair.0.tS, pair.1.tS, tolerance: c.toleranceS, "\(name) fire \(i) time")
            XCTAssertEqual(pair.0.file, pair.1.file, "\(name) fire \(i) file")
        }
    }
}
