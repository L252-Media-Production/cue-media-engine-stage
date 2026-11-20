import XCTest
@testable import Engine

final class FrameTimingLoggerTests: XCTestCase {
    func testSteadyFramesHaveNoLateFrames() {
        let log = FrameTimingLogger(targetFPS: 60)
        let step: UInt64 = 16_666_667
        for i in 0..<120 {
            log.recordFrame(at: UInt64(i) * step)
        }
        let s = log.summary()
        XCTAssertEqual(s.frames, 120)
        XCTAssertEqual(s.lateFrames, 0)
        XCTAssertEqual(s.meanMs, 16.666667, accuracy: 0.001)
    }

    func testStallIsCountedAsLate() {
        let log = FrameTimingLogger(targetFPS: 60)
        let step: UInt64 = 16_666_667
        var t: UInt64 = 0
        for _ in 0..<10 { log.recordFrame(at: t); t += step }
        t += 3 * step // a 50 ms stall
        log.recordFrame(at: t)
        let s = log.summary()
        XCTAssertEqual(s.lateFrames, 1)
        XCTAssertGreaterThan(s.maxMs, 60)
    }

    func testEmptySummary() {
        let s = FrameTimingLogger(targetFPS: 30).summary()
        XCTAssertEqual(s.frames, 0)
        XCTAssertEqual(s.targetMs, 33.333, accuracy: 0.01)
    }

    func testResetClearsHistory() {
        let log = FrameTimingLogger(targetFPS: 60)
        log.recordFrame(at: 0)
        log.recordFrame(at: 16_000_000)
        log.reset()
        XCTAssertEqual(log.summary().frames, 0)
    }
}
