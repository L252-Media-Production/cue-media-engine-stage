/// Playlists and a mixer together: plays a track and, when it ends by itself, starts what follows it (docs/audio-spec-1.md, "Play modes and shuffle bag").
///
/// The advance is driven only by the frames given to `advance(frames:)`. The mixer is stepped to the exact frame a deck ends at and the successor starts
/// there, so a chain of tracks has no gap and no dependency on how big the steps of the caller are. There is no wall clock and no timer.
///
/// It also runs the trigger points of the playing track: the file position of its deck is watched, and the step is cut at the exact frame a point is reached
/// (or a pass begins), so the voice-over starts there whatever the size of the caller's steps. The voice is a second `Deck` on top (`Mixer.startOnTop`).
///
/// Real-time: `advance(frames:)` allocates nothing while no track ends and no trigger fires. Starting the next track or a trigger voice appends a deck to the
/// mixer, which can allocate (and ended decks are kept by the mixer, so a long show grows that array by one deck per track and one per fired trigger): see
/// `Mixer.start` and `Mixer.startOnTop`.
public struct PlaylistPlayer<Random: RandomSource> {
    /// The track that is playing: its place, stable id and deck.
    public struct Current: Equatable {
        public var position: TrackPosition
        public var track: TrackID
        public var deck: Deck.ID
    }

    public private(set) var mixer: Mixer
    public private(set) var playlists: [Playlist]
    public let policy: TrimPolicy
    public private(set) var current: Current?
    private var random: Random
    public var settings: TriggerSettings
    private var readiness: any TargetReadiness
    private var ducking: any DuckingHook
    /// What the playing track's deck has done with its trigger points.
    public private(set) var watch = TriggerWatch()
    /// The deck of the trigger voice that is playing on top, if any.
    public private(set) var topDeck: Deck.ID?

    /// A trigger that fired: which point, which target, the voice's deck, and the exact play frame it started at.
    public struct Fired: Equatable {
        public var trigger: TriggerID
        public var target: TrackID
        public var deck: Deck.ID
        public var frame: Int64
    }

    public static var firedCapacity: Int { 32 }
    /// The triggers that fired during the last `play`, `seekLive` or `advance`, in order. Preallocated; cleared in place.
    public private(set) var fired: [Fired] = []
    /// Fires that did not fit in `fired` (they still happened: see `Deck.isTop` decks of the mixer).
    public private(set) var droppedFires = 0

    /// The most tracks one `advance` starts. A playlist whose tracks are shorter than a frame would otherwise never let time move.
    public static var maxStartsPerAdvance: Int { 64 }

    /// Setup path.
    public init(
        playlists: [Playlist], policy: TrimPolicy, random: Random, mixer: Mixer = Mixer(),
        readiness: any TargetReadiness = NoTargets(), ducking: any DuckingHook = NoDucking(), settings: TriggerSettings = TriggerSettings()
    ) {
        self.playlists = playlists
        self.policy = policy
        self.random = random
        self.mixer = mixer
        self.readiness = readiness
        self.ducking = ducking
        self.settings = settings
        fired.reserveCapacity(Self.firedCapacity)
    }

    private mutating func clearFired() {
        fired.removeAll(keepingCapacity: true)
        droppedFires = 0
    }

    // MARK: editing the play data

    /// Setup path: may allocate (a shuffle bag is reset or resized).
    public mutating func setMode(_ mode: PlaylistMode, ofPlaylist p: Int) {
        guard playlists.indices.contains(p) else { return }
        playlists[p].mode = mode
    }

    /// Changes what a track does when it ends. If it is playing, the pass that is running is played out and the NEW action decides what follows:
    /// `followPlayMode` the play mode, `stop` nothing, `loop` the track starts again. A switch TO `twice` while the track plays changes nothing for
    /// that run (not specified; docs/audio-conformance.md, "Stage decisions to make").
    public mutating func setEnd(_ end: TrackEnd, ofTrack id: TrackID, inPlaylist p: Int) {
        guard playlists.indices.contains(p), let i = playlists[p].index(of: id) else { return }
        playlists[p].tracks[i].end = end
        if let c = current, c.track == id, c.position.playlist == p, end != .twice {
            mixer.finishCurrentPass(of: c.deck)
        }
    }

    // MARK: trigger points

    /// Adds a trigger point to a track. Setup path. False (and counted in the list's `overflowCount`) when the track already has `TriggerList.capacity` points.
    @discardableResult
    public mutating func addTrigger(_ trigger: Trigger, toTrack id: TrackID, inPlaylist p: Int) -> Bool {
        editTriggers(id, p) { $0.add(trigger) } ?? false
    }

    /// Setup path.
    public mutating func removeTrigger(_ trigger: TriggerID, fromTrack id: TrackID, inPlaylist p: Int) {
        _ = editTriggers(id, p) { $0.remove(trigger) }
    }

    /// Setup path. A trigger that is switched off while it waits is dropped.
    public mutating func setTrigger(_ trigger: TriggerID, enabled: Bool, ofTrack id: TrackID, inPlaylist p: Int) {
        _ = editTriggers(id, p) { $0.setEnabled(enabled, for: trigger) }
    }

    private mutating func editTriggers<T>(_ id: TrackID, _ p: Int, _ body: (inout TriggerList) -> T) -> T? {
        guard playlists.indices.contains(p), let i = playlists[p].index(of: id) else { return nil }
        let old = playlists[p].tracks[i].triggers
        let result = body(&playlists[p].tracks[i].triggers)
        if let c = current, c.track == id, c.position.playlist == p { watch.remap(from: old, to: playlists[p].tracks[i].triggers) }
        return result
    }

    /// Skips the trigger that is coming next on the playing track, once. Returns it, or nil when nothing is coming.
    @discardableResult
    public mutating func skipNextTrigger() -> TriggerID? {
        guard let list = currentTriggers(), let c = current, let pb = mixer.deck(c.deck)?.playback,
              let i = watch.nextPending(pb, list, at: mixer.transport.playFrame) else { return nil }
        watch.skip(i)
        return list.items[i].id
    }

    /// Moves the playing track to `seconds` of its file (held to [A, B - 0.3 s]). Ignored while a voice plays on top: the live deck is then the voice.
    /// Trigger points ahead of the new position are armed again, those behind it are done, whatever the seek jumped over does not fire.
    @discardableResult
    public mutating func seekLive(toSeconds seconds: Double) -> Bool {
        guard let c = current, mixer.deck(c.deck)?.isPlaying == true, !isVoiceOnTop else { return false }
        clearFired()
        mixer.seek(c.deck, toSeconds: seconds)
        if let list = currentTriggers(), let pb = mixer.deck(c.deck)?.playback { watch.seeked(pb, list, at: mixer.transport.playFrame) }
        serviceTriggers()
        return true
    }

    private var isVoiceOnTop: Bool { topDeck.flatMap { mixer.deck($0)?.isPlaying } ?? false }

    /// The trigger points of the playing track (a read: no copy of the points).
    private func currentTriggers() -> TriggerList? {
        guard let c = current, playlists.indices.contains(c.position.playlist), let i = playlists[c.position.playlist].index(of: c.track) else { return nil }
        return playlists[c.position.playlist].tracks[i].triggers
    }

    /// Takes in what the playhead did and fires what is due. Allocates nothing unless a voice starts (`Mixer.startOnTop`).
    private mutating func serviceTriggers() {
        guard let c = current, let list = currentTriggers(), let pb = mixer.deck(c.deck)?.playback, mixer.deck(c.deck)?.isPlaying == true else { return }
        let now = mixer.transport.playFrame
        watch.observe(pb, list, at: now)
        let waitFrames = Int64((settings.waitLimitSeconds * Double(mixer.transport.sampleRate)).rounded())
        for i in list.items.indices where watch.isDue(i) {
            let t = list.items[i]
            if !t.enabled || watch.isSkipped(i) || !settings.armed || isVoiceOnTop {
                // Gone, skipped by the operator, switched off, or a Play on Top is already running: the point is skipped, not queued.
                watch.unskip(i)
                watch.clearDue(i)
                continue
            }
            switch readiness.state(of: t.target) {
            case .missing:
                watch.clearDue(i)
            case .loading:
                if now - watch.dueFrame(i) > waitFrames { watch.clearDue(i) }
            case .ready(let length):
                // A voice has no trim and no fade-in, and plays one pass.
                let plan = TrackPlan(trim: Trim(), policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), fileLength: length, sampleRate: mixer.transport.sampleRate)
                let id = mixer.startOnTop(plan)
                topDeck = id
                if fired.count < Self.firedCapacity {
                    fired.append(Fired(trigger: t.id, target: t.target, deck: id, frame: now))
                } else {
                    droppedFires += 1
                }
                ducking.voiceStarted(id, over: c.deck, atFrame: now)
                watch.clearDue(i)
            }
        }
    }

    // MARK: playing

    /// Starts a track with a cut (the old deck and any voice on top are removed at once). Does nothing for a position that is not in the playlists.
    @discardableResult
    public mutating func play(_ position: TrackPosition, crossfadeMs: Int = 0) -> Bool {
        guard playlists.indices.contains(position.playlist), playlists[position.playlist].tracks.indices.contains(position.track) else { return false }
        let t = playlists[position.playlist].tracks[position.track]
        let plan = TrackPlan(trim: t.trim, policy: policy, fileLength: t.lengthSeconds, end: t.end, sampleRate: mixer.transport.sampleRate)
        clearFired()
        releaseVoice()
        let id = mixer.start(plan, crossfadeMs: crossfadeMs)
        current = Current(position: position, track: t.id, deck: id)
        if let pb = mixer.deck(id)?.playback { watch.begin(pb, t.triggers, at: mixer.transport.playFrame) }
        serviceTriggers()      // a point at A fires on the first frame
        return true
    }

    public mutating func pause() { mixer.pause() }
    public mutating func resume() { mixer.resume() }

    /// Stops what plays, a voice on top included (a cut). Setup and UI path.
    public mutating func stop() {
        releaseVoice()
        mixer.stopAll()
        current = nil
    }

    /// The voice on top, if any, is about to be removed by a cut: tell the ducking hook.
    private mutating func releaseVoice() {
        if let v = topDeck, mixer.deck(v)?.isPlaying == true { ducking.voiceEnded(v, atFrame: mixer.transport.playFrame) }
        topDeck = nil
    }

    /// The most `advance` events it handles at one frame before it moves time on anyway.
    private static var maxEventsAtOneFrame: Int { 8 }

    /// Moves time by `frames`. The step is cut at every frame something happens: the playing track ends (what follows starts there), a trigger point is reached
    /// or a pass begins (a due voice starts there), the voice on top ends. The result does not depend on how the caller splits time into steps.
    public mutating func advance(frames: Int64) {
        var left = frames
        var starts = 0
        var zeroSteps = 0
        clearFired()
        serviceTriggers()      // a target may have become ready since the last call
        while left > 0 {
            let now = mixer.transport.playFrame
            var step = left
            if let c = current, let pb = mixer.deck(c.deck)?.playback {
                if let end = pb.endFrame { step = min(step, max(0, end - now)) }
                if let list = currentTriggers(), let ev = watch.nextEvent(pb, list, after: now) { step = min(step, max(0, ev - now)) }
            }
            if let v = topDeck, let end = mixer.deck(v)?.playback?.endFrame { step = min(step, max(0, end - now)) }
            if step == 0 {
                zeroSteps += 1
                if zeroSteps > Self.maxEventsAtOneFrame { step = left }      // nothing moves time: move it
            } else {
                zeroSteps = 0
            }
            mixer.advance(frames: step)
            left -= step
            for e in mixer.ended where e.deck == topDeck {
                ducking.voiceEnded(e.deck, atFrame: e.frame)
                topDeck = nil
            }
            if let c = current {
                var ended = false
                for e in mixer.ended where e.deck == c.deck { ended = true }
                if ended {
                    starts += 1
                    guard starts <= Self.maxStartsPerAdvance else { current = nil; return }
                    startSuccessor(of: c)
                    continue
                }
            }
            serviceTriggers()
        }
    }

    /// The track at `c` ended: what follows it, by its end action as it is NOW and its playlist's play mode.
    private mutating func startSuccessor(of c: Current) {
        // The track may have been moved or removed while it played: follow its id.
        var from = c.position
        if playlists.indices.contains(from.playlist), let i = playlists[from.playlist].index(of: c.track) {
            from.track = i
        } else {
            current = nil
            return
        }
        switch PlayOrder.successor(after: from, in: &playlists, using: &random) {
        case .stopped:
            current = nil
        case .same:
            play(from)
        case .track(let next):
            play(next)
        }
    }
}
