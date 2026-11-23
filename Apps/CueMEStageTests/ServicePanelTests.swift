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

    func testAServiceWithoutSectionsIsOneBlockWithNoHeader() async {
        let model = ServiceListModel(state: await state(), studio: studio, relink: nil)
        XCTAssertEqual(model.sections.map(\.title), [nil], "no sections in the Studio: one block under the ITEMS label")
        XCTAssertEqual(model.rows.map(\.title), lib.service.items.map(\.title), "every item, in service order")
        XCTAssertTrue(ServiceListModel(state: StageState(), studio: nil, relink: nil).sections.isEmpty, "no service, no rows")
    }

    func testRowsAreGroupedUnderTheirSectionHeaders() async {
        var studio = studio
        let items = lib.service.items
        studio.setSections([
            ServiceSection(name: "Worship", firstItemID: items[1].id),
            ServiceSection(name: "Closing", firstItemID: items[3].id),
            ServiceSection(name: "Offering"),
            ServiceSection(name: "Gone", firstItemID: UUID()),
        ], of: lib.service.id)
        let model = ServiceListModel(state: await state(), studio: studio, relink: nil)
        XCTAssertEqual(model.sections.map(\.title), [nil, "Worship", "Closing", "Offering", "Gone"])
        XCTAssertEqual(model.sections.map { $0.rows.map(\.id) }, [[items[0].id], [items[1].id, items[2].id], [items[3].id], [], []],
                       "items above the first header have none; headers without an item in the service go last, empty")
        XCTAssertEqual(model.rows.map(\.id), items.map(\.id), "the service order is unchanged")
        XCTAssertEqual(model.moving(items[0].id, by: 1), items[1].id, "arrows step over headers")
    }

    func testTheSectionPopoverAnchorsAtTheSelection() {
        var popover = NewSectionModel()
        XCTAssertFalse(popover.canAdd, "a name is needed")
        popover.name = "  Offering "
        XCTAssertTrue(popover.canAdd)
        XCTAssertEqual(popover.trimmedName, "Offering")
        XCTAssertEqual(NewSectionModel.label, "SECTION NAME")
        let service = lib.service
        XCTAssertEqual(NewSectionModel.anchor(selection: service.items[2].id, in: service), service.items[2].id)
        XCTAssertNil(NewSectionModel.anchor(selection: nil, in: service), "nothing selected: at the end")
        XCTAssertNil(NewSectionModel.anchor(selection: UUID(), in: service), "a selection not in the service: at the end")
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

    func testAStudioWithoutCollectionsShowsItsSongsAsBefore() {
        var model = CollectionsModel(studio: studio)
        XCTAssertEqual(model.rows, [.collection(id: "songs", title: "Songs", count: studio.songs.count, isExpanded: false)])
        model.expanded = model.toggling("songs")
        XCTAssertEqual(model.rows.count, 1 + studio.songs.count, "expanded in place")
        let first = studio.songs.min { $0.title < $1.title }!
        XCTAssertEqual(model.rows[1], .entry(.init(title: first.title, icon: "music.note", songID: first.id)), "by title")
        model.expanded = model.toggling("songs")
        XCTAssertEqual(model.rows.count, 1, "collapsed again")
        XCTAssertTrue(CollectionsModel(studio: nil).rows.isEmpty, "no Studio, no collections")
        var empty = studio
        empty.songs = []
        XCTAssertTrue(CollectionsModel(studio: empty).rows.isEmpty, "no empty collection is shown")
    }

    func testRealCollectionsWithCountsThenLooseSongs() throws {
        var studio = studio
        let worship = StudioCollection(name: "Worship Songs"), kids = StudioCollection(name: "Kids Songs")
        studio.collections = [worship, kids]
        studio.songs[0].collectionID = worship.id
        var model = CollectionsModel(studio: studio)
        XCTAssertEqual(model.rows, [
            .collection(id: worship.id.uuidString, title: "Worship Songs", count: 1, isExpanded: false),
            .collection(id: kids.id.uuidString, title: "Kids Songs", count: 0, isExpanded: false),
            .collection(id: "songs", title: "Songs", count: studio.songs.count - 1, isExpanded: false),
        ], "in the Studio's order; an empty collection shows 0; songs in none are listed as Songs")
        model.expanded = model.toggling(worship.id.uuidString)
        XCTAssertEqual(model.rows[1], .entry(.init(title: studio.songs[0].title, icon: "music.note", songID: studio.songs[0].id)))

        for i in studio.songs.indices { studio.songs[i].collectionID = worship.id }
        XCTAssertFalse(CollectionsModel(studio: studio).rows.contains { if case .collection(id: "songs", _, _, _) = $0 { true } else { false } },
                       "no Songs row when every song is in a collection")
        studio.songs[0].collectionID = UUID()
        XCTAssertEqual(CollectionsModel(studio: studio).collections.last?.entries.map(\.songID), [studio.songs[0].id],
                       "a song naming an unknown collection is listed with the loose songs")
    }

    func testNewCollectionDialog() {
        var dialog = NewCollectionModel()
        XCTAssertFalse(dialog.canCreate)
        dialog.name = "   "
        XCTAssertFalse(dialog.canCreate)
        dialog.name = " Kids Songs "
        XCTAssertTrue(dialog.canCreate)
        XCTAssertEqual(dialog.trimmedName, "Kids Songs")
        XCTAssertEqual(NewCollectionModel.title, "New collection")
        XCTAssertEqual(NewCollectionModel.createTitle, "Create collection")
    }

    /// Media files are not a collection (they belong in the Media and Audio bins), but a media item still shows as a
    /// row in the service.
    func testMediaIsNotACollectionButStaysInTheService() async throws {
        XCTAssertFalse(studio.media.isEmpty, "the sample Studio has media")
        let model = CollectionsModel(studio: studio)
        XCTAssertFalse(model.collections.contains { $0.id == "media" || $0.title == "Media" }, "no Media collection")
        let mediaNames = Set(studio.media.map(\.name))
        XCTAssertFalse(model.collections.flatMap(\.entries).contains { mediaNames.contains($0.title) }, "no media file in any collection")

        let list = ServiceListModel(state: await state(), studio: studio, relink: nil)
        let row = try XCTUnwrap(list.rows.first { $0.id == walkIn.id }, "the media item is still a service row")
        XCTAssertEqual(row.title, walkIn.title)
        XCTAssertEqual(row.icon, ServiceListModel.icon(try XCTUnwrap(studio.media.first).kind))
    }

    func testSearchFiltersSongsOnly() throws {
        let song = try XCTUnwrap(studio.songs.first)
        let word = String(song.title.split(separator: " ").last ?? "")
        var model = CollectionsModel(studio: studio, query: word.uppercased())
        let matching = studio.songs.filter { $0.title.localizedCaseInsensitiveContains(word) }
        XCTAssertEqual(model.rows.first, .collection(id: "songs", title: "Songs", count: matching.count, isExpanded: true),
                       "case-insensitive, opened, counted to the matches")
        XCTAssertEqual(model.rows.dropFirst().map { row -> String in
            if case let .entry(e) = row { e.title } else { "" }
        }, matching.map(\.title))

        model.query = "songs"
        XCTAssertEqual(model.rows.first, .collection(id: "songs", title: "Songs", count: studio.songs.count, isExpanded: true),
                       "a collection name match shows all of it")
        for media in studio.media {
            model.query = media.name
            XCTAssertFalse(model.rows.contains { if case let .entry(e) = $0 { e.title == media.name } else { false } },
                           "\(media.name): media is not searched")
        }
        model.query = "media"
        XCTAssertTrue(model.rows.isEmpty, "no Media collection to match")
        model.query = "zzz-no-match"
        XCTAssertTrue(model.rows.isEmpty)
        model.query = "   "
        XCTAssertEqual(model.rows.count, 1, "blank search = no search")
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
