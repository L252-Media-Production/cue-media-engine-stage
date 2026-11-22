import AudioCore

/// The slice of the spec that AudioCore implements so far, as pure functions. Everything else is still pending
/// (the protocol's default), so those tests are skipped until the transport port provides it.
///
/// Implemented: trim windows, fades at A and B, passes and end actions (trim.json, end_actions.json), integrated loudness and level match (levelmatch.json), play modes, next_in_order and the shuffle bag (play_modes.json, end_action_switched_mid_play), trigger points (triggers.json), the fade and crossfade rules (through `Mixer`, `Deck`, `Fade`, `CrossfadeSettings`: fades.json and xfade.json), the background multiplier `10^(-gr/20)`,
/// `duck_key`, `duck_curve` (hold on / off), `duck_smooth`, `input_target_db`, the resume record, plan and start (resume_flow.json).
struct AudioCoreSubject: AudioSpecSubject {
    func fadeGain(_ direction: FadeDirection, x: Double) throws -> Double {
        let fade = Fade(direction: direction == .up ? .up : .down, from: direction == .up ? 0 : 1, to: direction == .up ? 1 : 0, startFrame: 0, lengthFrames: 1)
        return fade.gain(progress: x)
    }

    /// A deck is playing, a second one starts with a crossfade of `fadeMs`, and the mixer runs `elapsedS` seconds.
    func crossfadeState(fadeMs: Int, elapsedS: Double) throws -> CrossfadeState {
        var mixer = Mixer()
        let old = mixer.start()
        let new = mixer.start(crossfadeMs: fadeMs)
        mixer.advance(frames: mixer.transport.frames(seconds: elapsedS))
        return state(of: mixer, old: old, new: new)
    }

    /// The same, with the transport paused at `pausedAtS` of the wall clock for `pausedForS`, read at `atWallS`.
    func crossfadeState(fadeMs: Int, pausedAtS: Double, pausedForS: Double, atWallS: Double) throws -> CrossfadeState {
        var mixer = Mixer()
        let old = mixer.start()
        let new = mixer.start(crossfadeMs: fadeMs)
        let pauseAt = pausedAtS, resumeAt = pausedAtS + pausedForS
        var wall = 0.0
        func run(to target: Double) {
            let t = min(target, atWallS)
            if t > wall {
                mixer.advance(frames: mixer.transport.frames(seconds: t - wall))
                wall = t
            }
        }
        run(to: pauseAt)
        if atWallS > pauseAt { mixer.pause() }
        run(to: resumeAt)
        if atWallS > resumeAt { mixer.resume() }
        run(to: atWallS)
        return state(of: mixer, old: old, new: new)
    }

    private func state(of mixer: Mixer, old: Deck.ID, new: Deck.ID) -> CrossfadeState {
        CrossfadeState(
            newGain: mixer.gain(of: new) ?? 0, oldGain: mixer.gain(of: old) ?? 0,
            oldStillPlaying: mixer.deck(old)?.isPlaying ?? false)
    }

    func fadeOutState(fadeMs: Int, elapsedS: Double) throws -> FadeOutState {
        var mixer = Mixer()
        let id = mixer.start()
        mixer.fadeOutLive(milliseconds: fadeMs)
        mixer.advance(frames: mixer.transport.frames(seconds: elapsedS))
        return FadeOutState(vol: mixer.gain(of: id) ?? 0, playing: mixer.deck(id)?.isPlaying ?? false)
    }

    func nothingLiveAfterFadeOut(fadeMs: Int) throws -> Bool {
        var mixer = Mixer()
        mixer.start()
        mixer.fadeOutLive(milliseconds: fadeMs)
        mixer.advance(frames: mixer.transport.frames(milliseconds: fadeMs))
        return mixer.live == nil
    }

    func crossfadeMs(explicitMs: Int?, ownMs: Int?, masterMs: Int) throws -> Int {
        CrossfadeSettings(masterMs: masterMs).timeMs(explicitMs: explicitMs, ownMs: ownMs)
    }

    /// A number goes to the engine as it is; text is refused unless it reads as a number (what a form field would send).
    func storeOwnCrossfade(seconds: FixtureScalar) throws -> (accepted: Bool, storedMs: Int?) {
        let value: Double?
        switch seconds {
        case .number(let n): value = n
        case .text(let t): value = Double(t)
        }
        let ms = value.flatMap(CrossfadeSettings.ownTimeMs(seconds:))
        return (ms != nil, ms)
    }

    /// Plays a track, then starts the next one the way `play_default` does with the crossfade transition, and reads the length of the fade it started.
    func playDefaultFadeLengthS(ownMs: Int?, masterMs: Int) throws -> Double {
        var mixer = Mixer()
        mixer.start()
        let ms = CrossfadeSettings(masterMs: masterMs).timeMs(ownMs: ownMs)
        let new = mixer.start(crossfadeMs: ms)
        return mixer.deck(new)?.fade?.lengthSeconds(sampleRate: mixer.transport.sampleRate) ?? 0
    }

    // MARK: trim.json

    private func trim(_ f: TrimFields) -> Trim {
        Trim(inPoint: f.inPoint, outPoint: f.outPoint, endsWithCut: f.end == "cut", fadeOutMs: f.fadeMs, fadeInMs: f.fadeInMs, fadesInAtStart: f.start == "fade")
    }

    private func fields(_ t: Trim) -> TrimFields {
        TrimFields(inPoint: t.inPoint, outPoint: t.outPoint, end: t.endsWithCut ? "cut" : nil, fadeMs: t.fadeOutMs, fadeInMs: t.fadeInMs, start: t.fadesInAtStart ? "fade" : nil)
    }

    private func policy(_ c: TrimConfig) -> TrimPolicy {
        TrimPolicy(defaultFadeOutMs: c.defaultFadeOutMs, defaultFadeInMs: c.defaultFadeInMs)
    }

    private func change<V: Equatable>(_ f: SetField<V>) -> Change<V> {
        switch f {
        case .absent: return .keep
        case .clear: return .clear
        case .value(let v): return .set(v)
        }
    }

    /// An edge written as text in the fixtures. Anything but fade and cut cannot be represented, so the edit is refused.
    private func edge(_ f: SetField<String>) -> Change<TrimEdge>? {
        switch f {
        case .absent: return .keep
        case .clear: return .clear
        case .value("fade"): return .set(.fade)
        case .value("cut"): return .set(.cut)
        case .value: return nil
        }
    }

    func trimRange(stored: TrimFields, fileDurationS: Double) throws -> TrimRange {
        let w = trim(stored).window(fileLength: fileDurationS)
        return TrimRange(a: w.start, b: w.end)
    }

    func setTrim(_ set: TrimSet, previous: TrimFields, config: TrimConfig) throws -> TrimOutcome {
        var t = trim(previous)
        var edit = TrimEdit()
        edit.inPoint = change(set.inPoint)
        edit.outPoint = change(set.outPoint)
        edit.fadeOutMs = change(set.fadeMs)
        edit.fadeInMs = change(set.fadeInMs)
        var accepted = false
        if let end = edge(set.end), let start = edge(set.start) {
            edit.endEdge = end
            edit.startEdge = start
            accepted = t.apply(edit, fileLength: config.fileDurationS)
        }
        let w = t.window(fileLength: config.fileDurationS)
        let p = policy(config)
        return TrimOutcome(
            accepted: accepted, stored: fields(t), range: TrimRange(a: w.start, b: w.end), durEffS: Trim.round2(w.length),
            fadeOutMs: t.fadeOutMs(policy: p), fadeInMsEff: t.fadeInMsEffective(policy: p), fadeInAppliedMs: t.fadeInAppliedMs(policy: p))
    }

    /// Starts the track on a mixer the way `_start` does: paused transport, or a crossfade into it, when the context says so.
    func startDeck(trim t: TrimFields, offsetS: Double, config: TrimConfig, context: DeckStartContext) throws -> DeckStart {
        let plan = TrackPlan(trim: trim(t), policy: policy(config), fileLength: config.fileDurationS, offsetSeconds: offsetS, end: trackEnd(context.endAction))
        var mixer = Mixer()
        if context.paused { mixer.pause() }
        let id = mixer.start(plan, crossfadeMs: context.crossfadeMs)
        guard let started = mixer.deck(id)?.playback?.plan else { throw pending("a deck without a plan") }
        return DeckStart(
            baseS: started.seconds(started.baseFrames), loS: started.seconds(started.loFrames), hiS: started.seconds(started.hiFrames),
            durationS: started.seconds(started.firstPassFrames), endFadeMs: started.endFadeMs, fadeInMs: started.fadeInMs,
            fadeInRampS: started.seconds(started.fadeInFrames), startVol: mixer.gain(of: id) ?? 0, fresh: started.isFresh, loop: started.end == .loop)
    }

    /// Starts the track from its beginning and runs the mixer `atS` seconds.
    private func run(_ t: TrimFields, _ config: TrimConfig, forS atS: Double) -> (mixer: Mixer, deck: Deck.ID) {
        var mixer = Mixer()
        let plan = TrackPlan(trim: trim(t), policy: policy(config), fileLength: config.fileDurationS)
        let id = mixer.start(plan)
        mixer.advance(frames: mixer.transport.frames(seconds: atS))
        return (mixer, id)
    }

    func trimEndFade(trim t: TrimFields, config: TrimConfig, atS: Double) throws -> FadeSample {
        let r = run(t, config, forS: atS)
        let now = r.mixer.transport.playFrame
        return FadeSample(vol: r.mixer.gain(of: r.deck) ?? 0, fading: r.mixer.deck(r.deck)?.isFadingOutAtB(at: now) ?? false)
    }

    func trimEndOutcome(trim t: TrimFields, config: TrimConfig, afterS: Double) throws -> (ended: Bool, nothingLive: Bool) {
        let r = run(t, config, forS: afterS)
        return (r.mixer.deck(r.deck)?.isPlaying == false, r.mixer.live == nil)
    }

    // MARK: end_actions.json

    private func trackEnd(_ a: EndAction) -> TrackEnd {
        switch a {
        case .default: return .followPlayMode
        case .once: return .twice
        case .loop: return .loop
        case .stop: return .stop
        }
    }

    private func endAction(_ e: TrackEnd) -> EndAction {
        switch e {
        case .followPlayMode: return .default
        case .twice: return .once
        case .loop: return .loop
        case .stop: return .stop
        }
    }

    func endActionDeckStart(_ action: EndAction) throws -> EndActionDeckStart {
        let end = trackEnd(action)
        return EndActionDeckStart(passes: end.passes ?? 1, loop: end == .loop)
    }

    /// One track alone, as long as the scenario says, with its trim. Runs to `atS`; the end action is switched at `switchOff.atS` on the way.
    private func play(_ s: EndActionScenario, upTo atS: Double) throws -> (mixer: Mixer, deck: Deck.ID) {
        var mixer = Mixer()
        let config = TrimConfig(fileDurationS: s.trackLengthS, defaultFadeOutMs: s.defaultFadeOutMs, defaultFadeInMs: s.defaultFadeInMs)
        let plan = TrackPlan(trim: trim(s.trim), policy: policy(config), fileLength: s.trackLengthS, end: trackEnd(s.endAction))
        let id = mixer.start(plan)
        var now = 0.0
        if let sw = s.switchOff, sw.atS <= atS {
            mixer.advance(frames: mixer.transport.frames(seconds: sw.atS))
            now = sw.atS
            // Only "the running pass is the last one" is specified. A switch to loop starts the track again after it (a restart, not
            // a longer pass); a switch TO once is not specified (quirk 12 of the spec).
            guard trackEnd(sw.to) != .twice else { throw pending("switching an end action to once while the track plays (not specified)") }
            mixer.finishCurrentPass(of: id)
        }
        mixer.advance(frames: mixer.transport.frames(seconds: atS - now))
        return (mixer, id)
    }

    func deckLevel(_ s: EndActionScenario, atS: Double) throws -> (vol: Double, live: Bool) {
        let r = try play(s, upTo: atS)
        return (r.mixer.gain(of: r.deck) ?? 0, r.mixer.deck(r.deck)?.isPlaying ?? false)
    }

    func endActionState(_ s: EndActionScenario, atS: Double) throws -> EndActionState {
        let r = try play(s, upTo: atS)
        let now = r.mixer.transport.playFrame
        guard let deck = r.mixer.deck(r.deck), deck.isPlaying else { return EndActionState(live: false, passNo: nil, remainingS: nil) }
        let pass = deck.pass(at: now)
        return EndActionState(live: true, passNo: pass?.number, remainingS: pass.map { r.mixer.transport.seconds(frames: $0.remainingFrames) })
    }

    func endActionEndTimeS(_ s: EndActionScenario) throws -> Double? {
        let r = try play(s, upTo: s.switchOff?.atS ?? 0)
        guard let end = r.mixer.deck(r.deck)?.playback?.endFrame else { return nil }
        return Double(end) / Double(r.mixer.transport.sampleRate)
    }

    func nextEndAction(after action: EndAction) throws -> EndAction {
        endAction(trackEnd(action).next)
    }

    // MARK: play_modes.json and end_action_switched_mid_play

    private func playlistMode(_ m: PlayMode) -> PlaylistMode {
        switch m {
        case .stop: return .stop
        case .loopPlaylist: return .loopPlaylist
        case .nextPlaylist: return .nextPlaylist
        case .shuffle: return .shuffle
        }
    }

    /// Playlists of `counts` tracks of 2 s each, all in `mode`. Track ids are `100 * playlist + index`.
    private func playlists(_ counts: [Int], mode: PlayMode) -> [Playlist] {
        counts.enumerated().map { p, n in
            Playlist(tracks: (0..<n).map { PlaylistTrack(id: TrackID(100 * p + $0), lengthSeconds: 2) }, mode: playlistMode(mode))
        }
    }

    func successor(mode: PlayMode, endAction: EndAction, playlistTrackCounts: [Int], from: (playlist: Int, track: Int)) throws -> Successor {
        var lists = playlists(playlistTrackCounts, mode: mode)
        lists[from.playlist].tracks[from.track].end = trackEnd(endAction)
        var random = SeededRandomSource(seed: 1234)
        switch PlayOrder.successor(after: TrackPosition(playlist: from.playlist, track: from.track), in: &lists, using: &random) {
        case .stopped: return .stopped
        case .same: return .same
        case .track(let p): return .track(playlist: p.playlist, track: p.track)
        }
    }

    func nextInOrder(mode: PlayMode, fromTrack: Int, trackCount: Int, loopingTracks: Set<Int>) throws -> [Int] {
        PlayOrder.nextInOrder(mode: playlistMode(mode), from: fromTrack, trackCount: trackCount, trackLoops: loopingTracks.contains(fromTrack))
    }

    func shuffleDraws(trackCount: Int, startTrack: Int, count: Int) throws -> [Int] {
        var lists = playlists([trackCount], mode: .shuffle)
        var random = SeededRandomSource(seed: 20_240_229)
        var current = startTrack
        var draws = [Int]()
        for _ in 0..<count {
            guard case .track(let next) = PlayOrder.successor(after: TrackPosition(playlist: 0, track: current), in: &lists, using: &random) else { break }
            draws.append(next.track)
            current = next.track
        }
        return draws
    }

    func shuffleTracksLeftAfterOneDraw(trackCount: Int, startTrack: Int) throws -> Int {
        var lists = playlists([trackCount], mode: .shuffle)
        var random = SeededRandomSource(seed: 7)
        _ = PlayOrder.successor(after: TrackPosition(playlist: 0, track: startTrack), in: &lists, using: &random)
        return lists[0].bag.remaining.count
    }

    func shuffleForgetsRoundOnModeChange() throws -> Bool {
        var lists = playlists([3], mode: .shuffle)
        var random = SeededRandomSource(seed: 7)
        _ = PlayOrder.successor(after: TrackPosition(playlist: 0, track: 0), in: &lists, using: &random)
        guard !lists[0].bag.remaining.isEmpty else { return false }   // there has to be a round to forget
        lists[0].mode = .loopPlaylist
        lists[0].mode = .shuffle
        return lists[0].bag.remaining.isEmpty
    }

    /// Two tracks of 2 s; track 0 starts with `from`, the end action is switched to `to` at `atS`, and the player runs to the exact end of the pass that
    /// was running. Reports what plays then.
    func liveAfterEndActionSwitch(playMode: PlayMode, from: EndAction, to: EndAction, atS: Double) throws -> LiveTrack? {
        guard trackEnd(to) != .twice else { throw pending("switching an end action to once while the track plays (not specified)") }
        var lists = playlists([2], mode: playMode)
        lists[0].tracks[0].end = trackEnd(from)
        var player = PlaylistPlayer(playlists: lists, policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1))
        player.play(TrackPosition(playlist: 0, track: 0))
        player.advance(frames: player.mixer.transport.frames(seconds: atS))
        player.setEnd(trackEnd(to), ofTrack: TrackID(0), inPlaylist: 0)
        guard let c = player.current, let end = player.mixer.deck(c.deck)?.playback?.endFrame else { throw pending("a deck with no end after the switch") }
        player.advance(frames: end - player.mixer.transport.playFrame)
        guard let now = player.current, let pass = player.mixer.deck(now.deck)?.pass(at: player.mixer.transport.playFrame) else { return nil }
        return LiveTrack(track: now.position.track, passNo: pass.number)
    }

    // MARK: triggers.json

    /// The test's answer to "can this target play": a voice-over of the scenario is decoded, with its length, once its gate is open.
    private final class FixtureReadiness: TargetReadiness {
        var lengths: [TrackID: Double]
        var open: Set<TrackID>

        init(lengths: [TrackID: Double], open: Set<TrackID>) {
            self.lengths = lengths
            self.open = open
        }

        func state(of target: TrackID) -> TargetState {
            guard let length = lengths[target] else { return .missing }
            return open.contains(target) ? .ready(lengthSeconds: length) : .loading
        }
    }

    private struct TriggerRun {
        var fires: [TriggerFire] = []
        var snapshots: [TriggerSnapshot] = []
    }

    /// Plays the scenario: the main track (with the trim, end action and trigger points), the seeks, the other track and the moment the targets are decoded
    /// happen at their times; the player is read at `readAt`. Voice-over targets are the files of `voiceOverLengthsS`. Time is cut at every event, so the
    /// result does not depend on a step.
    private func runTrigger(_ s: TriggerScenario, readAt: [Double]) throws -> TriggerRun {
        let voiceNames = s.voiceOverLengthsS.keys.sorted()
        var targetIds = [String: TrackID]()
        var lengths = [TrackID: Double]()
        for (i, name) in voiceNames.enumerated() {
            targetIds[name] = TrackID(100 + i)
            lengths[TrackID(100 + i)] = s.voiceOverLengthsS[name]
        }
        var list = TriggerList()
        for (n, point) in s.triggers.enumerated() {
            guard let target = targetIds[point.file] else { throw pending("a trigger whose target is not a voice-over of the scenario") }
            list.add(Trigger(id: TriggerID(n), atSeconds: point.at, target: target, once: point.once ?? false, enabled: point.enabled ?? true))
        }
        var tracks = [PlaylistTrack(id: TrackID(0), lengthSeconds: s.fileDurationS, trim: trim(s.trim), end: trackEnd(s.endAction), triggers: list)]
        var trackNames = [s.mainName]
        if let other = s.otherTrack {
            tracks.append(PlaylistTrack(id: TrackID(1), lengthSeconds: other.lengthS))
            trackNames.append(other.name)
        }
        func readiness(of file: String) -> TargetReadyAt { s.targetReadyByFile[file] ?? s.targetReady }
        let gate = FixtureReadiness(lengths: lengths, open: Set(voiceNames.filter { readiness(of: $0) == .always }.compactMap { targetIds[$0] }))
        // Ducking only where the scenario asks for it: its voice-over files are a constant sample value, so the key is that value in every 10 ms window.
        var hook: any DuckingHook = NoDucking()
        if let d = s.duck {
            var sidechain = SidechainDucking(settings: duckingSettings(d.settings))
            for (id, seconds) in lengths {
                let value = Double(abs(d.voiceSampleValue)) / 32768
                sidechain.prepare(target: id, key: Array(repeating: value, count: Int(seconds * 100)))
            }
            hook = sidechain
        }
        var player = PlaylistPlayer(
            playlists: [Playlist(tracks: tracks, mode: .stop)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0),
            random: SeededRandomSource(seed: 1), readiness: gate, ducking: hook, settings: TriggerSettings(armed: s.armed, topTrackPercent: s.topTrackPct))

        var run = TriggerRun()
        var deckNames = [Deck.ID: String]()
        var firesSoFar = 0
        func collect() {
            for f in player.fired {
                let name = voiceNames[Int(f.target.raw) - 100]
                deckNames[f.deck] = name
                firesSoFar += 1
                run.fires.append(TriggerFire(tS: player.mixer.transport.seconds(frames: f.frame), file: name))
            }
        }
        func start(_ track: Int, crossfadeMs: Int, offset: Double) {
            player.play(TrackPosition(playlist: 0, track: track), crossfadeMs: crossfadeMs, offsetSeconds: offset)
            if let c = player.current { deckNames[c.deck] = trackNames[track] }
            collect()
        }
        func snapshot(_ t: Double) {
            let decks = player.mixer.decks.filter(\.isPlaying).map {
                DeckView(
                    name: deckNames[$0.id] ?? "?", top: $0.isTop, vol: $0.volume(at: player.mixer.transport.playFrame), ending: $0.endsWhenFadeEnds && $0.fade != nil,
                    fading: $0.fade != nil, levelGain: $0.levelGain(at: player.mixer.transport.playFrame), ducked: $0.duck(at: player.mixer.transport.playFrame) < 0.99)
            }
            run.snapshots.append(TriggerSnapshot(atS: t, liveName: player.mixer.live.flatMap { deckNames[$0.id] }, decks: decks, firesSoFar: firesSoFar))
        }

        enum Event { case ready(TrackID), seek(Double), newTrack(Int), read }
        var events: [(t: Double, order: Int, e: Event)] = []
        for name in voiceNames {
            if case .atS(let t) = readiness(of: name), let id = targetIds[name] { events.append((t, 0, .ready(id))) }
        }
        for seek in s.seeks { events.append((seek.atS, 1, .seek(seek.toS))) }
        if let n = s.newTrack { events.append((n.atS, 1, .newTrack(n.crossfadeMs))) }
        for t in readAt { events.append((t, 2, .read)) }
        events.sort { ($0.t, $0.order) < ($1.t, $1.order) }

        start(0, crossfadeMs: 0, offset: s.offsetS)
        var frame: Int64 = 0
        let rate = player.mixer.transport
        for ev in events {
            let target = rate.frames(seconds: ev.t)
            if target > frame {
                player.advance(frames: target - frame)
                frame = target
                collect()
            }
            switch ev.e {
            case .ready(let id): gate.open.insert(id)
            case .seek(let to): player.seekLive(toSeconds: to); collect()
            case .newTrack(let xf): start(1, crossfadeMs: xf, offset: 0)
            case .read: snapshot(ev.t)
            }
        }
        let end = rate.frames(seconds: s.runForS)
        if end > frame {
            player.advance(frames: end - frame)
            collect()
        }
        return run
    }

    func triggerFireTimes(_ s: TriggerScenario) throws -> [TriggerFire] {
        try runTrigger(s, readAt: []).fires
    }

    func triggerSnapshots(_ s: TriggerScenario, at times: [Double]) throws -> [TriggerSnapshot] {
        try runTrigger(s, readAt: times).snapshots
    }


    // MARK: levelmatch.json

    func measureLufs(pcm: [Int16]) throws -> Double? {
        Loudness.integratedLufs(interleaved: pcm, channels: AudioSpec.channels)
    }

    private func levelMode(_ m: LevelMatchMode) -> LevelMatch.Mode {
        switch m {
        case .off: return .off
        case .track: return .track
        case .lufs: return .lufs
        }
    }

    /// The setting as typed goes through `LevelMatch`; the reference is kept as an id and named again by the file of that track.
    func storeLevelMatch(typed: LevelMatchTyped, playlist: [String], clamp: LufsClamp) throws -> LevelMatchStored {
        let ids = playlist.indices.map { TrackID($0) }
        let stored = LevelMatch(
            typedMode: levelMode(typed.mode), typedReferenceIndex: typed.ref, typedLufs: typed.lufs, playlist: ids, clamp: .init(min: clamp.min, max: clamp.max, step: clamp.step))
        let mode: LevelMatchMode = typed.mode
        return LevelMatchStored(mode: mode, ref: stored.referenceTrack.map { playlist[$0.raw] }, lufs: stored.targetLufs)
    }

    func levelMatchGain(mode: LevelMatchMode, targetLufs: Double?, measuredLufs: Double?) throws -> LevelMatchResult {
        guard mode != .off else { return LevelMatchResult(gainDb: nil, linear: 1) }
        let db = LevelMatch.gainDb(measured: measuredLufs, target: targetLufs)
        return LevelMatchResult(gainDb: db, linear: LevelMatch.linear(db: db))
    }

    /// A track is playing with level match off, then the setting is changed: what the deck's gain is right away. For `track` mode the reference is a second
    /// track of the playlist measured at `trackLufs`' target.
    func liveDeckGain(mode: LevelMatchMode, targetLufs: Double?, trackLufs: Double?) throws -> Double {
        var tracks = [PlaylistTrack(id: TrackID(0), lengthSeconds: 60, measuredLufs: trackLufs)]
        var setting = LevelMatch(mode: levelMode(mode), targetLufs: targetLufs ?? LevelMatch.defaultTargetLufs)
        if mode == .track {
            tracks.append(PlaylistTrack(id: TrackID(1), lengthSeconds: 60, measuredLufs: targetLufs))
            setting.referenceTrack = TrackID(1)
        }
        var player = PlaylistPlayer(playlists: [Playlist(tracks: tracks, mode: .stop)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1))
        player.play(TrackPosition(playlist: 0, track: 0))
        player.advance(frames: 480)
        player.setLevelMatch(setting, ofPlaylist: 0)
        guard let c = player.current else { throw pending("a playing deck") }
        return player.mixer.deck(c.deck)?.levelGain(at: player.mixer.transport.playFrame) ?? 0
    }

    func backgroundMultiplier(reductionDb: Double) throws -> Double {
        Ducking.backgroundMultiplier(reductionDb: reductionDb)
    }

    func duckKey(pcm: [Int16]) throws -> [Double] {
        Ducking.key(pcm: pcm)
    }

    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double] {
        Ducking.curve(key: key, level: level, ratio: ratio, thresholdDb: thresholdDb, hold: hold)
    }

    func duckHoldDepthDb(key: [Double], level: Double, ratio: Double, thresholdDb: Double) throws -> Double {
        Ducking.holdDepthDb(key: key, level: level, ratio: ratio, thresholdDb: thresholdDb)
    }

    private func duckingSettings(_ s: DuckSettings, lookAheadS: Double = 0.02) -> DuckingSettings {
        DuckingSettings(
            thresholdDb: s.thresholdDb, ratio: s.ratio, attackMs: s.attackMs, releaseMs: s.releaseMs, hold: s.hold, topTrackPercent: s.topTrackPct,
            lookAheadMs: Int((lookAheadS * 1000).rounded()))
    }

    /// The real loop: a background deck from t = 0, a voice-over on top from `backgroundAloneS`, a mixer read every 10 ms. The voice-over is the segments of
    /// the fixture as 48 kHz stereo (the key is measured from those samples, like at import).
    ///
    /// Row i (0-based) is read at the play frame of its time: rows before the voice are one step apart (row `alone - 1` is the last background-only sample),
    /// the voice starts at the SAME time as that row (the next one), then every row is one step later. Columns:
    ///  - `grDb`, `bgMultiplier`: what the mixer's control loop has made current at that frame (`Mixer.duckReading`) and the background deck's factor.
    ///  - `targetDb`, `topPosS`: what the loop read for the voice. The fixture reports the voice until the first tick (every `tickEverySteps` steps from the
    ///    start of the voice) after it has ended: that is how the scenario samples it, so it is a REPORTING rule here, not a rule of the engine (the engine
    ///    releases at the exact frame; the reduction is the same either way).
    func duckLoop(_ r: DuckLoopRequest) throws -> DuckLoopSeries {
        let rate = AudioSpec.sampleRate
        var mixer = Mixer(sampleRate: rate)
        let stepFrames = mixer.transport.frames(seconds: r.stepS)
        let aloneRow = Int((r.backgroundAloneS / r.stepS).rounded())
        let voiceFrames = Int(((r.voiceOver.segments ?? []).reduce(0) { $0 + $1.seconds } * Double(rate)).rounded())
        var pcm = [Int16]()
        pcm.reserveCapacity(voiceFrames * 2)
        for seg in r.voiceOver.segments ?? [] {
            let v = Int16(clamping: seg.sampleValue)
            for _ in 0..<Int((seg.seconds * Double(rate)).rounded()) { pcm.append(v); pcm.append(v) }
        }
        var hook = SidechainDucking(settings: duckingSettings(r.settings, lookAheadS: r.lookAheadS))
        hook.prepare(target: TrackID(1), key: Ducking.key(pcm: pcm))
        let policy = TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0)
        let background = mixer.start(TrackPlan(trim: Trim(), policy: policy, fileLength: r.backgroundLengthS, sampleRate: rate))
        var voice = Deck.ID.none
        let voiceStart = Int64(aloneRow) * stepFrames
        let voiceEnd = voiceStart + Int64(voiceFrames)

        var out = DuckLoopSeries(tS: [], topPosS: [], targetDb: [], grDb: [], bgMultiplier: [])
        for i in 0..<r.sampleCount {
            let frame = Int64(i < aloneRow ? i + 1 : i) * stepFrames
            if frame > mixer.transport.playFrame { mixer.advance(frames: frame - mixer.transport.playFrame) }
            if i == aloneRow {
                voice = mixer.startOnTop(
                    TrackPlan(trim: Trim(), policy: policy, fileLength: Double(voiceFrames) / Double(rate), sampleRate: rate), level: r.settings.topTrackPct / 100)
                hook.voiceStarted(voice, target: TrackID(1), over: background, atFrame: frame, in: &mixer)
            }
            let reading = mixer.duckReading(at: frame)
            var seen = false
            if i >= aloneRow {
                let lastTick = voiceStart + Int64((i - aloneRow) / r.tickEverySteps * r.tickEverySteps) * stepFrames
                seen = lastTick <= voiceEnd
            }
            out.tS.append(Double(frame) / Double(rate))
            out.topPosS.append(seen ? Double(min(frame - voiceStart, voiceEnd - voiceStart)) / Double(rate) : nil)
            out.targetDb.append(seen ? reading?.targetDb ?? 0 : nil)
            out.grDb.append(reading?.reductionDb ?? 0)
            out.bgMultiplier.append(mixer.deck(background)?.duck(at: frame) ?? 1)
        }
        return out
    }

    /// `duck_loop` cases that start their voice-overs themselves. Row `r` is the loop's turn `r` of Python: the voice-over's position at it, the key window it
    /// read (`look_ahead_index`), the reduction after it.
    ///
    /// How the Python timer is reproduced (all of it in this adapter; the engine has a grid anchored where its loop starts and nothing else, quirk 16):
    ///  - The phase of the grid: Python's first turn comes `loop_first_turn_delay_s` after the first voice-over started and every later turn 10 ms after
    ///    the one before. The adapter lets the voice play that long before it hands it to the ducking hook, so the engine's first step is at that
    ///    position of the voice and row `r` is the engine's step `r` (the value that step computed, `duckReading(at: step + 10 ms)`).
    ///  - With no delay (the on-grid cases) Python's later turns read the playhead a float rounding error BELOW the 10 ms grid (the rig's fake clock adds
    ///    0.01 per turn; the recorded `look_ahead_index` of row k is k + 1, not k + 2). That is not contract: the adapter models it as a loop that runs
    ///    one frame (21 us) early: the hook is called 479 frames in, row 0 is the first turn before the loop (nothing has happened yet) and row `r` is
    ///    step `r - 1`. The `look_ahead_index` column checks this choice: a fixture made with other rounding noise fails there, loudly.
    ///  - Instants (`t_s`, `top_pos_s`) are the scenario's schedule (start + delay + 10 ms x row), not frame counts: 9.9 ms is not a whole number of frames,
    ///    and the 479-frame loop is not 10 ms. The engine runs on the nearest frame.
    ///  - REPORTING only (not in the engine): the player's own 50 ms tick (`tick_every_steps`) is what takes a finished voice-over away. Until it does,
    ///    the fixture keeps listing the voice-over with its position clamped to its length (the stale rows), whatever the loop has already done.
    func duckVoices(_ r: DuckVoicesRequest) throws -> DuckVoicesSeries {
        let rate = AudioSpec.sampleRate
        var mixer = Mixer(sampleRate: rate)
        let stepFrames = mixer.transport.frames(seconds: r.stepS)
        func frames(of segments: [VoiceOver.Segment]) -> Int {
            Int((segments.reduce(0) { $0 + $1.seconds } * Double(rate)).rounded())
        }
        func pcm(_ segments: [VoiceOver.Segment]) -> [Int16] {
            var out = [Int16]()
            for seg in segments {
                let v = Int16(clamping: seg.sampleValue)
                for _ in 0..<Int((seg.seconds * Double(rate)).rounded()) { out.append(v); out.append(v) }
            }
            return out
        }
        let policy = TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0)
        func plan(_ segments: [VoiceOver.Segment]) -> TrackPlan {
            TrackPlan(trim: Trim(), policy: policy, fileLength: Double(frames(of: segments)) / Double(rate), sampleRate: rate)
        }
        var hook = SidechainDucking(settings: duckingSettings(r.settings, lookAheadS: r.lookAheadS))
        hook.prepare(target: TrackID(1), key: Ducking.key(pcm: pcm(r.firstVoice)))
        if let second = r.secondVoice { hook.prepare(target: TrackID(2), key: Ducking.key(pcm: pcm(second.segments))) }

        let background = mixer.start(TrackPlan(trim: Trim(), policy: policy, fileLength: r.backgroundLengthS, sampleRate: rate))
        let voiceStart = mixer.transport.frames(seconds: r.backgroundAloneS)
        mixer.advance(frames: voiceStart)
        let level = r.settings.topTrackPct / 100
        let voice1 = mixer.startOnTop(plan(r.firstVoice), level: level)

        let delayFrames = mixer.transport.frames(seconds: r.loopFirstTurnDelayS)
        let onGrid = delayFrames == 0
        let loopPhase = onGrid ? stepFrames - 1 : delayFrames
        let rowOffset = onGrid ? 1 : 0
        mixer.advance(frames: loopPhase)
        hook.voiceStarted(voice1, target: TrackID(1), over: background, atFrame: mixer.transport.playFrame, in: &mixer)
        // The second voice-over starts on the clock of Python's turns (delay + 10 ms x turns), not on the loop's phase.
        let secondStart: Int64? = r.secondVoice.map {
            voiceStart + delayFrames + Int64($0.startsAtStep - 1) * stepFrames + mixer.transport.frames(seconds: $0.clockMovedBeforeS)
        }
        var voice2 = Deck.ID.none
        let secondStartS = r.secondVoice.map { r.backgroundAloneS + r.loopFirstTurnDelayS + Double($0.startsAtStep - 1) * r.stepS + $0.clockMovedBeforeS }
        let lengthS = [Double(frames(of: r.firstVoice)) / Double(rate), r.secondVoice.map { Double(frames(of: $0.segments)) / Double(rate) } ?? 0]

        var out = DuckVoicesSeries(tS: [], topN: [], topPosS: [], lookAheadIndex: [], targetDb: [], grDb: [], bgMultiplier: [], loopRuns: 0)
        var wasDucking = false
        var removed = false
        for row in 0..<r.sampleCount {
            if mixer.isDucking, !wasDucking { out.loopRuns += 1 }
            wasDucking = mixer.isDucking
            let step = row - rowOffset
            var reading: DuckReading?
            var multiplier = 1.0
            if step >= 0 {
                let at = voiceStart + loopPhase + Int64(step) * stepFrames
                if let start = secondStart, voice2 == .none, start < at, let second = r.secondVoice {
                    mixer.advance(frames: start - mixer.transport.playFrame)
                    voice2 = mixer.startOnTop(plan(second.segments), level: level)
                    hook.voiceStarted(voice2, target: TrackID(2), over: background, atFrame: start, in: &mixer)
                }
                if at > mixer.transport.playFrame { mixer.advance(frames: at - mixer.transport.playFrame) }
                reading = mixer.duckReading(at: at + stepFrames)
                multiplier = mixer.deck(background)?.duck(at: at + stepFrames) ?? 1
            }
            let time = r.backgroundAloneS + r.loopFirstTurnDelayS + Double(row) * r.stepS
            let driver = voice2 != .none && mixer.duckVoice == voice2 ? 2 : 1
            let startS = driver == 2 ? (secondStartS ?? 0) : r.backgroundAloneS
            var topN: Int?
            var pos: Double?
            var index: Int?
            if step < 0 {
                topN = 1; pos = 0; index = 2             // the first turn, before the loop has a phase: position 0, window 2, nothing to do yet
            } else if let reading, reading.window >= 0 {
                topN = driver; pos = time - startS; index = reading.window
            } else {
                if row > 0, row % r.tickEverySteps == 0 { removed = true }
                if !removed {
                    topN = driver; pos = lengthS[driver - 1]; index = Int((lengthS[driver - 1] / r.stepS + 1e-9).rounded(.down)) + 2
                }
            }
            out.tS.append(time)
            out.topN.append(topN)
            out.topPosS.append(pos)
            out.lookAheadIndex.append(index)
            out.targetDb.append(reading?.targetDb ?? 0)
            out.grDb.append(reading?.reductionDb ?? 0)
            out.bgMultiplier.append(multiplier)
        }
        return out
    }

    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double {
        Ducking.smooth(gr: gr, target: target, dt: dt, attackMs: attackMs, releaseMs: releaseMs)
    }

    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double {
        Ducking.inputTargetDb(rms: rms, gainDb: gainDb, ratio: ratio, thresholdDb: thresholdDb)
    }

    // MARK: resume_flow.json

    /// One playlist of the scenario's files: track i has `TrackID(i)`, the file's length and its trim (if the scenario gives one).
    private func resumePlayer(_ env: ResumeEnvironment) throws -> PlaylistPlayer<SeededRandomSource> {
        let tracks = try env.playlist.enumerated().map { i, file -> PlaylistTrack in
            guard let length = env.fileLengthsS[file] else { throw FixtureReadError(file: "resume_flow", caseName: "scenario", message: "library_s has no entry for \(file)") }
            return PlaylistTrack(id: TrackID(i), lengthSeconds: length, trim: env.trims[file].map(trim) ?? Trim())
        }
        return PlaylistPlayer(playlists: [Playlist(tracks: tracks)], policy: TrimPolicy(defaultFadeOutMs: 0, defaultFadeInMs: 0), random: SeededRandomSource(seed: 1))
    }

    private func settings(_ c: ResumeConfig) -> ResumeSettings {
        ResumeSettings(onStart: c.onStart, maxAgeSeconds: c.maxAgeS, saveSeconds: c.saveIntervalS)
    }

    func resumeRecord(_ situation: ResumeSituation, environment env: ResumeEnvironment) throws -> ResumeRecord? {
        var player = try resumePlayer(env)
        let catalog = ResumeCatalog(playlists: [env.playlist])
        guard player.play(TrackPosition(playlist: 0, track: situation.playTrack)) else { throw pending("a track that does not start") }
        let rate = player.mixer.transport.sampleRate
        player.advance(frames: Int64((situation.atS * Double(rate)).rounded()))
        if situation.paused { player.pause() }
        if let clock = situation.clockAtSaveS, clock > situation.atS { player.advance(frames: Int64(((clock - situation.atS) * Double(rate)).rounded())) }
        switch situation.then {
        case nil: break
        case .stopAll?: player.stop()
        case .fadeOut(let ms)?: player.fadeOut(milliseconds: ms)
        }
        // The engine's record (AudioCore) is converted to the harness model of the fixture, which has the same four fields.
        return player.resumeRecord(catalog: catalog).map { ResumeRecord(pt: $0.pt, id: $0.id, pos: $0.pos, paused: $0.paused) }
    }

    func tryResume(record: ResumeRecord, ageS: Double, environment env: ResumeEnvironment) throws -> ResumeOutcome {
        let decision = Resume.plan(
            record: .init(pt: record.pt, id: record.id, pos: record.pos, paused: record.paused), ageSeconds: ageS, catalog: ResumeCatalog(playlists: [env.playlist]), settings: settings(env.config))
        guard let plan = decision.plan else { return ResumeOutcome(pending: nil, started: nil, recordKept: decision.recordKept) }
        var player = try resumePlayer(env)
        guard player.startResume(plan), let c = player.current, let deck = player.mixer.deck(c.deck), let p = deck.playback?.plan else { throw pending("a resumed track that does not start") }
        func pt(_ position: TrackPosition) -> [Int] { [position.playlist, position.track] }
        return ResumeOutcome(
            pending: .init(pt: pt(plan.position), offsetS: plan.offsetSeconds, paused: plan.paused, xfadeMs: plan.crossfadeMs),
            started: .init(
                pt: pt(c.position), baseS: p.seconds(p.baseFrames), loS: p.seconds(p.loFrames), hiS: p.seconds(p.hiFrames),
                paused: player.mixer.transport.isPaused, startVol: player.mixer.gain(of: c.deck) ?? 0, fadeInMs: p.fadeInMs, fresh: p.isFresh),
            recordKept: decision.recordKept)
    }
}
