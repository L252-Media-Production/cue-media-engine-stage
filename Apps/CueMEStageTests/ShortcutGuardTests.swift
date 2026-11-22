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

    private var savedMenu: NSMenu?
    private var window: NSWindow!
    private let counter = Counter()

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
        top.submenu = sub
        menu.addItem(top)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
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
