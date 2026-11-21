import XCTest

/// resume_flow.json. Library of the scenario (generate.py): playlist 0 = [a.wav, b.wav], both 60 s; `resume_max_age_s` 1800.
final class ResumeFlowConformanceTests: FixtureTestCase {
    private func fixture() throws -> Fixture<ResumeCases> { try FixtureLoader.load("resume_flow") }

    private let environment = ResumeEnvironment(playlists: [["a.wav", "b.wav"]], fileDurationS: 60, maxAgeS: 1800, trims: [:])

    func testAllCasesHaveATest() throws {
        try assertCoversAllCases(of: "resume_flow", known: ["record", "try_resume", "resume_inside_a_trim"])
    }

    /// The scenarios are named by the row labels only.
    func testRecord() throws {
        let f = try fixture()
        let scenarios: [String: ResumeRecordScenario] = [
            "playing, 12.5 s in": .playing(trackPT: [0, 1], id: "b.wav", atS: 12.5),
            // paused at 7.25 s, then the clock runs on to 20 s: the position does not move
            "paused at 7.25 s": .paused(trackPT: [0, 1], id: "b.wav", atS: 7.25, waitedS: 12.75),
            "after a deliberate stop": .afterDeliberateStop,
            "while fading out": .whileFadingOut,
        ]
        for row in f.cases.record.rows {
            guard let scenario = scenarios[row.label] else {
                XCTFail("record: unknown row '\(row.label)': add it to the harness")
                continue
            }
            let got = try subject.resumeRecord(scenario)
            let what = "record '\(row.label)'"
            switch (got, row.record) {
            case (nil, nil):
                break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "\(what) pt")
                XCTAssertEqual(g.id, e.id, "\(what) id")
                assertClose(g.pos, e.pos, tolerance: f.tolerance, "\(what) pos")
                XCTAssertEqual(g.paused, e.paused, "\(what) paused")
            default:
                XCTFail("\(what): got \(String(describing: got)), expected \(String(describing: row.record))")
            }
        }
    }

    func testTryResume() throws {
        let f = try fixture()
        for row in f.cases.tryResume.rows {
            let what = "try_resume '\(row.label)'"
            let out = try subject.tryResume(record: row.record, ageS: row.ageS, environment: environment)
            XCTAssertEqual(out.recordKept, row.recordKept, "\(what) record_kept")

            switch (out.pending, row.pending) {
            case (nil, nil): break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "\(what) pending pt")
                assertClose(g.offsetS, e.offsetS, tolerance: f.tolerance, "\(what) pending offset_s")
                XCTAssertEqual(g.paused, e.paused, "\(what) pending paused")
                XCTAssertEqual(g.xfadeMs, e.xfadeMs, "\(what) pending xfade_ms")
            default:
                XCTFail("\(what): pending was \(String(describing: out.pending)), expected \(String(describing: row.pending))")
            }

            switch (out.started, row.started) {
            case (nil, nil): break
            case let (g?, e?):
                XCTAssertEqual(g.pt, e.pt, "\(what) started pt")
                assertClose(g.baseS, e.baseS, tolerance: f.tolerance, "\(what) started base_s")
                XCTAssertEqual(g.paused, e.paused, "\(what) started paused")
                assertClose(g.startVol, e.startVol, tolerance: f.tolerance, "\(what) started start_vol")
                XCTAssertEqual(g.fadeInMs, e.fadeInMs, "\(what) started fade_in_ms")
            default:
                XCTFail("\(what): started was \(String(describing: out.started)), expected \(String(describing: row.started))")
            }
        }
    }

    /// Trim A = 2 s, B = 40 s with a 1.5 s fade-in; the record is a.wav at 20 s, 5 s old (generate.py).
    func testResumeInsideATrim() throws {
        let f = try fixture()
        var env = environment
        env.trims = ["a.wav": TrimFields(inPoint: 2, outPoint: 40, fadeInMs: 1500, start: "fade")]
        let record = ResumeRecord(pt: [0, 0], id: "a.wav", pos: 20, paused: false)
        let out = try subject.tryResume(record: record, ageS: 5, environment: env)
        let e = f.cases.resumeInsideATrim.started
        guard let g = out.started else { return XCTFail("resume_inside_a_trim: nothing started") }
        assertClose(g.baseS, e.baseS, tolerance: f.tolerance, "resume_inside_a_trim base_s")
        assertClose(g.loS, e.loS, tolerance: f.tolerance, "resume_inside_a_trim lo_s")
        assertClose(g.hiS, e.hiS, tolerance: f.tolerance, "resume_inside_a_trim hi_s")
        assertClose(g.startVol, e.startVol, tolerance: f.tolerance, "resume_inside_a_trim start_vol")
        XCTAssertEqual(g.fadeInMs, e.fadeInMs, "resume_inside_a_trim fade_in_ms")
        XCTAssertEqual(g.fresh, e.fresh, "resume_inside_a_trim fresh")
    }
}
