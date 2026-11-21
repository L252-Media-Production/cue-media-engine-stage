import Foundation
import XCTest

/// levelmatch.json. LUFS values are compared within `tolerance_lufs`, gains within `tolerance` (the case's own, else the file's).
/// Signals, playlists, loudness values and the settings of each row come from the cases' `scenario`.
final class LevelMatchConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<LevelMatchCases> { try FixtureLoader.load("levelmatch") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "levelmatch")
    }

    /// Builds a signal as the scenario's `synthesis` says: `round(32768 * 10^(peak_dbfs/20) * sin(2*pi*frequency_hz*n/48000))`, the second
    /// channel the same or silent; silence is all zero. 48 kHz, stereo, 16 bit are the spec's format.
    private func pcm(_ s: Scenario) throws -> [Int16] {
        XCTAssertEqual(try s.int("channels"), AudioSpec.channels, "\(s.path): the harness builds stereo")
        let frames = Int((try s.double("duration_s") * Double(AudioSpec.sampleRate)).rounded())
        let kind = try s.string("kind")
        var out = [Int16]()
        out.reserveCapacity(frames * AudioSpec.channels)
        switch kind {
        case "silence":
            return [Int16](repeating: 0, count: frames * AudioSpec.channels)
        case "sine":
            let amplitude = 32768 * pow(10, try s.double("peak_dbfs") / 20)
            let hz = try s.double("frequency_hz")
            let second = try s.string("second_channel")
            guard second == "silent" || second == "same as the first" else {
                throw FixtureReadError(file: s.file, caseName: s.caseName, message: "\(s.path).second_channel is \"\(second)\": add it to the harness")
            }
            for n in 0..<frames {
                let raw = (amplitude * sin(2 * .pi * hz * Double(n) / Double(AudioSpec.sampleRate))).rounded()
                guard let v = Int16(exactly: raw) else {
                    throw FixtureReadError(file: s.file, caseName: s.caseName, message: "\(s.path) does not fit 16 bits (the spec leaves clipping unspecified)")
                }
                out.append(v)
                out.append(second == "silent" ? 0 : v)
            }
            return out
        default:
            throw FixtureReadError(file: s.file, caseName: s.caseName, message: "\(s.path).kind is \"\(kind)\": add it to the harness")
        }
    }

    func testLufsFromPcm() throws {
        let c = try fixtureCase("levelmatch", "lufs_from_pcm")
        let tolerance = try c.toleranceLufs()
        let signals = try c.scenario().objects("signals")
        let rows = try fixture().cases.lufsFromPcm.rows
        XCTAssertEqual(rows.map(\.signal), try signals.map { try $0.string("signal") }, "lufs_from_pcm: rows and scenario signals differ")
        for (signal, row) in zip(signals, rows) {
            let measured = try subject.measureLufs(pcm: try pcm(signal))
            assertClose(measured, row.lufs, tolerance: tolerance, "lufs_from_pcm '\(row.signal)'")
        }
    }

    /// Tracks are the scenario's playlist; their loudness is `measured_lufs` (null = no measurement). A row is typed (`typed`), kept (`stored`),
    /// and then read for every track. `stored.lufs` of the off and track modes is an unused default and is not compared.
    func testNormGain() throws {
        let c = try fixtureCase("levelmatch", "norm_gain")
        let s = try c.scenario()
        let playlist = try s.strings("playlist")
        let measured = try s.optionalNumbersByName("measured_lufs")
        XCTAssertEqual(measured.map(\.name), playlist, "norm_gain: measured_lufs is not in playlist order")
        let clampSettings = try s.object("lufs_clamp_db")
        let clamp = LufsClamp(min: try clampSettings.double("min"), max: try clampSettings.double("max"), step: try clampSettings.double("step"))

        for row in try fixture().cases.normGain.rows {
            let what = "norm_gain '\(row.setting)'"
            XCTAssertEqual(row.measuredLufs, measured.map(\.value), "\(what): measured_lufs of the row and of the scenario differ")

            let stored = try subject.storeLevelMatch(typed: row.typed, playlist: playlist, clamp: clamp)
            XCTAssertEqual(stored.mode, row.stored.mode, "\(what) stored mode (typed \(row.typed))")
            XCTAssertEqual(stored.ref, row.stored.ref, "\(what) stored ref (typed \(row.typed))")
            if row.stored.mode == .lufs {
                assertClose(stored.lufs, row.stored.lufs, in: c, "\(what) stored lufs (typed \(String(describing: row.typed.lufs)))")
            }

            var target: Double?
            switch row.stored.mode {
            case .off: target = nil
            case .lufs: target = row.stored.lufs
            case .track:
                guard let ref = row.stored.ref else { return XCTFail("\(what): track mode without a reference") }
                target = try s.number("measured_lufs", named: ref)
            }
            for (i, value) in row.measuredLufs.enumerated() {
                let r = try subject.levelMatchGain(mode: row.stored.mode, targetLufs: target, measuredLufs: value)
                assertClose(r.gainDb, row.gainDb[i], in: c, "\(what) track \(i) gain_db")
                assertClose(r.linear, row.gainLinear[i], in: c, "\(what) track \(i) gain_linear")
            }
        }
    }

    /// `row_inputs` says what is set for each row; `playing` names the file on the deck.
    func testAppliedToDeck() throws {
        let c = try fixtureCase("levelmatch", "applied_to_deck")
        let s = try c.scenario()
        let playing = try s.string("playing")
        guard let file = playing.split(separator: " ").first.map(String.init), try s.object("measured_lufs").has(file) else {
            throw FixtureReadError(file: s.file, caseName: s.caseName, message: "scenario.playing \"\(playing)\" does not start with a file of measured_lufs")
        }
        let trackLufs = try s.optionalDouble(path: "measured_lufs", file)
        for row in try fixture().cases.appliedToDeck.rows {
            let setNorm = try s.row("row_inputs", label: row.track).object("set_norm")
            let mode: LevelMatchMode = try setNorm.named("mode")
            let target = setNorm.has("lufs") ? try setNorm.double("lufs") : nil
            let gain = try subject.liveDeckGain(mode: mode, targetLufs: target, trackLufs: trackLufs)
            assertClose(gain, row.deckGain, in: c, "'\(row.track)' deck_gain")
            if let db = row.deckGainDb {
                assertClose(20 * log10(gain), db, in: c, "'\(row.track)' deck_gain_db")
            }
        }
    }
}

private extension Scenario {
    /// A loudness by file name from the object under `path` (null = none).
    func optionalDouble(path: String, _ name: String) throws -> Double? {
        try object(path).optionalDouble(name)
    }
}
