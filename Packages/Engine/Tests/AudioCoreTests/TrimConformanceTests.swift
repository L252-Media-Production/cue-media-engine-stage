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
            let out = try subject.setTrim(row.set, previous: TrimFields(), config: config)
            XCTAssertEqual(out.accepted, row.accepted, "windows \(what) accepted")
            assertTrimFields(out.stored, row.stored, in: c, "\(what) stored")
            assertClose([out.range.a, out.range.b], row.rangeS, in: c, "\(what) range_s")
            assertClose(out.durEffS, row.durEffS, in: c, key: "dur_eff_s", "\(what) dur_eff_s")
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
            let d = try subject.startDeck(trim: row.trim, offsetS: row.offset, config: config, context: DeckStartContext())
            let e = row.deck
            assertClose(d.baseS, e.baseS, in: c, key: "base_s", "\(what) base_s")
            assertClose(d.loS, e.loS, in: c, key: "lo_s", "\(what) lo_s")
            assertClose(d.hiS, e.hiS, in: c, key: "hi_s", "\(what) hi_s")
            assertClose(d.durationS, e.durationS, in: c, key: "duration_s", "\(what) duration_s")
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

    // MARK: boundary cases

    func testShortWindowStored() throws {
        let c = try fixtureCase("trim", "short_window_stored")
        let config = try config(c.scenario())
        for (i, row) in try fixture().cases.shortWindowStored.rows.enumerated() {
            let what = "row \(i) stored=\(row.stored)"
            let range = try subject.trimRange(stored: row.stored, fileDurationS: config.fileDurationS)
            assertClose([range.a, range.b], row.rangeS, in: c, key: "range_s", "\(what) range_s")
            let d = try subject.startDeck(trim: row.stored, offsetS: 0, config: config, context: DeckStartContext())
            assertClose(((range.b - range.a) * 100).rounded() / 100, row.durEffS, in: c, key: "dur_eff_s", "\(what) dur_eff_s (rounded to 0.01 s)")
            assertClose(d.baseS, row.deck.baseS, in: c, key: "base_s", "\(what) base_s")
            assertClose(d.loS, row.deck.loS, in: c, key: "lo_s", "\(what) lo_s")
            assertClose(d.hiS, row.deck.hiS, in: c, key: "hi_s", "\(what) hi_s")
            assertClose(d.durationS, row.deck.durationS, in: c, key: "duration_s", "\(what) duration_s")
            XCTAssertEqual(d.endFadeMs, row.deck.endFadeMs, "short_window_stored \(what) end_fade_ms")
        }
    }

    /// Rows of `set_trim` calls. A row with `previous` starts from that trim; the cases that say so run the rows one after the other on the same track.
    private func checkSetRows(_ name: String, _ path: KeyPath<TrimCases, Rows<TrimCases.SetRow>>, chained: Bool = false) throws {
        let c = try fixtureCase("trim", name)
        let config = try config(c.scenario())
        var held = TrimFields()
        for (i, row) in try fixture().cases[keyPath: path].rows.enumerated() {
            let what = "row \(i) set=\(row.set)"
            let out = try subject.setTrim(row.set, previous: row.previous ?? (chained ? held : TrimFields()), config: config)
            XCTAssertEqual(out.accepted, row.accepted, "\(name) \(what) accepted")
            assertTrimFields(out.stored, row.stored, in: c, "\(what) stored")
            assertClose([out.range.a, out.range.b], row.rangeS, in: c, "\(what) range_s")
            held = out.stored
        }
    }

    func testSetTrimRoundingAB() throws { try checkSetRows("set_trim_rounding_a_b", \.setTrimRoundingAB) }
    func testSetTrimMinimumWindow() throws { try checkSetRows("set_trim_minimum_window", \.setTrimMinimumWindow) }
    func testSetTrimOutVsFileLength() throws { try checkSetRows("set_trim_out_vs_file_length", \.setTrimOutVsFileLength) }
    func testFadeLengthLimits() throws { try checkSetRows("fade_length_limits", \.fadeLengthLimits) }
    func testFadeLengthHeldToWindow() throws { try checkSetRows("fade_length_held_to_window", \.fadeLengthHeldToWindow) }
    func testFadeLengthFollowsWindowChanges() throws { try checkSetRows("fade_length_follows_window_changes", \.fadeLengthFollowsWindowChanges, chained: true) }

    func testDefaultFadeLongerThanWindow() throws {
        let c = try fixtureCase("trim", "default_fade_longer_than_window")
        let scenario = try c.scenario()
        let config = try config(scenario)
        let trim: TrimFields = try scenario.decode("trim")
        let data = try fixture().cases.defaultFadeLongerThanWindow
        let times = try scenario.doubles("sampled_at_s")
        XCTAssertEqual(data.rows.map(\.tS), times, "default_fade_longer_than_window: the rows are not at the scenario's sampled_at_s")

        let d = try subject.startDeck(trim: trim, offsetS: 0, config: config, context: DeckStartContext())
        XCTAssertEqual(d.endFadeMs, data.deck.endFadeMs, "default_fade_longer_than_window deck end_fade_ms")
        let set = try subject.setTrim(try trimSet(trim), previous: TrimFields(), config: config)
        XCTAssertEqual(set.fadeOutMs, data.deck.fadeMsEff, "default_fade_longer_than_window deck fade_ms_eff")

        let level = EndActionScenario(trackLengthS: config.fileDurationS, playMode: .stop, endAction: .default, switchOff: nil, trim: trim, defaultFadeOutMs: config.defaultFadeOutMs, defaultFadeInMs: config.defaultFadeInMs)
        for row in data.rows {
            let got = try subject.deckLevel(level, atS: row.tS)
            assertClose(got.vol, row.vol, in: c, "t=\(row.tS) vol")
            XCTAssertEqual(got.live, row.live, "default_fade_longer_than_window t=\(row.tS) live")
        }
    }

    /// A stored trim written as the `set_trim` call that makes it.
    private func trimSet(_ f: TrimFields) throws -> TrimSet {
        try JSONDecoder().decode(TrimSet.self, from: JSONEncoder().encode(f))
    }

    /// The level of a track and whether it still plays, at the sampled times, and when it ends.
    private func checkLevels(_ name: String, _ path: KeyPath<TrimCases, TrimCases.LevelCase>) throws {
        let c = try fixtureCase("trim", name)
        let scenario = try c.scenario()
        let config = try config(scenario)
        let data = try fixture().cases[keyPath: path]
        let times = try scenario.doubles("sampled_at_s")
        XCTAssertEqual(data.rows.map(\.tS), times, "\(name): the rows are not at the scenario's sampled_at_s")
        let level = try levelScenario(scenario, config)
        for row in data.rows {
            let got = try subject.deckLevel(level, atS: row.tS)
            assertClose(got.vol, row.vol, in: c, "t=\(row.tS) vol")
            XCTAssertEqual(got.live, row.live, "\(name) t=\(row.tS) live")
        }
        let end = try subject.endActionEndTimeS(level)
        assertClose(end, data.idealEndedAtS, tolerance: data.toleranceS, "\(name) ideal_ended_at_s")
    }

    private func levelScenario(_ s: Scenario, _ config: TrimConfig) throws -> EndActionScenario {
        var switchOff: EndActionScenario.Switch?
        if s.has("switch_off_to") || s.has("switch_off_at_s") {
            switchOff = .init(to: try s.named("switch_off_to"), atS: try s.double("switch_off_at_s"))
        }
        return EndActionScenario(
            trackLengthS: config.fileDurationS, playMode: .stop, endAction: try s.named("end_action"), switchOff: switchOff,
            trim: try s.decode("trim"), defaultFadeOutMs: config.defaultFadeOutMs, defaultFadeInMs: config.defaultFadeInMs)
    }

    func testOutFadePlacementLoop() throws { try checkLevels("out_fade_placement_loop", \.outFadePlacementLoop) }
    func testOutFadePlacementOnce() throws { try checkLevels("out_fade_placement_once", \.outFadePlacementOnce) }
    func testOutFadePlacementDefault() throws { try checkLevels("out_fade_placement_default", \.outFadePlacementDefault) }
    func testOutFadePlacementStop() throws { try checkLevels("out_fade_placement_stop", \.outFadePlacementStop) }

    func testOutFadeOnceSwitchedOffInPass1() throws {
        let c = try fixtureCase("trim", "out_fade_once_switched_off_in_pass_1")
        let scenario = try c.scenario()
        let config = try config(scenario)
        let data = try fixture().cases.outFadeOnceSwitchedOffInPass1
        let times = try scenario.doubles("sampled_at_s")
        XCTAssertEqual(data.rows.map(\.tS), Array(times.prefix(data.rows.count)), "out_fade_once_switched_off_in_pass_1: the rows are not at the start of the scenario's sampled_at_s")
        let level = try levelScenario(scenario, config)
        for row in data.rows {
            let got = try subject.deckLevel(level, atS: row.tS)
            assertClose(got.vol, row.vol, in: c, "t=\(row.tS) vol")
            XCTAssertEqual(got.live, row.live, "out_fade_once_switched_off_in_pass_1 t=\(row.tS) live")
        }
        assertClose(try subject.endActionEndTimeS(level), data.idealEndedAtS, tolerance: data.toleranceS, "out_fade_once_switched_off_in_pass_1 ideal_ended_at_s")
    }

    /// Only the end is contract: what the level does in the last pass of a loop that was switched off is a Python quirk (not compared).
    func testLoopSwitchedOffInPass1End() throws {
        let c = try fixtureCase("trim", "loop_switched_off_in_pass_1_end")
        let scenario = try c.scenario()
        let data = try fixture().cases.loopSwitchedOffInPass1End
        let level = try levelScenario(scenario, try config(scenario))
        assertClose(try subject.endActionEndTimeS(level), data.idealEndedAtS, tolerance: data.toleranceS, "loop_switched_off_in_pass_1_end ideal_ended_at_s")
    }

    func testFadeInStartThreshold() throws {
        let c = try fixtureCase("trim", "fade_in_start_threshold")
        let scenario = try c.scenario()
        let config = try config(scenario)
        let endAction: EndAction = try scenario.named("end_action")
        for row in try fixture().cases.fadeInStartThreshold.rows {
            let what = "'\(row.label)' offset \(row.offsetS)\(row.paused == true ? " paused" : "")\(row.crossfadeMs.map { $0 > 0 ? " crossfade \($0) ms" : "" } ?? "")"
            let context = DeckStartContext(endAction: endAction, paused: row.paused ?? false, crossfadeMs: row.crossfadeMs ?? 0)
            let d = try subject.startDeck(trim: row.trim, offsetS: row.offsetS, config: config, context: context)
            assertClose(d.baseS, row.deck.baseS, in: c, key: "base_s", "\(what) base_s")
            XCTAssertEqual(d.fadeInMs, row.deck.fadeInMs, "fade_in_start_threshold \(what) fade_in_ms")
            assertClose(d.startVol, row.deck.startVol, in: c, "\(what) start_vol")
            XCTAssertEqual(d.fresh, row.deck.fresh, "fade_in_start_threshold \(what) fresh")
            XCTAssertEqual(d.loop, row.deck.loop, "fade_in_start_threshold \(what) loop")
        }
    }

    func testFadeInCap() throws {
        let c = try fixtureCase("trim", "fade_in_cap")
        let config = try config(c.scenario())
        for row in try fixture().cases.fadeInCap.rows {
            let what = "'\(row.label)'"
            let out = try subject.setTrim(row.set, previous: TrimFields(), config: config)
            XCTAssertEqual(out.accepted, row.accepted, "fade_in_cap \(what) accepted")
            assertTrimFields(out.stored, row.stored, in: c, "\(what) stored")
            assertClose(out.durEffS, row.windowS, in: c, "\(what) window_s")
            let d = try subject.startDeck(trim: out.stored, offsetS: 0, config: config, context: DeckStartContext())
            XCTAssertEqual(d.endFadeMs, row.deck.endFadeMs, "fade_in_cap \(what) end_fade_ms")
            XCTAssertEqual(d.fadeInMs, row.deck.fadeInMs, "fade_in_cap \(what) fade_in_ms")
            assertClose(d.fadeInRampS, row.deck.fadeInRampS, in: c, "\(what) fade_in_ramp_s")
        }
    }

    /// Only the deck values are contract: the level while the two fades overlap is a Python quirk (not compared).
    private func checkOverlap(_ name: String, _ path: KeyPath<TrimCases, TrimCases.OverlapCase>) throws {
        let scenario = try fixtureCase("trim", name).scenario()
        let data = try fixture().cases[keyPath: path]
        let d = try subject.startDeck(trim: try scenario.decode("trim"), offsetS: 0, config: try config(scenario), context: DeckStartContext())
        XCTAssertEqual(d.endFadeMs, data.deck.endFadeMs, "\(name) deck end_fade_ms")
        XCTAssertEqual(d.fadeInMs, data.deck.fadeInMs, "\(name) deck fade_in_ms")
    }

    func testFadeInOutFadeOverlap901() throws { try checkOverlap("fade_in_out_fade_overlap_901", \.fadeInOutFadeOverlap901) }
    func testFadeInOutFadeOverlap1000() throws { try checkOverlap("fade_in_out_fade_overlap_1000", \.fadeInOutFadeOverlap1000) }

    private func assertTrimFields(_ a: TrimFields, _ e: TrimFields, in c: FixtureCase, _ what: String, line: UInt = #line) {
        assertClose(a.inPoint, e.inPoint, in: c, "\(what) in", line: line)
        assertClose(a.outPoint, e.outPoint, in: c, "\(what) out", line: line)
        XCTAssertEqual(a.end, e.end, "\(what) end", line: line)
        XCTAssertEqual(a.fadeMs, e.fadeMs, "\(what) fade_ms", line: line)
        XCTAssertEqual(a.fadeInMs, e.fadeInMs, "\(what) fade_in_ms", line: line)
        XCTAssertEqual(a.start, e.start, "\(what) start", line: line)
    }
}
