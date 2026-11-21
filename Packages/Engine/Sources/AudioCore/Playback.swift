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
    private let reportsOnePass: Bool

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
