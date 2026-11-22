import Foundation

/// Integrated loudness (LUFS) of a track, the number level match works from (docs/audio-spec-1.md, "Level match and LUFS"): ITU-R BS.1770 K-weighting,
/// mean square over 400 ms blocks every 100 ms (75 % overlap), an absolute gate at -70 LUFS and a relative gate 10 LU below the mean of what passed it.
///
/// Offline: it runs when a track is imported, never on the audio thread. It allocates (the K-weighted segment sums), and it is a pure function of the
/// sample buffer, so it can run on any background thread.
public enum Loudness {
    /// 400 ms blocks, a new one every 100 ms.
    public static let blockSeconds = 0.4
    public static let stepSeconds = 0.1
    /// Blocks quieter than this are ignored, and then blocks more than `relativeGateLU` below the mean of the rest.
    public static let absoluteGateLufs = -70.0
    public static let relativeGateLU = -10.0
    /// The constant of the BS.1770 loudness formula: `-0.691 + 10 log10(power)`.
    static let offset = -0.691

    /// The K-weighting filter at 48 kHz: a high-shelf (stage 1) and a high-pass (stage 2), the coefficients ITU-R BS.1770 gives for that rate.
    /// Direct form I: `y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`.
    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    static func shelf() -> Biquad {
        Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585)
    }

    static func highPass() -> Biquad {
        Biquad(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    }

    /// The integrated loudness of 48 kHz interleaved 16-bit samples with `channels` channels (1 or 2; every channel has weight 1), in LUFS. nil when nothing is
    /// loud enough to count (silence), when the signal is shorter than one block (0.4 s), or when `channels` is not 1 or 2 (not specified).
    /// The result is not rounded.
    public static func integratedLufs(interleaved samples: [Int16], channels: Int) -> Double? {
        guard channels == 1 || channels == 2 else { return nil }
        return integratedLufs(frames: samples.count / channels, channels: channels) { frame, channel in Double(samples[frame * channels + channel]) / 32768 }
    }

    /// The same for floating point samples in -1...1.
    public static func integratedLufs(interleaved samples: [Float], channels: Int) -> Double? {
        guard channels == 1 || channels == 2 else { return nil }
        return integratedLufs(frames: samples.count / channels, channels: channels) { frame, channel in Double(samples[frame * channels + channel]) }
    }

    private static func integratedLufs(frames: Int, channels: Int, sample: (Int, Int) -> Double) -> Double? {
        let rate = AudioFormat.sampleRate
        let step = Int((stepSeconds * Double(rate)).rounded())            // 4800
        let blockSteps = Int((blockSeconds / stepSeconds).rounded())      // 4 steps make a block
        let steps = frames / step
        guard steps >= blockSteps else { return nil }

        // K-weighted mean-square energy of every 100 ms step, summed over the channels. A block is the sum of four consecutive steps.
        var energy = [Double](repeating: 0, count: steps)
        for c in 0..<channels {
            var stage1 = shelf(), stage2 = highPass()
            for s in 0..<steps {
                var sum = 0.0
                for n in (s * step)..<((s + 1) * step) {
                    let y = stage2.process(stage1.process(sample(n, c)))
                    sum += y * y
                }
                energy[s] += sum
            }
        }
        let blockCount = steps - blockSteps + 1
        let samplesPerBlock = Double(step * blockSteps)
        var power = [Double](repeating: 0, count: blockCount)       // mean square of the block, channels summed
        for b in 0..<blockCount {
            var e = 0.0
            for k in 0..<blockSteps { e += energy[b + k] }
            power[b] = e / samplesPerBlock
        }

        func lufs(_ p: Double) -> Double { p > 0 ? offset + 10 * log10(p) : -Double.infinity }
        // Absolute gate.
        var sum = 0.0, count = 0
        for p in power where lufs(p) > absoluteGateLufs {
            sum += p
            count += 1
        }
        guard count > 0 else { return nil }
        // Relative gate: 10 LU below the loudness of the blocks that passed the absolute gate.
        let relative = lufs(sum / Double(count)) + relativeGateLU
        sum = 0
        count = 0
        for p in power where lufs(p) > absoluteGateLufs && lufs(p) > relative {
            sum += p
            count += 1
        }
        guard count > 0 else { return nil }
        return lufs(sum / Double(count))
    }
}
