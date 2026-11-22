@testable import AudioCore
import Darwin
import XCTest

/// The sidechain control loop, the duck factor of a deck and the hook, without the fixtures: block-size independence, no allocation, what is ducked and what not.
final class AudioCoreDuckingTests: XCTestCase {
    private let rate = 48_000
    private let policy = TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0)

    private func plan(_ seconds: Double) -> TrackPlan { TrackPlan(trim: Trim(), policy: policy, fileLength: seconds, sampleRate: rate) }

    /// The voice of the duck_loop fixture as a key: 0.3 s silence, 0.7 s at 16384, 0.5 s at 4096, 0.5 s silence (one value per 10 ms).
    private var voiceKey: [Double] {
        Array(repeating: 0, count: 30) + Array(repeating: 16384.0 / 32768, count: 70) + Array(repeating: 4096.0 / 32768, count: 50) + Array(repeating: 0, count: 50)
    }

    private func heapBlocks() -> Int {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        return Int(s.blocks_in_use)
    }

    /// A background deck, 0.5 s alone, then the 2 s voice on top with ducking.
    private func scene(settings: DuckingSettings = DuckingSettings()) -> (mixer: Mixer, background: Deck.ID, voice: Deck.ID, hook: SidechainDucking) {
        var m = Mixer(sampleRate: rate)
        var hook = SidechainDucking(settings: settings)
        hook.prepare(target: TrackID(1), key: voiceKey)
        let bg = m.start(plan(30))
        m.advance(frames: 24_000)
        let v = m.startOnTop(plan(2), level: settings.voiceLevel)
        hook.voiceStarted(v, target: TrackID(1), over: bg, atFrame: m.transport.playFrame, in: &m)
        return (m, bg, v, hook)
    }

    /// The control values read at every `every` frames from the start of the voice until the loop has ended, advancing in blocks of `block`.
    private func series(block: Int64, every: Int64, settings: DuckingSettings = DuckingSettings()) -> [DuckReading] {
        var (m, bg, _, _) = scene(settings: settings)
        var out = [DuckReading]()
        var done: Int64 = 0
        let total: Int64 = 5 * 48_000
        while done < total {
            let target = min(every, total - done)
            var left = target
            while left > 0 {
                let n = min(block, left)
                m.advance(frames: n)
                left -= n
            }
            done += target
            out.append(m.duckReading(at: m.transport.playFrame) ?? DuckReading())
            XCTAssertEqual(m.deck(bg)?.duck(at: m.transport.playFrame), (m.duckReading(at: m.transport.playFrame) ?? DuckReading()).multiplier, "the deck and the loop agree")
        }
        return out
    }

    func testTheControlLoopDoesNotDependOnTheBlockSize() {
        let reference = series(block: 480, every: 480)
        XCTAssertGreaterThan(reference.map(\.reductionDb).max() ?? 0, 19, "the dip is there")
        for block in [Int64(1), 7, 480, 2400] {
            XCTAssertEqual(series(block: block, every: 480), reference, "blocks of \(block) frames")
        }
        // Read only every 2400 frames, and once at the very end: the same values at the same frames.
        let coarse = series(block: 2400, every: 2400)
        XCTAssertEqual(coarse, stride(from: 4, to: reference.count, by: 5).map { reference[$0] }, "read every 2400 frames")
        XCTAssertEqual(series(block: 5 * 48_000, every: 5 * 48_000), [reference.last!], "one big step")
    }

    func testTheLoopFollowsTheCurveOneStepLate() {
        // The step at the start of the voice reads the key window 20 ms ahead; its value is in force one step later.
        var (m, bg, _, _) = scene()
        let start = m.transport.playFrame
        let curve = Ducking.curve(key: voiceKey, level: 1, ratio: 6, thresholdDb: -30, hold: true)
        var gr = 0.0
        for j in 0..<60 {
            let at = start + Int64(j) * 480
            XCTAssertEqual(m.duckReading(at: at + 480)?.reductionDb ?? -1, gr == 0 && j == 0 ? 0 : m.duckReading(at: at + 480)?.reductionDb ?? -1)
            gr = Ducking.smooth(gr: gr, target: curve[j + 2], dt: 0.01, attackMs: 10, releaseMs: 500)
            m.advance(frames: 480)
            if j >= 1 { XCTAssertEqual(m.duckReading(at: start + Int64(j + 1) * 480)?.reductionDb ?? -1, gr, accuracy: 1e-12, "step \(j)") }
        }
        XCTAssertLessThan(m.deck(bg)?.duck(at: m.transport.playFrame) ?? 1, 0.2)
    }

    func testTheFactorIsAFactorOfItsOwnInTheDeckGain() {
        var (m, bg, _, _) = scene()
        m.setLevelGain(of: bg, 0.5)
        m.advance(frames: 24_000)
        let d = m.deck(bg)!
        let f = m.transport.playFrame
        XCTAssertEqual(d.gain(at: f), d.volume(at: f) * d.levelGain(at: f) * d.duck(at: f), accuracy: 1e-15)
        XCTAssertLessThan(d.duck(at: f), 0.2)
        XCTAssertEqual(d.volume(at: f), 1, "the fade / level of the deck is untouched")
    }

    func testTheFactorChangesAtAStepSoABlockCanRampBetweenTwoValues() {
        var (m, bg, _, _) = scene()
        m.advance(frames: 480 * 25)           // silent until 0.30 s; the look-ahead makes the first change come at 0.29 s
        var changes = 0
        var last = m.deck(bg)!.duck(at: m.transport.playFrame)
        XCTAssertEqual(last, 1, accuracy: 1e-9, "nothing is ducked yet 0.25 s into the silence")
        for _ in 0..<20 {
            // The renderer reads the start of the block before it advances and the end after: the deck knows the factor from now to one step ahead.
            let a = m.transport.playFrame
            let atStart = m.deck(bg)!.duck(at: a)
            m.advance(frames: 480)
            let atEnd = m.deck(bg)!.duck(at: a + 480)
            if atStart != atEnd { changes += 1 }
            XCTAssertEqual(atStart, last, "the start of a block is where the last one ended")
            XCTAssertLessThanOrEqual(atEnd, atStart + 1e-12, "attack only goes down")
            last = atEnd
        }
        XCTAssertGreaterThan(changes, 5)
    }

    func testNothingAllocatesWhileTheLoopRuns() {
        var (m, _, _, _) = scene()
        m.advance(frames: 1)      // warm up
        // Whatever else the process does between two reads (the test runner's own threads) is not ours: the loop is compared with the same run without one.
        var quiet = Mixer(sampleRate: rate)
        quiet.start(plan(30))
        quiet.advance(frames: 1)
        var idle = [Int]()
        for _ in 0..<5 {
            let b = heapBlocks()
            for _ in 0..<(5 * 48_000 / 96) { quiet.advance(frames: 96) }
            idle.append(heapBlocks() - b)
        }
        let before = heapBlocks()
        for _ in 0..<(5 * 48_000 / 96) { m.advance(frames: 96) }
        let grown = heapBlocks() - before
        XCTAssertLessThanOrEqual(grown, idle.max() ?? 0, "advance with a running loop (attack, hold, release, end of the session) allocated \(grown) blocks; without a loop the noise is \(idle)")
        XCTAssertFalse(m.isDucking, "the loop has ended after the release")
        XCTAssertEqual(m.counters, EngineCounters())
    }

    func testAnEndedVoiceReleasesAndTheLoopStopsAtZero() {
        var (m, bg, _, _) = scene()
        m.advance(frames: 3 * 48_000)
        XCTAssertTrue(m.isDucking, "still releasing (500 ms release)")
        m.advance(frames: 5 * 48_000)
        XCTAssertFalse(m.isDucking)
        XCTAssertEqual(m.deck(bg)?.duck(at: m.transport.playFrame), 1)
        XCTAssertFalse(m.deck(bg)?.followsDuck ?? true)
    }

    func testACutEndsTheSessionAndTheNewTrackIsNeverDucked() {
        var (m, bg, v, hook) = scene()
        m.advance(frames: 24_000)
        XCTAssertLessThan(m.deck(bg)?.duck(at: m.transport.playFrame) ?? 1, 0.2)
        let new = m.start(plan(30))          // a cut removes the background and the voice
        hook.voiceEnded(v, atFrame: m.transport.playFrame, in: &m)
        m.advance(frames: 480)
        XCTAssertFalse(m.isDucking, "no residual depth")
        XCTAssertEqual(m.deck(new)?.duck(at: m.transport.playFrame), 1)
        XCTAssertFalse(m.deck(new)?.followsDuck ?? true)
    }

    func testACrossfadeKeepsTheOldBackgroundDuckedAndNeverDucksTheNewTrack() {
        var (m, bg, _, _) = scene()
        m.advance(frames: 24_000)
        let new = m.start(plan(30), crossfadeMs: 1000)
        for _ in 0..<20 {
            m.advance(frames: 480)
            XCTAssertLessThan(m.deck(bg)?.duck(at: m.transport.playFrame) ?? 1, 0.2, "the old background is still ducked while it fades out")
            XCTAssertEqual(m.deck(new)?.duck(at: m.transport.playFrame), 1)
        }
    }

    func testAVoiceWithoutAKeyDoesNotDuck() {
        var m = Mixer(sampleRate: rate)
        var hook = SidechainDucking()
        let bg = m.start(plan(30))
        let v = m.startOnTop(plan(2))
        hook.voiceStarted(v, target: TrackID(9), over: bg, atFrame: 0, in: &m)
        m.advance(frames: 48_000)
        XCTAssertEqual(m.deck(bg)?.duck(at: m.transport.playFrame), 1)
        XCTAssertEqual(hook.voicesWithoutKey, 1)
        XCTAssertFalse(m.isDucking)
    }

    func testTheHoldUsesTheSameFunctionAsTheCurve() {
        let key = voiceKey
        let depth = Ducking.holdDepthDb(key: key, level: 1, ratio: 6, thresholdDb: -30)
        let held = Ducking.curve(key: key, level: 1, ratio: 6, thresholdDb: -30, hold: true)
        let off = Ducking.curve(key: key, level: 1, ratio: 6, thresholdDb: -30, hold: false)
        XCTAssertGreaterThan(depth, 0)
        for i in key.indices where i >= 30 && i < 150 { XCTAssertEqual(held[i], max(off[i], depth), accuracy: 1e-12) }
        XCTAssertEqual(Ducking.holdDepthDb(key: [0, 0], level: 1, ratio: 6, thresholdDb: -30), 0)
    }

    func testChangingTheSettingsRemakesTheCurves() {
        var hook = SidechainDucking(settings: DuckingSettings(hold: false))
        hook.prepare(target: TrackID(1), key: voiceKey)
        hook.settings.hold = true
        var m = Mixer(sampleRate: rate)
        let bg = m.start(plan(30))
        let v = m.startOnTop(plan(2))
        hook.voiceStarted(v, target: TrackID(1), over: bg, atFrame: 0, in: &m)
        m.advance(frames: 48_000 * 2 - 480 * 40)       // the 4096 part (1.0 s .. 1.5 s of the voice) holds the 75th-percentile depth, not its own 10 dB
        XCTAssertLessThan(m.duckReading(at: m.transport.playFrame)?.reductionDb ?? 0, 100)
        XCTAssertGreaterThan(m.duckReading(at: m.transport.playFrame)?.reductionDb ?? 0, 15)
    }
}
