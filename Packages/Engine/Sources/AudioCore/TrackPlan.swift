/// What happens when a track's passes are over (docs/audio-spec-1.md, "End actions and pass counts").
public enum TrackEnd: Equatable, CaseIterable {
    /// One pass, then whatever the playlist play mode says.
    case followPlayMode
    /// Two passes, then as `followPlayMode`.
    case twice
    /// Passes without end.
    case loop
    /// One pass, then the run stops whatever the play mode is.
    case stop

    /// The value a cycling control moves to: followPlayMode, twice, loop, stop, and round again.
    public var next: TrackEnd {
        switch self {
        case .followPlayMode: return .twice
        case .twice: return .loop
        case .loop: return .stop
        case .stop: return .followPlayMode
        }
    }

    /// How many passes the track plays; nil = no end.
    public var passes: Int? {
        switch self {
        case .followPlayMode, .stop: return 1
        case .twice: return 2
        case .loop: return nil
        }
    }
}

/// Everything fixed about how one track starts, in frames: the window that plays (a window of the file, never a copy of the audio), where in it the
/// sound begins, the fades at A and B, and the end action. Built from the stored trim, the player policy, the file length and the start position.
public struct TrackPlan: Equatable {
    public let sampleRate: Int
    /// A, B and the position the sound begins at, in frames of the file. `loFrames <= baseFrames <= hiFrames`.
    public let loFrames: Int64
    public let hiFrames: Int64
    public let baseFrames: Int64
    /// The start was at A (not a seek or a resume part-way in), so a fade-in may apply.
    public let isFresh: Bool
    /// Fade-in at A and fade-out ahead of B, in ms and frames. 0 = none (a cut).
    public let fadeInMs: Int
    public let fadeInFrames: Int64
    public let endFadeMs: Int
    public let endFadeFrames: Int64
    public let end: TrackEnd

    /// - Parameters:
    ///   - offsetSeconds: where in the file the sound begins; at or before A means "at A".
    public init(trim: Trim, policy: TrimPolicy, fileLength: Double, offsetSeconds: Double = 0, end: TrackEnd = .followPlayMode, sampleRate: Int = AudioFormat.sampleRate) {
        func frames(_ s: Double) -> Int64 { Int64((s * Double(sampleRate)).rounded()) }
        let w = trim.window(fileLength: fileLength)
        let fresh = offsetSeconds <= w.start
        let base = fresh ? w.start : min(offsetSeconds, w.end)
        let durationMs = (w.end - base) * 1000

        // Fade at B: only with an Out point and a fade edge, and never longer than the part that plays.
        var endFade = 0
        if trim.outPoint != nil, !trim.endsWithCut { endFade = min(trim.fadeOutMs(policy: policy), Int(durationMs)) }
        // Fade in at A: only on a start at A; capped to the window minus the out-fade, unless that leaves less than the shortest fade.
        var fadeIn = fresh ? trim.fadeInAppliedMs(policy: policy) : 0
        let room = durationMs - Double(endFade)
        fadeIn = Int(min(Double(fadeIn), room >= Double(Trim.fadeRangeMs.lowerBound) ? room : durationMs))

        self.sampleRate = sampleRate
        loFrames = frames(w.start)
        hiFrames = frames(w.end)
        baseFrames = frames(base)
        isFresh = fresh
        fadeInMs = max(0, fadeIn)
        fadeInFrames = frames(Double(max(0, fadeIn)) / 1000)
        endFadeMs = endFade
        endFadeFrames = frames(Double(endFade) / 1000)
        self.end = end
    }

    private init(copying p: TrackPlan, fadeInMs: Int, fadeInFrames: Int64) {
        sampleRate = p.sampleRate
        loFrames = p.loFrames
        hiFrames = p.hiFrames
        baseFrames = p.baseFrames
        isFresh = p.isFresh
        self.fadeInMs = fadeInMs
        self.fadeInFrames = fadeInFrames
        endFadeMs = p.endFadeMs
        endFadeFrames = p.endFadeFrames
        end = p.end
    }

    /// The same plan without a fade-in (it is never applied under a crossfade or while paused).
    public func withoutFadeIn() -> TrackPlan { TrackPlan(copying: self, fadeInMs: 0, fadeInFrames: 0) }

    /// Length of the first pass (from where the sound begins to B) and of every later pass (A to B), in frames.
    public var firstPassFrames: Int64 { hiFrames - baseFrames }
    public var windowFrames: Int64 { hiFrames - loFrames }

    /// The gain at the very start: 0 while a fade-in is applied, else 1.
    public var startGain: Double { fadeInFrames > 0 ? 0 : 1 }

    public func seconds(_ frames: Int64) -> Double { Double(frames) / Double(sampleRate) }
}
