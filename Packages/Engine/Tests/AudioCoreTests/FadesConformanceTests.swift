import XCTest

/// fades.json: equal-power curve, crossfade gains, cut, fade-out, pause. Gains are `Deck.vol` (ideal), compared within the tolerance of the case.
/// Fade lengths and sampling points come from each case's `scenario`.
final class FadesConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<FadesCases> { try FixtureLoader.load("fades") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "fades")
    }

    func testEqualPowerFormula() throws {
        let c = try fixtureCase("fades", "equal_power_formula")
        let xs = try c.scenario().doubles("x_values")
        let rows = try fixture().cases.equalPowerFormula.rows
        XCTAssertEqual(rows.map(\.x), xs, "equal_power_formula: the rows are not at the scenario's x_values")
        for row in rows {
            let up = try subject.fadeGain(.up, x: row.x)
            let down = try subject.fadeGain(.down, x: row.x)
            assertClose(up, row.up, in: c, "x=\(row.x) up")
            assertClose(down, row.down, in: c, "x=\(row.x) down")
        }
    }

    func testCrossfade1000ms() throws { try checkCrossfade(\.crossfade1000ms, name: "crossfade_1000ms") }
    func testCrossfade3000ms() throws { try checkCrossfade(\.crossfade3000ms, name: "crossfade_3000ms") }

    private func checkCrossfade(_ path: KeyPath<FadesCases, FadesCases.CrossfadeCase>, name: String) throws {
        let c = try fixtureCase("fades", name)
        let scenario = try c.scenario()
        let fadeMs = try scenario.int("fade_ms")
        let fractions = try scenario.doubles("sampled_at_fractions")
        let rows = try fixture().cases[keyPath: path].rows
        XCTAssertEqual(try fixture().cases[keyPath: path].fadeMs, fadeMs, "\(name): fade_ms of the case and of its scenario differ")
        XCTAssertEqual(rows.map(\.x), fractions, "\(name): the rows are not at the scenario's sampled_at_fractions")
        for (x, row) in zip(fractions, rows) {
            let elapsed = x * Double(fadeMs) / 1000
            assertClose(row.tS, elapsed, in: c, "t=\(row.tS) is not \(x) of the fade")
            let state = try subject.crossfadeState(fadeMs: fadeMs, elapsedS: elapsed)
            assertClose(state.newGain, row.new, in: c, "x=\(x) new")
            assertClose(state.oldGain, row.old, in: c, "x=\(x) old")
            XCTAssertEqual(state.oldStillPlaying, row.oldStillPlaying, "\(name) x=\(x) old_still_playing")
        }
    }

    func testCrossfade0msIsACut() throws {
        let c = try fixtureCase("fades", "crossfade_0ms_is_a_cut")
        let scenario = try c.scenario()
        let fadeMs = try scenario.int("fade_ms")
        let expected = try fixture().cases.crossfade0msIsACut
        for x in try scenario.doubles("sampled_at_fractions") {
            let state = try subject.crossfadeState(fadeMs: fadeMs, elapsedS: x * Double(fadeMs) / 1000)
            assertClose(state.newGain, expected.newVol, in: c, "x=\(x) new_vol")
            XCTAssertEqual(!state.oldStillPlaying, expected.oldRemoved, "crossfade_0ms_is_a_cut x=\(x) old_removed")
            XCTAssertEqual(state.oldStillPlaying ? 2 : 1, expected.decks, "crossfade_0ms_is_a_cut x=\(x) decks")
        }
    }

    func testFadeOut2000ms() throws {
        let c = try fixtureCase("fades", "fade_out_2000ms")
        let scenario = try c.scenario()
        let fadeMs = try scenario.int("fade_ms")
        let fractions = try scenario.doubles("sampled_at_fractions")
        let rows = try fixture().cases.fadeOut2000ms.rows
        XCTAssertEqual(rows.map(\.x), fractions, "fade_out_2000ms: the rows are not at the scenario's sampled_at_fractions")
        for (x, row) in zip(fractions, rows) {
            let state = try subject.fadeOutState(fadeMs: fadeMs, elapsedS: x * Double(fadeMs) / 1000)
            assertClose(state.vol, row.vol, in: c, "x=\(x) vol")
            XCTAssertEqual(state.playing, row.playing, "fade_out_2000ms x=\(x) playing")
        }
    }

    /// `live_after` is written as `live() is None`: true means nothing is live once the fade is over.
    func testFadeOut2000msNothingLiveAfter() throws {
        let fadeMs = try fixtureCase("fades", "fade_out_2000ms").scenario().int("fade_ms")
        let nothingLive = try subject.nothingLiveAfterFadeOut(fadeMs: fadeMs)
        XCTAssertEqual(nothingLive, try fixture().cases.fadeOut2000ms.liveAfter, "fade_out_2000ms live_after")
    }

    /// The fade is frozen while paused: the pause time is not counted. The crossfade starts at 0; the transport is paused at the first
    /// sample time and resumed at the second, and the third sample is taken after the resume.
    func testPauseFreezesAFade() throws {
        let c = try fixtureCase("fades", "pause_freezes_a_fade")
        let scenario = try c.scenario()
        let fadeMs = try scenario.int("fade_ms")
        let first = try scenario.double("sample_1_at_s")
        let second = try scenario.double("sample_2_at_s")
        let third = try scenario.double("sample_3_at_s")
        let expected = try fixture().cases.pauseFreezesAFade
        let samples: [(String, Double, FadesCases.NewOld)] = [
            ("at_0_25", first, expected.atQuarter),
            ("after_5s_pause", second, expected.afterFiveSecondPause),
            ("0_25s_after_resume", third, expected.quarterAfterResume),
        ]
        for (label, wallS, expected) in samples {
            let state = try subject.crossfadeState(fadeMs: fadeMs, pausedAtS: first, pausedForS: second - first, atWallS: wallS)
            assertClose(state.newGain, expected.new, in: c, "\(label) new")
            assertClose(state.oldGain, expected.old, in: c, "\(label) old")
        }
    }
}
