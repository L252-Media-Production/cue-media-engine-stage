import AppKit
import XCTest
@testable import CueMEStage

/// The app icon: the built bundle carries it, and the icon set in the repo is complete (rebuild it with
/// `swift tests/tools/make-app-icon.swift`).
final class AppIconTests: XCTestCase {
    /// The test host is the built app, so `Bundle.main` is CueMEStage.app.
    func testTheBuiltAppHasItsIcon() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.bundleURL.pathExtension, "app")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "AppIcon")
        XCTAssertNotNil(bundle.url(forResource: "AppIcon", withExtension: "icns"), "Resources/AppIcon.icns")
        let image = try XCTUnwrap(NSImage(named: "AppIcon"), "the asset catalog's AppIcon")
        XCTAssertGreaterThanOrEqual(image.representations.map(\.pixelsWide).max() ?? 0, 256)
    }

    func testTheIconSetIsCompleteAndEachFileHasItsSize() throws {
        let set = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent() // Apps/
            .appendingPathComponent("CueMEStage/Resources/Assets.xcassets/AppIcon.appiconset")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json"))) as? [String: Any]
        let images = try XCTUnwrap(json?["images"] as? [[String: String]])

        var seen: [String] = []
        for entry in images {
            let size = try XCTUnwrap(entry["size"]), scale = try XCTUnwrap(entry["scale"]), file = try XCTUnwrap(entry["filename"])
            XCTAssertEqual(entry["idiom"], "mac")
            let points = try XCTUnwrap(Int(size.split(separator: "x")[0]))
            let factor = try XCTUnwrap(Int(scale.dropLast()))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: set.appendingPathComponent(file))), "\(file) is a PNG")
            XCTAssertEqual(rep.pixelsWide, points * factor, "\(file) width")
            XCTAssertEqual(rep.pixelsHigh, points * factor, "\(file) height")
            XCTAssertTrue(rep.hasAlpha, "\(file): transparent canvas around the tile")
            seen.append("\(size)@\(scale)")
        }
        let expected = [16, 32, 128, 256, 512].flatMap { ["\($0)x\($0)@1x", "\($0)x\($0)@2x"] }
        XCTAssertEqual(Set(seen), Set(expected), "every macOS size at 1x and 2x")
        XCTAssertEqual(seen.count, expected.count)
    }
}
