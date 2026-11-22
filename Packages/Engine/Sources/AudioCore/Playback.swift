/// The position of a deck inside its passes at one moment.
public struct PassPosition: Equatable {
    /// 1 for the first pass. A looping track reports 1 for ever; a twice-played one goes 1, then 2.
    public var number: Int
    /// Frames left of the pass that is running.
    public var remainingFrames: Int64
}

/// A deck that plays a `TrackPlan` from a play frame. Everything here is derived from the frame counts by arithmetic, so the state is a handful of
/// integers: no per-frame bookkeeping, nothing to allocate, nothing that can drift against the clock.
///
/// Real-time: every method below is plain integer and floating-point arithmetic on value types. No allocation, no closures, no locks.
public struct Playback: Equatable {
    public let plan: TrackPlan
    /// The play frame the first sample was played at.
    public let startFrame: Int64
    /// The play frame at which the deck ends by itself; nil while it never does (a loop).
    public private(set) var endFrame: Int64?
    /// A loop reports pass 1 for ever, also after it has been switched to end with the running pass.
    private var reportsOnePass: Bool

    init(plan: TrackPlan, startFrame: Int64) {
        self.plan = plan
        self.startFrame = startFrame
        reportsOnePass = plan.end == .loop
        if let passes = plan.end.passes {
            endFrame = startFrame + plan.firstPassFrames + Int64(passes - 1) * plan.windowFrames
        } else {
            endFrame = nil
        }
    }

    func withoutFadeIn() -> Playback {
        var p = Playback(plan: plan.withoutFadeIn(), startFrame: startFrame)
        p.endFrame = endFrame
        return p
    }

    public func isEnded(at frame: Int64) -> Bool {
        guard let e = endFrame else { return false }
        return frame >= e
    }

    /// The pass that is running and how long it has left; nil once the deck has ended.
    public func pass(at frame: Int64) -> PassPosition? {
        guard !isEnded(at: frame) else { return nil }
        let elapsed = frame - startFrame
        let first = plan.firstPassFrames
        if elapsed < first { return PassPosition(number: 1, remainingFrames: first - elapsed) }
        let w = plan.windowFrames
        let later = elapsed - first
        let index = later / w
        return PassPosition(number: reportsOnePass ? 1 : Int(index) + 2, remainingFrames: w - later % w)
    }

    /// The 0-based pass the deck is in, counted truly (a loop keeps counting; `pass(at:)` reports 1 for ever). nil once ended.
    public func passIndex(at frame: Int64) -> Int? {
        guard !isEnded(at: frame) else { return nil }
        let elapsed = frame - startFrame
        let first = plan.firstPassFrames
        if elapsed < first { return 0 }
        return Int((elapsed - first) / plan.windowFrames) + 1
    }

    /// Where in the FILE the deck is at `frame`, in frames of the file: from where the sound began during the first pass, from A in every later one.
    /// nil once the deck has ended.
    public func filePositionFrames(at frame: Int64) -> Int64? {
        guard !isEnded(at: frame) else { return nil }
        let elapsed = max(0, frame - startFrame)
        let first = plan.firstPassFrames
        if elapsed < first { return plan.baseFrames + elapsed }
        return plan.loFrames + (elapsed - first) % plan.windowFrames
    }

    /// The first play frame after `frame` at which the next pass begins; nil when no further pass comes (the deck ends first, or it never started one).
    public func nextPassBoundary(after frame: Int64) -> Int64? {
        let first = plan.firstPassFrames
        let elapsed = frame - startFrame
        let boundary = elapsed < first ? startFrame + first : startFrame + first + ((elapsed - first) / plan.windowFrames + 1) * plan.windowFrames
        if let e = endFrame, boundary >= e { return nil }
        return boundary
    }

    /// The same deck, moved to `seconds` of the file at `frame`. The target is held to [A, B - 0.3 s] (docs/audio-spec-1.md, quirk 1). The passes that were left are
    /// kept (a loop keeps looping; the out-fade and the end follow from the new position), the fade-in does not play again. Pure arithmetic.
    func seeked(toSeconds seconds: Double, at frame: Int64) -> Playback {
        let rate = Double(plan.sampleRate)
        let target = Int64((seconds * rate).rounded())
        let latest = max(plan.loFrames, plan.hiFrames - Int64((0.3 * rate).rounded()))
        let base = min(max(target, plan.loFrames), latest)
        // Passes still to play, the running one included.
        var remaining = Int64.max
        if let e = endFrame {
            let total = e - startFrame <= plan.firstPassFrames ? 1 : 1 + (e - startFrame - plan.firstPassFrames + plan.windowFrames - 1) / plan.windowFrames
            remaining = max(1, total - Int64(passIndex(at: frame) ?? 0))
        }
        var p = Playback(plan: plan.seeked(toBaseFrames: base), startFrame: frame)
        p.reportsOnePass = reportsOnePass
        if remaining != Int64.max { p.endFrame = frame + p.plan.firstPassFrames + (remaining - 1) * plan.windowFrames } else { p.endFrame = nil }
        return p
    }

    /// The running pass becomes the last one: the deck ends at its end instead of going on (the end action was switched off).
    /// A deck that has ended already is left alone.
    mutating func finishCurrentPass(at frame: Int64) {
        guard !isEnded(at: frame) else { return }
        let elapsed = frame - startFrame
        let first = plan.firstPassFrames
        if elapsed < first {
            endFrame = startFrame + first
        } else {
            let w = plan.windowFrames
            endFrame = startFrame + first + ((elapsed - first) / w + 1) * w
        }
    }

    /// Whether the out-fade ahead of B is running at `frame`: in the last pass of a deck that ends, for the last `endFadeFrames`
    /// (never longer than that pass). A looping deck has none.
    public func isFadingOut(at frame: Int64) -> Bool {
        fadeOutFrames(at: frame) != nil
    }

    /// Remaining frames of the out-fade and its length, nil when it is not running.
    private func fadeOutFrames(at frame: Int64) -> (remaining: Int64, length: Int64)? {
        guard let e = endFrame, plan.endFadeFrames > 0, frame < e else { return nil }
        let lastPass = (e - startFrame) <= plan.firstPassFrames ? plan.firstPassFrames : plan.windowFrames
        let length = min(plan.endFadeFrames, lastPass)
        let remaining = e - frame
        return remaining <= length ? (remaining, length) : nil
    }

    /// The gain the edges of the window give at `frame`: a sin ramp up over the fade-in at A, a cos ramp down over the out-fade ahead of B
    /// (reaching 0 at B), 1 in between. A cut at B has no ramp: the deck just ends.
    public func edgeGain(at frame: Int64) -> Double {
        var g = 1.0
        let elapsed = frame - startFrame
        if plan.fadeInFrames > 0, elapsed < plan.fadeInFrames {
            g *= EqualPower.rampUp(x: Double(max(0, elapsed)) / Double(plan.fadeInFrames))
        }
        if let f = fadeOutFrames(at: frame) {
            g *= EqualPower.rampDown(x: 1 - Double(f.remaining) / Double(f.length))
        }
        return g
    }
}
