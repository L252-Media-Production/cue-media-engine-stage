import XCTest

/// resume_flow.json. The library, playlist, settings, age limit and the inputs of each row come from the cases' `scenario`.
final class ResumeFlowConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<ResumeCases> { try FixtureLoader.load("resume_flow") }

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "resume_flow")
    }

    private func environment(_ s: Scenario, trims: [String: TrimFields] = [:]) throws -> ResumeEnvironment {
        let settings = try s.object("config")
        let config = ResumeConfig(
            onStart: try settings.bool("resume_on_start"), maxAgeS: try settings.double("resume_max_age_s"),
            saveIntervalS: try settings.double("resume_save_s"))
        XCTAssertEqual(try s.double("age_limit_s"), config.maxAgeS, "\(s.caseName): age_limit_s and config.resume_max_age_s differ")
        let ids = try s.object("track_ids")
        XCTAssertEqual(try ids.keys.map { try ids.string($0) }, try s.strings("playlist"), "\(s.caseName): track_ids and playlist differ")
        return ResumeEnvironment(
            playlist: try s.strings("playlist"),
            fileLengthsS: Dictionary(uniqueKeysWithValues: try s.numbersByName("library_s").map { ($0.name, $0.value) }),
            config: config, trims: trims)
    }

    /// `then` is text in the scenario ("stop_all, save_resume", "fade_out(1000 ms), save_resume").
    private func then(_ input: Scenario) throws -> ResumeSituation.Then? {
        guard input.has("then") else { return nil }
        let text = try input.string("then")
        if text.hasPrefix("stop_all") { return .stopAll }
        if text.hasPrefix("fade_out("), let close = text.firstIndex(of: ")") {
            let digits = text[text.index(text.startIndex, offsetBy: "fade_out(".count)..<close].prefix { $0.isNumber }
            if let ms = Int(digits) { return .fadeOut(ms: ms) }
        }
        throw FixtureReadError(file: input.file, caseName: input.caseName, message: "\(input.path).then is \"\(text)\": add it to the harness")
    }

    func testRecord() throws {
        let c = try fixtureCase("resume_flow", "record")
        let s = try c.scenario()
        let env = try environment(s)
        for row in try fixture().cases.record.rows {
            let input = try s.row("row_inputs", label: row.label)
            let situation = ResumeSituation(
                playTrack: try input.int("play_track"), atS: try input.double("at_s"),
                paused: input.has("paused") ? try input.bool("paused") : false,
                clockAtSaveS: input.has("clock_at_save_s") ? try input.double("clock_at_save_s") : nil,
                then: try then(input))
            let got = try subject.resumeRecord(situation, environment: env)
            let what = "'\(row.label)'"
            switch (got, row.record) {
            case (nil, nil):
                break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "record \(what) pt")
                XCTAssertEqual(g.id, e.id, "record \(what) id")
                assertClose(g.pos, e.pos, in: c, "\(what) pos")
                XCTAssertEqual(g.paused, e.paused, "record \(what) paused")
            default:
                XCTFail("record \(what): got \(String(describing: got)), expected \(String(describing: row.record))")
            }
        }
    }

    func testTryResume() throws {
        let c = try fixtureCase("resume_flow", "try_resume")
        let env = try environment(try c.scenario())
        for row in try fixture().cases.tryResume.rows {
            let what = "'\(row.label)'"
            let out = try subject.tryResume(record: row.record, ageS: row.ageS, environment: env)
            XCTAssertEqual(out.recordKept, row.recordKept, "try_resume \(what) record_kept")

            switch (out.pending, row.pending) {
            case (nil, nil): break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "try_resume \(what) pending pt")
                assertClose(g.offsetS, e.offsetS, in: c, "\(what) pending offset_s")
                XCTAssertEqual(g.paused, e.paused, "try_resume \(what) pending paused")
                XCTAssertEqual(g.xfadeMs, e.xfadeMs, "try_resume \(what) pending xfade_ms")
            default:
                XCTFail("try_resume \(what): pending was \(String(describing: out.pending)), expected \(String(describing: row.pending))")
            }

            switch (out.started, row.started) {
            case (nil, nil): break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "try_resume \(what) started pt")
                assertClose(g.baseS, e.baseS, in: c, "\(what) started base_s")
                XCTAssertEqual(g.paused, e.paused, "try_resume \(what) started paused")
                assertClose(g.startVol, e.startVol, in: c, "\(what) started start_vol")
                XCTAssertEqual(g.fadeInMs, e.fadeInMs, "try_resume \(what) started fade_in_ms")
            default:
                XCTFail("try_resume \(what): started was \(String(describing: out.started)), expected \(String(describing: row.started))")
            }
        }
    }

    /// The trim of track 0 (`trim_of_track_0`), the record and its age are in the scenario.
    func testResumeInsideATrim() throws {
        let c = try fixtureCase("resume_flow", "resume_inside_a_trim")
        let s = try c.scenario()
        let ids = try s.object("track_ids")
        let trim: TrimFields = try s.decode("trim_of_track_0")
        let env = try environment(s, trims: [try ids.string("0"): trim])
        let record: ResumeRecord = try s.decode("record")
        let out = try subject.tryResume(record: record, ageS: try s.double("age_s"), environment: env)
        let e = try fixture().cases.resumeInsideATrim.started
        guard let g = out.started else { return XCTFail("resume_inside_a_trim: nothing started") }
        assertClose(g.baseS, e.baseS, in: c, "base_s")
        assertClose(g.loS, e.loS, in: c, "lo_s")
        assertClose(g.hiS, e.hiS, in: c, "hi_s")
        assertClose(g.startVol, e.startVol, in: c, "start_vol")
        XCTAssertEqual(g.fadeInMs, e.fadeInMs, "resume_inside_a_trim fade_in_ms")
        XCTAssertEqual(g.fresh, e.fresh, "resume_inside_a_trim fresh")
    }
}
