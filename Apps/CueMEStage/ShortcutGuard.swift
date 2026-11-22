import AppKit
import SwiftUI

/// Keeps the menu bar's unmodified shortcuts (Return, Left and Right arrow; see `Shortcuts.unmodified`) from firing
/// while a text field or text view is being edited, so those keys do what they do in text (move the cursor, end
/// the line).
///
/// How: a local key-down monitor. AppKit hands a key-down to local monitors before it matches menu key
/// equivalents, so when the key window's first responder is text input (an `NSText`: a field editor or a text
/// view) and the key is one of those shortcuts with no Command, Control or Option, the monitor gives the event to
/// that responder's `keyDown` itself and swallows it. Anywhere else the event goes on as normal and the menu fires.
@MainActor
enum ShortcutGuard {
    private static var monitor: Any?

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

    /// True when `event` must go to the text input instead of the menu.
    static func shouldRouteToText(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        guard event.type == .keyDown, isTextInput(firstResponder) else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return guardedKeys.contains(event.charactersIgnoringModifiers ?? "")
    }

    /// The monitor's body: returns the event to let it go on, or nil after giving it to the text input.
    static func handle(_ event: NSEvent, window: NSWindow?) -> NSEvent? {
        guard let responder = window?.firstResponder, shouldRouteToText(event, firstResponder: responder) else { return event }
        responder.keyDown(with: event)
        return nil
    }
}
