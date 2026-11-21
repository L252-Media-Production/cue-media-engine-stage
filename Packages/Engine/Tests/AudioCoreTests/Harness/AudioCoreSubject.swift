import AudioCore

/// The slice of the spec that AudioCore implements so far, as pure functions. Everything else is still pending
/// (the protocol's default), so those tests are skipped until the transport port provides it.
///
/// Implemented: the fade and crossfade rules (through `Mixer`, `Deck`, `Fade`, `CrossfadeSettings`: fades.json and xfade.json), the background multiplier `10^(-gr/20)`,
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
