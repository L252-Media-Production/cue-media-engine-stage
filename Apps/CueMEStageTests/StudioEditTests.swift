import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// Editing show data from the operator view (collections, sections, songs): autosaved through the store with only
/// the changed files, then handed to the engine with `reloadStudio`. Nothing on the outputs changes until it is taken
/// again.
@MainActor
class StudioEditTestCase: TempFolderTestCase {
    var dialogs: FakeDialogs!
    var defaults: UserDefaults!
    var controller: StudioController!
    var stage: StageStore { controller.stage }

    override func setUp() async throws {
        try await super.setUp()
        dialogs = FakeDialogs()
        defaults = UserDefaults(suiteName: "cueme.tests.edit.\(UUID().uuidString)")
        let catalog = StudioCatalog()
        controller = StudioController(
            studios: StudioStore(environment: environment()), stage: StageStore.mock(library: .empty, studios: catalog), catalog: catalog,
            defaults: defaults, documentsFolder: temp.appendingPathComponent("Documents/CueME Stage", isDirectory: true), dialogs: dialogs
        )
    }

    override func tearDown() async throws {
        controller?.shutdown()
        try await super.tearDown()
    }

    func until(_ what: String, timeout: Double = 2, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        let met = condition()
        XCTAssertTrue(met, "timed out waiting for \(what)")
    }

    /// Launches into the first-launch Studio and waits until the engine has it.
    func launch() async {
        controller.launch()
        await until("the engine loads the Studio") { [self] in stage.state.studio?.id == controller.studios.studio?.id && stage.state.service != nil }
    }

    var studio: Studio { controller.studios.studio! }
    var service: Service { studio.activeService! }

    func item(_ title: String) -> Item { service.items.first { $0.title == title }! }

    /// Waits for the debounced autosave and returns the paths it wrote.
    func saved(after count: Int) async -> [String] {
        await until("an autosave") { [self] in controller.studios.saveCount > count }
        return controller.studios.lastWrite
    }
}

@MainActor
final class StudioEditTests: StudioEditTestCase {
    func testTheFirstLaunchStudioHasACollectionAndSections() async {
        await launch()
        XCTAssertEqual(studio.collections.map(\.name), ["Worship Songs"])
        XCTAssertTrue(studio.songs.allSatisfy { $0.collectionID == studio.collections[0].id }, "every sample song is in it")
        let list = ServiceListModel(state: stage.state, studio: studio, relink: nil)
        XCTAssertEqual(list.sections.map(\.title), ["Pre-service", "Worship", "Closing"])
        XCTAssertEqual(list.sections.map { $0.rows.map(\.title) }, [["Walk-in loop"], ["Amazing Grace", "Blank"], ["Doxology"]])
        XCTAssertEqual(CollectionsModel(studio: studio).rows, [
            .collection(id: studio.collections[0].id.uuidString, title: "Worship Songs", count: 2, isExpanded: false),
        ])
        XCTAssertEqual(studio.validationIssues(), [])
    }

    func testANewCollectionWritesOnlyCollectionsJSON() async {
        await launch()
        let count = controller.studios.saveCount
        let id = controller.addCollection(named: "  Kids Songs ")
        XCTAssertNotNil(id)
        XCTAssertNil(controller.addCollection(named: "   "), "a name is needed")
        XCTAssertEqual(studio.collections.map(\.name), ["Worship Songs", "Kids Songs"])
        let written = await saved(after: count)
        XCTAssertEqual(Set(written), ["collections.json", "manifest.json"], "only the changed file (and the manifest)")
        let reread = try? StudioPackage(url: controller.studios.url!).read().studio
        XCTAssertEqual(reread?.collections.map(\.name), ["Worship Songs", "Kids Songs"])
    }

    func testASectionGoesAboveTheSelectionAndOnlyTheServiceFileIsWritten() async {
        await launch()
        let count = controller.studios.saveCount
        let blank = item("Blank")
        controller.addSection(named: "Offering", above: blank.id)
        let written = await saved(after: count)
        XCTAssertEqual(Set(written), ["services/\(service.id.uuidString).json", "manifest.json"])
        let list = ServiceListModel(state: stage.state, studio: studio, relink: nil)
        XCTAssertEqual(list.sections.map(\.title), ["Pre-service", "Worship", "Offering", "Closing"])
        XCTAssertEqual(list.sections[2].rows.map(\.id), [blank.id])

        controller.addSection(named: "Prayer", above: nil)
        XCTAssertEqual(ServiceListModel(state: stage.state, studio: studio, relink: nil).sections.last?.title, "Prayer",
                       "nothing selected: at the end")
        XCTAssertEqual(stage.state.service?.items.map(\.id), service.items.map(\.id), "the engine's items are untouched")
    }

    /// The proof: editing what is live (its song's text, sections around it, collections) changes the Studio and
    /// the engine's content, but not the outputs. The audience sees the new text only when the slide is taken again.
    func testEditingTheLiveItemDoesNotChangeWhatTheAudienceSees() async throws {
        await launch()
        let amazing = item("Amazing Grace")
        stage.send(.go(itemID: amazing.id, slideIndex: 0))
        await until("the slide is live") { [self] in stage.state.primaryLive?.itemID == amazing.id }
        let screensBefore = stage.state.screens
        let liveBefore = try XCTUnwrap(stage.state.primaryLive)
        guard case let .song(songID) = amazing.content else { return XCTFail("a song") }

        controller.edit { studio in
            let i = studio.songs.firstIndex { $0.id == songID }!
            studio.songs[i].slides[0].lines = ["Changed while live"]
            studio.songs[i].slides.removeLast()
        }
        controller.addSection(named: "Offering", above: amazing.id)
        controller.addCollection(named: "Kids Songs")

        // The engine has the new content (the operator's slide grid shows it) ...
        await until("the engine reloads") { [self] in stage.state.slides[amazing.id]?.first?.lines == ["Changed while live"] }
        XCTAssertEqual(stage.state.slides[amazing.id]?.count, 2)
        // ... and the outputs still show exactly what was taken.
        XCTAssertEqual(stage.state.screens, screensBefore, "no output changed")
        XCTAssertEqual(stage.state.primaryLive, liveBefore)
        XCTAssertEqual(stage.state.primaryLive?.lines, ["Amazing grace, how sweet the sound", "That saved a wretch like me"])

        // Taken again, the audience gets the edited slide.
        stage.send(.go(itemID: amazing.id, slideIndex: 0))
        await until("the new text is live") { [self] in stage.state.primaryLive?.lines == ["Changed while live"] }
    }

    func testSectionHeadersDoNotChangeWhatNextTakes() async {
        await launch()
        let amazing = item("Amazing Grace")
        stage.send(.go(itemID: amazing.id, slideIndex: 2))
        await until("the last slide is live") { [self] in stage.state.primaryLive?.slideIndex == 2 }
        controller.addSection(named: "Offering", above: item("Blank").id)
        controller.addSection(named: "Before all", above: item("Walk-in loop").id)
        await until("the engine reloads") { [self] in controller.catalog.get(studio.id)?.library.service.items.count == service.items.count }
        stage.send(.next)
        await until("Next takes the next song") { [self] in stage.state.primaryLive?.itemID == item("Doxology").id }
        XCTAssertEqual(stage.state.primaryLive?.slideIndex, 0)
    }

    func testFileMenuNewCollection() {
        XCTAssertTrue(FileMenuModel(hasStudio: true, isModalOpen: false).canNewCollection)
        XCTAssertFalse(FileMenuModel(hasStudio: false, isModalOpen: false).canNewCollection)
        XCTAssertFalse(FileMenuModel(hasStudio: true, isModalOpen: true).canNewCollection)
        XCTAssertEqual(Shortcuts.newCollection, KeyboardShortcut("n", modifiers: [.command, .shift]), "MenuBar.dc.html: ⇧⌘N")
    }

    func testDialogsAndThePopoverCountAsModal() {
        let ui = OperatorUIState()
        XCTAssertFalse(ui.isModalOpen)
        ui.showNewCollection = true
        XCTAssertTrue(ui.isModalOpen)
        ui.showNewCollection = false
        ui.showAddSection = true
        XCTAssertTrue(ui.isModalOpen)
    }
}
