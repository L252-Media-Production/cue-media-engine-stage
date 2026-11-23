import Darwin
import Foundation
import os

/// Launch timing: os_signpost intervals (visible in Instruments) and, with CUEME_LAUNCH_TIMING=1 in the environment,
/// one line per step on stderr ("launch: <step> <ms>"), measured from process start.
enum LaunchTiming {
    static let enabled = ProcessInfo.processInfo.environment["CUEME_LAUNCH_TIMING"] == "1"
    private static let signposter = OSSignposter(subsystem: "com.l252mp.cuemestage", category: "launch")
    nonisolated(unsafe) private static var firstWindowMarked = false

    /// When the kernel started this process.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }()

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now()
        defer {
            signposter.endInterval(name, state)
            if enabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                FileHandle.standardError.write(Data(String(format: "launch: %@ %.1f ms\n", "\(name)", ms).utf8))
            }
        }
        return try body()
    }

    /// A point in time, measured from process start.
    static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        guard enabled else { return }
        let ms = Date().timeIntervalSince(processStart) * 1000
        FileHandle.standardError.write(Data(String(format: "launch: %@ at %.1f ms after process start\n", "\(name)", ms).utf8))
    }

    /// The first window's content appeared.
    static func markFirstWindow() {
        guard !firstWindowMarked else { return }
        firstWindowMarked = true
        mark("first window")
    }
}
