import AudioCore
import XCTest

/// The synced fixtures must be the ones of the spec version this code implements.
final class SpecVersionTests: FixtureTestCase {
    func testPinnedVersionFolderIsTheOnlyOneAndSaysTheSame() throws {
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(atPath: AudioSpec.fixturesRoot.path).filter { $0.hasPrefix("spec-") }
        XCTAssertEqual(folders, ["spec-\(AudioSpec.pinnedVersion)"],
                       "Fixtures/ must hold exactly the folder of the pinned version (remove stale ones, see docs/audio-conformance.md)")

        let versionFile = try String(contentsOf: AudioSpec.url("SPEC_VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Int(versionFile), AudioSpec.pinnedVersion, "SPEC_VERSION file")

        let firstLine = try String(contentsOf: AudioSpec.url("AUDIO-SPEC-LINE1.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(firstLine.hasPrefix("Spec version: \(AudioSpec.pinnedVersion)"), "first line of AUDIO-SPEC.md was: \(firstLine)")
    }

    func testEveryFixtureSaysThePinnedVersion() {
        for file in AudioSpec.fixtureFiles + ["renders/renders.json"] {
            let found = FixtureLoader.specVersion(ofFile: file)
            XCTAssertEqual(found, AudioSpec.pinnedVersion, "\(file): spec_version")
        }
    }

    func testLoaderRefusesAnotherVersion() {
        let other = AudioSpec.pinnedVersion + 1
        let json = #"{"spec_version": \#(other), "name": "x", "tolerance": 1, "cases": {}}"#
        XCTAssertThrowsError(try FixtureLoader.decode(Data(json.utf8), file: "x", as: EmptyCases.self)) { error in
            guard case FixtureError.versionMismatch(_, let found, let pinned) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(found, other)
            XCTAssertEqual(pinned, AudioSpec.pinnedVersion)
        }
    }

    private struct EmptyCases: Decodable {}
}
