// Resume after an engine restart (slice 8; docs/audio-spec-1.md "Resume", fixture resume_flow.json).
//
// CONTROL SIDE ONLY. Nothing in this file runs on the render callback: it allocates (strings, arrays, a store), reads a wall clock and may touch a file
// through a `ResumeStore`. The only things it reads from the engine are values the render side already keeps (`Mixer.transport`, `Deck`, `Playback`);
// it adds no per-frame state.

/// What Python's `resume.json` holds, without its wall-clock `saved` stamp (the stamp travels in `ResumeEntry`): the live track by place and by stable
/// library file id, the position in the FILE in seconds (a paused track keeps its position) and the paused flag.
public struct ResumeRecord: Codable, Equatable {
    /// `[playlist, track]` as the record was written. Not trusted at start-up: the place is found again by `id`.
    public var pt: [Int]
    /// The stable library file id of the track (never an index: playlists are edited).
    public var id: String
    public var pos: Double
    public var paused: Bool

    public init(pt: [Int], id: String, pos: Double, paused: Bool) {
        self.pt = pt
        self.id = id
        self.pos = pos
        self.paused = paused
    }
}

/// The three settings of the decision (2026-11-22): `resume_on_start`, `resume_max_age_s`, `resume_save_s`.
public struct ResumeSettings: Equatable {
    public var onStart: Bool
    public var maxAgeSeconds: Double
    public var saveSeconds: Double

    public static let defaultMaxAgeSeconds = 1800.0
    public static let defaultSaveSeconds = 5.0

    public init(onStart: Bool = true, maxAgeSeconds: Double = ResumeSettings.defaultMaxAgeSeconds, saveSeconds: Double = ResumeSettings.defaultSaveSeconds) {
        self.onStart = onStart
        self.maxAgeSeconds = maxAgeSeconds
        self.saveSeconds = saveSeconds
    }
}

/// The library as the resume logic sees it: per playlist, the stable library file id of each track, in order. The engine's `TrackID` is a show-local
/// number; the record holds the file id, so the app supplies this mapping (control side, rebuilt when a playlist is edited).
public struct ResumeCatalog: Equatable {
    public var playlists: [[String]]

    public init(playlists: [[String]]) { self.playlists = playlists }

    public func fileID(at position: TrackPosition) -> String? {
        guard playlists.indices.contains(position.playlist), playlists[position.playlist].indices.contains(position.track) else { return nil }
        return playlists[position.playlist][position.track]
    }

    /// Where a file is now. A file in more than one playlist: the recorded playlist wins if it still holds the id (and within it the recorded track if
    /// that still holds the id, else the first track that does); otherwise the first playlist (in order) that holds it. nil: in no playlist.
    public func position(of id: String, recordedPt pt: [Int]) -> TrackPosition? {
        let recorded = pt.count == 2 ? TrackPosition(playlist: pt[0], track: pt[1]) : nil
        if let r = recorded, playlists.indices.contains(r.playlist), playlists[r.playlist].contains(id) {
            if playlists[r.playlist].indices.contains(r.track), playlists[r.playlist][r.track] == id { return r }
            return TrackPosition(playlist: r.playlist, track: playlists[r.playlist].firstIndex(of: id)!)
        }
        for p in playlists.indices {
            if let t = playlists[p].firstIndex(of: id) { return TrackPosition(playlist: p, track: t) }
        }
        return nil
    }
}

/// What to start after a restart: the place found again from the id, the position in the file, the paused flag and a crossfade of 0 (a resumed start is a cut).
public struct ResumePlan: Equatable {
    public var position: TrackPosition
    public var offsetSeconds: Double
    public var paused: Bool
    public var crossfadeMs: Int { 0 }
}

/// The result of looking at a record at start-up: what to start (nil: nothing) and whether the record stays in the store (`record_kept`).
public struct ResumeDecision: Equatable {
    public var plan: ResumePlan?
    public var recordKept: Bool
}

public enum Resume {
    /// Decides what a record means at start-up.
    /// - Not resuming (`resume_on_start` off): no plan, the record is KEPT (it is not ours to discard; the next autosave replaces it).
    /// - Older than `resume_max_age_s` (strictly: exactly the limit still resumes), unknown file, file in no playlist, or a position that is not a number: dropped.
    /// - A negative age (the wall clock went back) counts as 0.
    public static func plan(record: ResumeRecord, ageSeconds: Double, catalog: ResumeCatalog, settings: ResumeSettings = ResumeSettings()) -> ResumeDecision {
        guard settings.onStart else { return ResumeDecision(plan: nil, recordKept: true) }
        guard !ageSeconds.isNaN, record.pos.isFinite else { return ResumeDecision(plan: nil, recordKept: false) }
        guard max(0, ageSeconds) <= settings.maxAgeSeconds else { return ResumeDecision(plan: nil, recordKept: false) }
        guard let position = catalog.position(of: record.id, recordedPt: record.pt) else { return ResumeDecision(plan: nil, recordKept: false) }
        return ResumeDecision(plan: ResumePlan(position: position, offsetSeconds: max(0, record.pos), paused: record.paused), recordKept: true)
    }

    /// True when a periodic save is due: never saved, or `saveSeconds` have passed since the last one, or the wall clock went back. A save interval that is
    /// not a positive number falls back to the default (5 s). The caller runs this on the control thread (a timer there); there is no timer in AudioCore.
    public static func isSaveDue(now: Double, lastSave: Double?, settings: ResumeSettings = ResumeSettings()) -> Bool {
        guard let last = lastSave else { return true }
        let interval = settings.saveSeconds.isFinite && settings.saveSeconds > 0 ? settings.saveSeconds : ResumeSettings.defaultSaveSeconds
        return now < last || now - last >= interval
    }
}

extension PlaylistPlayer {
    /// What `resume.json` would hold now; nil when nothing is to be recorded:
    /// - no track plays (nothing started, ended, or `stop()` / a finished fade-out removed it);
    /// - a fade-out is running on the track (a deliberate end is on its way);
    /// - the track is not in the catalog.
    ///
    /// The record is the track the show is on (`current`): the background track when a voice-over is on top (the voice is never recorded, even with a
    /// trigger voice running; if the background has already ended and only the voice plays, nothing is recorded); during a crossfade the NEW track
    /// (the old one is only fading away). The position is the deck's position in the file (`Playback.filePositionFrames`), which a paused transport
    /// freezes. Read-only; control side.
    public func resumeRecord(catalog: ResumeCatalog) -> ResumeRecord? {
        guard let c = current, let deck = mixer.deck(c.deck), deck.isPlaying else { return nil }
        if let f = deck.fade, f.direction == .down { return nil }
        let now = mixer.transport.playFrame
        guard let playback = deck.playback, let frames = playback.filePositionFrames(at: now), let id = catalog.fileID(at: c.position) else { return nil }
        return ResumeRecord(pt: [c.position.playlist, c.position.track], id: id, pos: Double(frames) / Double(mixer.transport.sampleRate), paused: mixer.transport.isPaused)
    }

    /// Starts a resume plan through the normal start path (`play`: trim window, loop and once gate, trigger arming, level match) with the transport
    /// paused or running as recorded, a cut, and NO fade-in at A (start volume 1, fade-in 0) whatever the track's trim says. Returns false when the
    /// place is not in the playlists or the pool refused the start.
    @discardableResult
    public mutating func startResume(_ plan: ResumePlan) -> Bool {
        if plan.paused { pause() } else { resume() }
        return play(plan.position, crossfadeMs: plan.crossfadeMs, offsetSeconds: plan.offsetSeconds, fadeIn: false)
    }
}

// MARK: store and clock

/// A record and the wall-clock second it was written at (Python's `saved`).
public struct ResumeEntry: Equatable {
    public var record: ResumeRecord
    public var savedAt: Double

    public init(record: ResumeRecord, savedAt: Double) {
        self.record = record
        self.savedAt = savedAt
    }
}

/// Where the record lives between runs. Slice 8 has only `InMemoryResumeStore`; the file-backed store is integration work (Apps/StageEngine) and MUST:
/// - write atomically: write a temp file in the same directory, flush it (fsync), then rename it over the old one, so a crash or power loss leaves the
///   old record or the new one, never half of one;
/// - be called from the control thread only, never from the render callback (it does file I/O and allocates);
/// - treat an unreadable or corrupt file as no record (`load` returns nil).
public protocol ResumeStore {
    func load() -> ResumeEntry?
    func save(_ entry: ResumeEntry)
    func remove()
}

/// A store in memory, for tests. A class so a test can look at it after handing it over.
public final class InMemoryResumeStore: ResumeStore {
    public private(set) var entry: ResumeEntry?
    public private(set) var saveCount = 0
    public private(set) var removeCount = 0

    public init(entry: ResumeEntry? = nil) { self.entry = entry }

    public func load() -> ResumeEntry? { entry }
    public func save(_ entry: ResumeEntry) { self.entry = entry; saveCount += 1 }
    public func remove() { entry = nil; removeCount += 1 }
}

/// Wall-clock seconds (any fixed epoch), injected: the frame clock does not survive a restart, so the age of a record needs this one.
public protocol WallClock {
    var nowSeconds: Double { get }
}

/// A wall clock a test moves by hand.
public final class ManualWallClock: WallClock {
    public var nowSeconds: Double

    public init(nowSeconds: Double = 0) { self.nowSeconds = nowSeconds }

    public func advance(seconds: Double) { nowSeconds += seconds }
}

/// The control-thread side of resume: the decision at start-up and the periodic save, over a store and a clock.
public struct ResumeController {
    public var settings: ResumeSettings
    public private(set) var lastSave: Double?

    public init(settings: ResumeSettings = ResumeSettings()) { self.settings = settings }

    /// At start-up: reads the record, decides, drops it from the store when it is dropped, and starts the track. Returns whether a track was started.
    @discardableResult
    public mutating func startUp<R: RandomSource>(player: inout PlaylistPlayer<R>, catalog: ResumeCatalog, store: ResumeStore, clock: WallClock) -> Bool {
        guard let entry = store.load() else { return false }
        let decision = Resume.plan(record: entry.record, ageSeconds: clock.nowSeconds - entry.savedAt, catalog: catalog, settings: settings)
        if !decision.recordKept { store.remove() }
        guard let plan = decision.plan else { return false }
        return player.startResume(plan)
    }

    /// Called by a control-thread timer: when a save is due writes the record (or removes it when nothing is to be recorded). Returns whether it ran.
    @discardableResult
    public mutating func saveIfDue<R: RandomSource>(player: PlaylistPlayer<R>, catalog: ResumeCatalog, store: ResumeStore, clock: WallClock) -> Bool {
        let now = clock.nowSeconds
        guard Resume.isSaveDue(now: now, lastSave: lastSave, settings: settings) else { return false }
        if let record = player.resumeRecord(catalog: catalog) { store.save(ResumeEntry(record: record, savedAt: now)) } else { store.remove() }
        lastSave = now
        return true
    }
}
