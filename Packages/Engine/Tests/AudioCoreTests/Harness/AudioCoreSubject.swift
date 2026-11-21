import AudioCore

/// The slice of the spec that AudioCore implements so far, as pure functions. Everything else is still pending
/// (the protocol's default), so those tests are skipped until the transport port provides it.
///
/// Implemented: equal-power fades and crossfade gains, fade-out gain, the background multiplier `10^(-gr/20)`,
/// `duck_key`, `duck_curve` (hold on / off), `duck_smooth`, `input_target_db`.
struct AudioCoreSubject: AudioSpecSubject {
    func fadeGain(_ direction: FadeDirection, x: Double) throws -> Double {
        switch direction {
        case .up: return EqualPower.rampUp(x: x)
        case .down: return EqualPower.rampDown(x: x)
        }
    }

    func crossfadeState(fadeMs: Int, elapsedS: Double) throws -> CrossfadeState {
        let x = EqualPower.progress(elapsed: elapsedS, length: Double(fadeMs) / 1000)
        let gains = EqualPower.crossfade(x: x)
        return CrossfadeState(newGain: gains.new, oldGain: gains.old, oldStillPlaying: x < 1)
    }

    func fadeOutState(fadeMs: Int, elapsedS: Double) throws -> FadeOutState {
        let x = EqualPower.progress(elapsed: elapsedS, length: Double(fadeMs) / 1000)
        return FadeOutState(vol: EqualPower.rampDown(x: x), playing: x < 1)
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
