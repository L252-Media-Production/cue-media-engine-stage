import AppKit
import SwiftUI
import XCTest
@testable import CueMEStage

/// Proves the unmodified shortcuts do not fire while text input has focus. The events go through
/// `NSApp.sendEvent` (the path a real key press takes, local monitors and menu key equivalents included), against
/// a stand-in main menu whose item has the same key equivalent as Service > Next Slide.
@MainActor
final class ShortcutGuardTests: XCTestCase {
    private final class Counter: NSObject {
        var count = 0
        @objc func fire(_ sender: Any?) { count += 1 }
    }

    private final class PlainView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Records the key presses that reach it (a control inside a sheet).
    private final class KeyView: NSView {
        var keys: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.charactersIgnoringModifiers ?? "") }
    }

    private var savedMenu: NSMenu?
    private var window: NSWindow!
    private let counter = Counter()
    private let goLive = Counter()

    private let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    override func setUp() async throws {
        ShortcutGuard.install() // the app already did; installing again is a no-op
        savedMenu = NSApp.mainMenu
        let menu = NSMenu()
        let top = NSMenuItem(title: "Service", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Service")
        let next = NSMenuItem(title: "Next Slide", action: #selector(Counter.fire(_:)), keyEquivalent: rightArrow)
        next.keyEquivalentModifierMask = []
        next.target = counter
        sub.addItem(next)
        let go = NSMenuItem(title: "Go Live", action: #selector(Counter.fire(_:)), keyEquivalent: "\r")
        go.keyEquivalentModifierMask = []
        go.target = goLive
        sub.addItem(go)
        top.submenu = sub
        menu.addItem(top)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
        ShortcutGuard.isModalOpen = false
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        NSApp.mainMenu = savedMenu
    }

    private func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: Editor windows

    /// In a Song editor window, Return and the arrows never reach show control, even with no text field focused.
    func testInAnEditorWindowShowKeysNeverReachTheMenu() {
        ShortcutGuard.registerEditorWindow(window)
        let keys = KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(keys)
        XCTAssertTrue(window.makeFirstResponder(keys))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        XCTAssertEqual(counter.count, 0, "Next Slide did not fire")
        XCTAssertEqual(goLive.count, 0, "Go Live did not fire")
    }

    func testInAnEditorWindowTextStillGetsReturnAndArrows() {
        ShortcutGuard.registerEditorWindow(window)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "ab"
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        NSApp.sendEvent(keyDown(" ", keyCode: 49))
        XCTAssertEqual(textView.string, "a\n b", "the arrow moved, Return broke the line, space typed a space")
        XCTAssertEqual(counter.count + goLive.count, 0, "nothing reached show control")
    }

    func testAWindowThatIsNotAnEditorStillGetsTheMenu() {
        XCTAssertFalse(ShortcutGuard.isEditorWindow(window))
        XCTAssertFalse(ShortcutGuard.isEditorWindow(nil))
        let plain = PlainView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(plain)
        XCTAssertTrue(window.makeFirstResponder(plain))
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        XCTAssertEqual(goLive.count, 1)
    }

    /// The real Song editor view marks the window it is in as an editor window.
    func testTheSongEditorMarksItsWindow() {
        let delegate = AppDelegate()
        defer { delegate.studios.shutdown() }
        let target = SongEditorTarget(studioID: UUID(), songID: UUID())
        let view = SongEditorView(model: delegate.editors.model(for: target, controller: delegate.studios)) {}
            .modifier(Themed())
        window.contentView = NSHostingView(rootView: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(ShortcutGuard.isEditorWindow(window))
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        XCTAssertEqual(goLive.count, 0)
    }

    func testArrowFiresTheMenuWhenNoTextHasFocus() {
        let plain = PlainView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(plain)
        XCTAssertTrue(window.makeFirstResponder(plain))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(counter.count, 1, "control: the stand-in menu item takes the unmodified arrow")
    }

    func testArrowMovesTheCursorInATextFieldAndDoesNotFireTheMenu() throws {
        let field = NSTextField(string: "abcdef")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field editor has focus")
        XCTAssertTrue(ShortcutGuard.isTextInput(editor))
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(counter.count, 0, "the menu did not fire")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "the cursor moved two characters")

        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        NSApp.sendEvent(keyDown(left, keyCode: 123))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testTextViewIsGuardedToo() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        textView.string = "line one"
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(textView.selectedRange().location, 1)
    }

    /// A SwiftUI TextField with the app's own SwiftUI menu bar in place (Service > Next Slide on the bare Right
    /// arrow): the arrow moves the cursor.
    func testSwiftUITextFieldWithTheRealMenuBar() throws {
        NSApp.mainMenu = savedMenu
        let host = NSHostingView(rootView: TextField("Text", text: .constant("abcdef")).frame(width: 300))
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let field = try XCTUnwrap(firstTextField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }

    // MARK: While a sheet is open

    func testRightArrowDoesNotReachTheMenuWhileModal() {
        // A focused view that does not use the arrow: normally the key climbs the responder chain to the menu.
        let plain = PlainView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(plain)
        XCTAssertTrue(window.makeFirstResponder(plain))

        ShortcutGuard.isModalOpen = true
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        XCTAssertEqual(counter.count, 0, "Next Slide (.next) did not fire")
        XCTAssertEqual(goLive.count, 0, "Go Live did not fire")

        // A view that would use the arrow does not get it either (only text input and key equivalents do).
        let control = KeyView(frame: NSRect(x: 60, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(control)
        XCTAssertTrue(window.makeFirstResponder(control))
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(control.keys, [])
        XCTAssertEqual(counter.count, 0)

        ShortcutGuard.isModalOpen = false
        XCTAssertTrue(window.makeFirstResponder(plain))
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(counter.count, 1, "control: back to normal once the sheet closes")
    }

    func testArrowsStillMoveTheCursorInASheetsTextField() throws {
        let field = NSTextField(string: "abcdef")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        ShortcutGuard.isModalOpen = true
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        NSApp.sendEvent(keyDown(rightArrow, keyCode: 124))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(counter.count, 0)
    }

    func testReturnStillPressesTheSheetsDefaultButton() {
        let button = NSButton(title: "Done", target: counter, action: #selector(Counter.fire(_:)))
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 10, y: 10, width: 80, height: 30)
        window.contentView?.addSubview(button)
        let pressed = counter.count

        ShortcutGuard.isModalOpen = true
        NSApp.sendEvent(keyDown("\r", keyCode: 36))
        XCTAssertEqual(counter.count, pressed + 1, "the window's own Return button")
        XCTAssertEqual(goLive.count, 0, "not the menu's Go Live")
    }

    func testWindowBehindASheetGetsNothing() {
        let behind = KeyView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(behind)
        XCTAssertTrue(window.makeFirstResponder(behind))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(window.attachedSheet)

        ShortcutGuard.isModalOpen = true
        XCTAssertNil(ShortcutGuard.handle(keyDown(rightArrow, keyCode: 124), window: window))
        XCTAssertEqual(behind.keys, [], "the service list behind the sheet gets nothing")
        XCTAssertEqual(counter.count, 0)
        XCTAssertNotNil(ShortcutGuard.handle(keyDown(".", keyCode: 47, modifiers: .command), window: window),
                       "Cmd-. (Black Out) is not guarded and goes on to the menu")
    }

    func testRoutingRule() {
        let text = NSTextView()
        let plain = PlainView()
        XCTAssertTrue(ShortcutGuard.shouldRouteToText(keyDown(rightArrow, keyCode: 124), firstResponder: text))
        XCTAssertTrue(ShortcutGuard.shouldRouteToText(keyDown("\r", keyCode: 36), firstResponder: text), "Return (Go Live)")
        XCTAssertTrue(ShortcutGuard.shouldRouteToText(keyDown(rightArrow, keyCode: 124, modifiers: .shift), firstResponder: text),
                      "Shift-arrow extends the selection")
        XCTAssertFalse(ShortcutGuard.shouldRouteToText(keyDown(rightArrow, keyCode: 124), firstResponder: plain), "not text")
        XCTAssertFalse(ShortcutGuard.shouldRouteToText(keyDown(".", keyCode: 47, modifiers: .command), firstResponder: text),
                       "Cmd shortcuts still work while typing")
        XCTAssertFalse(ShortcutGuard.shouldRouteToText(keyDown("a", keyCode: 0), firstResponder: text), "not a shortcut key")
        XCTAssertEqual(ShortcutGuard.guardedKeys, ["\r", rightArrow, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))])
    }
}
