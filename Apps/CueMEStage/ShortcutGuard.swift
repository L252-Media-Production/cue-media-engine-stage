import AppKit
import SwiftUI

/// Keeps the menu bar's unmodified shortcuts (Return, Left and Right arrow; see `Shortcuts.unmodified`) from firing
/// where they must not:
///
/// 1. While a text field or text view is being edited, so those keys do what they do in text (move the cursor, end
///    the line).
/// 2. In an editor window (the Song editor), always: editing is never show control. Text input gets the key; then
///    the window's own key equivalents; anything else is swallowed, so the menu never sees it.
/// 3. While a sheet or dialog is open (`isModalOpen`, set from `OperatorUIState.isModalOpen`), so nothing is taken
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
