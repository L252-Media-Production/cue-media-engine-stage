import AppKit
import SwiftUI

/// Keeps the menu bar's unmodified shortcuts (Return, Left and Right arrow; see `Shortcuts.unmodified`) from firing
/// where they must not:
///
/// 1. While a text field or text view is being edited, so those keys do what they do in text (move the cursor, end
///    the line).
/// 2. In an editor window (the Song editor), always: editing is never show control. Text input gets the key; then
///    the window's own key equivalents; anything else is swallowed, so the menu never sees it.
/// 3. Show shortcuts that are also text-editing keys (`Shortcuts.textEditingCollisions`: Cmd-Delete Clear Slide,
///    Shift-Cmd-Delete Clear All): while a text field or text view has focus in any window but the operator window,
///    the key edits the text (delete to the start of the line) and the menu never sees it. The menu items stay
///    clickable. Black Out and the audio emergency keys are not text keys and work from everywhere.
/// 4. While a sheet or dialog is open (`isModalOpen`, set from `OperatorUIState.isModalOpen`), so nothing is taken
///    live behind the sheet. The monitor never lets these keys go on to the menu then. Inside the sheet they still
///    do two things: a key equivalent of the sheet's own controls (Return on a default button) and typing in a
///    focused text field. Any other use is swallowed: a key a focused view does not use climbs the responder chain
///    and AppKit then offers it to the main menu, so handing it to a non-text view is not safe. A window that has a
///    sheet attached (the operator window behind it) gets nothing.
///
/// How: a local key-down monitor. AppKit hands a key-down to local monitors before it matches menu key
/// equivalents, so the monitor can deliver the event itself and swallow it. Anywhere else the event goes on as
/// normal and the menu fires.
@MainActor
enum ShortcutGuard {
    private static var monitor: Any?

    /// True while any sheet or dialog of the app is open.
    static var isModalOpen = false

    /// Editor windows (weak): show-control keys never act from them.
    private static let editorWindows = NSHashTable<NSWindow>.weakObjects()

    static func registerEditorWindow(_ window: NSWindow) { editorWindows.add(window) }
    static func isEditorWindow(_ window: NSWindow?) -> Bool { window.map(editorWindows.contains) ?? false }

    /// The operator window(s) (weak): there, Cmd-Delete keeps clearing the slide even from a text field, as before.
    private static let operatorWindows = NSHashTable<NSWindow>.weakObjects()

    static func registerOperatorWindow(_ window: NSWindow) { operatorWindows.add(window) }
    static func isOperatorWindow(_ window: NSWindow?) -> Bool { window.map(operatorWindows.contains) ?? false }

    /// The characters a key press of `key` reports. SwiftUI's `.delete` is backspace (U+0008), but the Delete key
    /// reports U+007F; both count.
    static func characters(of key: KeyEquivalent) -> Set<String> {
        key == .delete ? ["\u{8}", "\u{7F}"] : [String(key.character)]
    }

    /// True when `event` is exactly `shortcut` (same key, same Command / Shift / Option / Control).
    static func matches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
        guard event.type == .keyDown, characters(of: shortcut.key).contains(event.charactersIgnoringModifiers ?? "") else { return false }
        var wanted: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { wanted.insert(.command) }
        if shortcut.modifiers.contains(.shift) { wanted.insert(.shift) }
        if shortcut.modifiers.contains(.option) { wanted.insert(.option) }
        if shortcut.modifiers.contains(.control) { wanted.insert(.control) }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]) == wanted
    }

    static func isTextCollision(_ event: NSEvent) -> Bool {
        Shortcuts.textEditingCollisions.contains { matches(event, $0) }
    }

    /// Cmd-Delete's text meaning: delete to the start of the line (or the selection, when there is one). Shift-Cmd-Delete
    /// has no binding of its own in AppKit and gets the same.
    static func deleteToLineStart(in responder: NSResponder, event: NSEvent) {
        if let text = responder as? NSTextView { text.deleteToBeginningOfLine(nil) } else { responder.keyDown(with: event) }
    }

    /// Installs the monitor once per process.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, window: event.window ?? NSApp.keyWindow)
        }
    }

    /// The characters (as AppKit reports them, ignoring modifiers) of the guarded shortcuts.
    static var guardedKeys: Set<String> {
        Set(Shortcuts.unmodified.map { String($0.key.character) })
    }

    static func isTextInput(_ responder: NSResponder?) -> Bool { responder is NSText }

    /// True when `event` is one of the guarded shortcuts: a guarded key without Command, Control or Option.
    static func isGuardedShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return guardedKeys.contains(event.charactersIgnoringModifiers ?? "")
    }

    /// True when `event` must go to the text input instead of the menu.
    static func shouldRouteToText(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        isTextInput(firstResponder) && isGuardedShortcut(event)
    }

    /// The monitor's body: returns the event to let it go on, or nil after delivering or swallowing it.
    static func handle(_ event: NSEvent, window: NSWindow?) -> NSEvent? {
        if let window, !isOperatorWindow(window), isTextCollision(event),
           let responder = window.firstResponder, isTextInput(responder) {
            deleteToLineStart(in: responder, event: event)
            return nil
        }
        if let window, isEditorWindow(window), isGuardedShortcut(event) {
            if let responder = window.firstResponder, isTextInput(responder) {
                responder.keyDown(with: event)
            } else {
                _ = window.performKeyEquivalent(with: event)
            }
            return nil
        }
        if isModalOpen, isGuardedShortcut(event) {
            // The window behind a sheet gets nothing. The sheet gets its own key equivalents, then text input; the
            // menu never sees the key.
            guard let window, window.attachedSheet == nil else { return nil }
            if window.performKeyEquivalent(with: event) { return nil }
            if let responder = window.firstResponder, isTextInput(responder) { responder.keyDown(with: event) }
            return nil
        }
        guard let responder = window?.firstResponder, shouldRouteToText(event, firstResponder: responder) else { return event }
        responder.keyDown(with: event)
        return nil
    }
}

/// Tells `ShortcutGuard` what kind of window a view is in: put it in the background of a window's root view.
struct ShortcutGuardWindowMarker: NSViewRepresentable {
    enum Role { case `operator`, editor }
    let role: Role

    func makeNSView(context: Context) -> NSView { MarkerView(role: role) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MarkerView: NSView {
        let role: Role
        init(role: Role) {
            self.role = role
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            switch role {
            case .operator: ShortcutGuard.registerOperatorWindow(window)
            case .editor: ShortcutGuard.registerEditorWindow(window)
            }
        }
    }
}
