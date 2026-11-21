@testable import AudioCore
import XCTest

/// Properties of trim, passes and the deck's end that do not come from a fixture. A 1000 Hz clock keeps the frame numbers readable.
final class AudioCorePlaybackTests: XCTestCase {
    private let rate = 1000
    private let policy = TrimPolicy(defaultFadeOutMs: 1500, defaultFadeInMs: 0)

    private func plan(_ trim: Trim = Trim(), length: Double = 2, end: TrackEnd = .followPlayMode, offset: Double = 0) -> TrackPlan {
        TrackPlan(trim: trim, policy: policy, fileLength: length, offsetSeconds: offset, end: end, sampleRate: rate)
    }

    func testDeckEndsAtTheExactFrameEvenWhenAdvanceOvershoots() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan())
        m.advance(frames: 5000)
        XCTAssertEqual(m.ended, [Mixer.DeckEnded(deck: id, frame: 2000)])
        XCTAssertEqual(m.deck(id)?.endedAtFrame, 2000)
        m.advance(frames: 1)
        XCTAssertTrue(m.ended.isEmpty, "an end is reported once")
    }

    func testOncePlaysTwoPassesAndEndsAtTheEndOfTheSecond() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan(end: .twice))
        m.advance(frames: 1999)
        XCTAssertEqual(m.deck(id)?.pass(at: m.transport.playFrame), PassPosition(number: 1, remainingFrames: 1))
        m.advance(frames: 1)
        XCTAssertEqual(m.deck(id)?.pass(at: m.transport.playFrame), PassPosition(number: 2, remainingFrames: 2000))
        m.advance(frames: 2000)
        XCTAssertEqual(m.ended.map(\.frame), [4000])
    }

    func testFirstPassOfAResumedStartIsShorterThanTheNext() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan(length: 10, end: .twice, offset: 7))   // 3 s left, then a whole 10 s pass
        m.advance(frames: 3000)
        XCTAssertEqual(m.deck(id)?.pass(at: m.transport.playFrame), PassPosition(number: 2, remainingFrames: 10_000))
    }

    func testPauseFreezesPassesAndTheEnd() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan())
        m.advance(frames: 1000)
        m.pause()
        m.advance(frames: 60_000)
        XCTAssertEqual(m.deck(id)?.isPlaying, true)
        m.resume()
        m.advance(frames: 1000)
        XCTAssertEqual(m.ended.map(\.frame), [2000])
    }

    func testALoopNeverEndsAndHasNoOutFade() {
        var m = Mixer(sampleRate: rate)
        var t = Trim()
        XCTAssertTrue(t.apply({ var e = TrimEdit(); e.outPoint = .set(1.5); return e }(), fileLength: 10))
        let id = m.start(plan(t, length: 10, end: .loop))
        for _ in 0..<5 {
            m.advance(frames: 1400)
            XCTAssertEqual(m.gain(of: id), 1)
        }
        XCTAssertEqual(m.deck(id)?.isPlaying, true)
    }

    func testSwitchingALoopOffPlaysOutTheRunningPassAndKeepsReportingPassOne() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan(end: .loop))
        m.advance(frames: 3000)                      // pass 2 of the window is running
        m.finishCurrentPass(of: id)
        m.advance(frames: 500)
        XCTAssertEqual(m.deck(id)?.pass(at: m.transport.playFrame), PassPosition(number: 1, remainingFrames: 500))
        m.advance(frames: 500)
        XCTAssertEqual(m.ended.map(\.frame), [4000])
    }

    func testSwitchingOffAfterTheEndDoesNothing() {
        var m = Mixer(sampleRate: rate)
        let id = m.start(plan())
        m.advance(frames: 3000)
        m.finishCurrentPass(of: id)
        XCTAssertEqual(m.deck(id)?.endedAtFrame, 2000)
    }

    func testFadeInIsDroppedUnderACrossfadeAndWhilePaused() {
        var t = Trim()
        t.fadesInAtStart = true
        t.fadeInMs = 500
        let p = plan(t, length: 10)
        XCTAssertEqual(p.fadeInFrames, 500)
        var m = Mixer(sampleRate: rate)
        m.start()
        let crossed = m.start(p, crossfadeMs: 100)
        XCTAssertEqual(m.deck(crossed)?.playback?.plan.fadeInFrames, 0)
        m.pause()
        let paused = m.start(p)
        XCTAssertEqual(m.deck(paused)?.playback?.plan.fadeInFrames, 0)
    }

    func testOutFadeIsNeverLongerThanTheLastPass() {
        var t = Trim()
        t.outPoint = 1
        t.fadeOutMs = 5000                           // asks for more than the 1 s window
        let p = plan(t, length: 10, offset: 0.5)     // resumed 0.5 s from B
        XCTAssertEqual(p.endFadeMs, 500)
        var m = Mixer(sampleRate: rate)
        let id = m.start(p)
        XCTAssertEqual(m.gain(of: id), 1)
        m.advance(frames: 250)
        XCTAssertEqual(m.gain(of: id)!, EqualPower.rampDown(x: 0.5), accuracy: 1e-12)
    }

    func testARefusedEditChangesNothing() {
        var t = Trim()
        var first = TrimEdit()
        first.inPoint = .set(2)
        XCTAssertTrue(t.apply(first, fileLength: 10))
        var bad = TrimEdit()
        bad.outPoint = .set(2.3)
        XCTAssertFalse(t.apply(bad, fileLength: 10))
        XCTAssertEqual(t.inPoint, 2)
        XCTAssertNil(t.outPoint)
    }

    func testEndActionCycleReturnsToTheStart() {
        var a = TrackEnd.followPlayMode
        var seen = [TrackEnd]()
        for _ in 0..<5 { seen.append(a); a = a.next }
        XCTAssertEqual(seen, [.followPlayMode, .twice, .loop, .stop, .followPlayMode])
    }
}
