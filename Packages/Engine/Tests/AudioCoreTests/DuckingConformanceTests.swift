import XCTest

/// ducking.json.
final class DuckingConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<DuckingCases> { try FixtureLoader.load("ducking") }

    /// Per 10 ms: 5 silent, 10 at (16384, 8192), 5 at (3277, 0), 5 silent, 3 at (1000, 16384). It is written in the `_info` text of
    /// duck_key (which a consumer ignores) and in generate.py, so it lives here.
    private static let stimulus: [(left: Int16, right: Int16)] =
        Array(repeating: (0, 0), count: 5) + Array(repeating: (16384, 8192), count: 10) + Array(repeating: (3277, 0), count: 5)
        + Array(repeating: (0, 0), count: 5) + Array(repeating: (1000, 16384), count: 3)

    private static var stimulusPCM: [Int16] {
        stimulus.flatMap { window in (0..<480).flatMap { _ in [window.left, window.right] } }
    }

    /// The exact key of the stimulus (constant windows: the RMS of a constant is its absolute value). The fixture's `key` is rounded to
    /// 6 decimals, which is too coarse to feed duck_curve (it would move the result by more than the tolerance), so curve rows start from this.
    private static var exactKey: [Double] {
        stimulus.map { max(abs(Double($0.left)), abs(Double($0.right))) / 32768 }
    }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "ducking", known: [
            "duck_key", "duck_curve", "duck_smooth", "background_gain", "input_target_db", "duck_loop",
        ])
        let f = try fixture()
        XCTAssertEqual(Set(f.cases.duckLoop.cases.values.keys), ["production_defaults_hold_on", "slow_attack_hold_off"], "duck_loop cases")
    }

    func testDuckKey() throws {
        let f = try fixture()
        let key = try subject.duckKey(pcm: Self.stimulusPCM)
        assertClose(key, f.cases.duckKey.key, tolerance: f.tolerance, "duck_key")
    }

    /// The Python player computes the key in float32 (`np.float32`, a sequential sum of 480 squares), so a key that is not a power-of-two
    /// fraction carries about 1e-6 of relative noise. In duck_curve that moves the reduction by up to ~1.2e-5 dB, more than the file's
    /// `tolerance` (2e-6), for the windows at (3277, 0). The windows at 16384 / 8192 are exact and match to the file's tolerance.
    /// This allowance is added to the file's tolerance for duck_curve rows ONLY. It belongs to the Python fixture, not to the contract:
    /// remove it when the Python side computes the key in float64 or the file's tolerance for ducking is widened (docs/audio-conformance.md).
    private static let pythonFloat32KeyNoiseDb = 2e-5

    func testDuckCurve() throws {
        let f = try fixture()
        let input = Self.exactKey
        for (i, row) in f.cases.duckCurve.rows.enumerated() {
            let what = "duck_curve row \(i) level=\(row.level) ratio=\(row.ratio) threshold=\(row.thresholdDb) hold=\(row.hold)"
            let got = try subject.duckCurve(key: input, level: row.level, ratio: row.ratio, thresholdDb: row.thresholdDb, hold: row.hold)
            assertClose(got, row.reductionDb, tolerance: f.tolerance + Self.pythonFloat32KeyNoiseDb, what)
        }
    }

    /// `gr` starts at 0 and takes one step per row with `dt` seconds.
    func testDuckSmooth() throws {
        let f = try fixture()
        for (i, row) in f.cases.duckSmooth.rows.enumerated() {
            let what = "duck_smooth row \(i) attack=\(row.attackMs) release=\(row.releaseMs)"
            let targets = row.targetDb.values
            XCTAssertEqual(targets.count, row.grDb.count, "\(what): target and gr lengths")
            var gr = 0.0
            var series = [Double]()
            for target in targets {
                gr = try subject.duckSmooth(gr: gr, target: target, dt: row.dtS, attackMs: row.attackMs, releaseMs: row.releaseMs)
                series.append(gr)
            }
            assertClose(series, row.grDb, tolerance: f.tolerance, what)
        }
    }

    func testBackgroundGain() throws {
        let f = try fixture()
        for row in f.cases.backgroundGain.rows {
            let m = try subject.backgroundMultiplier(reductionDb: row.grDb)
            assertClose(m, row.multiplier, tolerance: f.tolerance, "background_gain gr=\(row.grDb) dB")
        }
    }

    func testInputTargetDb() throws {
        let f = try fixture()
        for row in f.cases.inputTargetDb.rows {
            let got = try subject.inputTargetDb(rms: row.rms, gainDb: row.gainDb, ratio: row.ratio, thresholdDb: row.thresholdDb)
            assertClose(got, row.reductionDb, tolerance: f.tolerance, "input_target_db rms=\(row.rms) gain=\(row.gainDb) ratio=\(row.ratio) threshold=\(row.thresholdDb)")
        }
    }

    func testDuckLoopProductionDefaultsHoldOn() throws { try checkLoop("production_defaults_hold_on") }
    func testDuckLoopSlowAttackHoldOff() throws { try checkLoop("slow_attack_hold_off") }

    /// Rows are matched by INDEX, not by time: two rows share t = 0.5 (index 49 is the last background-only sample, index 50 the voice-over starting).
    /// `bg_multiplier` may trail 10^(-gr/20) by 0.0005 in the Python player (it only writes the multiplier when it moved by more than that).
    /// That write threshold is a quirk, not contract (AUDIO-SPEC quirk 9), so this column is compared within `tolerance + 0.0005`.
    private func checkLoop(_ name: String) throws {
        let f = try fixture()
        let c = try XCTUnwrap(f.cases.duckLoop.cases.values[name], "duck_loop has no case \(name)")
        let s = c.samples
        let n = s.tS.count
        XCTAssertEqual([s.topPosS.count, s.targetDb.count, s.grDb.count, s.bgMultiplier.count], Array(repeating: n, count: 4), "\(name): columns differ in length")
        XCTAssertEqual(s.tS[49], s.tS[50], "\(name): rows 49 and 50 are meant to share t")

        let request = DuckLoopRequest(settings: c.settings, voiceOver: c.voiceOver, stepS: c.stepS, lookAheadS: c.lookAheadS, sampleCount: n)
        let got = try subject.duckLoop(request)
        XCTAssertEqual(got.tS.count, n, "\(name): rows")
        guard [got.topPosS.count, got.targetDb.count, got.grDb.count, got.bgMultiplier.count] == Array(repeating: n, count: 4), got.tS.count == n else {
            return XCTFail("\(name): the series do not have \(n) rows")
        }
        let multiplierTolerance = f.tolerance + 0.0005
        for i in 0..<n {
            assertClose(got.tS[i], s.tS[i], tolerance: f.tolerance, "\(name) row \(i) t_s")
            assertClose(got.topPosS[i], s.topPosS[i], tolerance: f.tolerance, "\(name) row \(i) top_pos_s")
            assertClose(got.targetDb[i], s.targetDb[i], tolerance: f.tolerance, "\(name) row \(i) target_db")
            assertClose(got.grDb[i], s.grDb[i], tolerance: f.tolerance, "\(name) row \(i) gr_db")
            assertClose(got.bgMultiplier[i], s.bgMultiplier[i], tolerance: multiplierTolerance, "\(name) row \(i) bg_multiplier")
        }
        assertClose(got.grDb.max() ?? 0, c.peakReductionDb, tolerance: f.tolerance, "\(name) peak_reduction_db")
        assertClose(got.bgMultiplier.last ?? 0, c.finalMultiplier, tolerance: multiplierTolerance, "\(name) final_multiplier")
    }
}
