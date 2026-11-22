import AppKit
import XCTest
@testable import CueMEStage

/// Runs inside the app (hosted test), so `Bundle.main` is CueMEStage.app with its Resources/Fonts.
final class BundledFontsTests: XCTestCase {
    func testJetBrainsMonoIsRegisteredFromTheBundle() {
        let registered = BundledFonts.registerOnce().map(\.lastPathComponent).sorted()
        XCTAssertEqual(registered, ["JetBrainsMono-Bold.ttf", "JetBrainsMono-Medium.ttf", "JetBrainsMono-Regular.ttf"])

        XCTAssertNotNil(NSFont(name: "JetBrainsMono-Regular", size: 12))
        XCTAssertNotNil(NSFont(name: "JetBrainsMono-Medium", size: 12))
        XCTAssertNotNil(NSFont(name: "JetBrainsMono-Bold", size: 12))
        XCTAssertTrue(ThemeTokens.hasJetBrainsMono)

        // The face comes from the app bundle, not from a copy installed on this Mac.
        let font = NSFont(name: "JetBrainsMono-Regular", size: 12).map { $0 as CTFont }
        let url = font.flatMap { CTFontCopyAttribute($0, kCTFontURLAttribute) as? URL }
        XCTAssertEqual(url?.resolvingSymlinksInPath().path,
                       Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf", subdirectory: "Fonts")?
                           .resolvingSymlinksInPath().path)
    }

    func testLicenceShipsNextToTheFonts() {
        XCTAssertNotNil(Bundle.main.url(forResource: "OFL", withExtension: "txt", subdirectory: BundledFonts.subdirectory))
    }

    func testRegisteringAgainIsHarmless() {
        BundledFonts.registerOnce()
        XCTAssertEqual(BundledFonts.register(in: .main).count, 3) // already registered counts as available
    }
}
