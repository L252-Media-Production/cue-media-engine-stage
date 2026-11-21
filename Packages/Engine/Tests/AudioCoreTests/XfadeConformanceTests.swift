import XCTest

/// xfade.json: crossfade time precedence and limits.
final class XfadeConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<XfadeCases> { try FixtureLoader.load("xfade") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "xfade")
    }

    func testPrecedence() throws {
        let master = try fixtureCase("xfade", "precedence").scenario().int("master_crossfade_ms")
        for row in try fixture().cases.precedence.rows {
            XCTAssertEqual(row.masterMs, master, "precedence: \(row.label): master_ms of the row and master_crossfade_ms of the scenario differ")
            let ms = try subject.crossfadeMs(explicitMs: row.explicitMs, ownMs: row.ownMs, masterMs: master)
            XCTAssertEqual(ms, row.resultMs, "precedence: \(row.label)")
        }
    }

    func testOwnTimeLimits() throws {
        for row in try fixture().cases.ownTimeLimits.rows {
            let result = try subject.storeOwnCrossfade(seconds: row.seconds)
            XCTAssertEqual(result.accepted, row.accepted, "own_time_limits \(row.seconds) accepted")
            XCTAssertEqual(result.storedMs, row.storedMs, "own_time_limits \(row.seconds) stored_ms")
        }
    }

    /// The inputs of each row (the track's own time, null = none) are in `row_inputs` of the scenario, keyed by the row label.
    func testPlayDefaultUsesIt() throws {
        let c = try fixtureCase("xfade", "play_default_uses_it")
        let scenario = try c.scenario()
        let master = try scenario.int("master_crossfade_ms")
        let transition = try scenario.string("default_transition")
        XCTAssertEqual(transition, "crossfade", "play_default_uses_it: the harness asks about default_transition crossfade only")
        for row in try fixture().cases.playDefaultUsesIt.rows {
            let input = try scenario.row("row_inputs", label: row.label)
            let ownS = try input.optionalDouble("own_time_s")
            let len = try subject.playDefaultFadeLengthS(ownMs: ownS.map { Int(($0 * 1000).rounded()) }, masterMs: master)
            assertClose(len, row.fadeLenS, in: c, "\(row.label)")
        }
    }
}
