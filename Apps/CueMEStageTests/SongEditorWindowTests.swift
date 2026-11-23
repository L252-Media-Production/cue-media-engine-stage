import AppKit
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The Song editor as a window: the failure-only save message, Done, and opening on a slide (slide card Edit…).
@MainActor
final class SongEditorWindowTests: StudioEditTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        AtomicFile.testHook = nil
        for window in windows { window.orderOut(nil) }
        try await super.tearDown()
    }

    private func amazingModel() -> SongEditorModel {
        guard case let .song(id) = item("Amazing Grace").content else { fatalError("a song") }
        return controller.editors.model(for: SongEditorTarget(studioID: studio.id, songID: id), controller: controller)
    }

    private func host(_ model: SongEditorModel) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1440, height: 860), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: SongEditorView(model: model) {}.modifier(Themed()))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (window, hosting)
    }

    /// Pixels of about the dark theme's warning colour (#FFB020) in `rect` (view coordinates, top-left origin).
    private func warningPixels(in view: NSView, rect: NSRect) throws -> Int {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["CUEME_SNAPSHOT_DIR"] {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("save-\(Int(rect.minY))-\(Int(rect.height)).png"))
        }
        let sx = CGFloat(rep.pixelsWide) / view.bounds.width, sy = CGFloat(rep.pixelsHigh) / view.bounds.height
        var count = 0
        for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 2) {
            for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Amber, with room for colour-space conversion and antialiasing.
                if c.redComponent > 0.85, (0.5...0.8).contains(c.greenComponent), c.blueComponent < 0.35 { count += 1 }
            }
        }
        return count
    }

    func testTheSaveMessageShowsOnlyWhileAWriteFails() async throws {
        await launch()
        let model = amazingModel()
        let (window, view) = host(model)
        let all = view.bounds
        let strip = NSRect(x: 0, y: 0, width: all.width, height: 32)

        model.setKey("G")
        XCTAssertNil(model.saveProblem)
        XCTAssertEqual(try warningPixels(in: view, rect: all), 0, "nothing while saving normally")

        struct DiskFull: Error {}
        AtomicFile.testHook = { _, _ in throw DiskFull() }
        model.setKey("D")
        await until("the save fails") { [self] in controller.studios.notice != nil }
        XCTAssertEqual(model.saveProblem, "Not saved, retrying")
        XCTAssertGreaterThan(try warningPixels(in: view, rect: strip), 20, "the message, in the warning colour, at the top of the content")
        XCTAssertEqual(try warningPixels(in: view, rect: NSRect(x: 0, y: 40, width: all.width, height: all.height - 40)), 0,
                       "and nowhere else")
        // Done lives in the window's toolbar, outside the content the message is in, so they cannot overlap; the toolbar
        // holds Done and nothing else.
        XCTAssertLessThanOrEqual(window.toolbar?.items.count ?? 0, 1)

        AtomicFile.testHook = nil
        await until("the retry succeeds") { [self] in controller.studios.notice == nil }
        XCTAssertNil(model.saveProblem)
        XCTAssertEqual(try warningPixels(in: view, rect: all), 0, "gone once saved")
    }

    func testDoneClosesTheWindow() async {
        await launch()
        let model = amazingModel()
        let (window, _) = host(model)
        XCTAssertTrue(window.isVisible)
        model.done()
        XCTAssertFalse(window.isVisible, "Done closed the editor window")
    }

    func testSlideCardEditSelectsThatSlide() async throws {
        await launch()
        guard case let .song(id) = item("Amazing Grace").content else { return XCTFail("a song") }
        let slides = studio.songs.first { $0.id == id }!.slides

        let target = try XCTUnwrap(SongEditorScene.prepare(id, slide: slides[2].id, studios: controller))
        let model = controller.editors.model(for: target, controller: controller)
        XCTAssertEqual(model.selectedSlide, slides[2].id)
        XCTAssertEqual(model.centreTab, .slide)
        XCTAssertEqual(model.slideInfo, "Slide 3 of 3 · Verse 3")

        // Already open (on the Text edit tab, another slide): the same editor, now on the clicked slide.
        model.centreTab = .text
        XCTAssertEqual(SongEditorScene.prepare(id, slide: slides[1].id, studios: controller), target, "the same window value")
        XCTAssertTrue(controller.editors.model(for: target, controller: controller) === model)
        XCTAssertEqual(model.selectedSlide, slides[1].id)
        XCTAssertEqual(model.centreTab, .slide)

        // Row / collection Edit…: an open editor keeps its selection ...
        SongEditorScene.prepare(id, studios: controller)
        XCTAssertEqual(model.selectedSlide, slides[1].id)
        // ... and a new one starts on the first slide.
        controller.editors.close(target)
        SongEditorScene.prepare(id, studios: controller)
        XCTAssertEqual(controller.editors.model(for: target, controller: controller).selectedSlide, slides[0].id)

        XCTAssertNil(SongEditorScene.prepare(UUID(), studios: controller), "not a song of the open Studio")
    }

    /// Unmodified Return and arrows typed in the real editor view never reach show control.
    func testReturnAndArrowsInTheRealEditorDoNotTouchTheShow() async throws {
        await launch()
        let row = item("Amazing Grace")
        stage.send(.go(itemID: row.id, slideIndex: 0))
        await until("live") { [self] in stage.state.primaryLive != nil }
        let screens = stage.state.screens
        let (window, _) = host(amazingModel())
        XCTAssertTrue(ShortcutGuard.isEditorWindow(window))
        window.makeFirstResponder(nil)
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        for (chars, code) in [("\r", UInt16(36)), (right, 124), (" ", 49)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            if ShortcutGuard.isGuardedShortcut(event) {
                XCTAssertNil(ShortcutGuard.handle(event, window: window), "swallowed: \(code)")
            }
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(stage.state.screens, screens)
    }
}
