import XCTest
@testable import AudioCore

/// Slice 8: the choices the fixtures do not pin (docs/audio-conformance.md, "Slice 8: resume"), the store and the save schedule.
/// The harness has a `ResumeRecord` of its own (the fixture model), which shadows the engine's in this module; `engineRecord` builds the engine's.
final class AudioCoreResumeTests: XCTestCase {
    private func engineRecord(_ pt: [Int], _ id: String, _ pos: Double, paused: Bool) -> ResumeEntry {
        ResumeEntry(record: .init(pt: pt, id: id, pos: pos, paused: paused), savedAt: 0)
    }

    private let catalog = ResumeCatalog(playlists: [["a.wav", "b.wav"], ["c.wav", "b.wav"]])

    private struct Targets: TargetReadiness {
        func state(of target: TrackID) -> TargetState { target == TrackID(9) ? .ready(lengthSeconds: 30) : .missing }
    }

    /// Two playlists of 60 s files (a, b | c, b). `voiceAt` puts a trigger point on track 0 that fires a 30 s voice-over (`TrackID(9)`, not in any playlist).
    private func player(trimA: Trim = Trim(), voiceAt: Double? = nil) -> PlaylistPlayer<SeededRandomSource> {
        var t0 = PlaylistTrack(id: TrackID(0), lengthSeconds: 60, trim: trimA)
        if let at = voiceAt { t0.triggers.add(Trigger(id: TriggerID(0), atSeconds: at, target: TrackID(9), once: false)) }
        let l0 = Playlist(tracks: [t0, PlaylistTrack(id: TrackID(1), lengthSeconds: 60)])
        let l1 = Playlist(tracks: [PlaylistTrack(id: TrackID(2), lengthSeconds: 60), PlaylistTrack(id: TrackID(3), lengthSeconds: 60)])
        return PlaylistPlayer(
            playlists: [l0, l1], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1), readiness: Targets())
    }

    private func secs(_ p: PlaylistPlayer<SeededRandomSource>, _ s: Double) -> Int64 { p.mixer.transport.frames(seconds: s) }

    func testRecordJSONRoundTrip() throws {
        let r = engineRecord([0, 1], "b.wav", 12.5, paused: false).record
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(type(of: r), from: data), r)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"pt\""))
    }

    // (a) a record at or before 0.05 s: starts at A like any start from the top, without a fade-in
    func testAnEarlyPositionStartsWithoutFadeIn() {
        let trim = Trim(inPoint: nil, outPoint: nil, endsWithCut: false, fadeOutMs: nil, fadeInMs: 1500, fadesInAtStart: true)
        var p = player(trimA: trim)
        XCTAssertTrue(p.play(TrackPosition(playlist: 0, track: 0)))
        XCTAssertEqual(p.mixer.deck(p.current!.deck)?.playback?.plan.fadeInMs, 1500, "a normal start fades in")
        var q = player(trimA: trim)
        let d = Resume.plan(record: engineRecord([0, 0], "a.wav", 0.03, paused: false).record, ageSeconds: 1, catalog: catalog)
        XCTAssertTrue(q.startResume(d.plan!))
        let plan = q.mixer.deck(q.current!.deck)!.playback!.plan
        XCTAssertEqual(plan.fadeInMs, 0)
        XCTAssertEqual(q.mixer.gain(of: q.current!.deck), 1)
        XCTAssertTrue(plan.isFresh)
    }

    // (b) crossfade in progress: the new track is recorded
    func testDuringACrossfadeTheNewTrackIsRecorded() {
        var p = player()
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: secs(p, 10))
        p.play(TrackPosition(playlist: 0, track: 1), crossfadeMs: 4000)
        p.advance(frames: secs(p, 1))
        let r = p.resumeRecord(catalog: catalog)
        XCTAssertEqual(r?.id, "b.wav")
        XCTAssertEqual(r?.pt, [0, 1])
        XCTAssertEqual(r?.pos ?? -1, 1, accuracy: 1e-4)
    }

    // (c) a file in more than one playlist
    func testAFileInTwoPlaylists() {
        XCTAssertEqual(catalog.position(of: "b.wav", recordedPt: [1, 0]), TrackPosition(playlist: 1, track: 1), "recorded playlist still holds it")
        XCTAssertEqual(catalog.position(of: "b.wav", recordedPt: [0, 0]), TrackPosition(playlist: 0, track: 1))
        XCTAssertEqual(catalog.position(of: "b.wav", recordedPt: [5, 0]), TrackPosition(playlist: 0, track: 1), "recorded playlist gone: first one that holds it")
        XCTAssertEqual(catalog.position(of: "c.wav", recordedPt: [0, 0]), TrackPosition(playlist: 1, track: 0), "recorded playlist lacks it: first that holds it")
        XCTAssertEqual(catalog.position(of: "b.wav", recordedPt: []), TrackPosition(playlist: 0, track: 1))
        XCTAssertNil(catalog.position(of: "x.wav", recordedPt: [0, 0]))
        let twice = ResumeCatalog(playlists: [["a", "b", "a"]])
        XCTAssertEqual(twice.position(of: "a", recordedPt: [0, 2]), TrackPosition(playlist: 0, track: 2), "recorded track still holds it")
        XCTAssertEqual(twice.position(of: "a", recordedPt: [0, 1]), TrackPosition(playlist: 0, track: 0))
    }

    // (d) a voice on top: the background is recorded, never the voice
    func testAVoiceOnTopIsNeverRecorded() {
        var p = player(voiceAt: 2)
        p.play(TrackPosition(playlist: 0, track: 0))
        p.advance(frames: secs(p, 5))
        XCTAssertNotNil(p.topDeck, "the voice plays on top")
        XCTAssertEqual(p.mixer.live?.id, p.topDeck, "the voice is the live deck")
        let r = p.resumeRecord(catalog: catalog)
        XCTAssertEqual(r?.id, "a.wav")
        XCTAssertEqual(r?.pos ?? -1, 5, accuracy: 1e-4)
    }

    func testStopFadeOutAndNothingPlaying() {
        var p = player()
        XCTAssertNil(p.resumeRecord(catalog: catalog))
        p.play(TrackPosition(playlist: 0, track: 0))
        XCTAssertNotNil(p.resumeRecord(catalog: catalog))
        p.fadeOut(milliseconds: 1000)
        XCTAssertNil(p.resumeRecord(catalog: catalog))
        p.advance(frames: secs(p, 2))
        XCTAssertNil(p.resumeRecord(catalog: catalog))
    }

    func testPlanRules() {
        let rec = engineRecord([0, 0], "a.wav", 8, paused: true).record
        XCTAssertEqual(Resume.plan(record: rec, ageSeconds: 1800, catalog: catalog).plan?.offsetSeconds, 8, "exactly the limit still resumes")
        XCTAssertNil(Resume.plan(record: rec, ageSeconds: 1800.5, catalog: catalog).plan)
        XCTAssertFalse(Resume.plan(record: rec, ageSeconds: 1800.5, catalog: catalog).recordKept)
        XCTAssertNotNil(Resume.plan(record: rec, ageSeconds: -30, catalog: catalog).plan)
        XCTAssertNil(Resume.plan(record: rec, ageSeconds: .nan, catalog: catalog).plan)
        let off = Resume.plan(record: rec, ageSeconds: 1, catalog: catalog, settings: ResumeSettings(onStart: false))
        XCTAssertNil(off.plan)
        XCTAssertTrue(off.recordKept)
        XCTAssertEqual(ResumeSettings(), ResumeSettings(onStart: true, maxAgeSeconds: 1800, saveSeconds: 5))
    }

    func testPausedResumeKeepsItsPositionAndRecordsAgain() {
        var p = player()
        XCTAssertTrue(p.startResume(ResumePlan(position: TrackPosition(playlist: 0, track: 1), offsetSeconds: 33.5, paused: true)))
        p.advance(frames: secs(p, 10))
        let r = p.resumeRecord(catalog: catalog)
        XCTAssertEqual(r?.pos ?? -1, 33.5, accuracy: 1e-4)
        XCTAssertEqual(r?.paused, true)
    }

    func testSaveDueDecision() {
        let s = ResumeSettings()
        XCTAssertTrue(Resume.isSaveDue(now: 100, lastSave: nil, settings: s))
        XCTAssertFalse(Resume.isSaveDue(now: 104.99, lastSave: 100, settings: s))
        XCTAssertTrue(Resume.isSaveDue(now: 105, lastSave: 100, settings: s))
        XCTAssertTrue(Resume.isSaveDue(now: 90, lastSave: 100, settings: s), "the clock went back")
        XCTAssertFalse(Resume.isSaveDue(now: 102, lastSave: 100, settings: ResumeSettings(saveSeconds: 0)), "0 falls back to 5 s")
        XCTAssertTrue(Resume.isSaveDue(now: 101, lastSave: 100, settings: ResumeSettings(saveSeconds: 1)))
    }

    func testControllerSavesOnScheduleAndRemovesWhenNothingPlays() {
        var p = player()
        p.play(TrackPosition(playlist: 0, track: 0))
        let store = InMemoryResumeStore()
        let clock = ManualWallClock(nowSeconds: 1000)
        var c = ResumeController()
        XCTAssertTrue(c.saveIfDue(player: p, catalog: catalog, store: store, clock: clock))
        XCTAssertEqual(store.entry?.savedAt, 1000)
        clock.advance(seconds: 3)
        XCTAssertFalse(c.saveIfDue(player: p, catalog: catalog, store: store, clock: clock))
        clock.advance(seconds: 2)
        p.stop()
        XCTAssertTrue(c.saveIfDue(player: p, catalog: catalog, store: store, clock: clock))
        XCTAssertNil(store.entry)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testStartUpResumesOrDropsTheStoredRecord() {
        let rec = engineRecord([0, 0], "b.wav", 5, paused: false).record
        let clock = ManualWallClock(nowSeconds: 5000)
        var fresh = player()
        let store = InMemoryResumeStore(entry: ResumeEntry(record: rec, savedAt: 4990))
        var c = ResumeController()
        XCTAssertTrue(c.startUp(player: &fresh, catalog: catalog, store: store, clock: clock))
        XCTAssertEqual(fresh.current?.position, TrackPosition(playlist: 0, track: 1))
        XCTAssertNotNil(store.entry)

        var old = player()
        let oldStore = InMemoryResumeStore(entry: ResumeEntry(record: rec, savedAt: 1000))
        XCTAssertFalse(c.startUp(player: &old, catalog: catalog, store: oldStore, clock: clock))
        XCTAssertNil(old.current)
        XCTAssertNil(oldStore.entry)
        XCTAssertFalse(c.startUp(player: &old, catalog: catalog, store: InMemoryResumeStore(), clock: clock))
    }
}
