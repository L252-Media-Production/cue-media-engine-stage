import Foundation

/// Sidechain ducking maths of the audio spec (docs/AUDIO-SPEC.md, "Play on Top and sidechain ducking").
/// Ports `duck_key`, `duck_curve`, `duck_smooth` and `input_target_db` of the Python player's `cpl/dsp.py`.
/// Pure functions in Double: no state, no I/O.
public enum Ducking {
    /// Length of one analysis window and one loop step, in seconds.
    public static let step = 0.01

    /// Frames of 48 kHz audio in one window.
    public static let framesPerWindow = 480

    /// Multiplier for the background decks while the reduction is `reductionDb` dB: `10^(-gr/20)`.
    public static func backgroundMultiplier(reductionDb: Double) -> Double {
        pow(10, -reductionDb / 20)
    }

    /// Loudness (0...1 RMS of the louder channel) of every whole 10 ms window of interleaved 48 kHz 16-bit stereo.
    /// A trailing part window is dropped; the result is empty when there is not one whole window (Python: `None`).
    public static func key(pcm: [Int16]) -> [Double] {
        let frames = pcm.count / 2
        let windows = frames / framesPerWindow
        var out = [Double]()
        out.reserveCapacity(windows)
        for w in 0..<windows {
            var left = 0.0
            var right = 0.0
            let base = w * framesPerWindow * 2
            for i in 0..<framesPerWindow {
                let l = Double(pcm[base + 2 * i]) / 32768
                let r = Double(pcm[base + 2 * i + 1]) / 32768
                left += l * l
                right += r * r
            }
            let n = Double(framesPerWindow)
            out.append(max((left / n).squareRoot(), (right / n).squareRoot()))
        }
        return out
    }

    /// dB of reduction wanted for each window before attack and release:
    /// `max(0, dB(key * level) - threshold) * (1 - 1/ratio)`, capped at 60 dB.
    /// With `hold`, from the first to the last active window (target > 0.05 dB) the reduction stays at least
    /// the 75th percentile of the active values.
    public static func curve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) -> [Double] {
        let ratio = max(1, ratio)
        var target = key.map { k -> Double in
            let db = 20 * log10(max(k * max(level, 1e-4), 1e-6))
            return min(max(db - thresholdDb, 0) * (1 - 1 / ratio), 60)
        }
        if hold, let first = target.firstIndex(where: { $0 > 0.05 }), let last = target.lastIndex(where: { $0 > 0.05 }) {
            let active = target[first...last].filter { $0 > 0.05 }
            let depth = percentile(active, 75)
            for i in first...last { target[i] = max(target[i], depth) }
        }
        return target
    }

    /// One step of the attack / release smoothing of the reduction (dB). `gr` moves toward `target` with the attack
    /// time constant when going down (`target > gr`) and the release one when coming back (time constants at least 1 ms).
    /// Snaps to 0 once the target is 0 and what is left is under 0.05 dB.
    public static func smooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) -> Double {
        let tau = max(1, target > gr ? attackMs : releaseMs) / 1000
        var next = gr + (target - gr) * (1 - exp(-dt / tau))
        if target == 0, next < 0.05 { next = 0 }
        return next
    }

    /// dB of reduction the Live input detector asks for at block level `rms` (0...1, before the input gain):
    /// the same computation as `curve` with hold off.
    public static func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) -> Double {
        curve(key: [rms], level: pow(10, gainDb / 20), ratio: ratio, thresholdDb: thresholdDb, hold: false)[0]
    }

    /// Percentile with linear interpolation between ranks (the default of numpy's `percentile`).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = p / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }
}
