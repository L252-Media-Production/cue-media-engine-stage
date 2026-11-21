import XCTest

/// renders.json is loaded and its version checked. The WAVs are not compared yet: that needs the real mixer.
final class RendersManifestTests: FixtureTestCase {
    func testManifestLoadsAndMatchesTheFiles() throws {
        let url = AudioSpec.fixtureURL("renders/renders.json")
        let manifest = try JSONDecoder().decode(RendersManifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(manifest.specVersion, AudioSpec.pinnedVersion)
        XCTAssertEqual(Set(manifest.renders.keys), ["crossfade", "ducked", "loop", "trim_fade_out"])
        XCTAssertEqual(manifest.sampleRate, 48_000)
        for (name, render) in manifest.renders {
            let wav = AudioSpec.url("renders/\(render.file)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "\(name): \(render.file) missing")
        }
    }
}
