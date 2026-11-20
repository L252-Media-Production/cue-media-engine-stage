import Foundation

/// Summary of frame-to-frame timing over a run.
public struct FrameTimingSummary: Sendable, Equatable, CustomStringConvertible {
    public var frames: Int
    public var targetMs: Double
    public var meanMs: Double
    public var p99Ms: Double
    public var maxMs: Double
    /// Frames whose interval exceeded the late threshold (1.5x the target).
    public var lateFrames: Int

    public var description: String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        return "frames=\(frames) target=\(f(targetMs))ms mean=\(f(meanMs))ms "
            + "p99=\(f(p99Ms))ms max=\(f(maxMs))ms late=\(lateFrames)"
    }
}

/// Records the time between frames so we can see jitter and late frames.
/// Thread-safe: `recordFrame` may be called from a render or output callback.
public final class FrameTimingLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let targetMs: Double
    private let lateThresholdMs: Double
    private var intervalsMs: [Double] = []
    private var lastNanos: UInt64?

    public init(targetFPS: Double) {
        precondition(targetFPS > 0, "targetFPS must be positive")
        self.targetMs = 1000.0 / targetFPS
        self.lateThresholdMs = targetMs * 1.5
    }

    /// Call once per frame. `nanos` defaults to the current monotonic time.
    public func recordFrame(at nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastNanos {
            intervalsMs.append(Double(nanos &- last) / 1_000_000.0)
        }
        lastNanos = nanos
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        intervalsMs.removeAll(keepingCapacity: true)
        lastNanos = nil
    }

    public func summary() -> FrameTimingSummary {
        lock.lock()
        let values = intervalsMs
        lock.unlock()

        guard !values.isEmpty else {
            return FrameTimingSummary(frames: 0, targetMs: targetMs, meanMs: 0,
                                      p99Ms: 0, maxMs: 0, lateFrames: 0)
        }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let p99Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.99).rounded(.down)))
        let late = values.filter { $0 > lateThresholdMs }.count
        return FrameTimingSummary(
            frames: values.count + 1,
            targetMs: targetMs,
            meanMs: mean,
            p99Ms: sorted[p99Index],
            maxMs: sorted[sorted.count - 1],
            lateFrames: late
        )
    }
}
