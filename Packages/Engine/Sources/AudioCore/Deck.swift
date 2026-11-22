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
    /// The play frame at which the deck ended, exactly (not the frame at which anyone noticed). nil while it plays.
    public private(set) var endedAtFrame: Int64?
    /// The track window, passes and fades at A and B. nil: a deck that plays without end (slice 1).
    public private(set) var playback: Playback?

    /// The deck plays on top of the others (a voice-over fired by a trigger point): starting it does not stop them.
    public let isTop: Bool

    init(id: ID, level: Double, playback: Playback? = nil, isTop: Bool = false) {
        self.id = id
        self.isTop = isTop
        self.level = level
        self.playback = playback
    }

    /// The gain at a play frame: the crossfade / fade-out ramp times the edges of the window. An ended deck is silent.
    /// Real-time: arithmetic only.
    public func gain(at frame: Int64) -> Double {
        guard isPlaying else { return 0 }
        return (fade?.gain(at: frame) ?? level) * (playback?.edgeGain(at: frame) ?? 1)
    }

    /// The pass that is running and what is left of it (nil: no passes, or ended).
    public func pass(at frame: Int64) -> PassPosition? { isPlaying ? playback?.pass(at: frame) : nil }

    public func isFadingOutAtB(at frame: Int64) -> Bool { isPlaying && (playback?.isFadingOut(at: frame) ?? false) }

    /// Replaces any running fade with a new one that starts from the gain the deck has right now.
    mutating func fade(_ direction: Fade.Direction, to target: Double, at frame: Int64, lengthFrames: Int64, endsDeck: Bool) {
        fade = Fade(direction: direction, from: fade?.gain(at: frame) ?? level, to: target, startFrame: frame, lengthFrames: lengthFrames)
        endsWhenFadeEnds = endsDeck
        settle(at: frame)
    }

    /// Takes a finished fade over into the level and ends the deck when its fade was meant to end it or its last pass is over.
    /// The end is recorded at the exact frame it happened, not at `frame`.
    /// Real-time: arithmetic only.
    mutating func settle(at frame: Int64) {
        guard isPlaying else { return }
        var endedAt: Int64?
        if let f = fade, f.isFinished(at: frame) {
            level = f.to
            fade = nil
            if endsWhenFadeEnds { endedAt = f.startFrame + f.lengthFrames }
        }
        if let e = playback?.endFrame, frame >= e { endedAt = Swift.min(endedAt ?? e, e) }
        if let t = endedAt {
            isPlaying = false
            endedAtFrame = t
        }
    }

    /// Makes the running pass the last one.
    mutating func finishCurrentPass(at frame: Int64) {
        playback?.finishCurrentPass(at: frame)
        settle(at: frame)
    }

    /// Moves the deck to `seconds` of the file (see `Playback.seeked`). Volume, fades and the pause state are kept.
    mutating func seek(toSeconds seconds: Double, at frame: Int64) {
        guard isPlaying, let p = playback else { return }
        playback = p.seeked(toSeconds: seconds, at: frame)
        settle(at: frame)
    }

    /// Removes the deck at once (a cut).
    mutating func stop(at frame: Int64) {
        level = 0
        fade = nil
        isPlaying = false
        endedAtFrame = frame
    }

    /// The deck starts under a crossfade or while paused: no fade-in (it applies only on a plain start at A).
    mutating func dropFadeIn() { playback = playback?.withoutFadeIn() }
}
