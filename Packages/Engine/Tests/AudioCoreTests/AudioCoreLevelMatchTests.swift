@testable import AudioCore
import Darwin
import XCTest

/// Properties of the loudness measurement, the level-match arithmetic and the deck's level factor that do not come from a fixture.
final class AudioCoreLevelMatchTests: XCTestCase {
    /// 48 kHz stereo 16-bit sine, as the fixtures synthesise it: `round(32768 * 10^(peak/20) * sin(...))`.
    private func sine(hz: Double, peakDbfs: Double, seconds: Double, channels: Int = 2, silentSecond: Bool = false) -> [Int16] {
        let frames = Int((seconds * 48000).rounded())
        let amp = 32768 * pow(10, peakDbfs / 20)
        var out = [Int16]()
        out.reserveCapacity(frames * channels)
        for n in 0..<frames {
            let v = Int16((amp * sin(2 * .pi * hz * Double(n) / 48000)).rounded())
            for c in 0..<channels { out.append(c == 1 && silentSecond ? 0 : v) }
        }
        return out
    }

    // MARK: loudness

    func testMonoIsThe3dBLowerOfTheSameSignalOnBothChannels() throws {
        let stereo = try XCTUnwrap(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 5), channels: 2))
        let mono = try XCTUnwrap(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 5, channels: 1), channels: 1))
        let leftOnly = try XCTUnwrap(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 5, silentSecond: true), channels: 2))
        XCTAssertEqual(stereo - mono, 10 * log10(2.0), accuracy: 1e-9)
        XCTAssertEqual(mono, leftOnly, accuracy: 1e-9, "a silent second channel adds no energy")
    }

    func testLoudnessMovesWithTheLevelDecibelForDecibel() throws {
        let a = try XCTUnwrap(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -30, seconds: 3), channels: 2))
        let b = try XCTUnwrap(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -10, seconds: 3), channels: 2))
        XCTAssertEqual(b - a, 20, accuracy: 0.005)
    }

    func testTheRelativeGateIgnoresAQuietPartAndTheAbsoluteGateASignalBelowMinus70() throws {
        let loud = sine(hz: 1000, peakDbfs: -20, seconds: 5)
        let quiet = sine(hz: 1000, peakDbfs: -50, seconds: 5)          // 30 LU below: under the relative gate
        let both = try XCTUnwrap(Loudness.integratedLufs(interleaved: loud + quiet, channels: 2))
        let alone = try XCTUnwrap(Loudness.integratedLufs(interleaved: loud, channels: 2))
        // The blocks that straddle the change (75, 50 and 25 % loud) pass the gate and pull the mean down a little; the quiet half itself does not count.
        XCTAssertEqual(both, alone, accuracy: 0.2)
        XCTAssertGreaterThan(both, alone - 3.0 + 2.5, "an ungated mean would be about 3 LU lower")
        XCTAssertNil(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -85, seconds: 3), channels: 2), "about -85 LUFS: under the absolute gate")
        let stillCounted = sine(hz: 1000, peakDbfs: -65, seconds: 3)
        XCTAssertNotNil(Loudness.integratedLufs(interleaved: stillCounted, channels: 2), "about -65 LUFS: over the absolute gate")
    }

    func testTheShortestMeasurableSignalIsOneBlock() {
        XCTAssertNotNil(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 0.4), channels: 2))
        XCTAssertNil(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 0.399), channels: 2))
        XCTAssertNil(Loudness.integratedLufs(interleaved: [Int16](), channels: 2))
    }

    func testOnlyOneAndTwoChannelsAreSpecified() {
        XCTAssertNil(Loudness.integratedLufs(interleaved: sine(hz: 1000, peakDbfs: -20, seconds: 1, channels: 3), channels: 3))
        XCTAssertNil(Loudness.integratedLufs(interleaved: [Int16](repeating: 100, count: 100), channels: 0))
    }

    func testTheMeasurementIsAPureFunctionOfTheBufferAndFloatsAgree() throws {
        let pcm = sine(hz: 440, peakDbfs: -18, seconds: 2)
        let a = try XCTUnwrap(Loudness.integratedLufs(interleaved: pcm, channels: 2))
        XCTAssertEqual(Loudness.integratedLufs(interleaved: pcm, channels: 2), a, "same buffer, same number")
        let floats = pcm.map { Float($0) / 32768 }
        XCTAssertEqual(try XCTUnwrap(Loudness.integratedLufs(interleaved: floats, channels: 2)), a, accuracy: 1e-5)
    }

    // MARK: level-match arithmetic

    func testTheTargetIsClampedAndRoundedToTheStep() {
        let c = LevelMatch.Clamp.standard
        XCTAssertEqual(LevelMatch.clamped(-80, c), -60)
        XCTAssertEqual(LevelMatch.clamped(5, c), 0)
        XCTAssertEqual(LevelMatch.clamped(-18.04, c), -18.0)
        XCTAssertEqual(LevelMatch.clamped(-18.06, c), -18.1)
        XCTAssertEqual(LevelMatch.clamped(-23, c), -23)
        XCTAssertEqual(LevelMatch.clamped(-.infinity, c), -60)
        XCTAssertEqual(LevelMatch.clamped(.infinity, c), 0)
    }

    func testTheTypedSettingIsStoredWithAnIdForTheReferenceAndADefaultForNaN() {
        let ids = [TrackID(10), TrackID(11), TrackID(12)]
        XCTAssertEqual(LevelMatch(typedMode: .track, typedReferenceIndex: 1, typedLufs: nil, playlist: ids).referenceTrack, TrackID(11))
        XCTAssertNil(LevelMatch(typedMode: .track, typedReferenceIndex: 7, typedLufs: nil, playlist: ids).referenceTrack, "an index outside the playlist keeps no reference")
        XCTAssertNil(LevelMatch(typedMode: .track, typedReferenceIndex: -1, typedLufs: nil, playlist: ids).referenceTrack)
        XCTAssertEqual(LevelMatch(typedMode: .lufs, typedReferenceIndex: nil, typedLufs: .nan, playlist: ids).targetLufs, LevelMatch.defaultTargetLufs)
        XCTAssertEqual(LevelMatch(typedMode: .lufs, typedReferenceIndex: nil, typedLufs: -80, playlist: ids).targetLufs, -60)
        XCTAssertEqual(LevelMatch(typedMode: .off, typedReferenceIndex: 1, typedLufs: -30, playlist: ids), LevelMatch(), "off keeps nothing of what was typed")
    }

    func testAGainNeverBoostsAndIsNilWithoutAMeasurementOrTarget() {
        XCTAssertEqual(LevelMatch.gainDb(measured: -14, target: -23), -9)
        XCTAssertEqual(LevelMatch.gainDb(measured: -30, target: -23), 0, "never turned up")
        XCTAssertNil(LevelMatch.gainDb(measured: nil, target: -23))
        XCTAssertNil(LevelMatch.gainDb(measured: -14, target: nil))
        XCTAssertEqual(LevelMatch.linear(db: nil), 1)
        XCTAssertEqual(LevelMatch.linear(db: -6.0206), 0.5, accuracy: 1e-4)
    }

    func testAPlaylistGivesTracksTheirGainByTheModeAndTheReferenceTrack() {
        let tracks = [
            PlaylistTrack(id: TrackID(0), lengthSeconds: 10, measuredLufs: -14), PlaylistTrack(id: TrackID(1), lengthSeconds: 10, measuredLufs: -23),
            PlaylistTrack(id: TrackID(2), lengthSeconds: 10, measuredLufs: nil),
        ]
        var list = Playlist(tracks: tracks)
        XCTAssertNil(list.levelGainDb(ofTrackAt: 0), "off")
        XCTAssertEqual(list.levelGain(ofTrackAt: 0), 1)
        list.levelMatch = LevelMatch(mode: .track, referenceTrack: TrackID(1))
        XCTAssertEqual(list.levelGainDb(ofTrackAt: 0), -9)
        XCTAssertEqual(list.levelGainDb(ofTrackAt: 1), 0)
        XCTAssertNil(list.levelGainDb(ofTrackAt: 2), "not measured")
        list.levelMatch = LevelMatch(mode: .track, referenceTrack: TrackID(2))
        XCTAssertNil(list.levelGainDb(ofTrackAt: 0), "the reference is not measured")
        list.levelMatch = LevelMatch(mode: .lufs, targetLufs: -18)
        XCTAssertEqual(list.levelGainDb(ofTrackAt: 0), -4)
        XCTAssertNil(list.levelGainDb(ofTrackAt: 9))
    }

    // MARK: the deck's level factor

    private func player(lufs: Double? = -14, mode: LevelMatch.Mode = .off, target: Double = -23, voices: Bool = false) -> PlaylistPlayer<SeededRandomSource> {
        var list = TriggerList()
        if voices { list.add(Trigger(id: TriggerID(0), atSeconds: 1, target: TrackID(100))) }
        var playlist = Playlist(tracks: [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, measuredLufs: lufs, triggers: list)], mode: .stop)
        playlist.levelMatch = LevelMatch(mode: mode, targetLufs: target)
        struct Ready: TargetReadiness { func state(of target: TrackID) -> TargetState { .ready(lengthSeconds: 3) } }
        return PlaylistPlayer(playlists: [playlist], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), mixer: Mixer(sampleRate: 1000), readiness: Ready())
    }

    func testATrackStartsWithItsLevelGainAndAChangeFollowsAtOnce() throws {
        var p = player(mode: .lufs)
        p.play(TrackPosition(playlist: 0, track: 0))
        let id = try XCTUnwrap(p.current?.deck)
        let g = pow(10, -9.0 / 20)
        XCTAssertEqual(p.mixer.gain(of: id)!, g, accuracy: 1e-12, "from the first frame, no ramp at a start")
        XCTAssertEqual(p.mixer.deck(id)?.levelGain(at: 0), g)
        p.advance(frames: 100)
        p.setLevelMatch(LevelMatch(mode: .off), ofPlaylist: 0)
        XCTAssertEqual(p.mixer.gain(of: id)!, 1, accuracy: 1e-12, "the gain follows a change at once")
    }

    func testABlockThatContainsAChangeCanRampFromTheOldValueToTheNew() throws {
        var p = player(mode: .off)
        p.play(TrackPosition(playlist: 0, track: 0))
        let id = try XCTUnwrap(p.current?.deck)
        p.advance(frames: 1000)
        p.setLevelMatch(LevelMatch(mode: .lufs, targetLufs: -23), ofPlaylist: 0)
        let d = try XCTUnwrap(p.mixer.deck(id))
        let g = pow(10, -9.0 / 20)
        XCTAssertEqual(d.levelGain(at: 999), 1, "a block that ends before the change")
        XCTAssertEqual(d.levelGain(at: 1000), g, accuracy: 1e-12, "from the frame of the change")
        // The render block [900, 1100) ramps from the value at its start to the value at its end.
        XCTAssertEqual([d.levelGain(at: 900), d.levelGain(at: 1100)], [1, g])
        // Level gain is a factor of its own: it multiplies the fade.
        var q = player(mode: .lufs)
        q.play(TrackPosition(playlist: 0, track: 0))
        let a = q.current!.deck
        q.advance(frames: 100)
        let before = q.mixer.gain(of: a)!
        XCTAssertEqual(before, g, accuracy: 1e-12)
        q.play(TrackPosition(playlist: 0, track: 0), crossfadeMs: 1000)
        q.advance(frames: 500)
        XCTAssertEqual(q.mixer.gain(of: a)!, g * EqualPower.rampDown(x: 0.5), accuracy: 1e-12, "the old deck fades out at its own level")
    }

    func testAMeasurementThatArrivesWhileTheTrackPlaysIsApplied() throws {
        var p = player(lufs: nil, mode: .lufs)
        p.play(TrackPosition(playlist: 0, track: 0))
        let id = try XCTUnwrap(p.current?.deck)
        XCTAssertEqual(p.mixer.gain(of: id), 1, "no measurement yet: no gain")
        p.setMeasuredLufs(-14, ofTrack: TrackID(0), inPlaylist: 0)
        XCTAssertEqual(p.mixer.gain(of: id)!, pow(10, -9.0 / 20), accuracy: 1e-12)
    }

    func testALevelMatchedPlaylistNeverLevelMatchesATriggerVoice() throws {
        var p = player(mode: .lufs, voices: true)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: 1500)
        let voice = try XCTUnwrap(p.topDeck)
        XCTAssertEqual(p.mixer.deck(voice)?.levelGain(at: p.mixer.transport.playFrame), 1)
        XCTAssertEqual(p.mixer.gain(of: voice), 1, "only the top-track level applies to a voice")
        XCTAssertEqual(p.mixer.gain(of: p.current!.deck)!, pow(10, -9.0 / 20), accuracy: 1e-12)
    }

    func testTheLastGainOfAnEndedDeckIncludesItsLevel() {
        var m = Mixer(sampleRate: 1000)
        let plan = TrackPlan(trim: Trim(), policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), fileLength: 1, sampleRate: 1000)
        let id = m.start(plan)
        m.setLevelGain(of: id, 0.5, atStart: true)
        m.advance(frames: 1000)
        XCTAssertEqual(m.ended.first?.lastGain ?? -1, 0.5, accuracy: 1e-12)
    }

    func testAStaleHandleCannotSetALevel() {
        var m = Mixer(sampleRate: 1000, poolCapacity: 1)
        let plan = TrackPlan(trim: Trim(), policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), fileLength: 1, sampleRate: 1000)
        let old = m.start(plan)
        m.advance(frames: 1000)
        let new = m.start(plan)
        m.setLevelGain(of: old, 0.1)
        XCTAssertEqual(m.deck(new)?.levelGainNow, 1)
    }

    // MARK: real-time

    func testCombiningTheLevelIntoTheGainAllocatesNothing() throws {
        var p = player(mode: .lufs)
        p.play(TrackPosition(playlist: 0, track: 0))
        let id = try XCTUnwrap(p.current?.deck)
        var m = p.mixer
        func heap() -> Int { var s = malloc_statistics_t(); malloc_zone_statistics(nil, &s); return Int(s.blocks_in_use) }
        func round() {
            for i in 0..<1000 {
                m.setLevelGain(of: id, i % 2 == 0 ? 0.5 : 0.25)
                m.advance(frames: 10)
                _ = m.gain(of: id)
            }
        }
        round()
        var deltas = [Int]()
        for _ in 0..<3 {
            let before = heap()
            round()
            deltas.append(heap() - before)
        }
        XCTAssertEqual(deltas, [0, 0, 0])
    }
}
