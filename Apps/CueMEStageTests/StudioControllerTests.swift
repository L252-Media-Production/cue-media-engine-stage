import AppKit
import CoreServices
import UniformTypeIdentifiers
import XCTest
import StageKit
@testable import CueMEStage

@MainActor
final class FakeDialogs: StudioDialogs {
    var switchAnswer = false
    var lockAnswer = LockChoice.cancel
    var switchAsked: [String] = []
    var lockAsked: [String] = []
    var quitAnswer = false
    var quitAsked: [String] = []
    var saveAnswer: URL?

    func confirmSwitch(live: String, action: String) -> Bool { switchAsked.append(live); return switchAnswer }
    func lockChoice(message: String) -> LockChoice { lockAsked.append(message); return lockAnswer }
    func bundleImportChoice(name: String) -> BundleImportChoice { .openAsNew }
    func clashChoice(for item: StudioItemPayload, remaining: Int) -> (ItemClashChoice, forAll: Bool) { (.skip, true) }
    func chooseFile(title: String, types: [UTType], directory: URL?) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseSave(title: String, name: String, type: UTType, directory: URL?) -> URL? { saveAnswer }
    func showError(_ title: String, _ error: Error) { XCTFail("\(title): \(error)") }
    func confirmQuit(subject: String) -> Bool { quitAsked.append(subject); return quitAnswer }
}

@MainActor
final class StudioControllerTests: TempFolderTestCase {
    var dialogs: FakeDialogs!
    var defaults: UserDefaults!
    var controller: StudioController!
    var stage: StageStore { controller.stage }

    override func setUp() async throws {
        try await super.setUp()
        dialogs = FakeDialogs()
        defaults = UserDefaults(suiteName: "cueme.tests.controller.\(UUID().uuidString)")
        controller = makeController()
    }

    override func tearDown() async throws {
        controller?.shutdown()
        try await super.tearDown()
    }

    private func makeController() -> StudioController {
        let catalog = StudioCatalog()
        return StudioController(
            studios: StudioStore(environment: environment()), stage: StageStore.mock(library: .empty, studios: catalog), catalog: catalog,
            defaults: defaults, documentsFolder: temp.appendingPathComponent("Documents/CueME Stage", isDirectory: true), dialogs: dialogs
        )
    }

    private func until(_ what: String, timeout: Double = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func makeStudio(_ name: String) throws -> URL {
        let url = temp.appendingPathComponent("\(name).stg")
        _ = try StudioPackage.create(sampleStudio(name: name), at: url)
        return url
    }

    // MARK: Launch

    func testFirstLaunchCreatesTheSeededStudio() async throws {
        controller.launch()
        let url = temp.appendingPathComponent("Documents/CueME Stage/Studio.stg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(controller.title, "Studio")
        XCTAssertEqual(controller.studios.studio?.songs.count, Library.sample.songs.count)
        XCTAssertEqual(defaults.string(forKey: StorageKeys.lastStudio), url.standardizedFileURL.path)
        await until("the engine loads it") { stage.state.studio?.name == "Studio" }
        XCTAssertEqual(stage.state.service?.items.count, Library.sample.service.items.count)
    }

    func testLastStudioReopensAndAMissingOneFallsBackWithANotice() async throws {
        let sunday = try makeStudio("Sunday")
        defaults.set(sunday.path, forKey: StorageKeys.lastStudio)
        controller.launch()
        XCTAssertEqual(controller.title, "Sunday")
        XCTAssertNil(controller.notice)
        controller.shutdown()

        defaults.set(temp.appendingPathComponent("Gone.stg").path, forKey: StorageKeys.lastStudio)
        controller = makeController()
        controller.launch()
        XCTAssertEqual(controller.title, "Studio", "first-launch behaviour")
        XCTAssertTrue(controller.notice?.contains("was not found") == true)
    }

    // MARK: Per-machine outputs

    func testOpenedStudioIsUnassignedAndAssignmentsSurviveReopening() async throws {
        let url = try makeStudio("Sunday")
        controller.open(url)
        await until("loaded") { stage.state.studio?.name == "Sunday" }
        XCTAssertTrue(stage.state.assignments.allSatisfy { $0.connectorID == nil }, "nothing guessed on a new machine")
        let left = try XCTUnwrap(controller.studios.studio?.screens.first?.id)

        stage.send(.assignScreen(left, connector: "decklink-A-1"))
        await until("saved on this machine") {
            MachineOutputs(paths: machine).assignments(studio: controller.studios.studio!.id, screens: [left]).first?.connectorID == "decklink-A-1"
        }
        let screensJSON = try String(contentsOf: url.appendingPathComponent("screens.json"), encoding: .utf8)
        XCTAssertFalse(screensJSON.contains("decklink"), "assignments are not show data")

        controller.closeStudio()
        await until("closed") { stage.state.studio == nil }
        controller.open(url)
        await until("reopened") { stage.state.studio?.name == "Sunday" }
        XCTAssertEqual(stage.state.connectorID(for: left), "decklink-A-1")
    }

    func testScreenLayoutChangesGoIntoTheStudio() async throws {
        let url = try makeStudio("Sunday")
        controller.open(url)
        await until("loaded") { stage.state.studio?.name == "Sunday" }
        let right = controller.studios.studio!.screens[2]
        var setup = right.setup
        setup.rotation = .right
        stage.send(.setScreenSetup(right.id, setup))
        await until("in the Studio and saved") {
            (try? StudioPackage(url: url).read().studio.screens.first { $0.id == right.id }?.setup.rotation) == .right
        }
    }

    // MARK: Switching

    func testSwitchWarningOnlyWhenSomethingIsLive() async throws {
        let a = try makeStudio("A"), b = try makeStudio("B"), c = try makeStudio("C")
        controller.open(a)
        await until("A loaded") { stage.state.studio?.name == "A" }
        XCTAssertTrue(controller.open(b))
        XCTAssertEqual(dialogs.switchAsked, [], "nothing live: no warning")
        await until("B loaded") { stage.state.studio?.name == "B" }

        let item = try XCTUnwrap(stage.state.service?.items.first { stage.state.slides[$0.id] != nil })
        stage.send(.go(itemID: item.id, slideIndex: 0))
        await until("live") { stage.state.primaryLive != nil }

        dialogs.switchAnswer = false // Cancel
        XCTAssertFalse(controller.open(c))
        XCTAssertEqual(dialogs.switchAsked, ["Left, Stage and Right showing slides"])
        XCTAssertEqual(controller.title, "B", "Cancel changes nothing")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stage.state.studio?.name, "B")
        XCTAssertNotNil(stage.state.primaryLive, "still live")
        XCTAssertNil(StudioLocking(identity: MachineIdentity(id: UUID(), name: "x"), appVersion: "").read(StudioPackage(url: c)), "C untouched")

        dialogs.switchAnswer = true
        XCTAssertTrue(controller.open(c))
        await until("C loaded") { stage.state.studio?.name == "C" }
        XCTAssertNil(stage.state.primaryLive)
    }

    func testTheWarningListsWhatIsLive() async {
        let client = MockStageClient(library: .sample)
        let lib = Library.sample
        await client.send(.go(itemID: lib.service.items[1].id, slideIndex: 0))
        await client.send(.playAudio(mediaID: lib.media[0].id))
        await client.send(.showMessage(lib.messages[0].id, screens: [lib.screens[1].id]))
        let state = await client.currentState
        XCTAssertEqual(LiveSummary.text(state), "Left, Stage and Right showing slides; a message showing; audio playing")
        XCTAssertNil(LiveSummary.text(StageState()))
        XCTAssertEqual(LiveSummary.joined(["Main", "Stage"]), "Main and Stage")
    }

    func testAlertsDefaultToCancel() {
        for alert in [StudioAlerts.switchWarning(live: "x", action: "Switch Studio"), StudioAlerts.lockWarning("x"), StudioAlerts.quitWarning(subject: "x")] {
            XCTAssertEqual(alert.buttons.first?.title, "Cancel")
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "Cancel is the default button")
            XCTAssertFalse(alert.buttons.dropFirst().contains { $0.keyEquivalent == "\r" }, "no other button takes Return")
        }
        XCTAssertEqual(StudioAlerts.lockWarning("x").buttons.map(\.title), ["Cancel", "Open Anyway", "Open a Copy"])
        XCTAssertEqual(StudioAlerts.bundleImport(name: "x").buttons.first?.title, "Open as New Studio")
    }

    func testLockedStudioAsksAndOpenACopyGetsANewID() async throws {
        let url = try makeStudio("Sunday")
        let original = try StudioPackage(url: url).read().studio.id
        let theirs = StudioLock(machineID: UUID(), machineName: "FOH Mac", pid: 1, openedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1")
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(theirs), to: StudioPackage(url: url).lockURL)

        dialogs.lockAnswer = .cancel
        XCTAssertFalse(controller.open(url))
        XCTAssertNil(controller.studios.studio)
        XCTAssertTrue(dialogs.lockAsked.first?.contains("FOH Mac") == true)

        dialogs.lockAnswer = .openCopy
        XCTAssertTrue(controller.open(url))
        XCTAssertNotEqual(controller.studios.studio?.id, original)
        XCTAssertEqual(controller.title, "Sunday copy")
    }

    // MARK: Quit while live

    /// Opens a Studio and puts its first song's first slide on the outputs.
    private func openAndGoLive(_ name: String) async throws -> URL {
        let url = try makeStudio(name)
        controller.open(url)
        await until("\(name) loaded") { stage.state.studio?.name == name }
        let item = try XCTUnwrap(stage.state.service?.items.first { stage.state.slides[$0.id] != nil })
        stage.send(.go(itemID: item.id, slideIndex: 0))
        await until("live") { stage.state.primaryLive != nil }
        return url
    }

    func testQuitWithNothingLiveDoesNotAsk() async throws {
        controller.open(try makeStudio("Quiet"))
        await until("loaded") { stage.state.studio?.name == "Quiet" }
        XCTAssertTrue(controller.shouldQuit())
        XCTAssertEqual(AppDelegate.terminateReply(controller), .terminateNow)
        XCTAssertEqual(dialogs.quitAsked, [], "nothing live: quits at once, no dialog")
    }

    func testQuitWhileLiveAsksAndCancelKeepsEverythingRunning() async throws {
        let url = try await openAndGoLive("Sunday")
        dialogs.quitAnswer = false // Cancel (also Return and Escape)
        XCTAssertFalse(controller.shouldQuit())
        XCTAssertEqual(AppDelegate.terminateReply(controller), .terminateCancel)
        let service = try XCTUnwrap(stage.state.service?.name)
        XCTAssertEqual(dialogs.quitAsked, [service, service], "asked each time, about the service that is live")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(stage.state.primaryLive, "still live")
        XCTAssertEqual(controller.title, "Sunday", "the Studio stays open")
        XCTAssertNotNil(StudioLocking(identity: MachineIdentity(id: UUID(), name: "x"), appVersion: "").read(StudioPackage(url: url)),
                        "the lock is still held")
    }

    func testQuitWhileLiveConfirmedQuitsAndShutdownStillSavesAndUnlocks() async throws {
        let url = try await openAndGoLive("Sunday")
        dialogs.quitAnswer = true
        XCTAssertEqual(AppDelegate.terminateReply(controller), .terminateNow)
        XCTAssertEqual(dialogs.quitAsked.count, 1)
        // AppKit then calls applicationWillTerminate, which runs shutdown().
        controller.shutdown()
        XCTAssertNil(StudioLocking(identity: MachineIdentity(id: UUID(), name: "x"), appVersion: "").read(StudioPackage(url: url)),
                     "the lock is released")
        controller = nil
    }

    func testWhatCountsAsLiveForQuit() async {
        let lib = Library.sample
        let client = MockStageClient(library: lib)
        var state = await client.currentState
        XCTAssertFalse(QuitWarning.isLive(state), "nothing")
        await client.send(.playAudio(mediaID: lib.media[0].id))
        state = await client.currentState
        XCTAssertTrue(QuitWarning.isLive(state), "audio playing alone")
        await client.send(.pauseAudio)
        state = await client.currentState
        XCTAssertFalse(QuitWarning.isLive(state), "paused audio is not heard")
        await client.send(.go(itemID: lib.service.items[1].id, slideIndex: 0))
        state = await client.currentState
        XCTAssertTrue(QuitWarning.isLive(state), "a slide on the outputs")
        XCTAssertEqual(QuitWarning.subject(state), "Sunday 10:00")
        XCTAssertEqual(QuitWarning.subject(StageState()), "The show")
    }

    func testQuitAlertWording() {
        let alert = StudioAlerts.quitWarning(subject: "Nov 22 Service")
        XCTAssertEqual(alert.messageText, "Quit CueME Stage?")
        XCTAssertEqual(alert.informativeText, "Nov 22 Service is live. Quitting stops the engine too, so the displays and audio will stop.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Quit"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction, "Quit is the red button, as on the board")
    }

    func testClosingTheLastWindowDoesNotQuit() {
        let delegate = AppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow, "nothing live in a fresh app: no dialog")
        delegate.studios.shutdown()
    }

    // MARK: Menus and types

    func testFileMenuWhileASheetIsOpen() {
        let open = FileMenuModel(hasStudio: true, isModalOpen: true)
        XCTAssertFalse(open.canNew)
        XCTAssertFalse(open.canOpen)
        XCTAssertFalse(open.canClose)
        XCTAssertFalse(open.canImportStudio)
        XCTAssertFalse(open.canExport)
        let closed = FileMenuModel(hasStudio: true, isModalOpen: false)
        XCTAssertTrue(closed.canNew && closed.canOpen && closed.canClose && closed.canImportItems && closed.canExport && closed.canRelink)
        XCTAssertFalse(closed.canExportSelectedItem, "nothing selected")
        XCTAssertFalse(FileMenuModel(hasStudio: false, isModalOpen: false).canClose)
        XCTAssertTrue(closed.canCloseWindow)
        XCTAssertFalse(open.canCloseWindow, "not under a sheet")
        XCTAssertTrue(FileMenuModel(hasStudio: false, isModalOpen: false).canCloseWindow, "also without a Studio")
    }

    func testStudioShortcuts() {
        XCTAssertEqual(Shortcuts.newStudio, KeyboardShortcut("n", modifiers: .command))
        XCTAssertEqual(Shortcuts.openStudio, KeyboardShortcut("o", modifiers: .command))
        XCTAssertTrue(Shortcuts.all.contains(Shortcuts.newStudio))
        XCTAssertTrue(Shortcuts.all.contains(Shortcuts.openStudio))
        XCTAssertEqual(Shortcuts.closeWindow, KeyboardShortcut("w", modifiers: .command))
        XCTAssertTrue(Shortcuts.all.contains(Shortcuts.closeWindow))
        XCTAssertEqual(Set(Shortcuts.all).count, Shortcuts.all.count, "no shortcut used twice")
    }

    func testBlankStudio() {
        let blank = Studio.blank(name: "New", now: Date(), appVersion: "0.1")
        XCTAssertEqual(blank.services.count, 1)
        XCTAssertEqual(blank.songs, [])
        XCTAssertEqual(blank.screens.map(\.name), ["Left", "Stage", "Right", "IMAG"])
        XCTAssertEqual(blank.validationIssues(), [])
    }
}

import SwiftUI

/// The app's Info.plist declares the three document types and UTIs once, and they resolve.
final class InfoPlistTests: XCTestCase {
    let expected = [
        ("stg", "com.l252mp.cuemestage.studio", UTType.package),
        ("stgbundle", "com.l252mp.cuemestage.studio-bundle", UTType.zip),
        ("stgitem", "com.l252mp.cuemestage.item", UTType.json),
    ]

    func testDeclarations() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(exported.count, 3, "declared once")
        for (ext, id, _) in expected {
            let declaration = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == id }, id)
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            XCTAssertEqual(tags?["public.filename-extension"] as? [String], [ext])
            XCTAssertTrue(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains(id) == true }, "a document type for \(id)")
        }
        let studio = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == "com.l252mp.cuemestage.studio" })
        XCTAssertEqual(studio["UTTypeConformsTo"] as? [String], ["com.apple.package", "public.composite-content"])
    }

    /// Registers the built app with Launch Services (as running it from Xcode does), then resolves each extension.
    func testTypesResolve() throws {
        XCTAssertEqual(LSRegisterURL(Bundle.main.bundleURL as CFURL, true), noErr)
        for (ext, id, parent) in expected {
            // Looked up within its parent: the default lookup only finds types conforming to public.data, and a
            // package (.stg) does not.
            let type = try XCTUnwrap(UTType(filenameExtension: ext, conformingTo: parent), ext)
            XCTAssertEqual(type.identifier, id)
            XCTAssertTrue(type.conforms(to: parent), "\(id) conforms to \(parent.identifier)")
        }
        XCTAssertEqual(UTType.cuemeStudio.identifier, "com.l252mp.cuemestage.studio")
        XCTAssertEqual(UTType.cuemeItems.identifier, "com.l252mp.cuemestage.item")
    }
}
