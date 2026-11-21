import XCTest

/// Base class of the conformance tests: comparison helpers and the check that every case of a fixture file has a test.
class FixtureTestCase: XCTestCase {
    /// The engine under test (see `AudioSpecSubjects.current`).
    var subject: AudioSpecSubject { AudioSpecSubjects.current }

    /// `actual` equals `expected` within `tolerance` (absolute). `what` names the row so a failure says which one.
    func assertClose(
        _ actual: Double, _ expected: Double, tolerance: Double, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, accuracy: tolerance, what(), file: file, line: line)
    }

    /// Both nil, or both numbers within `tolerance`.
    func assertClose(
        _ actual: Double?, _ expected: Double?, tolerance: Double, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (a?, e?):
            XCTAssertEqual(a, e, accuracy: tolerance, what(), file: file, line: line)
        default:
            XCTFail("\(what()): got \(String(describing: actual)), expected \(String(describing: expected))", file: file, line: line)
        }
    }

    /// Element-wise `assertClose` of two lists of the same length.
    func assertClose(
        _ actual: [Double], _ expected: [Double], tolerance: Double, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard actual.count == expected.count else {
            XCTFail("\(what()): got \(actual.count) values, expected \(expected.count)", file: file, line: line)
            return
        }
        for (i, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: tolerance, "\(what()) [index \(i)]", file: file, line: line)
        }
    }

    /// Fails when the fixture file has a case this harness has no entry for (a sync brought something new),
    /// or when a case the harness expects is gone. The names come from `FixtureSchema`.
    func assertCoversAllCases(of file: String, line: UInt = #line) throws {
        let found = Set(try FixtureDocument.load(file).caseNames)
        let known = FixtureSchema.caseNames(file)
        XCTAssertEqual(found.subtracting(known), [], "\(file).json has cases with no test: add them to FixtureSchema and the harness", line: line)
        XCTAssertEqual(known.subtracting(found), [], "\(file).json lost cases the harness tests", line: line)
    }

    /// A case of a fixture file: raw JSON, the scenario it was generated from and the tolerance that applies to it.
    func fixtureCase(_ file: String, _ name: String) throws -> FixtureCase {
        try FixtureDocument.load(file).case(name)
    }

    /// `actual` equals `expected` within the tolerance of the case (the case's own `tolerance`, else the file's).
    func assertClose(
        _ actual: Double, _ expected: Double, in c: FixtureCase, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertClose(actual, expected, tolerance: c.tolerance, "\(c.name): \(what())", file: file, line: line)
    }

    func assertClose(
        _ actual: Double?, _ expected: Double?, in c: FixtureCase, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertClose(actual, expected, tolerance: c.tolerance, "\(c.name): \(what())", file: file, line: line)
    }

    func assertClose(
        _ actual: [Double], _ expected: [Double], in c: FixtureCase, _ what: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertClose(actual, expected, tolerance: c.tolerance, "\(c.name): \(what())", file: file, line: line)
    }
}
