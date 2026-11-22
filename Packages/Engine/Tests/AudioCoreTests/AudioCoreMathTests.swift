@testable import AudioCore
import XCTest

/// Properties of the AudioCore maths that do not come from a fixture.
final class AudioCoreMathTests: XCTestCase {
    func testCrossfadePowerIsConstant() {
        for i in 0...100 {
            let g = EqualPower.crossfade(x: Double(i) / 100)
            XCTAssertEqual(g.new * g.new + g.old * g.old, 1, accuracy: 1e-12, "x = \(Double(i) / 100)")
        }
    }

    func testFadeOfZeroLengthIsACut() {
        XCTAssertEqual(EqualPower.progress(elapsed: 0, length: 0), 1)
        XCTAssertEqual(EqualPower.progress(elapsed: 5, length: 2), 1)
        XCTAssertEqual(EqualPower.progress(elapsed: -1, length: 2), 0)
    }

    func testRampsHonourStartAndEnd() {
        XCTAssertEqual(EqualPower.rampUp(x: 0, from: 0.2, to: 0.8), 0.2, accuracy: 1e-12)
        XCTAssertEqual(EqualPower.rampUp(x: 1, from: 0.2, to: 0.8), 0.8, accuracy: 1e-12)
        XCTAssertEqual(EqualPower.rampDown(x: 0, from: 0.8, to: 0.2), 0.8, accuracy: 1e-12)
        XCTAssertEqual(EqualPower.rampDown(x: 1, from: 0.8, to: 0.2), 0.2, accuracy: 1e-12)
    }

    func testDuckSmoothSnapsToZero() {
        XCTAssertEqual(Ducking.smooth(gr: 0.04, target: 0, dt: 0.01, attackMs: 10, releaseMs: 500), 0)
        XCTAssertGreaterThan(Ducking.smooth(gr: 0.04, target: 0.04, dt: 0.01, attackMs: 10, releaseMs: 500), 0)
    }

    func testDuckKeyDropsAPartialWindowAndIsEmptyBelowOne() {
        XCTAssertEqual(Ducking.key(pcm: [Int16](repeating: 100, count: 2 * 479)), [])
        XCTAssertEqual(Ducking.key(pcm: [Int16](repeating: 100, count: 2 * 481)).count, 1)
    }

    /// The fixture rows cannot tell the 75th percentile from the 60th (the quiet windows are under 28 % of the active ones),
    /// so the interpolation is pinned here. Values are numpy's `np.percentile` with the default linear method.
    func testPercentileMatchesNumpyLinearInterpolation() {
        XCTAssertEqual(Ducking.percentile([1, 2, 3, 4], 75), 3.25, accuracy: 1e-12)
        XCTAssertEqual(Ducking.percentile([4, 1, 3, 2], 75), 3.25, accuracy: 1e-12)
        XCTAssertEqual(Ducking.percentile([5], 75), 5, accuracy: 1e-12)
        XCTAssertEqual(Ducking.percentile([1, 2, 3, 4, 5], 75), 4, accuracy: 1e-12)
        XCTAssertEqual(Ducking.percentile([10, 20], 75), 17.5, accuracy: 1e-12)
    }

    /// Hold lifts every window between the first and the last active one to the typical depth, and leaves the rest alone.
    func testHoldLiftsOnlyBetweenFirstAndLastActiveWindow() {
        // active reductions 12, 12, 2, 12, 12: 75th percentile of the active values is 12
        let key = [0, 0.5, 0.5, 0.05, 0.5, 0.5, 0].map { $0 }
        let held = Ducking.curve(key: key, level: 1, ratio: 6, thresholdDb: -30, hold: true)
        let loose = Ducking.curve(key: key, level: 1, ratio: 6, thresholdDb: -30, hold: false)
        XCTAssertEqual(held.first, 0)
        XCTAssertEqual(held.last, 0)
        XCTAssertLessThan(loose[3], loose[1])
        XCTAssertEqual(held[3], held[1], accuracy: 1e-12)
    }

    /// With four different active reductions the hold depth is the 75th percentile (rank 2.25 of 0...3), not the maximum or the median.
    func testHoldDepthIsTheSeventyFifthPercentileOfTheActiveWindows() {
        let key = [0.1, 0.2, 0.4, 0.8]
        let loose = Ducking.curve(key: key, level: 1, ratio: 2, thresholdDb: -30, hold: false)
        XCTAssertTrue(zip(loose, loose.dropFirst()).allSatisfy { $0 < $1 }, "the four reductions must differ: \(loose)")
        let depth = loose[2] + 0.25 * (loose[3] - loose[2])
        let held = Ducking.curve(key: key, level: 1, ratio: 2, thresholdDb: -30, hold: true)
        XCTAssertEqual(held[0], depth, accuracy: 1e-9)
        XCTAssertEqual(held[1], depth, accuracy: 1e-9)
        XCTAssertEqual(held[2], depth, accuracy: 1e-9)
        XCTAssertEqual(held[3], loose[3], accuracy: 1e-12)
    }
}
