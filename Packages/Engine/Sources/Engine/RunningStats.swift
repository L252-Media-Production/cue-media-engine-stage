import Foundation

/// Thread-safe running count, mean and max of a stream of values (for example GPU time per frame).
public final class RunningStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sum = 0.0
    private var maxValue = 0.0

    public init() {}

    public func add(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        sum += value
        if value > maxValue { maxValue = value }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
        sum = 0
        maxValue = 0
    }

    public var snapshot: (count: Int, mean: Double, max: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (count, count == 0 ? 0 : sum / Double(count), maxValue)
    }
}
