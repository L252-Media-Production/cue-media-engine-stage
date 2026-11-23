import AppKit
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// Cmd-Delete (Clear Slide) and Shift-Cmd-Delete (Clear All) are also text-editing keys. With text focused in a Song
/// editor they edit the text and never clear the show; Black Out and the audio emergency keys still work; the operator
/// window is unchanged. Key presses go through `NSApp.sendEvent` (local monitors, then menu key equivalents) against
/// stand-in menu items that carry the real `Shortcuts` and send the real Commands to the store the outputs come from.
@MainActor
final class EditorTextKeysTests: StudioEditTestCase {
    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run() }
    }

    private var savedMenu: NSMenu?
    private var actions: [MenuAction] = []
    private var sent: [Command] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        ShortcutGuard.install()
        savedMenu = NSApp.mainMenu
    }

    /// Puts the stand-in menu in place. Called right before the key presses: while a test awaits, SwiftUI may put
    /// the app's own menu bar back.
    private func installMenu() {
        actions = []
        let menu = NSMenu(), top = NSMenuItem(title: "Service", action: nil, keyEquivalent: ""), sub = NSMenu(title: "Service")
        let entries: [(String, KeyboardShortcut, Command)] = [
            ("Slide", Shortcuts.clearSlide, .clear(.slide)),
            ("All", Shortcuts.clearAll, .clear(.all)),
            ("Black Out", Shortcuts.blackout, .blackout(true)),
            ("Stop Playback", Shortcuts.audioStop, .stopAudio),
        ]
        for (title, shortcut, command) in entries {
            let action = MenuAction { [unowned self] in sent.append(command); stage.send(command) }
            actions.append(action)
            // The Delete key reports U+007F; a menu item matches it with that key equivalent (SwiftUI's `.delete` is
            // U+0008, which an NSMenuItem does not match against the key).
            let keyEquivalent = shortcut.key == .delete ? "\u{7F}" : String(shortcut.key.character)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: keyEquivalent)
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            item.keyEquivalentModifierMask = mask
            item.target = action
            sub.addItem(item)
        }
        top.submenu = sub
        menu.addItem(top)
        NSApp.mainMenu = menu
    }

    private func press(_ event: NSEvent) {
        installMenu()
        NSApp.sendEvent(event)
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        NSApp.mainMenu = savedMenu
        try await super.tearDown()
    }

    private func window<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1440, height: 860), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.modifier(Themed()))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return window
    }

    private func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    private let delete = "\u{7F}"

    /// A plain AppKit window (no SwiftUI content) for the pass-through checks: they test the guard's decision, and a
    /// hosting view has key handling of its own.
    private func plainWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        return window
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    /// The Song editor on Amazing Grace, Text edit tab, with Amazing Grace's first slide live.
    private func editorWithLiveSlide() async throws -> (SongEditorModel, NSWindow, NSTextView) {
        await launch()
        let row = item("Amazing Grace")
        stage.send(.go(itemID: row.id, slideIndex: 0))
        await until("live") { [self] in stage.state.primaryLive?.itemID == row.id }
        guard case let .song(id) = row.content else { throw XCTSkip("not a song") }
        let model = SongEditorModel(target: SongEditorTarget(studioID: studio.id, songID: id), controller: controller)
        model.centreTab = .text
        let window = window(SongEditorView(model: model) {})
        XCTAssertTrue(ShortcutGuard.isEditorWindow(window))
        let text = try XCTUnwrap(textViews(in: window.contentView!).first { $0.isEditable && $0.string.contains("[Verse 1]") },
                                 "the lyrics text editor")
        XCTAssertTrue(window.makeFirstResponder(text))
        return (model, window, text)
    }

    func testCmdDeleteAndShiftCmdDeleteEditTheLyricsAndNeverClearTheShow() async throws {
        let (model, window, text) = try await editorWithLiveSlide()
        let screens = stage.state.screens
        let firstLine = "Amazing grace, how sweet the sound"
        let start = (text.string as NSString).range(of: firstLine)
        text.setSelectedRange(NSRange(location: NSMaxRange(start), length: 0))

        press(key(delete, 51, .command, in: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(text.string.contains(firstLine), "Cmd-Delete deleted to the start of the line")
        XCTAssertFalse(model.song!.slides[0].lines.contains(firstLine), "and the song followed the text")

        let second = (text.string as NSString).range(of: "That saved a wretch like me")
        text.setSelectedRange(NSRange(location: NSMaxRange(second), length: 0))
        press(key(delete, 51, [.command, .shift], in: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(text.string.contains("That saved a wretch like me"), "Shift-Cmd-Delete edited the text too")

        XCTAssertEqual(sent, [], "no Clear Slide or Clear All was sent")
        await until("the engine has the edit") { [self] in
            stage.state.slides[item("Amazing Grace").id]?.first?.lines.contains(firstLine) == false
        }
        XCTAssertEqual(stage.state.screens, screens, "the audience still sees the slide")
        XCTAssertNotNil(stage.state.primaryLive)
    }

    func testBlackOutAndAudioStopStillWorkFromTheEditor() async throws {
        let (_, window, _) = try await editorWithLiveSlide()
        press(key(".", 47, .command, in: window))
        press(key(".", 47, [.command, .option], in: window))
        XCTAssertEqual(sent, [.blackout(true), .stopAudio], "emergency keys reach the menu from a focused text editor")
        await until("blackout") { [self] in stage.state.blackout }
    }

    func testTheOperatorWindowIsUnchanged() async throws {
        await launch()
        let field = NSTextField(string: "search")
        let window = plainWindow()
        ShortcutGuard.registerOperatorWindow(window)
        field.frame = NSRect(x: 10, y: 10, width: 150, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        press(key(delete, 51, .command, in: window))
        XCTAssertEqual(sent, [.clear(.slide)], "in the operator window Cmd-Delete is Clear Slide, as before")
        XCTAssertEqual(field.stringValue, "search")
    }

    func testOtherWindowsWithoutTextStillGetClearSlide() async throws {
        await launch()
        let window = plainWindow()
        window.makeFirstResponder(nil)
        press(key(delete, 51, .command, in: window))
        XCTAssertEqual(sent, [.clear(.slide)], "only focused text takes the key")
    }

    /// Control for the main test: without the guard's rule the stand-in menu does take Cmd-Delete from a text view.
    func testTheStandInMenuWouldClearWithoutTheGuard() async throws {
        await launch()
        let window = plainWindow()
        let event = key(delete, 51, .command, in: window)
        XCTAssertTrue(ShortcutGuard.isTextCollision(event))
        installMenu()
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: event))
        XCTAssertEqual(sent, [.clear(.slide)])
        XCTAssertTrue(ShortcutGuard.isTextCollision(key(delete, 51, [.command, .shift], in: window)))
        XCTAssertFalse(ShortcutGuard.isTextCollision(key(".", 47, .command, in: window)), "Black Out is not a text key")
        XCTAssertFalse(ShortcutGuard.isTextCollision(key(delete, 51, .option, in: window)), "Option-Delete is no show key")
    }

    func testTheCollisionList() {
        XCTAssertEqual(Shortcuts.textEditingCollisions, [Shortcuts.clearSlide, Shortcuts.clearAll])
        let textKeys: [KeyboardShortcut] = [
            .init(.leftArrow, modifiers: .command), .init(.rightArrow, modifiers: .command),
            .init(.upArrow, modifiers: .command), .init(.downArrow, modifiers: .command),
            .init("a", modifiers: .command), .init("c", modifiers: .command), .init("v", modifiers: .command),
            .init("x", modifiers: .command), .init(.delete, modifiers: .command), .init(.delete, modifiers: [.command, .shift]),
            .init(.delete, modifiers: .option),
        ]
        let show = Shortcuts.all.filter { ![Shortcuts.undo, Shortcuts.redo].contains($0) }
        XCTAssertEqual(show.filter(textKeys.contains), Shortcuts.textEditingCollisions, "every collision is guarded, nothing more")
    }
}
