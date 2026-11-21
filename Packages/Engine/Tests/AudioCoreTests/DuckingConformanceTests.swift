import XCTest

/// ducking.json.
final class DuckingConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<DuckingCases> { try FixtureLoader.load("ducking") }

    /// One run of 10 ms windows that each hold ONE constant sample value per channel (the `windows` of a scenario).
    private struct Window {
        let count: Int
        let left: Int16
        let right: Int16
    }

    /// The windows of a scenario, after checking that its window length is the spec's 10 ms.
    private func windows(_ s: Scenario) throws -> (list: [Window], frames: Int) {
        let frames = try s.int("window_samples")
        if s.has("window_s") {
            XCTAssertEqual(try s.double("window_s"), Double(frames) / Double(AudioSpec.sampleRate), "\(s.caseName): window_s and window_samples disagree")
            XCTAssertEqual(try s.double("window_s"), AudioSpec.controlStepS, "\(s.caseName): the window is not the spec's 10 ms control step")
        }
        let list = try s.objects("windows").map { w -> Window in
            guard let l = Int16(exactly: try w.int("left")), let r = Int16(exactly: try w.int("right")) else {
                throw FixtureReadError(file: s.file, caseName: s.caseName, message: "\(w.path): a sample value does not fit 16 bits (the spec leaves clipping unspecified)")
            }
            return Window(count: try w.int("windows"), left: l, right: r)
        }
        return (list, frames)
    }

    private func pcm(_ s: Scenario) throws -> [Int16] {
        let (list, frames) = try windows(s)
        return list.flatMap { w in (0..<(w.count * frames)).flatMap { _ in [w.left, w.right] } }
    }

    /// The exact key of the windows (the RMS of a constant is its absolute value, the louder channel counts). The fixture's `key` is rounded to
    /// 6 decimals, which is too coarse to feed duck_curve, so curve cases start from this.
    private func exactKey(_ s: Scenario) throws -> [Double] {
        try windows(s).list.flatMap { w in
            Array(repeating: max(abs(Double(w.left)), abs(Double(w.right))) / 32768, count: w.count)
        }
    }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "ducking")
        let nested = try fixtureCase("ducking", "duck_loop").nestedCases().map { $0.name.replacingOccurrences(of: "duck_loop/", with: "") }
        XCTAssertEqual(Set(nested), Set(FixtureSchema.duckLoopCases.keys), "duck_loop cases")
    }

    func testDuckKey() throws {
        let c = try fixtureCase("ducking", "duck_key")
        let key = try subject.duckKey(pcm: try pcm(c.scenario()))
        assertClose(key, try fixture().cases.duckKey.key, in: c, "key")
    }

    func testDuckCurve() throws {
        let c = try fixtureCase("ducking", "duck_curve")
        let input = try exactKey(c.scenario())
        for (i, row) in try fixture().cases.duckCurve.rows.enumerated() {
            let what = "row \(i) level=\(row.level) ratio=\(row.ratio) threshold=\(row.thresholdDb) hold=\(row.hold)"
            let got = try subject.duckCurve(key: input, level: row.level, ratio: row.ratio, thresholdDb: row.thresholdDb, hold: row.hold)
            assertClose(got, row.reductionDb, in: c, what)
        }
    }

    /// The ramp has targets from 0 to about 25 dB, so the hold depth tells the 60th, 75th and 90th percentile apart (`_info_alternatives`).
    func testDuckCurveHoldPercentile() throws {
        let c = try fixtureCase("ducking", "duck_curve_hold_percentile")
        let s = try c.scenario()
        let key = try exactKey(s)
        let level = try s.double("level"), ratio = try s.double("ratio"), threshold = try s.double("threshold_db")
        let expected = try fixture().cases.duckCurveHoldPercentile
        let depth = try subject.duckHoldDepthDb(key: key, level: level, ratio: ratio, thresholdDb: threshold)
        assertClose(depth, expected.holdDepthDb, in: c, "hold_depth_db")
        let off = try subject.duckCurve(key: key, level: level, ratio: ratio, thresholdDb: threshold, hold: false)
        assertClose(off, expected.reductionDbHoldOff, in: c, "reduction_db_hold_off")
        let on = try subject.duckCurve(key: key, level: level, ratio: ratio, thresholdDb: threshold, hold: true)
        assertClose(on, expected.reductionDbHoldOn, in: c, "reduction_db_hold_on")
    }

    /// `gr` starts at the scenario's `initial_gr_db` and takes one step per row with `dt_s` seconds.
    func testDuckSmooth() throws {
        let c = try fixtureCase("ducking", "duck_smooth")
        let s = try c.scenario()
        let dt = try s.double("dt_s")
        let initial = try s.double("initial_gr_db")
        for (i, row) in try fixture().cases.duckSmooth.rows.enumerated() {
            let what = "row \(i) attack=\(row.attackMs) release=\(row.releaseMs)"
            let targets = row.targetDb.values
            XCTAssertEqual(targets.count, row.grDb.count, "\(what): target and gr lengths")
            XCTAssertEqual(row.dtS, dt, "\(what): dt_s of the row and of the scenario differ")
            var gr = initial
            var series = [Double]()
            for target in targets {
                gr = try subject.duckSmooth(gr: gr, target: target, dt: dt, attackMs: row.attackMs, releaseMs: row.releaseMs)
                series.append(gr)
            }
            assertClose(series, row.grDb, in: c, what)
        }
    }
    func testBackgroundGain() throws {
        let c = try fixtureCase("ducking", "background_gain")
        for row in try fixture().cases.backgroundGain.rows {
            let m = try subject.backgroundMultiplier(reductionDb: row.grDb)
            assertClose(m, row.multiplier, in: c, "gr=\(row.grDb) dB")
        }
    }

    func testInputTargetDb() throws {
        let c = try fixtureCase("ducking", "input_target_db")
        for row in try fixture().cases.inputTargetDb.rows {
            let got = try subject.inputTargetDb(rms: row.rms, gainDb: row.gainDb, ratio: row.ratio, thresholdDb: row.thresholdDb)
            assertClose(got, row.reductionDb, in: c, "rms=\(row.rms) gain=\(row.gainDb) ratio=\(row.ratio) threshold=\(row.thresholdDb)")
        }
    }

    func testDuckLoopProductionDefaultsHoldOn() throws { try checkLoop("production_defaults_hold_on") }
    func testDuckLoopSlowAttackHoldOff() throws { try checkLoop("slow_attack_hold_off") }

    /// Rows are matched by INDEX, not by time: two rows share t = 0.5 (the last background-only sample and the voice-over starting).
    /// Every column, `bg_multiplier` included, is compared within the tolerance of the case.
    private func checkLoop(_ name: String) throws {
        let parent = try fixtureCase("ducking", "duck_loop")
        let fc = try parent.nested(name)
        let ps = try parent.scenario()
        let f = try fixture()
        let c = try XCTUnwrap(f.cases.duckLoop.cases.values[name], "duck_loop has no case \(name)")
        let s = c.samples
        let n = s.tS.count
        XCTAssertEqual([s.topPosS.count, s.targetDb.count, s.grDb.count, s.bgMultiplier.count], Array(repeating: n, count: 4), "\(name): columns differ in length")

        let step = try ps.double("step_s")
        let aloneS = try ps.double("background_alone_s")
        XCTAssertEqual(c.stepS, step, "\(name): step_s of the case and of the scenario differ")
        XCTAssertEqual(c.voiceOver.startsAtS, aloneS, "\(name): the voice-over does not start after background_alone_s")
        let background = try ps.object("background")
        XCTAssertEqual(c.voiceOver.file, try ps.object("voice_over").string("file"), "\(name): voice-over file")
        let lastBackgroundOnly = Int((aloneS / step).rounded()) - 1
        XCTAssertTrue(s.tS.indices.contains(lastBackgroundOnly + 1), "\(name): too few rows")
        XCTAssertEqual(s.tS[lastBackgroundOnly], s.tS[lastBackgroundOnly + 1], "\(name): rows \(lastBackgroundOnly) and \(lastBackgroundOnly + 1) are meant to share t")

        let request = DuckLoopRequest(
            settings: c.settings, voiceOver: c.voiceOver, stepS: step, lookAheadS: c.lookAheadS,
            backgroundLengthS: try background.double("length_s"), backgroundAloneS: aloneS,
            tickEverySteps: try ps.int("tick_every_steps"), maxSteps: try ps.int("max_steps"), sampleCount: n)
        let got = try subject.duckLoop(request)
        XCTAssertEqual(got.tS.count, n, "\(name): rows")
        guard [got.topPosS.count, got.targetDb.count, got.grDb.count, got.bgMultiplier.count] == Array(repeating: n, count: 4), got.tS.count == n else {
            return XCTFail("\(name): the series do not have \(n) rows")
        }
        for i in 0..<n {
            assertClose(got.tS[i], s.tS[i], in: fc, "row \(i) t_s")
            assertClose(got.topPosS[i], s.topPosS[i], in: fc, "row \(i) top_pos_s")
            assertClose(got.targetDb[i], s.targetDb[i], in: fc, "row \(i) target_db")
            assertClose(got.grDb[i], s.grDb[i], in: fc, "row \(i) gr_db")
            assertClose(got.bgMultiplier[i], s.bgMultiplier[i], in: fc, "row \(i) bg_multiplier")
        }
        assertClose(got.grDb.max() ?? 0, c.peakReductionDb, in: fc, "peak_reduction_db")
        assertClose(got.bgMultiplier.last ?? 0, c.finalMultiplier, in: fc, "final_multiplier")
    }
}
