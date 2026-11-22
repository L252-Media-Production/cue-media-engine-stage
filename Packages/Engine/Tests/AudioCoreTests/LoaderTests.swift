import XCTest

/// Every fixture file decodes into its models, `_info*` keys are ignored, and tolerances come from the files.
final class LoaderTests: FixtureTestCase {
    func testEveryFixtureFileDecodes() throws {
        _ = try FixtureLoader.load("fades", as: FadesCases.self)
        _ = try FixtureLoader.load("xfade", as: XfadeCases.self)
        _ = try FixtureLoader.load("trim", as: TrimCases.self)
        _ = try FixtureLoader.load("end_actions", as: EndActionsCases.self)
        _ = try FixtureLoader.load("play_modes", as: PlayModesCases.self)
        _ = try FixtureDocument.load("triggers")   // the cases have different shapes (lists of fires, rows, deck snapshots): read raw, case by case
        _ = try FixtureLoader.load("ducking", as: DuckingCases.self)
        _ = try FixtureLoader.load("levelmatch", as: LevelMatchCases.self)
        _ = try FixtureLoader.load("resume_flow", as: ResumeCases.self)
    }

    func testTolerancesAreReadFromTheFiles() throws {
        for file in AudioSpec.fixtureFiles {
            let data = try Data(contentsOf: AudioSpec.fixtureURL(file))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let tolerance = try XCTUnwrap(object["tolerance"] as? Double, "\(file): tolerance")
            XCTAssertGreaterThan(tolerance, 0, file)
        }
        XCTAssertGreaterThan(try FixtureDocument.load("levelmatch").topNumber("tolerance_lufs"), 0, "levelmatch.json has tolerance_lufs")
    }

    func testInfoKeysAreIgnored() throws {
        let json = #"{"_info": "text", "_info_sequence": [1, 2], "a": {"v": 1}, "b": {"v": 2}}"#
        struct V: Decodable { let v: Int }
        let dict = try JSONDecoder().decode(InfoFilteredDictionary<V>.self, from: Data(json.utf8))
        XCTAssertEqual(Set(dict.values.keys), ["a", "b"])
    }

    func testTriggerCaseNamesDoNotIncludeInfoKeys() throws {
        let names = Set(try FixtureDocument.load("triggers").caseNames)
        XCTAssertFalse(names.contains { $0.hasPrefix("_info") })
        XCTAssertEqual(names.count, 23)   // 11 cases of the first sync, the 11 trigger boundary cases of Python 1241963 and target_never_ready_does_not_block_next_point (ba6c883)
    }
}
