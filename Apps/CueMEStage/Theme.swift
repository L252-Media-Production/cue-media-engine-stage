import AppKit
import SwiftUI

/// Colour, spacing and type tokens. Views use these instead of literal colours so dark and light stay in step.
///
/// The colours are the mockup's (docs/mockups, `Main.dc.html` `renderVals()` `vars`, L843 light and L844 dark).
/// Mockup variable → token: `--bg` background, `--chrome` surface (panels, bars), `--panel` surfaceRaised (controls,
/// headers, cards), `--line` border, `--fg` textPrimary, `--dim` textSecondary, `--accent` accent, `--live` live,
/// `--next` preview, `--ok` ok, `--warn` warning, `--sel` selection. The mockup has no separate danger colour; danger
/// uses `--live`.
struct ThemeTokens {
    var background: Color
    var surface: Color
    var surfaceRaised: Color
    var border: Color
    var textPrimary: Color
    var textSecondary: Color
    var accent: Color
    /// Program / on-air.
    var live: Color
    /// Preview / next.
    var preview: Color
    var ok: Color
    var warning: Color
    var danger: Color
    /// A selected row's tint (`--sel`).
    var selection: Color
    /// Text on an accent fill (Next, Play, Show): `onAccent` in `Main.dc.html` L948.
    var onAccent: Color
    /// Text on an amber fill (Black while on): `#111` in `Main.dc.html` L979, both themes.
    var onWarning: Color
    /// Text on a live-red fill (the LIVE chip): `#fff` in `Main.dc.html` L85, both themes.
    var onLive: Color
    /// A slide picture's placeholder background, top-left to bottom-right (`linear-gradient(135deg,#1c3a5e,#0d1b2e)`,
    /// `Main.dc.html` L123), both themes. Real slides will show their own background.
    var slideGradient: [Color] = [Color(hex: 0x1C3A5E), Color(hex: 0x0D1B2E)]
    /// Slide text on that background (`#fff`, L123).
    var slideText: Color = Color(hex: 0xFFFFFF)
    /// Text on a song group's colour (`#fff`, SongEditor.dc.html group headers), both themes.
    var onGroup: Color = Color(hex: 0xFFFFFF)
    /// Behind the Song editor's slide canvas (SongEditor.dc.html `stageBg`).
    var editorStage: Color = Color(hex: 0x4A4A4C)

    /// `Main.dc.html` L844.
    static let dark = ThemeTokens(
        background: Color(hex: 0x161616),    // --bg
        surface: Color(hex: 0x202020),       // --chrome
        surfaceRaised: Color(hex: 0x2B2B2B), // --panel
        border: Color(hex: 0x3A3A3A),        // --line
        textPrimary: Color(hex: 0xF5F5F5),   // --fg
        textSecondary: Color(hex: 0xA8A8A8), // --dim
        accent: Color(hex: 0x47C86E),        // --accent
        live: Color(hex: 0xE5483F),          // --live
        preview: Color(hex: 0x4DA3FF),       // --next
        ok: Color(hex: 0x47C86E),            // --ok
        warning: Color(hex: 0xFFB020),       // --warn
        danger: Color(hex: 0xE5483F),        // --live
        selection: Color(hex: 0x1F3A29),     // --sel
        onAccent: Color(hex: 0x0D0D0D),
        onWarning: Color(hex: 0x111111),
        onLive: Color(hex: 0xFFFFFF)
    )

    /// `Main.dc.html` L843; `editorStage` from SongEditor.dc.html. (`QuitDialog.dc.html` L37 has slightly different light --warn and --live; Main wins.)
    static let light = ThemeTokens(
        background: Color(hex: 0xF3F3F1),    // --bg
        surface: Color(hex: 0xE8E8E5),       // --chrome
        surfaceRaised: Color(hex: 0xFFFFFF), // --panel
        border: Color(hex: 0xCFCFCA),        // --line
        textPrimary: Color(hex: 0x1A1A1A),   // --fg
        textSecondary: Color(hex: 0x555555), // --dim
        accent: Color(hex: 0x17803C),        // --accent
        live: Color(hex: 0xC4231C),          // --live
        preview: Color(hex: 0x0A6BD6),       // --next
        ok: Color(hex: 0x17803C),            // --ok
        warning: Color(hex: 0xA85A00),       // --warn
        danger: Color(hex: 0xC4231C),        // --live
        selection: Color(hex: 0xD6EEDE),     // --sel
        onAccent: Color(hex: 0xFFFFFF),
        onWarning: Color(hex: 0x111111),
        onLive: Color(hex: 0xFFFFFF),
        editorStage: Color(hex: 0x9A9A96)
    )

    static func `for`(_ scheme: ColorScheme) -> ThemeTokens { scheme == .dark ? .dark : .light }

    // Spacing and shape.
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 20
    static let radius: CGFloat = 6

    /// The mockup's section label (`label`, Main.dc.html L845): mono 11, weight 600, letter-spacing .06em.
    static let labelTracking: CGFloat = 0.66

    // Type.
    static let monoPostScriptName = "JetBrainsMono-Regular"

    /// JetBrains Mono is bundled (Resources/Fonts) and registered for this process before the first check, so this is
    /// true in a normal build; the system monospaced font is the fallback if the files are missing.
    static let hasJetBrainsMono: Bool = {
        BundledFonts.registerOnce()
        return NSFont(name: monoPostScriptName, size: 12) != nil
    }()

    /// Monospaced type for timecodes, counters and levels.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        hasJetBrainsMono
            ? .custom(monoPostScriptName, size: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }
}

extension AppTheme {
    /// What `NSApp.appearance` is set to: nil for Auto (the system appearance applies), Dark Aqua, or Aqua.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .auto: nil
        case .dark: .darkAqua
        case .light: .aqua
        }
    }
}

/// Applies View > Theme to the whole app through `NSApp.appearance`, so every window, sheet, alert and menu follows,
/// and Auto (nil) tracks the system live.
@MainActor
enum ThemeAppearance {
    /// The theme applied at launch (nil before `applyStored` ran). For tests.
    private(set) static var launchTheme: AppTheme?
    private static var observer: NSObjectProtocol?

    static func apply(_ theme: AppTheme, to app: NSApplication = .shared) {
        let name = theme.appearanceName
        guard app.appearance?.name != name else { return }
        app.appearance = name.flatMap(NSAppearance.init(named:))
    }

    /// Reads the stored theme (fallback Dark) and applies it. Returns what it applied.
    @discardableResult
    static func applyStored(from defaults: UserDefaults = .standard, to app: NSApplication = .shared) -> AppTheme {
        let theme = AppTheme.resolve(defaults.string(forKey: StorageKeys.theme) ?? AppTheme.fallback.rawValue)
        apply(theme, to: app)
        if launchTheme == nil { launchTheme = theme }
        return theme
    }

    /// Re-applies the stored theme whenever the defaults change (View > Theme writes the key through @AppStorage).
    /// The key has dots, so KVO on it is not an option; `apply` is a no-op when nothing changed.
    static func startFollowingDefaults(_ defaults: UserDefaults = .standard) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = applyStored(from: defaults) }
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.dark
}

extension EnvironmentValues {
    var theme: ThemeTokens {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Puts the tokens for the current colour scheme into the environment.
struct Themed: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let tokens = ThemeTokens.for(scheme)
        // The accent also tints SwiftUI controls (toggles, prominent buttons, focus) instead of the system blue.
        content.environment(\.theme, tokens).tint(tokens.accent)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
