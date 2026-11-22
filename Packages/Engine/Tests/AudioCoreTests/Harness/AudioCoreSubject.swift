import AudioCore

/// The slice of the spec that AudioCore implements so far, as pure functions. Everything else is still pending
/// (the protocol's default), so those tests are skipped until the transport port provides it.
///
/// Implemented: trim windows, fades at A and B, passes and end actions (trim.json, end_actions.json), play modes, next_in_order and the shuffle bag (play_modes.json, end_action_switched_mid_play), the fade and crossfade rules (through `Mixer`, `Deck`, `Fade`, `CrossfadeSettings`: fades.json and xfade.json), the background multiplier `10^(-gr/20)`,
/// `duck_key`, `duck_curve` (hold on / off), `duck_smooth`, `input_target_db`.
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

    func backgroundMultiplier(reductionDb: Double) throws -> Double {
        Ducking.backgroundMultiplier(reductionDb: reductionDb)
    }

    func duckKey(pcm: [Int16]) throws -> [Double] {
        Ducking.key(pcm: pcm)
    }

    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double] {
        Ducking.curve(key: key, level: level, ratio: ratio, thresholdDb: thresholdDb, hold: hold)
    }

    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double {
        Ducking.smooth(gr: gr, target: target, dt: dt, attackMs: attackMs, releaseMs: releaseMs)
    }

    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double {
        Ducking.inputTargetDb(rms: rms, gainDb: gainDb, ratio: ratio, thresholdDb: thresholdDb)
    }
}
