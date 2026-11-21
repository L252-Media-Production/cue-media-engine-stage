import Foundation

/// Equal-power fade maths of the audio spec (docs/AUDIO-SPEC.md, "Fades and equal-power curves").
/// Pure functions: no state, no I/O. `x` is the fraction of the fade that has run (elapsed / length).
public enum EqualPower {
    /// Fraction of a fade that has run, clamped to 0...1. A length of 0 or less is a cut (1).
    public static func progress(elapsed: Double, length: Double) -> Double {
        guard length > 0 else { return 1 }
        return min(1, max(0, elapsed / length))
    }

    /// Fade up from `a` to `b`: `a + (b - a) * sin(x * pi / 2)`.
    public static func rampUp(x: Double, from a: Double = 0, to b: Double = 1) -> Double {
        let x = min(1, max(0, x))
        return a + (b - a) * sin(x * .pi / 2)
    }

    /// Fade down from `a` to `b`: `b + (a - b) * cos(x * pi / 2)`.
    public static func rampDown(x: Double, from a: Double = 1, to b: Double = 0) -> Double {
        let x = min(1, max(0, x))
        return b + (a - b) * cos(x * .pi / 2)
    }

    /// Gains of the two decks in a crossfade at fraction `x`: the new deck goes 0 -> 1, the old one 1 -> 0,
    /// so `new^2 + old^2 = 1`.
    public static func crossfade(x: Double) -> (new: Double, old: Double) {
        (rampUp(x: x), rampDown(x: x))
    }
}
