import AppKit
import SwiftUI

/// Colour, spacing and type tokens. Views use these instead of literal colours so dark and light stay in step.
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

    static let dark = ThemeTokens(
        background: Color(hex: 0x111214),
        surface: Color(hex: 0x1A1C1F),
        surfaceRaised: Color(hex: 0x24272B),
        border: Color(hex: 0x33373D),
        textPrimary: Color(hex: 0xECEDEE),
        textSecondary: Color(hex: 0x9BA1A8),
        accent: Color(hex: 0x4C9EFF),
        live: Color(hex: 0xFF453A),
        preview: Color(hex: 0x30D158),
        ok: Color(hex: 0x30D158),
        warning: Color(hex: 0xFFD60A),
        danger: Color(hex: 0xFF453A)
    )

    static let light = ThemeTokens(
        background: Color(hex: 0xF4F5F7),
        surface: Color(hex: 0xFFFFFF),
        surfaceRaised: Color(hex: 0xECEEF1),
        border: Color(hex: 0xD5D9DE),
        textPrimary: Color(hex: 0x16181B),
        textSecondary: Color(hex: 0x5D646C),
        accent: Color(hex: 0x0A66D8),
        live: Color(hex: 0xD70015),
        preview: Color(hex: 0x248A3D),
        ok: Color(hex: 0x248A3D),
        warning: Color(hex: 0xB25000),
        danger: Color(hex: 0xD70015)
    )

    static func `for`(_ scheme: ColorScheme) -> ThemeTokens { scheme == .dark ? .dark : .light }

    // Spacing and shape.
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 20
    static let radius: CGFloat = 6

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
        content.environment(\.theme, .for(scheme))
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
