import XCTest

/// triggers.json. Fire times are compared with `ideal_fires` / `ideal_fired` / `ideal_t_s` within `tolerance_s`, never with `fires` / `fired` / `first_fire_t_s`
/// (the Python measurement includes its 50 ms tick) and never with `python_differs` rows' Python values or `_info_python_*` (quirks 13, 14 and 15 of the spec
/// are not contract). Everything the scenario needs comes from the case's `scenario`.
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

    func testOnceSeekBackInPass1() throws { try run("once_seek_back_in_pass_1") }
    func testOnceSkippedBySeekForwardThenBack() throws { try run("once_skipped_by_seek_forward_then_back") }
    func testOnceLoopSeekBackInLap1() throws { try run("once_loop_seek_back_in_lap_1") }
    func testOnceLoopSeekBackInLap2() throws { try run("once_loop_seek_back_in_lap_2") }
    func testTargetReadyAfter1s() throws { try run("target_ready_after_1s") }
    func testTargetNeverReady() throws { try run("target_never_ready") }
    func testTargetNeverReadyDoesNotBlockNextPoint() throws { try run("target_never_ready_does_not_block_next_point") }

    // MARK: cases with a list of fires

    private func scenario(_ name: String, _ s: Scenario) throws -> TriggerScenario {
        let mainLength = try s.double("main_track_length_s")
        XCTAssertEqual(try s.number("library_s", named: try s.string("main_track")), mainLength, "\(name): main_track_length_s is not the main track's library length")
        var seeks: [(atS: Double, toS: Double)] = []
        if s.has("seek"), let o = try s.optionalObject("seek") { seeks.append((try o.double("at_s"), try o.double("to_s"))) }
        if s.has("seeks") {
            let seekIsNull = try s.has("seek") ? s.isNull("seek") : true
            XCTAssertTrue(seekIsNull, "\(name): `seek` and `seeks` are both set")
            seeks = try s.objects("seeks").map { (try $0.double("at_s"), try $0.double("to_s")) }
        }
        var ready = TargetReadyAt.always
        var readyByFile = [String: TargetReadyAt]()
        if s.has("target_decoded_at_s") {
            if case .object = try s.raw("target_decoded_at_s") {
                // One time per file (null: never decoded).
                let o = try s.object("target_decoded_at_s")
                for file in o.keys { readyByFile[file] = try o.optionalDouble(file).map { .atS($0) } ?? .never }
            } else {
                ready = try s.optionalDouble("target_decoded_at_s").map { .atS($0) } ?? .never
            }
        }
        var scenario = TriggerScenario(
            triggers: try s.decode("triggers"), trim: s.has("trim") ? try s.decode("trim") : TrimFields(), fileDurationS: mainLength,
            voiceOverLengthsS: Dictionary(uniqueKeysWithValues: try s.numbersByName("voice_over_lengths_s").map { ($0.name, $0.value) }),
            endAction: try s.named("end_action"), seeks: seeks, runForS: s.has("run_s") ? try s.double("run_s") : 0, targetReady: ready)
        scenario.targetReadyByFile = readyByFile
        return scenario
    }

    private func run(_ name: String) throws {
        let fc = try fixtureCase("triggers", name)
        let s = try fc.scenario()
        let c = caseValues(fc)
        let triggers: [TriggerCase.Point] = try s.decode("triggers")
        XCTAssertEqual(try c.decode("triggers") as [TriggerCase.Point], triggers, "\(name): triggers of the case and of its scenario differ")
        if s.has("trim") {
            XCTAssertEqual(try s.decode("trim") as TrimFields, try c.decode("trim"), "\(name): trim of the case and of its scenario differ")
        }
        let ideal: [TriggerCase.Fire] = try c.decode("ideal_fires")
        let tolerance = try c.double("tolerance_s")
        let fires = try subject.triggerFireTimes(try scenario(name, s)).sorted { $0.tS < $1.tS }
        XCTAssertEqual(fires.count, ideal.count, "\(name): number of fires (got \(fires.map(\.tS)), ideal \(ideal.map(\.tS)))")
        for (i, pair) in zip(fires, ideal).enumerated() {
            assertClose(pair.0.tS, pair.1.tS, tolerance: tolerance, "\(name) fire \(i) time")
            XCTAssertEqual(pair.0.file, pair.1.file, "\(name) fire \(i) file")
        }
    }

    // MARK: margins at A

    /// The case's own values (rows, `tolerance_s`), read with the scenario accessors.
    private func caseValues(_ fc: FixtureCase) -> Scenario {
        Scenario(file: fc.file, caseName: fc.name, path: "case", value: fc.value)
    }

    private func optionalBool(_ s: Scenario, _ key: String) throws -> Bool? {
        try s.isNull(key) ? nil : try s.bool(key)
    }

    /// One trigger point on a 120 s track, played from `offsetS` for `runFor` s; the fires.
    private func fires(of s: Scenario, trim: TrimFields, at: Double, offsetS: Double) throws -> [TriggerFire] {
        let voice = try s.string("voice_over")
        let scenario = TriggerScenario(
            triggers: [TriggerCase.Point(at: at, file: voice, enabled: nil, once: nil)], trim: trim, fileDurationS: try s.double("main_track_length_s"),
            voiceOverLengthsS: [voice: try s.number("library_s", named: voice)], endAction: try s.named("end_action"), seeks: [], runForS: try s.double("run_s"),
            offsetS: offsetS)
        return try subject.triggerFireTimes(scenario).sorted { $0.tS < $1.tS }
    }

    /// `ideal_fired` true/false is compared; null is not defined and is skipped. A fire is compared with `ideal_t_s` within `tolerance_s`.
    private func checkFire(_ fires: [TriggerFire], ideal: Bool?, idealT: Double?, tolerance: Double, _ what: String) {
        guard let ideal else { return }
        XCTAssertEqual(!fires.isEmpty, ideal, "\(what): fired")
        if ideal, let first = fires.first, let idealT { assertClose(first.tS, idealT, tolerance: tolerance, "\(what) first fire time") }
    }

    func testPointAtOrNearAStartAtA() throws {
        let fc = try fixtureCase("triggers", "point_at_or_near_A_start_at_A")
        let s = try fc.scenario()
        let top = caseValues(fc)
        let tolerance = try top.double("tolerance_s")
        for (i, row) in try top.objects("rows").enumerated() {
            let a = try row.double("A_s"), at = try row.double("at")
            let got = try fires(of: s, trim: a > 0 ? TrimFields(inPoint: a) : TrimFields(), at: at, offsetS: 0)
            checkFire(got, ideal: try optionalBool(row, "ideal_fired"), idealT: try row.optionalDouble("ideal_t_s"), tolerance: tolerance, "row \(i) A=\(a) at=\(at)")
        }
    }

    func testPointNearAStartWithOffset() throws {
        let fc = try fixtureCase("triggers", "point_near_A_start_with_offset")
        let s = try fc.scenario()
        let top = caseValues(fc)
        let tolerance = try top.double("tolerance_s")
        let trim: TrimFields = try s.decode("trim")
        let config = TrimConfig(fileDurationS: try s.double("main_track_length_s"), defaultFadeOutMs: 0, defaultFadeInMs: 0)
        for (i, row) in try top.objects("rows").enumerated() {
            let offset = try row.double("offset_s"), at = try row.double("at")
            let what = "row \(i) offset \(offset) at \(at)"
            let start = try subject.startDeck(trim: trim, offsetS: offset, config: config, context: DeckStartContext())
            assertClose(start.baseS, try row.double("start_s"), in: fc, key: "start_s", "\(what) start_s")
            // `python_differs` rows say Python deviates from `ideal_fired`; the ideal is what is compared.
            let got = try fires(of: s, trim: trim, at: at, offsetS: offset)
            checkFire(got, ideal: try optionalBool(row, "ideal_fired"), idealT: try row.optionalDouble("ideal_t_s"), tolerance: tolerance, what)
        }
    }

    // MARK: voice level, second point, a new track over a voice

    func testVoiceLevelAndSecondPoint() throws {
        let fc = try fixtureCase("triggers", "voice_level_and_second_point")
        let s = try fc.scenario()
        let rows = try caseValues(fc).objects("rows")
        for row in rows {
            let pct = try row.double("top_track_pct")
            var sc = try scenario("voice_level_and_second_point", s)
            sc.topTrackPct = pct
            sc.runForS = 20
            let at = try row.double("at_s")
            let later = try row.object("at_12_5_s")
            let end = try row.object("at_20_s")
            let snaps = try subject.triggerSnapshots(sc, at: [at, 12.5, 20])
            XCTAssertEqual(snaps.count, 3, "pct \(pct): snapshots")
            guard snaps.count == 3 else { continue }
            let voice = try row.string("voice")
            let tops = snaps[0].decks.filter(\.top)
            XCTAssertEqual(tops.count, 1, "pct \(pct) at \(at): one voice on top")
            XCTAssertEqual(tops.first.map { Self.bare($0.name) }, voice, "pct \(pct): which voice")
            XCTAssertEqual(snaps[0].liveName.map(Self.bare) == voice, try row.bool("voice_is_live"), "pct \(pct): voice_is_live")
            if let v = tops.first {
                assertClose(v.vol, try row.double("voice_vol"), in: fc, "pct \(pct) voice_vol")
                XCTAssertEqual(v.fading, try row.bool("voice_fading"), "pct \(pct): voice_fading")
            }
            // `voice_gain`: the level-match gain of the voice deck, a factor besides `voice_vol` (the fixture says level match never applies to a trigger voice).
            if let v = tops.first { assertClose(v.levelGain, try row.double("voice_gain"), in: fc, "pct \(pct) voice_gain") }
            XCTAssertEqual(snaps[0].decks.filter { !$0.top }.count, try row.int("background_decks"), "pct \(pct): background_decks")
            XCTAssertEqual(snaps[1].decks.filter(\.top).count, try later.int("tops"), "pct \(pct) at 12.5: tops")
            XCTAssertEqual(snaps[1].decks.first { $0.top }.map { Self.bare($0.name) }, try later.string("voice"), "pct \(pct) at 12.5: voice")
            XCTAssertEqual(snaps[1].firesSoFar, try later.int("trigger_fires_so_far"), "pct \(pct) at 12.5: trigger_fires_so_far")
            // At 20 s the 8 s voice-over (from 10 s) is over: nothing on top, the track is live again, and the voice-over at 12 s (still playing when the
            // first one was, "a Play on Top already running skips the point") never fired.
            XCTAssertEqual(snaps[2].decks.filter(\.top).count, try end.int("tops"), "pct \(pct) at 20: tops")
            XCTAssertEqual(snaps[2].liveName.map(Self.bare), try end.string("live"), "pct \(pct) at 20: live")
            XCTAssertEqual(snaps[2].firesSoFar, try end.int("trigger_fires_so_far"), "pct \(pct) at 20: trigger_fires_so_far")
        }
    }

    func testNewTrackCutWhileVoiceOnTop() throws { try newTrack("new_track_cut_while_voice_on_top") }
    func testNewTrackCrossfadeWhileVoiceOnTop() throws { try newTrack("new_track_crossfade_while_voice_on_top") }

    private static func bare(_ name: String) -> String { name.hasSuffix(".wav") ? String(name.dropLast(4)) : name }

    /// The decks at the listed times. Compared: which decks play, which one is live, `top`, `vol` (with the fade curves of fades.json), `ending` and
    /// `ducked` (the background multiplier is below 0.99). NOT compared: `_info_python_*` (the Python gr and multiplier; the release of the dip after a
    /// crossfade is quirk 14 and not contract).
    private func newTrack(_ name: String) throws {
        let fc = try fixtureCase("triggers", name)
        let s = try fc.scenario()
        let names = try s.strings("playlist").map(Self.bare)
        guard names.count == 2 else { throw FixtureReadError(file: s.file, caseName: name, message: "scenario.playlist should hold two tracks") }
        let nt = try s.object("new_track")
        XCTAssertEqual(try nt.int("track"), 1, "\(name): the new track is track 1")
        let config = try s.object("config")
        let triggers: [TriggerCase.Point] = try s.decode("triggers")
        // The voice-over file holds one constant sample value ("vo.wav (8 s, constant 16384 = -6 dBFS RMS)"): the key of a constant is its absolute value.
        let voiceText = try s.string("voice_over")
        guard let match = voiceText.range(of: #"constant (-?\d+)"#, options: .regularExpression), let value = Int(voiceText[match].dropFirst("constant ".count)) else {
            throw FixtureReadError(file: s.file, caseName: name, message: "scenario.voice_over does not say which constant sample value the voice-over holds: \(voiceText)")
        }
        let voiceFiles = Set(triggers.map(\.file))
        var lengths = [String: Double]()
        for f in voiceFiles { lengths[f] = try s.number("library_s", named: f) }
        let scenario = TriggerScenario(
            triggers: triggers, trim: TrimFields(), fileDurationS: try s.number("library_s", named: try s.strings("playlist")[0]), voiceOverLengthsS: lengths,
            endAction: try s.named("end_action"), seeks: [], runForS: 0, mainName: names[0], topTrackPct: try config.double("top_track_pct"),
            armed: try config.bool("triggers_armed"), otherTrack: (names[1], try s.number("library_s", named: try s.strings("playlist")[1])),
            newTrack: (try nt.double("at_s"), try nt.int("crossfade_ms")),
            duck: (try config.decodeSelf(as: DuckSettings.self), value))

        let top = caseValues(fc)
        var expected = try top.objects("rows").map { ($0, $0) }
        expected.append((try top.object("at_12_5_s"), try top.object("at_12_5_s")))
        let times = try expected.map { try $0.0.double("t_s") }
        var sc = scenario
        sc.runForS = times.max() ?? 0
        let snaps = try subject.triggerSnapshots(sc, at: times)
        XCTAssertEqual(snaps.count, times.count, "\(name): snapshots")
        let voiceName = Self.bare(try XCTUnwrap(triggers.first?.file, "\(name): no trigger"))
        for (snap, (row, _)) in zip(snaps, expected) {
            let t = try row.double("t_s")
            // `voice`, `old_background` and `new_track` say for each of the three decks whether it is still there, its level, whether it is ducked and
            // whether it is fading out (`ending`): the samples that tell a cut from a crossfade, and a deck that is faded out from one that is gone.
            for (key, deckName) in [("voice", voiceName), ("old_background", names[0]), ("new_track", names[1])] {
                let want = try row.object(key)
                let got = snap.decks.first { Self.bare($0.name) == deckName }
                XCTAssertEqual(got != nil, try want.bool("present"), "\(name) t=\(t) \(key) present")
                guard let got, try want.bool("present") else { continue }
                assertClose(got.vol, try want.double("vol"), in: fc, "t=\(t) \(key) vol")
                XCTAssertEqual(got.ducked, try want.bool("ducked"), "\(name) t=\(t) \(key) ducked")
                XCTAssertEqual(got.ending, try want.bool("fading_out"), "\(name) t=\(t) \(key) fading_out")
            }
            XCTAssertEqual(snap.liveName.map(Self.bare), try row.string("live"), "\(name) t=\(t) live")
            let want = try row.objects("decks")
            XCTAssertEqual(snap.decks.map { Self.bare($0.name) }.sorted(), try want.map { try $0.string("name") }.sorted(), "\(name) t=\(t): which decks play")
            for d in want {
                let deckName = try d.string("name")
                guard let got = snap.decks.first(where: { Self.bare($0.name) == deckName }) else { continue }
                XCTAssertEqual(got.top, try d.bool("top"), "\(name) t=\(t) \(deckName) top")
                assertClose(got.vol, try d.double("vol"), in: fc, "t=\(t) \(deckName) vol")
                XCTAssertEqual(got.ending, try d.bool("ending"), "\(name) t=\(t) \(deckName) ending")
                XCTAssertEqual(got.ducked, try d.bool("ducked"), "\(name) t=\(t) \(deckName) ducked")
            }
        }
    }
}
