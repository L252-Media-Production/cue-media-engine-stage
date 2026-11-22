import CoreText
import Foundation

/// Registers the fonts shipped in the app bundle (Resources/Fonts, JetBrains Mono under the OFL; the licence text
/// sits next to them) for this process only. Nothing is downloaded and nothing is installed system-wide.
enum BundledFonts {
    /// Folder of the bundle's resources that holds the .ttf files.
    static let subdirectory = "Fonts"

    /// Registers every bundled font once per process. Safe to call from anywhere and more than once; `ThemeTokens`
    /// calls it before it first checks for JetBrains Mono, so the order of launch code does not matter.
    @discardableResult
    static func registerOnce() -> [URL] { registered }

    private static let registered: [URL] = register(in: .main)

    /// Registers the fonts in `bundle` and returns the files that are now available (newly registered or already
    /// registered earlier in this process).
    static func register(in bundle: Bundle) -> [URL] {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: subdirectory) ?? []
        return urls.filter { url in
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            let cfError = error?.takeRetainedValue()
            if let cfError, CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue { return true }
            NSLog("CueME Stage: could not register font %@: %@", url.lastPathComponent, String(describing: cfError))
            return false
        }
    }
}
