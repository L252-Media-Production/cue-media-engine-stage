import Foundation

/// The level-match setting of a playlist and the gain it gives a track (docs/audio-spec-1.md, "Level match and LUFS"): `off`, `track` (the loudness of a
/// reference track is the target) or `lufs` (a fixed target). The gain is `min(0, target - measured)` dB: a track is only ever turned down.
/// Plain values and arithmetic; nothing here allocates.
public struct LevelMatch: Equatable {
    public enum Mode: Equatable, CaseIterable {
        case off, track, lufs
    }

    /// The range a fixed target is held to, in LUFS, and the step it is rounded to.
    public struct Clamp: Equatable {
        public var min: Double
        public var max: Double
        public var step: Double

        public init(min: Double, max: Double, step: Double) {
            self.min = min
            self.max = max
            self.step = step
        }

        /// -60...0 LUFS in 0.1 steps.
        public static let standard = Clamp(min: -60, max: 0, step: 0.1)
    }

    /// The target kept for `lufs` mode when none was typed. Unused in the other modes.
    public static let defaultTargetLufs = -18.0

    public var mode: Mode = .off
    /// The reference track of `track` mode, by id (a typed index becomes an id when it is stored).
    public var referenceTrack: TrackID?
    public var targetLufs = LevelMatch.defaultTargetLufs

    public init(mode: Mode = .off, referenceTrack: TrackID? = nil, targetLufs: Double = LevelMatch.defaultTargetLufs) {
        self.mode = mode
        self.referenceTrack = referenceTrack
        self.targetLufs = targetLufs
    }

    /// What `typed` is when the settings path stores it: a fixed target is clamped to the range and rounded to the step (typed -80 stores -60); a reference is
    /// kept by id (an index outside the playlist keeps no reference); a target that is not a number keeps the default. `playlist` lists the track ids in order.
    public init(typedMode mode: Mode, typedReferenceIndex: Int?, typedLufs: Double?, playlist: [TrackID], clamp: Clamp = .standard) {
        self.init(mode: mode)
        if mode == .track, let i = typedReferenceIndex, playlist.indices.contains(i) { referenceTrack = playlist[i] }
        if mode == .lufs, let typed = typedLufs, !typed.isNaN { targetLufs = Self.clamped(typed, clamp) }
    }

    /// `value` held to `clamp.min...clamp.max` and rounded to a multiple of `clamp.step`.
    public static func clamped(_ value: Double, _ clamp: Clamp) -> Double {
        let held = Swift.min(clamp.max, Swift.max(clamp.min, value))
        guard clamp.step > 0 else { return held }
        let stepped = (held / clamp.step).rounded() * clamp.step
        // Rounding to a step must not leave the range, and 0.1 steps are held to the decimal they stand for.
        return Swift.min(clamp.max, Swift.max(clamp.min, (stepped * 1e6).rounded() / 1e6))
    }

    /// The gain in dB for a track measured at `measured` LUFS when the target is `target`: `min(0, target - measured)`. nil: not applicable (no target or
    /// no measurement).
    public static func gainDb(measured: Double?, target: Double?) -> Double? {
        guard let measured, let target else { return nil }
        return Swift.min(0, target - measured)
    }

    /// `10^(dB/20)`; 1 when there is no gain.
    public static func linear(db: Double?) -> Double { db.map { pow(10, $0 / 20) } ?? 1 }

    /// The gain in dB this setting gives a track measured at `measured`; `referenceMeasured` is the loudness of the reference track (`track` mode).
    public func gainDb(measured: Double?, referenceMeasured: Double?) -> Double? {
        switch mode {
        case .off: return nil
        case .lufs: return Self.gainDb(measured: measured, target: targetLufs)
        case .track: return Self.gainDb(measured: measured, target: referenceMeasured)
        }
    }
}
