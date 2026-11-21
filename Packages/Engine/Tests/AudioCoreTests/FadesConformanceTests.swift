import XCTest

/// fades.json: equal-power curve, crossfade gains, cut, fade-out, pause. Gains are `Deck.vol` (ideal), compared within the file's `tolerance`.
final class FadesConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<FadesCases> { try FixtureLoader.load("fades") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "fades", known: [
            "equal_power_formula", "crossfade_1000ms", "crossfade_3000ms", "crossfade_0ms_is_a_cut", "fade_out_2000ms", "pause_freezes_a_fade",
        ])
    }

    func testEqualPowerFormula() throws {
        let f = try fixture()
        for row in f.cases.equalPowerFormula.rows {
            let up = try subject.fadeGain(.up, x: row.x)
            let down = try subject.fadeGain(.down, x: row.x)
            assertClose(up, row.up, tolerance: f.tolerance, "equal_power_formula x=\(row.x) up")
            assertClose(down, row.down, tolerance: f.tolerance, "equal_power_formula x=\(row.x) down")
        }
    }

    func testCrossfade1000ms() throws { try checkCrossfade(\.crossfade1000ms, name: "crossfade_1000ms") }
    func testCrossfade3000ms() throws { try checkCrossfade(\.crossfade3000ms, name: "crossfade_3000ms") }

    private func checkCrossfade(_ path: KeyPath<FadesCases, FadesCases.CrossfadeCase>, name: String) throws {
        let f = try fixture()
        let c = f.cases[keyPath: path]
        for row in c.rows {
            let state = try subject.crossfadeState(fadeMs: c.fadeMs, elapsedS: row.tS)
            assertClose(state.newGain, row.new, tolerance: f.tolerance, "\(name) t=\(row.tS) new")
            assertClose(state.oldGain, row.old, tolerance: f.tolerance, "\(name) t=\(row.tS) old")
            XCTAssertEqual(state.oldStillPlaying, row.oldStillPlaying, "\(name) t=\(row.tS) old_still_playing")
        }
    }

    func testCrossfade0msIsACut() throws {
        let f = try fixture()
        let c = f.cases.crossfade0msIsACut
        let state = try subject.crossfadeState(fadeMs: 0, elapsedS: 0)
        assertClose(state.newGain, c.newVol, tolerance: f.tolerance, "crossfade_0ms_is_a_cut new_vol")
        XCTAssertEqual(!state.oldStillPlaying, c.oldRemoved, "crossfade_0ms_is_a_cut old_removed")
        XCTAssertEqual(state.oldStillPlaying ? 2 : 1, c.decks, "crossfade_0ms_is_a_cut decks")
    }

    func testFadeOut2000ms() throws {
        let f = try fixture()
        for row in f.cases.fadeOut2000ms.rows {
            let state = try subject.fadeOutState(fadeMs: 2000, elapsedS: row.x * 2.0)
            assertClose(state.vol, row.vol, tolerance: f.tolerance, "fade_out_2000ms x=\(row.x) vol")
            XCTAssertEqual(state.playing, row.playing, "fade_out_2000ms x=\(row.x) playing")
        }
    }

    /// `live_after` is written as `live() is None`: true means nothing is live once the fade is over.
    func testFadeOut2000msNothingLiveAfter() throws {
        let f = try fixture()
        let nothingLive = try subject.nothingLiveAfterFadeOut(fadeMs: 2000)
        XCTAssertEqual(nothingLive, f.cases.fadeOut2000ms.liveAfter, "fade_out_2000ms live_after")
    }

    /// The fade is frozen while paused: the pause time is not counted.
    func testPauseFreezesAFade() throws {
        let f = try fixture()
        let c = f.cases.pauseFreezesAFade
        let samples: [(String, Double, FadesCases.NewOld)] = [
            ("at_0_25", 0.25, c.atQuarter),
            ("after_5s_pause", 5.25, c.afterFiveSecondPause),
            ("0_25s_after_resume", 5.5, c.quarterAfterResume),
        ]
        for (label, wallS, expected) in samples {
            // 1000 ms crossfade started at 0, paused at 0.25 s for 5 s (back at 5.25 s).
            let state = try subject.crossfadeState(fadeMs: 1000, pausedAtS: 0.25, pausedForS: 5.0, atWallS: wallS)
            assertClose(state.newGain, expected.new, tolerance: f.tolerance, "pause_freezes_a_fade \(label) new")
            assertClose(state.oldGain, expected.old, tolerance: f.tolerance, "pause_freezes_a_fade \(label) old")
        }
    }
}
