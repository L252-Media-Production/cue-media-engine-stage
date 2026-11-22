import Darwin
import Foundation

/// Gives a thread the macOS "time constraint" (real-time) scheduling class, so a tick that was due every
/// 16.7 ms is woken on time instead of waiting behind ordinary work. Opt-in (`--realtime`) so its effect
/// on the render-loop late-frame count can be compared directly.
public enum RealtimeThread {
    public nonisolated(unsafe) static var enabled = false
    private nonisolated(unsafe) static var activity: NSObjectProtocol?

    /// Call once at the start of the thread to promote. Does nothing unless `enabled`.
    public static func promoteCurrentThread(periodMs: Double = 16.667, computationMs: Double = 4, constraintMs: Double = 10) {
        guard enabled else { return }
        if activity == nil {
            // Keep the process out of App Nap and timer coalescing while it runs.
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "StageEngine render loop")
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func absolute(_ ms: Double) -> UInt32 {
            UInt32(ms * 1_000_000.0 * Double(timebase.denom) / Double(timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(period: absolute(periodMs),
                                                          computation: absolute(computationMs),
                                                          constraint: absolute(constraintMs),
                                                          preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        if result != KERN_SUCCESS { print("note: real-time scheduling was refused (\(result))") }
    }
}
