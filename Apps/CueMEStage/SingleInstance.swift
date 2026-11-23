import AppKit
import Foundation

/// Only one CueME Stage runs at a time: a second launch brings the running copy forward and quits at once, before any
/// window, Studio or lock file is touched. Skipped in the XCTest host and with CUEME_ALLOW_MULTIPLE=1.
enum SingleInstance {
    enum Decision: Equatable {
        /// Carry on launching.
        case proceed
        /// Another copy runs: activate it and quit this one.
        case handOff(to: pid_t)
    }

    /// One running process with this bundle id, as `NSRunningApplication` reports it.
    struct Copy: Equatable {
        var pid: pid_t
        var launchDate: Date?
        var isTerminated = false
    }

    static let allowMultipleKey = "CUEME_ALLOW_MULTIPLE"
    static let testHostKey = "XCTestConfigurationFilePath"

    /// The decision for this process. `running` may include this process; it is left out, as are copies that are
    /// already terminating. With several others, the oldest wins.
    static func decide(running: [Copy], current: pid_t, environment: [String: String]) -> Decision {
        if environment[testHostKey] != nil { return .proceed }
        if environment[allowMultipleKey] == "1" { return .proceed }
        let others = running.filter { $0.pid != current && !$0.isTerminated }
        guard let oldest = others.min(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else {
            return .proceed
        }
        return .handOff(to: oldest.pid)
    }

    /// At launch: if another copy runs, bring it forward and end this process without a window, a dialog or any
    /// Studio work (`exit`, not `NSApp.terminate`, so no quit dialog and no `applicationWillTerminate`).
    static func enforce() {
        let decision = LaunchTiming.measure("SingleInstance.check") { () -> Decision in
            let info = ProcessInfo.processInfo
            guard info.environment[testHostKey] == nil, info.environment[allowMultipleKey] != "1",
                  let id = Bundle.main.bundleIdentifier else { return .proceed }
            let copies = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .map { Copy(pid: $0.processIdentifier, launchDate: $0.launchDate, isTerminated: $0.isTerminated) }
            return decide(running: copies, current: info.processIdentifier, environment: info.environment)
        }
        guard case let .handOff(pid) = decision, let other = NSRunningApplication(processIdentifier: pid) else { return }
        activate(other)
        exit(0)
    }

    /// Brings the running copy forward. A process that is still launching is not active yet, so macOS (14+) may
    /// ignore its `activate()` call on another app without saying so. LaunchServices is asked instead: opening an app
    /// that already runs brings that copy forward rather than starting another. Waits at most one second.
    private static func activate(_ other: NSRunningApplication) {
        guard let url = other.bundleURL else {
            other.activate()
            return
        }
        let done = DispatchSemaphore(value: 0)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
        other.activate()
    }
}
