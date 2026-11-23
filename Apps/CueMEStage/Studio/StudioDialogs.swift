import AppKit
import StageKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared once, in Info.plist (UTExportedTypeDeclarations); see project.yml.
    static let cuemeStudio = UTType(exportedAs: "com.l252mp.cuemestage.studio", conformingTo: .package)
    static let cuemeStudioBundle = UTType(exportedAs: "com.l252mp.cuemestage.studio-bundle", conformingTo: .zip)
    static let cuemeItems = UTType(exportedAs: "com.l252mp.cuemestage.item", conformingTo: .json)
}

/// What is live, in one line, for the switching warning: "Left and Stage showing slides; audio playing".
/// nil when nothing is live (then there is no warning).
enum LiveSummary {
    static func text(_ state: StageState) -> String? {
        var parts: [String] = []
        let showing = state.outputScreens.filter { $0.live != nil }.map(\.name)
        if !showing.isEmpty { parts.append("\(joined(showing)) showing slides") }
        if !state.visibleMessages.isEmpty { parts.append(state.visibleMessages.count == 1 ? "a message showing" : "\(state.visibleMessages.count) messages showing") }
        switch state.audio.transport {
        case .playing: parts.append("audio playing")
        case .paused: parts.append("audio paused")
        case .fading: parts.append("audio fading out")
        case .stopped: break
        }
        if state.testPattern != nil { parts.append("a test pattern running") }
        if !state.runningTimers.isEmpty { parts.append("a timer running") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

enum LockChoice: Equatable { case cancel, openAnyway, openCopy }
enum BundleImportChoice: Equatable { case cancel, openAsNew, replaceCurrent }

/// Every question the Studio controller asks. The AppKit version shows alerts and panels; tests answer directly.
@MainActor
protocol StudioDialogs {
    /// True = switch anyway. Asked only when something is live.
    func confirmSwitch(live: String, action: String) -> Bool
    func lockChoice(message: String) -> LockChoice
    func bundleImportChoice(name: String) -> BundleImportChoice
    /// The choice for one clash, and whether to use it for the rest.
    func clashChoice(for item: StudioItemPayload, remaining: Int) -> (ItemClashChoice, forAll: Bool)
    func chooseFile(title: String, types: [UTType], directory: URL?) -> URL?
    func chooseFolder(title: String) -> URL?
    func chooseSave(title: String, name: String, type: UTType, directory: URL?) -> URL?
    func showError(_ title: String, _ error: Error)
}

/// Alerts built in one place so tests can check their buttons. The first button is the default (Return).
///
/// NSAlert gives any button titled "Cancel" the Escape key, even the first one, so where Cancel must be the default
/// its key is set to Return explicitly (Escape then does nothing in that alert).
enum StudioAlerts {
    private static func makeCancelDefault(_ alert: NSAlert) {
        alert.buttons.first?.keyEquivalent = "\r"
    }

    static func switchWarning(live: String, action: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action) while something is live?"
        alert.informativeText = "Live now: \(live). \(action) stops it on every output."
        alert.addButton(withTitle: "Cancel")          // default: Return does nothing harmful
        alert.addButton(withTitle: action)
        makeCancelDefault(alert)
        return alert
    }

    static func lockWarning(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This Studio is already open"
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")          // default
        alert.addButton(withTitle: "Open Anyway")
        alert.addButton(withTitle: "Open a Copy")
        makeCancelDefault(alert)
        return alert
    }

    static func bundleImport(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Import “\(name)”"
        alert.informativeText = "Open it as a new Studio, or replace the content of the Studio that is open now?"
        alert.addButton(withTitle: "Open as New Studio") // default
        alert.addButton(withTitle: "Replace Current Studio")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func clash(_ item: StudioItemPayload, remaining: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(item.name)” is already in this Studio"
        alert.informativeText = "The imported \(item.kind) has the same id as one in the Studio."
        alert.addButton(withTitle: "Skip")            // default: nothing is lost
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        if remaining > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do the same for the other \(remaining) clash\(remaining == 1 ? "" : "es")"
        }
        return alert
    }
}

/// Runs AppKit modals with the modal shortcut guard on, so Return and the arrows cannot take anything live behind them.
@MainActor
enum ModalRunner {
    static func run<T>(_ body: () -> T) -> T {
        let was = ShortcutGuard.isModalOpen
        ShortcutGuard.isModalOpen = true
        defer { ShortcutGuard.isModalOpen = was }
        return body()
    }
}

@MainActor
struct AppKitStudioDialogs: StudioDialogs {
    func confirmSwitch(live: String, action: String) -> Bool {
        ModalRunner.run { StudioAlerts.switchWarning(live: live, action: action).runModal() == .alertSecondButtonReturn }
    }

    func lockChoice(message: String) -> LockChoice {
        switch ModalRunner.run({ StudioAlerts.lockWarning(message).runModal() }) {
        case .alertSecondButtonReturn: .openAnyway
        case .alertThirdButtonReturn: .openCopy
        default: .cancel
        }
    }

    func bundleImportChoice(name: String) -> BundleImportChoice {
        switch ModalRunner.run({ StudioAlerts.bundleImport(name: name).runModal() }) {
        case .alertFirstButtonReturn: .openAsNew
        case .alertSecondButtonReturn: .replaceCurrent
        default: .cancel
        }
    }

    func clashChoice(for item: StudioItemPayload, remaining: Int) -> (ItemClashChoice, forAll: Bool) {
        let alert = StudioAlerts.clash(item, remaining: remaining)
        let response = ModalRunner.run { alert.runModal() }
        let choice: ItemClashChoice = switch response {
        case .alertSecondButtonReturn: .replace
        case .alertThirdButtonReturn: .keepBoth
        default: .skip
        }
        return (choice, alert.suppressionButton?.state == .on)
    }

    func chooseFile(title: String, types: [UTType], directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = directory
        return ModalRunner.run { panel.runModal() == .OK ? panel.url : nil }
    }

    func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return ModalRunner.run { panel.runModal() == .OK ? panel.url : nil }
    }

    func chooseSave(title: String, name: String, type: UTType, directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        return ModalRunner.run { panel.runModal() == .OK ? panel.url : nil }
    }

    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        ModalRunner.run { _ = alert.runModal() }
    }
}
