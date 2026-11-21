import XCTest

/// trim.json: windows, fade-in at A, fade or cut at B. The file length and the player's trim fade settings come from each case's `scenario`.
final class TrimConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<TrimCases> { try FixtureLoader.load("trim") }

    private func config(_ scenario: Scenario) throws -> TrimConfig {
        let settings = try scenario.object("config")
        return TrimConfig(
            fileDurationS: try scenario.double("file_length_s"),
            defaultFadeOutMs: try settings.int("trim_fade_ms"),
            defaultFadeInMs: try settings.int("trim_fadein_ms"))
    }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "trim")
    }

    func testTrimRangeOfStoredData() throws {
        let c = try fixtureCase("trim", "trim_range_of_stored_data")
        let config = try config(c.scenario())
        for (i, row) in try fixture().cases.trimRangeOfStoredData.rows.enumerated() {
            let range = try subject.trimRange(stored: row.stored, fileDurationS: config.fileDurationS)
            assertClose([range.a, range.b], row.rangeS, in: c, "row \(i) \(row.stored)")
        }
    }

    func testWindows() throws {
        let c = try fixtureCase("trim", "windows")
        let config = try config(c.scenario())
        for (i, row) in try fixture().cases.windows.rows.enumerated() {
            let what = "row \(i) set=\(row.set)"
            let out = try subject.setTrim(row.set, config: config)
            XCTAssertEqual(out.accepted, row.accepted, "windows \(what) accepted")
            assertTrimFields(out.stored, row.stored, in: c, "\(what) stored")
            assertClose([out.range.a, out.range.b], row.rangeS, in: c, "\(what) range_s")
            assertClose(out.durEffS, row.durEffS, in: c, "\(what) dur_eff_s")
            XCTAssertEqual(out.fadeOutMs, row.fadeOutMs, "windows \(what) fade_out_ms")
            XCTAssertEqual(out.fadeInMsEff, row.fadeInMsEff, "windows \(what) fade_in_ms_eff")
            XCTAssertEqual(out.fadeInAppliedMs, row.fadeInAppliedMs, "windows \(what) fade_in_applied_ms")
        }
    }

    func testDeckStart() throws {
        let c = try fixtureCase("trim", "deck_start")
        let config = try config(c.scenario())
        for row in try fixture().cases.deckStart.rows {
            let what = "'\(row.label)'"
            let d = try subject.startDeck(trim: row.trim, offsetS: row.offset, config: config)
            let e = row.deck
            assertClose(d.baseS, e.baseS, in: c, "\(what) base_s")
            assertClose(d.loS, e.loS, in: c, "\(what) lo_s")
            assertClose(d.hiS, e.hiS, in: c, "\(what) hi_s")
            assertClose(d.durationS, e.durationS, in: c, "\(what) duration_s")
            XCTAssertEqual(d.endFadeMs, e.endFadeMs, "deck_start \(what) end_fade_ms")
            XCTAssertEqual(d.fadeInMs, e.fadeInMs, "deck_start \(what) fade_in_ms")
            assertClose(d.startVol, e.startVol, in: c, "\(what) start_vol")
            XCTAssertEqual(d.fresh, e.fresh, "deck_start \(what) fresh")
        }
    }

    func testFadeOutAheadOfB() throws {
        let c = try fixtureCase("trim", "fade_out_ahead_of_B")
        let scenario = try c.scenario()
        let config = try config(scenario)
        let trim: TrimFields = try scenario.decode("trim")
        let times = try scenario.doubles("sampled_at_s")
        let rows = try fixture().cases.fadeOutAheadOfB.rows
        XCTAssertEqual(rows.map(\.tS), times, "fade_out_ahead_of_B: the rows are not at the scenario's sampled_at_s")
        for (t, row) in zip(times, rows) {
            let s = try subject.trimEndFade(trim: trim, config: config, atS: t)
            assertClose(s.vol, row.vol, in: c, "t=\(t) vol")
            XCTAssertEqual(s.fading, row.fading, "fade_out_ahead_of_B t=\(t) fading")
        }
    }

    /// `live_after` true = nothing is live once the track has ended by itself.
    func testFadeOutAheadOfBEndsByItself() throws {
        let scenario = try fixtureCase("trim", "fade_out_ahead_of_B").scenario()
        let outcome = try subject.trimEndOutcome(trim: try scenario.decode("trim"), config: try config(scenario), afterS: try scenario.double("ended_check_at_s"))
        let expected = try fixture().cases.fadeOutAheadOfB
        XCTAssertEqual(outcome.ended, expected.ended, "fade_out_ahead_of_B ended")
        XCTAssertEqual(outcome.nothingLive, expected.liveAfter, "fade_out_ahead_of_B live_after")
    }

    func testFadeInAtA() throws {
        let c = try fixtureCase("trim", "fade_in_at_A")
        let fractions = try c.scenario().doubles("sampled_at_fractions")
        let rows = try fixture().cases.fadeInAtA.rows
        XCTAssertEqual(rows.map(\.x), fractions, "fade_in_at_A: the rows are not at the scenario's sampled_at_fractions")
        for row in rows {
            let vol = try subject.fadeGain(.up, x: row.x)
            assertClose(vol, row.vol, in: c, "x=\(row.x)")
        }
    }

    private func assertTrimFields(_ a: TrimFields, _ e: TrimFields, in c: FixtureCase, _ what: String, line: UInt = #line) {
        assertClose(a.inPoint, e.inPoint, in: c, "\(what) in", line: line)
        assertClose(a.outPoint, e.outPoint, in: c, "\(what) out", line: line)
        XCTAssertEqual(a.end, e.end, "\(what) end", line: line)
        XCTAssertEqual(a.fadeMs, e.fadeMs, "\(what) fade_ms", line: line)
        XCTAssertEqual(a.fadeInMs, e.fadeInMs, "\(what) fade_in_ms", line: line)
        XCTAssertEqual(a.start, e.start, "\(what) start", line: line)
    }
}
