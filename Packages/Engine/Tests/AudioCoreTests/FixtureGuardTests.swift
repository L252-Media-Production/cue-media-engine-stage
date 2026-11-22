import XCTest

/// Guards that keep the harness and the fixtures from drifting apart: every case describes itself, nothing in a fixture goes unread without being
/// named in `FixtureSchema`, the source stamp matches, and the reading helpers fail loudly.
final class FixtureGuardTests: FixtureTestCase {
    func testEveryCaseHasAScenario() throws {
        for file in AudioSpec.fixtureFiles {
            for c in try FixtureDocument.load(file).allCases() {
                XCTAssertNotNil(c.value["scenario"], "\(file).json case '\(c.name)' has no `scenario`")
            }
        }
    }

    /// A key the harness neither reads nor ignores on purpose fails here, at the top of a file, on a case, or in a scenario.
    func testNoFixtureKeyIsUnknown() throws {
        for file in AudioSpec.fixtureFiles {
            let doc = try FixtureDocument.load(file)
            let top = Set(doc.root.keys.filter { !$0.hasPrefix("_info") })
            XCTAssertEqual(top.subtracting(FixtureSchema.topLevelKeys), [], "\(file).json: top-level keys the harness does not know")
            for c in try doc.allCases() {
                for problem in try FixtureSchema.problems(file: file, in: c) { XCTFail(problem) }
            }
        }
    }

    /// The guard also covers the trigger cases (they are read raw, case by case): a new key in a case or in its scenario, a case that is not listed, and a
    /// key that went missing all show up.
    func testTheGuardCatchesANewKeyInATriggerCase() throws {
        let real = try FixtureDocument.load("triggers").case("simple")
        XCTAssertEqual(try FixtureSchema.problems(file: "triggers", in: real), [], "the real case is covered")

        func variant(_ transform: (String) -> String, name: String = "simple") throws -> FixtureCase {
            let text = transform(String(decoding: real.value.serialized(), as: UTF8.self))
            let doc = FixtureDocument(file: "triggers", root: try JSONParser.parse(Data(#"{"tolerance": 2e-6, "cases": {"\#(name)": \#(text)}}"#.utf8)))
            return try doc.case(name)
        }
        let newCaseKey = try variant { $0.replacingOccurrences(of: "{", with: #"{"a_new_key": 1,"#, options: [], range: $0.startIndex..<$0.index(after: $0.startIndex)) }
        XCTAssertTrue(try FixtureSchema.problems(file: "triggers", in: newCaseKey).contains { $0.contains("a_new_key") }, "a new key in the case")
        let newScenarioKey = try variant { $0.replacingOccurrences(of: #""scenario":{"#, with: #""scenario":{"a_new_scenario_key":1,"#) }
        XCTAssertTrue(try FixtureSchema.problems(file: "triggers", in: newScenarioKey).contains { $0.contains("a_new_scenario_key") }, "a new key in the scenario")
        let unlisted = try variant({ $0 }, name: "a_new_trigger_case")
        XCTAssertTrue(try FixtureSchema.problems(file: "triggers", in: unlisted).contains { $0.contains("not in FixtureSchema") }, "a case that is not listed")
        let missing = try variant { $0.replacingOccurrences(of: #""ideal_fires""#, with: #""_info_ideal_fires""#) }
        XCTAssertTrue(try FixtureSchema.problems(file: "triggers", in: missing).contains { $0.contains("ideal_fires") }, "a key that went missing")
    }

    /// SOURCE.txt says which Python commit and spec version the fixtures were copied from.
    func testSourceStampIsPresentAndMatchesTheFixtures() throws {
        let url = AudioSpec.url("SOURCE.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("SOURCE.txt is missing from \(AudioSpec.directory.path): re-sync with scripts/sync-audio-spec.sh")
        }
        var fields = [String: String]()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        let commit = fields["python_commit"] ?? ""
        XCTAssertTrue(commit.count == 40 && commit.allSatisfy(\.isHexDigit), "SOURCE.txt python_commit is not a full commit hash: '\(commit)'")
        let stamped = Int(fields["spec_version"] ?? "")
        XCTAssertNotNil(stamped, "SOURCE.txt has no spec_version")
        for file in AudioSpec.fixtureFiles + ["renders/renders.json"] {
            XCTAssertEqual(stamped, FixtureLoader.specVersion(ofFile: file), "SOURCE.txt spec_version differs from the one in \(file)")
        }
        XCTAssertEqual(stamped, AudioSpec.pinnedVersion, "SOURCE.txt spec_version differs from the pinned version")
    }

    // MARK: the reading helpers

    private func scenario(_ json: String) throws -> Scenario {
        Scenario(file: "demo", caseName: "case_a", value: try JSONParser.parse(Data(json.utf8)))
    }

    func testMissingScenarioKeyNamesFileCaseAndKey() throws {
        let s = try scenario(#"{"a": 1}"#)
        XCTAssertThrowsError(try s.double("run_s")) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("demo.json") && text.contains("case_a") && text.contains("run_s"), text)
        }
        XCTAssertThrowsError(try s.string("a")) { XCTAssertTrue("\($0)".contains("scenario.a"), "\($0)") }
    }

    func testNullIsNotADefault() throws {
        let s = try scenario(#"{"seek": null, "n": 2}"#)
        XCTAssertThrowsError(try s.double("seek"))
        XCTAssertNil(try s.optionalObject("seek"))
        XCTAssertThrowsError(try s.optionalObject("absent"))
    }

    func testParserKeepsObjectOrder() throws {
        let v = try JSONParser.parse(Data(#"{"b": 1, "a": {"z": 1, "y": [1, "x\n"]}}"#.utf8))
        XCTAssertEqual(v.keys, ["b", "a"])
        XCTAssertEqual(v["a"]?.keys, ["z", "y"])
    }

    /// A tolerance on a case overrides the file's for that case and the cases nested in it; a nested one may override again.
    func testCaseToleranceOverridesTheFileAndInherits() throws {
        let root = try JSONParser.parse(Data(#"""
        {"spec_version": 1, "tolerance": 1e-6, "tolerance_lufs": 0.01, "cases": {
          "plain": {"scenario": {}},
          "loose": {"tolerance": 2e-5, "scenario": {}, "cases": {
            "inner": {"scenario": {}},
            "tighter": {"tolerance": 3e-7, "scenario": {}}}}}}
        """#.utf8))
        let doc = FixtureDocument(file: "demo", root: root)
        XCTAssertEqual(try doc.case("plain").tolerance, 1e-6)
        let loose = try doc.case("loose")
        XCTAssertEqual(loose.tolerance, 2e-5)
        XCTAssertEqual(try loose.nested("inner").tolerance, 2e-5)
        XCTAssertEqual(try loose.nested("tighter").tolerance, 3e-7)
        XCTAssertEqual(try loose.nested("inner").toleranceLufs(), 0.01)
    }

    /// `tolerance_by_key` beats the case tolerance for its keys only; other keys of the same case keep the case tolerance.
    func testToleranceByKeyBeatsTheCaseToleranceForItsKeysOnly() throws {
        let root = try JSONParser.parse(Data(#"""
        {"tolerance": 1e-6, "cases": {"a": {"tolerance": 1e-4, "tolerance_by_key": {"base_s": 2.5e-5}, "scenario": {}, "cases": {
          "inner": {"scenario": {}}}}, "plain": {"scenario": {}}}}
        """#.utf8))
        let doc = FixtureDocument(file: "demo", root: root)
        let a = try doc.case("a")
        XCTAssertEqual(a.tolerance(forKey: "base_s"), 2.5e-5, "the key's entry, not the case's 1e-4")
        XCTAssertEqual(a.tolerance(forKey: "hi_s"), 1e-4, "a key with no entry keeps the case tolerance")
        XCTAssertEqual(a.tolerance, 1e-4)
        XCTAssertEqual(try a.nested("inner").tolerance(forKey: "base_s"), 2.5e-5, "a nested case inherits it")
        XCTAssertEqual(try doc.case("plain").tolerance(forKey: "base_s"), 1e-6, "a case without the map uses the file tolerance")
        assertClose(1.00002, 1.0, in: a, key: "base_s", "inside 2.5e-5")
        assertClose(1.00002, 1.0, tolerance: a.tolerance(forKey: "hi_s"), "inside the case's 1e-4")
        XCTExpectFailure("outside the file tolerance for a key without an entry") {
            assertClose(1.00002, 1.0, tolerance: try! doc.case("plain").tolerance(forKey: "base_s"), "outside 1e-6")
        }
    }

    func testAssertCloseUsesTheCaseTolerance() throws {
        let root = try JSONParser.parse(Data(#"{"tolerance": 1e-6, "cases": {"a": {"tolerance": 1e-3, "scenario": {}}}}"#.utf8))
        let c = try FixtureDocument(file: "demo", root: root).case("a")
        assertClose(1.0005, 1.0, in: c, "inside the case tolerance")
    }
}
