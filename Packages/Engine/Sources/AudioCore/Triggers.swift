/// Trigger points (docs/audio-spec-1.md, "Trigger points"): a voice-over is fired from a position in the FILE of a track. Plain data and pure arithmetic; the
/// engine that runs them is `PlaylistPlayer`.

public struct TriggerID: Hashable {
    public var raw: Int

    public init(_ raw: Int) { self.raw = raw }
}

/// One trigger point of a track: when the playhead reaches `atSeconds` of the file, `target` plays on top of the track.
public struct Trigger: Equatable {
    public var id: TriggerID
    /// A position in the FILE, not relative to A.
    public var atSeconds: Double
    public var target: TrackID
    /// Fires in the first pass only (a loop or a second pass does not fire it again).
    public var once: Bool
    public var enabled: Bool

    public init(id: TriggerID, atSeconds: Double, target: TrackID, once: Bool = false, enabled: Bool = true) {
        self.id = id
        self.atSeconds = atSeconds
        self.target = target
        self.once = once
        self.enabled = enabled
    }
}

/// The trigger points of one track, kept sorted by `atSeconds` (points at the same time keep the order they were added in).
///
/// The capacity is fixed: `capacity` points. A point that does not fit is refused and counted in `overflowCount`; nothing crashes. The storage is reserved on
/// the first `add` (a setup path); the real-time code only reads it.
public struct TriggerList: Equatable {
    public static let capacity = 64

    public private(set) var items: [Trigger] = []
    /// How many points were refused because the list was full.
    public private(set) var overflowCount = 0

    public init() {}

    /// Setup path: may allocate.
    @discardableResult
    public mutating func add(_ trigger: Trigger) -> Bool {
        guard items.count < Self.capacity else {
            overflowCount += 1
            return false
        }
        if items.isEmpty { items.reserveCapacity(Self.capacity) }
        var i = items.count
        while i > 0, items[i - 1].atSeconds > trigger.atSeconds { i -= 1 }
        items.insert(trigger, at: i)
        return true
    }

    /// Setup path.
    public mutating func remove(_ id: TriggerID) { items.removeAll { $0.id == id } }

    /// Setup path.
    public mutating func setEnabled(_ enabled: Bool, for id: TriggerID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].enabled = enabled }
    }
}

/// What the engine knows about a trigger's target before firing it. A target has to be decoded; in the real engine that takes time.
public enum TargetState: Equatable {
    /// Decoded and playable; `lengthSeconds` is how long it plays.
    case ready(lengthSeconds: Double)
    /// Not decoded yet: the trigger waits (see `TriggerSettings.waitLimitSeconds`).
    case loading
    /// Not in the library: the trigger is given up on.
    case missing
}

/// Tells whether a trigger's target can play now. Tests drive it from the fixture; the real engine answers from its decode cache. Called from the audio
/// path: it must not block or allocate.
public protocol TargetReadiness {
    func state(of target: TrackID) -> TargetState
}

/// The hook the ducking slice plugs into. A voice on top starts over the deck it plays on (the background); when it ends the background is released.
/// The trigger code calls these at the exact frames and does nothing else about ducking.
public protocol DuckingHook {
    mutating func voiceStarted(_ voice: Deck.ID, over background: Deck.ID?, atFrame frame: Int64)
    mutating func voiceEnded(_ voice: Deck.ID, atFrame frame: Int64)
}

/// The default hook: no ducking.
public struct NoDucking: DuckingHook {
    public init() {}
    public mutating func voiceStarted(_ voice: Deck.ID, over background: Deck.ID?, atFrame frame: Int64) {}
    public mutating func voiceEnded(_ voice: Deck.ID, atFrame frame: Int64) {}
}

/// A readiness that knows no target: every trigger is given up on.
public struct NoTargets: TargetReadiness {
    public init() {}
    public func state(of target: TrackID) -> TargetState { .missing }
}

/// Settings of the trigger engine that the spec does not pin.
public struct TriggerSettings: Equatable {
    /// Triggers fire only while armed (the operator's "Auto triggers" switch).
    public var armed = true
    /// How long a due trigger waits for a target that is still loading before it is given up on. NOT contract: neither the spec text nor a fixture says it
    /// (the Python player gives up after 30 s); it is Stage's own default until a decision is made.
    public var waitLimitSeconds = 30.0

    public init(armed: Bool = true, waitLimitSeconds: Double = 30) {
        self.armed = armed
        self.waitLimitSeconds = waitLimitSeconds
    }
}

/// What one watched deck has done with the trigger points of its track. Bit `i` is the point at index `i` of the (sorted) `TriggerList`.
///   fired: dealt with in this pass (fired, skipped, or not eligible), armed again on a new pass or a seek back.
///   due: the time has come but the point has not started yet (its target is loading).
///   skipped: skipped ahead of time by the operator.
/// All of it is integers; every method is arithmetic on them (no allocation).
public struct TriggerWatch: Equatable {
    public private(set) var fired: UInt64 = 0
    public private(set) var due: UInt64 = 0
    public private(set) var skipped: UInt64 = 0
    /// The play frame each due point became due at. Fixed storage, set up once.
    private(set) var dueSince: [Int64]
    private var dueScratch: [Int64]
    /// The file position (frames) the watch has seen up to.
    public private(set) var lastFilePosition: Int64 = 0
    /// The pass the watch is in, and the passes that came before a seek.
    public private(set) var passIndex = 0
    public private(set) var passesBefore = 0

    /// Setup path: allocates the storage of `dueSince`.
    public init() {
        dueSince = [Int64](repeating: 0, count: TriggerList.capacity)
        dueScratch = dueSince
    }

    private static func bit(_ i: Int) -> UInt64 { 1 << UInt64(i) }

    private func atFrame(_ t: Trigger, _ plan: TrackPlan) -> Int64 { Int64((t.atSeconds * Double(plan.sampleRate)).rounded()) }

    /// Enabled and inside the part of the file the deck plays: a point before A, or at or after B, never fires.
    private func isEligible(_ t: Trigger, _ plan: TrackPlan) -> Bool {
        let at = atFrame(t, plan)
        return t.enabled && at >= plan.loFrames && at < plan.hiFrames
    }

    private mutating func firedUpTo(_ position: Int64, _ list: TriggerList, _ plan: TrackPlan) {
        fired = 0
        for i in list.items.indices where atFrame(list.items[i], plan) <= position { fired |= Self.bit(i) }
    }

    /// A deck starts being watched. A start at A has everything ahead of it (a point at A itself fires); a start part-way in has everything behind it done.
    /// Setup path in the sense that it runs when a deck starts; it allocates nothing.
    public mutating func begin(_ playback: Playback, _ list: TriggerList, at frame: Int64) {
        due = 0
        skipped = 0
        passesBefore = 0
        passIndex = playback.passIndex(at: frame) ?? 0
        let pos = playback.filePositionFrames(at: frame) ?? playback.plan.baseFrames
        if playback.plan.isFresh {
            lastFilePosition = playback.plan.loFrames - 1
            fired = 0
        } else {
            lastFilePosition = pos
            firedUpTo(pos, list, playback.plan)
        }
    }

    /// The deck was moved: what is ahead is armed again, what is behind is done, what was waiting is dropped.
    public mutating func seeked(_ playback: Playback, _ list: TriggerList, at frame: Int64) {
        passesBefore += passIndex
        passIndex = playback.passIndex(at: frame) ?? 0
        let pos = playback.filePositionFrames(at: frame) ?? playback.plan.baseFrames
        lastFilePosition = pos
        due = 0
        firedUpTo(pos, list, playback.plan)
    }

    /// Takes in what the playhead did up to `frame`: the points it crossed become due. Call it at every frame returned by `nextEvent`, and after any step.
    public mutating func observe(_ playback: Playback, _ list: TriggerList, at frame: Int64) {
        guard let pos = playback.filePositionFrames(at: frame), let pass = playback.passIndex(at: frame) else { return }
        if pass != passIndex {      // a pass ended: finish it, then start the next one from A
            cross(from: lastFilePosition, to: playback.plan.hiFrames, list, playback.plan, frame)
            passIndex = pass
            lastFilePosition = playback.plan.loFrames - 1
            fired = 0
        }
        cross(from: lastFilePosition, to: pos, list, playback.plan, frame)
        lastFilePosition = pos
    }

    /// Points with `from < at <= to` have been reached.
    private mutating func cross(from: Int64, to: Int64, _ list: TriggerList, _ plan: TrackPlan, _ frame: Int64) {
        for i in list.items.indices {
            let t = list.items[i]
            let b = Self.bit(i)
            let at = atFrame(t, plan)
            if (fired | due) & b != 0 || !(from < at && at <= to) { continue }
            fired |= b
            guard isEligible(t, plan) else { continue }
            if t.once, passesBefore + passIndex > 0 { continue }
            due |= b
            dueSince[i] = frame
        }
    }

    /// The first play frame after `frame` at which `observe` has something to do: a point of the running pass is reached, or the next pass begins. nil when
    /// nothing is coming before the deck ends. Pure arithmetic.
    public func nextEvent(_ playback: Playback, _ list: TriggerList, after frame: Int64) -> Int64? {
        guard let pos = playback.filePositionFrames(at: frame) else { return nil }
        let boundary = playback.nextPassBoundary(after: frame)
        var best = boundary
        for i in list.items.indices {
            let t = list.items[i]
            if (fired | due) & Self.bit(i) != 0 || !isEligible(t, playback.plan) { continue }
            let at = atFrame(t, playback.plan)
            guard at > pos else { continue }
            let f = frame + (at - pos)
            if let b = boundary, f > b { continue }
            if let e = playback.endFrame, f >= e { continue }
            if best == nil || f < best! { best = f }
        }
        return best
    }

    /// The index of the next point that would fire (not fired, not skipped, eligible, ahead of `pos`), for the operator's "skip next".
    public func nextPending(_ playback: Playback, _ list: TriggerList, at frame: Int64) -> Int? {
        guard let pos = playback.filePositionFrames(at: frame) else { return nil }
        for i in list.items.indices where (fired | due | skipped) & Self.bit(i) == 0 && isEligible(list.items[i], playback.plan) && atFrame(list.items[i], playback.plan) > pos {
            return i
        }
        return nil
    }

    // MARK: used by the player

    func isDue(_ i: Int) -> Bool { due & Self.bit(i) != 0 }
    func isSkipped(_ i: Int) -> Bool { skipped & Self.bit(i) != 0 }
    func dueFrame(_ i: Int) -> Int64 { dueSince[i] }

    mutating func clearDue(_ i: Int) { due &= ~Self.bit(i) }
    mutating func skip(_ i: Int) { skipped |= Self.bit(i) }
    mutating func unskip(_ i: Int) { skipped &= ~Self.bit(i) }

    /// The list changed (a point added or removed): moves the bits to the new indices by point id. Setup path; allocates nothing.
    mutating func remap(from old: TriggerList, to new: TriggerList) {
        var f: UInt64 = 0, d: UInt64 = 0, s: UInt64 = 0
        for j in new.items.indices {
            guard let i = old.items.firstIndex(where: { $0.id == new.items[j].id }) else { continue }
            let ob = Self.bit(i), nb = Self.bit(j)
            if fired & ob != 0 { f |= nb }
            if due & ob != 0 { d |= nb; dueScratch[j] = dueSince[i] }
            if skipped & ob != 0 { s |= nb }
        }
        fired = f
        due = d
        skipped = s
        swap(&dueSince, &dueScratch)
    }
}
