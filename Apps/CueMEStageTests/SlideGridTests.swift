import XCTest
import StageKit
@testable import CueMEStage

/// The slide grid's groups and header, from the data the model has.
final class SlideGridTests: XCTestCase {
    private func slides(_ labels: [String]) -> [Slide] { labels.map { Slide(label: $0, lines: [$0]) } }

    func testNeighbouringSlidesOfOneSectionShareAGroup() {
        let groups = SlideGrouping.groups(slides(["Verse 1", "Verse 2", "Verse 3"]))
        XCTAssertEqual(groups.map(\.title), ["VERSE"])
        XCTAssertEqual(groups.map(\.count), [3])
        XCTAssertEqual(groups[0].firstIndex, 0)
    }

    func testAnotherSectionStartsANewGroupAndNumbersKeepCounting() {
        let groups = SlideGrouping.groups(slides(["Verse 1", "Verse 1", "Chorus", "Verse 2", "Bridge", "Chorus"]))
        XCTAssertEqual(groups.map(\.title), ["VERSE", "CHORUS", "VERSE", "BRIDGE", "CHORUS"])
        XCTAssertEqual(groups.map(\.count), [2, 1, 1, 1, 1])
        XCTAssertEqual(groups.map(\.firstIndex), [0, 2, 3, 4, 5], "slide numbers run on across groups")
        XCTAssertEqual(groups.flatMap(\.slides).count, 6, "every slide once")
    }

    func testBaseName() {
        XCTAssertEqual(SlideGrouping.baseName("Verse 2"), "Verse")
        XCTAssertEqual(SlideGrouping.baseName("Chorus"), "Chorus")
        XCTAssertEqual(SlideGrouping.baseName("Pre-Chorus 1b"), "Pre-Chorus 1b", "only a plain trailing number goes")
        XCTAssertEqual(SlideGrouping.baseName("Verse "), "Verse")
        XCTAssertEqual(SlideGrouping.groups(slides([""])).map(\.title), ["SLIDES"], "an empty label still has a heading")
        XCTAssertTrue(SlideGrouping.groups([]).isEmpty)
    }

    func testHeaderChipsComeFromTheItemsOwnFile() throws {
        let lib = Library.sample
        var studio = Studio(seededFrom: lib, name: "S", now: Date(timeIntervalSince1970: 0), appVersion: "t")
        let walkIn = lib.service.items[0], song = lib.service.items[1]
        guard case let .media(id) = walkIn.content else { return XCTFail("media") }
        let i = try XCTUnwrap(studio.media.firstIndex { $0.id == id })
        studio.media[i].lastKnownPath = "/Media/track_02.wav"
        studio.media[i].kind = .audio
        XCTAssertEqual(SlideGridHeaderModel(item: walkIn, studio: studio).chips, ["♪ track_02.wav"])
        studio.media[i].kind = .video
        XCTAssertEqual(SlideGridHeaderModel(item: walkIn, studio: studio).chips, ["track_02.wav"])
        XCTAssertEqual(SlideGridHeaderModel(item: song, studio: studio).chips, [], "songs have no background or track in the model")
        XCTAssertTrue(SlideGridHeaderModel(item: song, studio: studio).showsEdit)
        XCTAssertFalse(SlideGridHeaderModel(item: walkIn, studio: studio).showsEdit)
        XCTAssertEqual(SlideGridHeaderModel(item: nil, studio: nil).title, "Slides")
        XCTAssertEqual(SlideGridHeaderModel.sendToHelp, "Send to is not available in v0.1")
    }

    func testFourFixedColumns() {
        XCTAssertEqual(SlideGridLayout.columns, 4, "Main.dc.html L116")
        XCTAssertEqual(SlideGridLayout.spacing, 10)
    }
}
