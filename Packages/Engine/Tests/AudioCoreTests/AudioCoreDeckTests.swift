@testable import AudioCore
import XCTest

/// Properties of the deck, clock and mixer types that do not come from a fixture.
final class AudioCoreDeckTests: XCTestCase {
    func testPauseStopsPlayTimeButNotWallTime() {
        var t = Transport()
        t.advance(frames: 100)
        t.pause()
        t.advance(frames: 50)
        t.resume()
        t.advance(frames: 10)
        XCTAssertEqual(t.wallFrame, 160)
        XCTAssertEqual(t.playFrame, 110)
    }

    func testCrossfadeKeepsPowerConstantEveryFrameStep() {
        var m = Mixer(sampleRate: 1000)
        let old = m.start()
        let new = m.start(crossfadeMs: 500)
        for _ in 0..<500 {
            m.advance(frames: 1)
            let a = m.gain(of: old)!, b = m.gain(of: new)!
            XCTAssertEqual(a * a + b * b, 1, accuracy: 1e-12)
        }
        XCTAssertEqual(m.playingCount, 1)
        XCTAssertEqual(m.live?.id, new)
    }

    func testCutRemovesTheOldDeckAtOnce() {
        var m = Mixer()
        let old = m.start()
        let new = m.start(crossfadeMs: 0)
        XCTAssertEqual(m.deck(old)?.isPlaying, false)
        XCTAssertEqual(m.gain(of: new), 1)
        XCTAssertEqual(m.playingCount, 1)
    }

    func testFadeOutOfNothingDoesNothing() {
        var m = Mixer()
        m.fadeOutLive(milliseconds: 500)
        XCTAssertNil(m.live)
    }

    func testOwnTimeIsCheckedAfterRoundingToWholeMilliseconds() {
        XCTAssertEqual(CrossfadeSettings.ownTimeMs(seconds: 30.0004), 30_000)
        XCTAssertNil(CrossfadeSettings.ownTimeMs(seconds: 30.0006))
        XCTAssertNil(CrossfadeSettings.ownTimeMs(seconds: .nan))
        XCTAssertNil(CrossfadeSettings.ownTimeMs(seconds: -0.001))
    }
}
