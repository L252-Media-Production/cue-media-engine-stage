import XCTest

/// xfade.json: crossfade time precedence and limits.
final class XfadeConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<XfadeCases> { try FixtureLoader.load("xfade") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "xfade", known: ["precedence", "own_time_limits", "play_default_uses_it"])
    }

    func testPrecedence() throws {
        for row in try fixture().cases.precedence.rows {
            let ms = try subject.crossfadeMs(explicitMs: row.explicitMs, ownMs: row.ownMs, masterMs: row.masterMs)
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

    /// The rows carry only a label; the inputs (master 3000 ms, own time none / 1500 ms) are read off the label and the case text.
    func testPlayDefaultUsesIt() throws {
        let f = try fixture()
        let inputs: [String: (own: Int?, master: Int)] = [
            "master": (nil, 3000),
            "own 1.5 s": (1500, 3000),
        ]
        for row in f.cases.playDefaultUsesIt.rows {
            guard let input = inputs[row.label] else {
                XCTFail("play_default_uses_it: unknown row '\(row.label)': add its inputs to the harness")
                continue
            }
            let len = try subject.playDefaultFadeLengthS(ownMs: input.own, masterMs: input.master)
            assertClose(len, row.fadeLenS, tolerance: f.tolerance, "play_default_uses_it: \(row.label)")
        }
    }
}
