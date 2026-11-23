import AppKit
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

@MainActor
final class StudioFixTests: TempFolderTestCase {
    var dialogs: FakeDialogs!
    var defaults: UserDefaults!
    var controller: StudioController!
    var stage: StageStore { controller.stage }

    override func setUp() async throws {
        try await super.setUp()
        dialogs = FakeDialogs()
        defaults = UserDefaults(suiteName: "cueme.tests.fix.\(UUID().uuidString)")
        let catalog = StudioCatalog()
        controller = StudioController(
            studios: StudioStore(environment: environment()), stage: StageStore.mock(library: .empty, studios: catalog), catalog: catalog,
            defaults: defaults, documentsFolder: temp.appendingPathComponent("Documents", isDirectory: true), dialogs: dialogs
        )
    }

    override func tearDown() async throws {
        controller?.shutdown()
        try await super.tearDown()
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

    // MARK: 1. Status-bar output chips

    func testChipsComeFromThisMachinesAssignmentsAndACopyHasNone() async throws {
        let url = try makeStudio("Sunday")
        controller.open(url)
        await until("loaded") { stage.state.studio?.name == "Sunday" }
        XCTAssertEqual(stage.state.outputs, [], "no assignments on this machine yet: no chips")
        let screens = controller.studios.studio!.screens
        stage.send(.assignScreen(screens[0].id, connector: "decklink-A-1"))
        stage.send(.assignScreen(screens[1].id, connector: "decklink-A-2"))
        await until("chips") { stage.state.outputs.count == 2 }
        XCTAssertEqual(stage.state.outputs.map(\.name), ["SDI 1 (A)", "SDI 2 (A)"])
        XCTAssertTrue(stage.state.outputs.allSatisfy { $0.health == .ok })

        // A copy has a new id, so this machine has no assignments for it.
        let copy = try StudioPackage(url: url).makeCopy(now: Date(), appVersion: "test")
        controller.open(copy)
        await until("copy loaded") { stage.state.studio?.name == "Sunday copy" }
        XCTAssertEqual(stage.state.outputs, [])

        controller.open(url)
        await until("original again") { stage.state.studio?.name == "Sunday" }
        XCTAssertEqual(stage.state.outputs.map(\.name), ["SDI 1 (A)", "SDI 2 (A)"], "read back from outputs.json")
    }

    // MARK: 2. Machine name

    func testNameFallsBackToTheHostNameWithoutItsDomain() throws {
        let names = MachineIdentity.NameSource(computerName: { nil }, hostName: { "jc-mbp.familyreyes.com" })
        let identity = MachineIdentity.loadOrCreate(machine, names: names)
        XCTAssertEqual(identity.name, "jc-mbp")
        XCTAssertEqual(MachineIdentity.shortHostName("studio.local"), "studio")
        XCTAssertEqual(MachineIdentity.makeName(.init(computerName: { nil }, hostName: { nil })), "This Mac")
        XCTAssertEqual(MachineIdentity.makeName(.init(computerName: { "Mac Studio" }, hostName: { "x.example.com" })), "Mac Studio")

        // The lock written into a Studio carries that name, not a qualified host name.
        let url = try makeStudio("Locked")
        let locking = StudioLocking(identity: identity, appVersion: "test")
        try locking.acquire(StudioPackage(url: url), now: Date())
        let lock = try String(contentsOf: url.appendingPathComponent("lock.json"), encoding: .utf8)
        XCTAssertTrue(lock.contains(#""machineName" : "jc-mbp""#))
        XCTAssertFalse(lock.contains("familyreyes"))
    }

    func testAComputerNameThatIsAQualifiedHostNameIsShortened() throws {
        // Found on the dev Mac: its computer name is "jc-mbp.familyreyes.com".
        XCTAssertEqual(MachineIdentity.makeName(.init(computerName: { "jc-mbp.familyreyes.com" }, hostName: { nil })), "jc-mbp")
        XCTAssertEqual(MachineIdentity.safeName("J.C.'s Mac Studio"), "J.C.'s Mac Studio", "a real name with dots and spaces is kept")
        // A qualified name stored by an earlier build is fixed on load.
        let id = UUID()
        try machine.save(["id": id.uuidString, "name": "jc-mbp.familyreyes.com"], to: machine.identity)
        XCTAssertEqual(MachineIdentity.loadOrCreate(machine, names: .init(computerName: { nil }, hostName: { nil })).name, "jc-mbp")
        XCTAssertFalse(try String(contentsOf: machine.identity, encoding: .utf8).contains("familyreyes"))
        // And the lock never carries one, whatever the identity says.
        let lock = StudioLocking(identity: MachineIdentity(id: id, name: "jc-mbp.familyreyes.com"), appVersion: "t").ourLock(now: Date())
        XCTAssertEqual(lock.machineName, "jc-mbp")
    }

    func testAStoredNameIsUsedWithoutAnyLookup() {
        let first = MachineIdentity.loadOrCreate(machine, names: .init(computerName: { "Mac Studio" }, hostName: { nil }))
        let again = MachineIdentity.loadOrCreate(machine, names: .init(
            computerName: { XCTFail("no lookup at launch when a name is stored"); return nil },
            hostName: { XCTFail("no lookup at launch when a name is stored"); return nil }
        ))
        XCTAssertEqual(again, first)
    }

    func testAnOldMachineFileWithoutANameKeepsItsID() throws {
        let id = UUID()
        try machine.save(["id": id.uuidString], to: machine.identity)
        let identity = MachineIdentity.loadOrCreate(machine, names: .init(computerName: { "FOH" }, hostName: { nil }))
        XCTAssertEqual(identity.id, id)
        XCTAssertEqual(identity.name, "FOH")
    }

    // MARK: 3. Escape and Return in the warnings

    /// Runs the alert as the app does, posts one key press into its modal loop, and returns what it answered.
    /// A safety timer aborts the modal if the key did nothing.
    private func answer(_ alert: NSAlert, keyCode: UInt16, characters: String, cancellable: Bool = true) -> NSApplication.ModalResponse {
        let safety = Timer(timeInterval: 1.5, repeats: false) { _ in NSApp.abortModal() }
        let press = Timer(timeInterval: 0.3, repeats: false) { _ in
            // In the test host the app may not be active; a real alert is the key window, so make it so.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: alert.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
            NSApp.postEvent(event, atStart: false)
        }
        RunLoop.main.add(safety, forMode: .modalPanel)
        RunLoop.main.add(press, forMode: .modalPanel)
        defer { safety.invalidate(); press.invalidate() }
        return cancellable ? StudioAlerts.runCancellable(alert) : alert.runModal()
    }

    func testReturnAndEscapeBothCancelTheWarnings() {
        for make in [{ StudioAlerts.switchWarning(live: "Left showing slides", action: "Switch Studio") }, { StudioAlerts.lockWarning("held") }] {
            XCTAssertEqual(answer(make(), keyCode: 36, characters: "\r"), .alertFirstButtonReturn, "Return = Cancel")
            XCTAssertEqual(answer(make(), keyCode: 53, characters: "\u{1b}"), .alertFirstButtonReturn, "Escape = Cancel")
        }
        // Control: without the Escape handling, Escape does nothing in these alerts (the modal is aborted by the timer).
        XCTAssertEqual(answer(StudioAlerts.lockWarning("held"), keyCode: 53, characters: "\u{1b}", cancellable: false), .abort)
    }

    // MARK: 4. Open Recent and the already-open Studio

    func testOpenRecentLeavesOutTheOpenStudio() throws {
        let a = try makeStudio("A"), b = try makeStudio("B")
        controller.open(a)
        XCTAssertEqual(controller.recentMenuURLs, [], "only the open one: the menu shows “No Other Studios”")
        controller.open(b)
        XCTAssertEqual(controller.recentMenuURLs.map(\.lastPathComponent), ["A.stg"])
        controller.open(a)
        XCTAssertEqual(controller.recentMenuURLs.map(\.lastPathComponent), ["B.stg"])
    }

    func testOpeningTheOpenStudioAgainIsANotice() throws {
        let a = try makeStudio("A")
        controller.open(a)
        XCTAssertNil(controller.notice)
        let saves = controller.studios.saveCount
        // Another spelling of the same path, as a Finder double-click or a recent entry might give it.
        let other = URL(fileURLWithPath: temp.path + "/./A.stg/", isDirectory: true)
        XCTAssertTrue(controller.open(other))
        XCTAssertEqual(controller.notice, "“A” is already open.")
        XCTAssertEqual(controller.studios.saveCount, saves, "not reopened")
    }

    // MARK: 6. No NEXT in the operator view

    private func host(_ store: StageStore, ui: OperatorUIState, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
        let view = AnyView(OperatorView(store: store, ui: ui, studios: controller).modifier(Themed()).frame(width: size.width, height: size.height))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (window, hosting)
    }

    /// Counts pixels of `color` (within a tolerance) in a rect of the view, in points from the top left.
    private func pixels(of color: (UInt8, UInt8, UInt8), in hosting: NSView, rect: NSRect) throws -> Int {
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        var count = 0
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt8(c.redComponent * 255), g = UInt8(c.greenComponent * 255), b = UInt8(c.blueComponent * 255)
                if abs(Int(r) - Int(color.0)) < 24, abs(Int(g) - Int(color.1)) < 24, abs(Int(b) - Int(color.2)) < 24 { count += 1 }
            }
        }
        return count
    }

    /// The NEXT monitor and the NEXT badge and outline were drawn in the "preview" green; LIVE is red. A real render
    /// of the monitors and the slide grid, with a next slide in the state (Verse 2 of the item shown), has no such
    /// green, and does have the live red.
    func testNoNextMarkerOrMonitorWhileNextSlideIsSet() async throws {
        let store = StageStore.mock(library: .sample)
        let song = Library.sample.service.items[1]
        store.send(.go(itemID: song.id, slideIndex: 0))
        await until("live with a next slide") { store.state.primaryLive != nil && store.state.nextSlide?.itemID == song.id }
        XCTAssertEqual(store.state.nextSlide?.slideIndex, 1, "the next slide is in this item's grid")
        let ui = OperatorUIState()
        ui.selection = song.id
        let size = NSSize(width: 1100, height: 720)
        let (window, hosting) = host(store, ui: ui, size: size)
        defer { window.orderOut(nil) }

        // Centre column (right of the 240 pt service panel), from the top down to the transport bar.
        let area = NSRect(x: 242, y: 0, width: size.width - 242, height: size.height - MonitorLayout.reservedBelow - 30)
        XCTAssertEqual(try pixels(of: (0x30, 0xD1, 0x58), in: hosting, rect: area), 0, "no next (preview green) marking")
        XCTAssertGreaterThan(try pixels(of: (0xFF, 0x45, 0x3A), in: hosting, rect: area), 100, "sanity: the live red is drawn")
        let statusBar = NSRect(x: 0, y: size.height - 22, width: 400, height: 22)
        XCTAssertGreaterThan(try pixels(of: (0x30, 0xD1, 0x58), in: hosting, rect: statusBar), 0,
                             "control: the detector sees that green where it is drawn (the output chips' dots)")
        XCTAssertTrue(MonitorRowTitles.titles(store.state).allSatisfy { $0 != "Next" }, "monitors are the output screens only")
        XCTAssertEqual(MonitorRowTitles.titles(store.state), ["Left", "Stage", "Right"])
        XCTAssertNotNil(store.state.nextSlide, "the data is still there")
    }

    func testNextSlideIsStillInTheStateAndPublished() async throws {
        let client = MockStageClient(library: .sample)
        let song = Library.sample.service.items[1]
        let stream = await client.states()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await client.send(.go(itemID: song.id, slideIndex: 0))
        let published = await iterator.next()
        XCTAssertEqual(published?.nextSlide?.slideIndex, 1, "every state subscriber (stage displays, control) gets it")
        XCTAssertEqual(published?.nextSlide?.itemID, song.id)

        let store = StageStore.mock(library: .sample)
        store.send(.go(itemID: song.id, slideIndex: 0))
        await until("store state") { store.state.nextSlide?.slideIndex == 1 }
        XCTAssertTrue(ServiceMenuModel(state: store.state, selection: nil).canNext, "Next still works from it")
    }

    func testMonitorsFillTheRowAndKeepTheirAspect() {
        // Centre column at the minimum window (1100 x 720): 1100 - 240 (service) - 1 (divider).
        // Centre column sizes for windows of 1100 x 720 (the minimum), 1440 x 900, 1920 x 1080 and 2560 x 1440.
        for (width, height) in [(859.0, 697.0), (1199.0, 877.0), (1679.0, 1057.0), (2319.0, 1417.0)] {
            for count in [2, 3] { // Main and Stage; Left, Stage and Right
                let w = MonitorLayout.monitorWidth(rowWidth: width, columnHeight: height, count: count)
                let row = CGFloat(count) * w + CGFloat(count - 1) * MonitorLayout.spacing + 2 * MonitorLayout.padding
                XCTAssertEqual(row, width, accuracy: 0.5, "\(count) monitors fill \(width) x \(height)")
                let rowHeight = w / MonitorLayout.aspect + MonitorLayout.titleHeight + 2 * MonitorLayout.padding
                XCTAssertGreaterThanOrEqual(height - rowHeight - MonitorLayout.reservedBelow, MonitorLayout.minGridHeight - 0.5, "the grid keeps its room")
            }
        }
        // Very wide and short (2560 x 720): capped by height, still 16:9; the row centres them.
        let capped = MonitorLayout.monitorWidth(rowWidth: 2319, columnHeight: 697, count: 3)
        XCTAssertLessThan(3 * capped + 48, 2319)
        XCTAssertEqual(capped / MonitorLayout.aspect + MonitorLayout.titleHeight + 2 * MonitorLayout.padding,
                       697 - MonitorLayout.reservedBelow - MonitorLayout.minGridHeight, accuracy: 0.5)
    }

    /// Renders the real operator view at several window sizes into PNGs when TEST_RUNNER_CUEME_SNAPSHOT_DIR is set
    /// (for looking at the layout without screen recording).
    func testLayoutSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CUEME_SNAPSHOT_DIR"] else { throw XCTSkip("no snapshot folder") }
        let store = StageStore.mock(library: .sample)
        let song = Library.sample.service.items[1]
        store.send(.go(itemID: song.id, slideIndex: 0))
        await until("live") { store.state.primaryLive != nil }
        let ui = OperatorUIState()
        ui.selection = song.id
        for (w, h) in [(1100, 720), (1440, 900), (1920, 1080), (2560, 1440), (2560, 720)] {
            let (window, hosting) = host(store, ui: ui, size: NSSize(width: w, height: h))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("operator-\(w)x\(h).png"))
            window.orderOut(nil)
        }
    }
}
