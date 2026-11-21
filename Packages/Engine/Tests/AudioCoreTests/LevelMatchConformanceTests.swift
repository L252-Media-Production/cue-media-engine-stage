import Foundation
import XCTest

/// levelmatch.json. LUFS values are compared within the file's `tolerance_lufs`, gains within `tolerance`.
final class LevelMatchConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<LevelMatchCases> { try FixtureLoader.load("levelmatch") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "levelmatch", known: ["lufs_from_pcm", "norm_gain", "applied_to_deck"])
    }

    /// The signal of each row is only a text label in the JSON, so the harness builds it (the same way generate.py does: a rounded
    /// sine of `32768 * 10^(dB/20)`, 48 kHz, stereo, 16 bit).
    private enum Signal {
        case sine(hz: Double, dbPeak: Double, seconds: Double, rightSilent: Bool = false)
        case silence(seconds: Double)

        var pcm: [Int16] {
            switch self {
            case .silence(let seconds):
                return [Int16](repeating: 0, count: Int(48_000 * seconds) * 2)
            case .sine(let hz, let dbPeak, let seconds, let rightSilent):
                let amplitude = 32768 * pow(10, dbPeak / 20)
                var out = [Int16]()
                out.reserveCapacity(Int(48_000 * seconds) * 2)
                for n in 0..<Int(48_000 * seconds) {
                    let v = Int16((amplitude * sin(2 * .pi * hz * Double(n) / 48_000)).rounded())
                    out.append(v)
                    out.append(rightSilent ? 0 : v)
                }
                return out
            }
        }
    }

    private static let signals: [String: Signal] = [
        "1 kHz sine, -20 dBFS peak, 5 s, stereo": .sine(hz: 1000, dbPeak: -20, seconds: 5),
        "1 kHz sine, -6 dBFS peak, 5 s": .sine(hz: 1000, dbPeak: -6, seconds: 5),
        "1 kHz sine, -30 dBFS peak, 5 s": .sine(hz: 1000, dbPeak: -30, seconds: 5),
        "100 Hz sine, -20 dBFS peak, 5 s": .sine(hz: 100, dbPeak: -20, seconds: 5),
        "10 kHz sine, -20 dBFS peak, 5 s": .sine(hz: 10_000, dbPeak: -20, seconds: 5),
        "1 kHz sine, -20 dBFS, left channel only": .sine(hz: 1000, dbPeak: -20, seconds: 5, rightSilent: true),
        "silence 5 s": .silence(seconds: 5),
        "too short (0.3 s)": .sine(hz: 1000, dbPeak: -20, seconds: 0.3),
        "1 kHz sine, -20 dBFS, 12 s": .sine(hz: 1000, dbPeak: -20, seconds: 12),
    ]

    func testLufsFromPcm() throws {
        let f = try fixture()
        let tolerance = try XCTUnwrap(f.toleranceLufs, "levelmatch.json has no tolerance_lufs")
        for row in f.cases.lufsFromPcm.rows {
            guard let signal = Self.signals[row.signal] else {
                XCTFail("lufs_from_pcm: unknown signal '\(row.signal)': add it to the harness")
                continue
            }
            let measured = try subject.measureLufs(pcm: signal.pcm)
            assertClose(measured, row.lufs, tolerance: tolerance, "lufs_from_pcm '\(row.signal)'")
        }
    }

    /// Tracks a, b, c are `measured_lufs[0...2]`; a track mode reference is named by its file ("a.wav" = index 0, "b.wav" = index 1).
    /// The fixture stores the target that resulted (for "-60 (clamped)" the typed value was -80: the clamp itself is not visible here).
    func testNormGain() throws {
        let f = try fixture()
        let references = ["a.wav": 0, "b.wav": 1]
        for row in f.cases.normGain.rows {
            let what = "norm_gain '\(row.setting)'"
            guard let mode = LevelMatchMode(rawValue: row.stored.mode) else {
                XCTFail("\(what): unknown mode \(row.stored.mode)")
                continue
            }
            var target: Double?
            switch mode {
            case .off: target = nil
            case .lufs: target = row.stored.lufs
            case .track:
                guard let ref = row.stored.ref, let index = references[ref] else {
                    XCTFail("\(what): unknown reference \(String(describing: row.stored.ref))")
                    continue
                }
                target = row.measuredLufs[index]
            }
            for (i, measured) in row.measuredLufs.enumerated() {
                let r = try subject.levelMatchGain(mode: mode, targetLufs: target, measuredLufs: measured)
                assertClose(r.gainDb, row.gainDb[i], tolerance: f.tolerance, "\(what) track \(i) gain_db")
                assertClose(r.linear, row.gainLinear[i], tolerance: f.tolerance, "\(what) track \(i) gain_linear")
            }
        }
    }

    /// Row 0: a.wav (-14 LUFS) on a lufs target of -23; row 1: the same deck after switching level match off.
    func testAppliedToDeck() throws {
        let f = try fixture()
        let rows = f.cases.appliedToDeck.rows
        let setups: [String: (mode: LevelMatchMode, target: Double?)] = [
            "a.wav (-14 LUFS), target -23": (.lufs, -23),
            "after switching level match off": (.off, nil),
        ]
        for row in rows {
            guard let setup = setups[row.track] else {
                XCTFail("applied_to_deck: unknown row '\(row.track)': add it to the harness")
                continue
            }
            let gain = try subject.liveDeckGain(mode: setup.mode, targetLufs: setup.target, trackLufs: -14)
            assertClose(gain, row.deckGain, tolerance: f.tolerance, "applied_to_deck '\(row.track)' deck_gain")
            if let db = row.deckGainDb {
                assertClose(20 * log10(gain), db, tolerance: f.tolerance, "applied_to_deck '\(row.track)' deck_gain_db")
            }
        }
    }
}
