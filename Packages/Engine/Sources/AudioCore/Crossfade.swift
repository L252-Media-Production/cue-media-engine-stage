/// Which time a crossfade into a track takes (docs/AUDIO-SPEC.md, "Crossfade time precedence").
public struct CrossfadeSettings: Equatable {
    /// The master crossfade time of the player, in milliseconds.
    public var masterMs: Int

    public init(masterMs: Int) { self.masterMs = masterMs }

    /// Longest own crossfade time of a track.
    public static let maxOwnMs = 30_000

    /// An explicitly asked time wins, then the track's own time (0 is allowed: a cut), then the master time.
    public func timeMs(explicitMs: Int? = nil, ownMs: Int? = nil) -> Int {
        explicitMs ?? ownMs ?? masterMs
    }

    /// The own crossfade time a track keeps for a value typed in seconds: whole milliseconds, 0 to 30 s. `nil` means the value is refused
    /// (out of range, not a number). The range is checked after rounding to a whole millisecond, so 30.0004 s is kept as 30000 ms.
    public static func ownTimeMs(seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        let ms = (seconds * 1000).rounded()
        guard ms >= 0, ms <= Double(maxOwnMs) else { return nil }
        return Int(ms)
    }
}
