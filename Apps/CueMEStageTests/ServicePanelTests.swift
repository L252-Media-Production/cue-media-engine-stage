import XCTest
import StageKit
@testable import CueMEStage

/// The service panel's models: the list (sections, sub-lines and meta from real data only), the collections and their
/// search, the service picker, and keyboard selection.
@MainActor
final class ServicePanelTests: XCTestCase {
    let lib = Library.sample
    lazy var studio = Studio(seededFrom: lib, name: "Sunday", now: Date(timeIntervalSince1970: 0), appVersion: "test")

    private func state(_ commands: [Command] = []) async -> StageState {
        let client = MockStageClient(library: lib)
        for command in commands { await client.send(command) }
        return await client.currentState
    }

    private var walkIn: Item { lib.service.items[0] }
    private var amazing: Item { lib.service.items[1] }

    // MARK: Sections

    func testItemsSitUnderTheItemsLabelAndNoSectionIsInvented() async {
        let model = ServiceListModel(state: await state(), studio: studio, relink: nil)
        XCTAssertEqual(model.sections.map(\.title), ["ITEMS"], "the model has no sections: one group, the board's ITEMS label")
        XCTAssertEqual(model.rows.map(\.title), lib.service.items.map(\.title), "every item, in service order")
        XCTAssertFalse(model.sections.map(\.title).contains { ["PRE-SERVICE", "WORSHIP", "WORD", "CLOSING"].contains($0) })
        XCTAssertTrue(ServiceListModel(state: StageState(), studio: nil, relink: nil).sections.isEmpty, "no service, no rows")
    }

    // MARK: Sub-line and meta

    func testSongsHaveNoFakedSubLineOrMeta() async {
        let row = ServiceListModel(state: await state(), studio: studio, relink: nil).row(amazing)
        XCTAssertEqual(row.icon, "music.note")
        XCTAssertNil(row.sub, "no look or track in the model")
        XCTAssertNil(row.meta, "no song length in the model")
    }

    func testMediaRowsShowFileAndLength() async throws {
        var studio = studio
        guard case let .media(id) = walkIn.content else { return XCTFail("walk-in is media") }
        let i = try XCTUnwrap(studio.media.firstIndex { $0.id == id })
        studio.media[i].duration = 252
        studio.media[i].lastKnownPath = "/Media/loop_blue_01.mov"
        let idle = await state()
        let row = ServiceListModel(state: idle, studio: studio, relink: nil).row(walkIn)
        XCTAssertEqual(row.sub, "loop_blue_01.mov", "the file name")
        XCTAssertEqual(row.meta, "4:12")
        XCTAssertEqual(row.metaTone, .dim)

        studio.media[i].duration = nil
        XCTAssertNil(ServiceListModel(state: idle, studio: studio, relink: nil).row(walkIn).meta, "unknown length: nothing")
        XCTAssertNil(ServiceListModel(state: idle, studio: nil, relink: nil).row(walkIn).sub, "no Studio: nothing")
    }

    func testMissingMediaShowsTheWarning() async {
        guard case let .media(id) = walkIn.content else { return XCTFail("walk-in is media") }
        var report = RelinkReport()
        report.statuses[id] = .missing
        let idle = await state()
        let row = ServiceListModel(state: idle, studio: studio, relink: report).row(walkIn)
        XCTAssertEqual(row.meta, "⚠ Missing")
        XCTAssertEqual(row.metaTone, .warning)
        report.statuses[id] = .found("/x")
        XCTAssertNotEqual(ServiceListModel(state: idle, studio: studio, relink: report).row(walkIn).meta, "⚠ Missing")
    }

    func testDurationFormat() {
        XCTAssertEqual(ServiceListModel.duration(252), "4:12")
        XCTAssertEqual(ServiceListModel.duration(59.6), "1:00")
        XCTAssertEqual(ServiceListModel.duration(3723), "1:02:03")
    }

    // MARK: Live and selection

    func testLiveRow() async {
        let s = await state([.go(itemID: amazing.id, slideIndex: 0)])
        let rows = ServiceListModel(state: s, studio: studio, relink: nil).rows
        XCTAssertEqual(rows.filter(\.isLive).map(\.id), [amazing.id])
    }

    func testArrowKeysMoveTheSelection() async {
        let model = ServiceListModel(state: await state(), studio: studio, relink: nil)
        let ids = lib.service.items.map(\.id)
        XCTAssertEqual(model.moving(nil, by: 1), ids.first, "nothing selected: the first")
        XCTAssertEqual(model.moving(ids[0], by: 1), ids[1])
        XCTAssertEqual(model.moving(ids[0], by: -1), ids[0], "clamped at the top")
        XCTAssertEqual(model.moving(ids.last, by: 1), ids.last, "clamped at the bottom")
    }

    // MARK: Collections and search

    func testCollectionsAreTheStudiosSongsAndMedia() {
        var model = CollectionsModel(studio: studio)
        XCTAssertEqual(model.rows, [
            .collection(id: "songs", title: "Songs", count: studio.songs.count, isExpanded: false),
            .collection(id: "media", title: "Media", count: studio.media.count, isExpanded: false),
        ])
        model.expanded = model.toggling("songs")
        XCTAssertEqual(model.rows.count, 2 + studio.songs.count, "expanded in place")
        XCTAssertEqual(model.rows[1], .entry(.init(title: studio.songs[0].title, icon: "music.note")))
        model.expanded = model.toggling("songs")
        XCTAssertEqual(model.rows.count, 2, "collapsed again")
        XCTAssertTrue(CollectionsModel(studio: nil).rows.isEmpty, "no Studio, no collections")
    }

    func testSearchFiltersTheCollections() throws {
        let song = try XCTUnwrap(studio.songs.first)
        let word = String(song.title.split(separator: " ").last ?? "")
        var model = CollectionsModel(studio: studio, query: word.uppercased())
        let matching = studio.songs.filter { $0.title.localizedCaseInsensitiveContains(word) }
        XCTAssertEqual(model.rows.first, .collection(id: "songs", title: "Songs", count: matching.count, isExpanded: true),
                       "case-insensitive, opened, counted to the matches")
        XCTAssertEqual(model.rows.dropFirst().prefix(matching.count).map { row -> String in
            if case let .entry(e) = row { e.title } else { "" }
        }, matching.map(\.title))

        model.query = "media"
        XCTAssertEqual(model.rows.first, .collection(id: "media", title: "Media", count: studio.media.count, isExpanded: true),
                       "a collection name match shows all of it")
        model.query = "zzz-no-match"
        XCTAssertTrue(model.rows.isEmpty)
        model.query = "   "
        XCTAssertEqual(model.rows.count, 2, "blank search = no search")
    }

    // MARK: Service picker and Add

    func testServicePickerListsServicesAndOnlyTheCurrentCanBePicked() async {
        var studio = studio
        studio.services.append(Service(name: "Youth Night", items: []))
        let model = ServicePickerModel(state: await state(), studio: studio)
        XCTAssertEqual(model.title, lib.service.name)
        XCTAssertEqual(model.services.map(\.name), [lib.service.name, "Youth Night"])
        XCTAssertTrue(model.canPick(lib.service.id))
        XCTAssertFalse(model.canPick(studio.services[1].id), "no service-switch operation in v0.1")
        XCTAssertEqual(ServicePickerModel.activityHelp, "Activities are not available in v0.1")
    }

    func testPanelWidth() {
        XCTAssertEqual(ServicePanelLayout.width, 280, "Main.dc.html L49")
        XCTAssertEqual(ServicePanelLayout.collectionsMaxHeight, 150)
    }
}
