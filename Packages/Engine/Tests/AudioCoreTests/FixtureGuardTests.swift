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
                guard let schema = FixtureSchema.schema(file: file, caseName: c.name) else {
                    XCTFail("\(file).json: case '\(c.name)' is not in FixtureSchema")
                    continue
                }
                let keys = Set(c.value.keys.filter { !$0.hasPrefix("_info") })
                let allowed = schema.keys.union(["scenario", "tolerance"])
                XCTAssertEqual(keys.subtracting(allowed), [], "\(file).json case '\(c.name)': keys the harness does not know")
                XCTAssertEqual(schema.keys.subtracting(keys), [], "\(file).json case '\(c.name)': keys the harness expects are gone")

                let scenarioKeys = Set(try c.scenario().keys.filter { !$0.hasPrefix("_info") })
                let known = schema.scenario.union(schema.ignoredScenario)
                XCTAssertEqual(scenarioKeys.subtracting(known), [], "\(file).json case '\(c.name)': scenario keys the harness does not know")
                XCTAssertEqual(schema.scenario.subtracting(scenarioKeys), [], "\(file).json case '\(c.name)': scenario keys the harness reads are gone")
            }
        }
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

    func testAssertCloseUsesTheCaseTolerance() throws {
        let root = try JSONParser.parse(Data(#"{"tolerance": 1e-6, "cases": {"a": {"tolerance": 1e-3, "scenario": {}}}}"#.utf8))
        let c = try FixtureDocument(file: "demo", root: root).case("a")
        assertClose(1.0005, 1.0, in: c, "inside the case tolerance")
    }
}
