/// One playing sound as far as the gain is concerned: a level and at most one running fade. The next slices (trim window, passes,
/// end actions) add their state here; the clock is always the `Transport`'s play frame.
public struct Deck: Equatable, Identifiable {
    public typealias ID = Int

    public let id: ID
    /// The gain when no fade is running (the spec's `Deck.vol`, as an ideal value: it is not quantised).
    public private(set) var level: Double
    public private(set) var fade: Fade?
    /// The deck is removed when its fade has finished (a fade-out, the old side of a crossfade).
    public private(set) var endsWhenFadeEnds = false
    public private(set) var isPlaying = true

    init(id: ID, level: Double) {
        self.id = id
        self.level = level
    }

    /// The gain at a play frame.
    public func gain(at frame: Int64) -> Double { fade?.gain(at: frame) ?? level }

    /// Replaces any running fade with a new one that starts from the gain the deck has right now.
    mutating func fade(_ direction: Fade.Direction, to target: Double, at frame: Int64, lengthFrames: Int64, endsDeck: Bool) {
        fade = Fade(direction: direction, from: gain(at: frame), to: target, startFrame: frame, lengthFrames: lengthFrames)
        endsWhenFadeEnds = endsDeck
        settle(at: frame)
    }

    /// Takes a finished fade over into the level and removes the deck when it was meant to end.
    mutating func settle(at frame: Int64) {
        guard let f = fade, f.isFinished(at: frame) else { return }
        level = f.to
        fade = nil
        if endsWhenFadeEnds { isPlaying = false }
    }

    /// Removes the deck at once (a cut).
    mutating func stop() {
        level = 0
        fade = nil
        isPlaying = false
    }
}
