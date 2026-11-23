import AppKit
import SwiftUI
import XCTest
@testable import CueMEStage

@MainActor
final class ThemeAppearanceTests: XCTestCase {
    private var saved: NSAppearance?
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        saved = NSApp.appearance
        suite = "cueme.tests.theme.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        NSApp.appearance = saved
        defaults.removePersistentDomain(forName: suite)
    }

    func testMappingToNSAppearance() {
        XCTAssertNil(AppTheme.auto.appearanceName, "Auto sets nothing, so the system appearance applies")
        XCTAssertEqual(AppTheme.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppTheme.light.appearanceName, .aqua)
    }

    func testApplySetsTheAppAppearance() {
        ThemeAppearance.apply(.light)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertEqual(NSApp.effectiveAppearance.name, .aqua)
        ThemeAppearance.apply(.dark)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        XCTAssertEqual(NSApp.effectiveAppearance.name, .darkAqua)
        ThemeAppearance.apply(.auto)
        XCTAssertNil(NSApp.appearance, "Auto clears the forced appearance")
    }

    func testAppliesTheStoredValue() {
        XCTAssertEqual(ThemeAppearance.applyStored(from: defaults), .dark, "nothing stored: Dark")
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)

        defaults.set("auto", forKey: StorageKeys.theme)
        XCTAssertEqual(ThemeAppearance.applyStored(from: defaults), .auto)
        XCTAssertNil(NSApp.appearance)

        defaults.set("light", forKey: StorageKeys.theme)
        XCTAssertEqual(ThemeAppearance.applyStored(from: defaults), .light)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)

        defaults.set("sepia", forKey: StorageKeys.theme)
        XCTAssertEqual(ThemeAppearance.applyStored(from: defaults), .dark, "unknown: Dark")
    }

    /// The test host is the app: its init applied the stored theme before any window.
    func testTheAppAppliedTheStoredThemeAtLaunch() {
        let stored = AppTheme.resolve(UserDefaults.standard.string(forKey: StorageKeys.theme) ?? AppTheme.fallback.rawValue)
        XCTAssertEqual(ThemeAppearance.launchTheme, stored)
    }

    /// Records the colour scheme `Themed` sees (the scheme the environment gives the view).
    private final class SchemeBox { var scheme: ColorScheme? }
    private struct Probe: View {
        let box: SchemeBox
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            Color.clear.frame(width: 40, height: 40)
                .onChange(of: scheme, initial: true) { _, new in box.scheme = new }
        }
    }

    private func hosting(_ box: SchemeBox) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Probe(box: box))
        return window
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

    /// What Auto must resolve to: the system appearance right now.
    private var systemScheme: ColorScheme {
        let saved = NSApp.appearance
        NSApp.appearance = nil
        defer { NSApp.appearance = saved }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// Dark -> Auto, Light -> Auto and Auto -> Dark / Light, in an open window and in a sheet attached to it.
    /// (Auto while macOS itself switches cannot be driven from a test; with NSApp.appearance nil the windows'
    /// effective appearance is the system's, which is the path checked here.)
    func testOpenWindowAndSheetFollowEveryChange() {
        let system = systemScheme
        let windowBox = SchemeBox(), sheetBox = SchemeBox()
        let window = hosting(windowBox), sheet = hosting(sheetBox)
        window.makeKeyAndOrderFront(nil)
        window.beginSheet(sheet)
        defer { window.endSheet(sheet); window.orderOut(nil) }

        let steps: [(AppTheme, ColorScheme)] = [
            (.dark, .dark), (.auto, system), (.light, .light), (.auto, system), (.dark, .dark), (.light, .light), (.dark, .dark),
        ]
        for (theme, expected) in steps {
            ThemeAppearance.apply(theme)
            settle()
            XCTAssertEqual(windowBox.scheme, expected, "window after \(theme)")
            XCTAssertEqual(sheetBox.scheme, expected, "sheet after \(theme)")
        }
    }

    /// The menu writes the key through @AppStorage; the app follows the change.
    func testFollowsAChangeOfTheStoredValue() {
        ThemeAppearance.startFollowingDefaults() // already done by the app; a no-op here
        let key = StorageKeys.theme
        let before = UserDefaults.standard.string(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        UserDefaults.standard.set("light", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        UserDefaults.standard.set("auto", forKey: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(NSApp.appearance)
    }
}
