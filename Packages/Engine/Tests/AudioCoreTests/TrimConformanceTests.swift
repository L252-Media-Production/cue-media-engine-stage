import XCTest

/// trim.json: windows, fade-in at A, fade or cut at B. The tracks are 10 s long, `trim_fade_ms` is 1500 and `trim_fadein_ms` is 0 (generate.py).
final class TrimConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<TrimCases> { try FixtureLoader.load("trim") }
    private let config = TrimConfig(fileDurationS: 10, defaultFadeOutMs: 1500, defaultFadeInMs: 0)

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "trim", known: [
            "trim_range_of_stored_data", "windows", "deck_start", "fade_out_ahead_of_B", "fade_in_at_A",
        ])
    }

    func testTrimRangeOfStoredData() throws {
        let f = try fixture()
        for (i, row) in f.cases.trimRangeOfStoredData.rows.enumerated() {
            let range = try subject.trimRange(stored: row.stored, fileDurationS: config.fileDurationS)
            assertClose([range.a, range.b], row.rangeS, tolerance: f.tolerance, "trim_range_of_stored_data row \(i) \(row.stored)")
        }
    }

    func testWindows() throws {
        let f = try fixture()
        for (i, row) in f.cases.windows.rows.enumerated() {
            let what = "windows row \(i) set=\(row.set)"
            let out = try subject.setTrim(row.set, config: config)
            XCTAssertEqual(out.accepted, row.accepted, "\(what) accepted")
            assertTrimFields(out.stored, row.stored, tolerance: f.tolerance, "\(what) stored")
            assertClose([out.range.a, out.range.b], row.rangeS, tolerance: f.tolerance, "\(what) range_s")
            assertClose(out.durEffS, row.durEffS, tolerance: f.tolerance, "\(what) dur_eff_s")
            XCTAssertEqual(out.fadeOutMs, row.fadeOutMs, "\(what) fade_out_ms")
            XCTAssertEqual(out.fadeInMsEff, row.fadeInMsEff, "\(what) fade_in_ms_eff")
            XCTAssertEqual(out.fadeInAppliedMs, row.fadeInAppliedMs, "\(what) fade_in_applied_ms")
        }
    }

    func testDeckStart() throws {
        let f = try fixture()
        for row in f.cases.deckStart.rows {
            let what = "deck_start '\(row.label)'"
            let d = try subject.startDeck(trim: row.trim, offsetS: row.offset, config: config)
            let e = row.deck
            assertClose(d.baseS, e.baseS, tolerance: f.tolerance, "\(what) base_s")
            assertClose(d.loS, e.loS, tolerance: f.tolerance, "\(what) lo_s")
            assertClose(d.hiS, e.hiS, tolerance: f.tolerance, "\(what) hi_s")
            assertClose(d.durationS, e.durationS, tolerance: f.tolerance, "\(what) duration_s")
            XCTAssertEqual(d.endFadeMs, e.endFadeMs, "\(what) end_fade_ms")
            XCTAssertEqual(d.fadeInMs, e.fadeInMs, "\(what) fade_in_ms")
            assertClose(d.startVol, e.startVol, tolerance: f.tolerance, "\(what) start_vol")
            XCTAssertEqual(d.fresh, e.fresh, "\(what) fresh")
        }
    }

    /// Window 0..6 s, out-fade 2000 ms: the cos fade starts when 2 s are left and reaches 0 at B.
    private let outFadeTrim = TrimFields(outPoint: 6, end: "fade", fadeMs: 2000)

    func testFadeOutAheadOfB() throws {
        let f = try fixture()
        for row in f.cases.fadeOutAheadOfB.rows {
            let s = try subject.trimEndFade(trim: outFadeTrim, config: config, atS: row.tS)
            assertClose(s.vol, row.vol, tolerance: f.tolerance, "fade_out_ahead_of_B t=\(row.tS) vol")
            XCTAssertEqual(s.fading, row.fading, "fade_out_ahead_of_B t=\(row.tS) fading")
        }
    }

    /// `live_after` true = nothing is live once the track has ended by itself.
    func testFadeOutAheadOfBEndsByItself() throws {
        let f = try fixture()
        let outcome = try subject.trimEndOutcome(trim: outFadeTrim, config: config, afterS: 6.25)
        XCTAssertEqual(outcome.ended, f.cases.fadeOutAheadOfB.ended, "fade_out_ahead_of_B ended")
        XCTAssertEqual(outcome.nothingLive, f.cases.fadeOutAheadOfB.liveAfter, "fade_out_ahead_of_B live_after")
    }

    func testFadeInAtA() throws {
        let f = try fixture()
        for row in f.cases.fadeInAtA.rows {
            let vol = try subject.fadeGain(.up, x: row.x)
            assertClose(vol, row.vol, tolerance: f.tolerance, "fade_in_at_A x=\(row.x)")
        }
    }

    private func assertTrimFields(_ a: TrimFields, _ e: TrimFields, tolerance: Double, _ what: String, line: UInt = #line) {
        assertClose(a.inPoint, e.inPoint, tolerance: tolerance, "\(what) in", line: line)
        assertClose(a.outPoint, e.outPoint, tolerance: tolerance, "\(what) out", line: line)
        XCTAssertEqual(a.end, e.end, "\(what) end", line: line)
        XCTAssertEqual(a.fadeMs, e.fadeMs, "\(what) fade_ms", line: line)
        XCTAssertEqual(a.fadeInMs, e.fadeInMs, "\(what) fade_in_ms", line: line)
        XCTAssertEqual(a.start, e.start, "\(what) start", line: line)
    }
}
