/// Playlists and a mixer together: plays a track and, when it ends by itself, starts what follows it (docs/audio-spec-1.md, "Play modes and shuffle bag").
///
/// The advance is driven only by the frames given to `advance(frames:)`. The mixer is stepped to the exact frame a deck ends at and the successor starts
/// there, so a chain of tracks has no gap and no dependency on how big the steps of the caller are. There is no wall clock and no timer.
///
/// Real-time: `advance(frames:)` allocates nothing while no track ends. Starting the next track appends a deck to the mixer, which can allocate (and
/// ended decks are kept by the mixer, so a long show grows that array by one deck per track): see `Mixer.start`.
public struct PlaylistPlayer<Random: RandomSource> {
    /// The track that is playing: its place, stable id and deck.
    public struct Current: Equatable {
        public var position: TrackPosition
        public var track: TrackID
        public var deck: Deck.ID
    }

    public private(set) var mixer: Mixer
    public private(set) var playlists: [Playlist]
    public let policy: TrimPolicy
    public private(set) var current: Current?
    private var random: Random

    /// The most tracks one `advance` starts. A playlist whose tracks are shorter than a frame would otherwise never let time move.
    public static var maxStartsPerAdvance: Int { 64 }

    /// Setup path.
    public init(playlists: [Playlist], policy: TrimPolicy, random: Random, mixer: Mixer = Mixer()) {
        self.playlists = playlists
        self.policy = policy
        self.random = random
        self.mixer = mixer
    }

    // MARK: editing the play data

    /// Setup path: may allocate (a shuffle bag is reset or resized).
    public mutating func setMode(_ mode: PlaylistMode, ofPlaylist p: Int) {
        guard playlists.indices.contains(p) else { return }
        playlists[p].mode = mode
    }

    /// Changes what a track does when it ends. If it is playing, the pass that is running is played out and the NEW action decides what follows:
    /// `followPlayMode` the play mode, `stop` nothing, `loop` the track starts again. A switch TO `twice` while the track plays changes nothing for
    /// that run (not specified; docs/audio-conformance.md, "Stage decisions to make").
    public mutating func setEnd(_ end: TrackEnd, ofTrack id: TrackID, inPlaylist p: Int) {
        guard playlists.indices.contains(p), let i = playlists[p].index(of: id) else { return }
        playlists[p].tracks[i].end = end
        if let c = current, c.track == id, c.position.playlist == p, end != .twice {
            mixer.finishCurrentPass(of: c.deck)
        }
    }

    // MARK: playing

    /// Starts a track with a cut (the old deck is removed at once). Does nothing for a position that is not in the playlists.
    @discardableResult
    public mutating func play(_ position: TrackPosition, crossfadeMs: Int = 0) -> Bool {
        guard playlists.indices.contains(position.playlist), playlists[position.playlist].tracks.indices.contains(position.track) else { return false }
        let t = playlists[position.playlist].tracks[position.track]
        let plan = TrackPlan(trim: t.trim, policy: policy, fileLength: t.lengthSeconds, end: t.end, sampleRate: mixer.transport.sampleRate)
        let id = mixer.start(plan, crossfadeMs: crossfadeMs)
        current = Current(position: position, track: t.id, deck: id)
        return true
    }

    /// Stops what plays (a cut). Setup and UI path.
    public mutating func stop() {
        mixer.fadeOutLive(milliseconds: 0)
        current = nil
    }

    /// Moves time by `frames`. Whenever the playing track ends by itself, what follows it starts at the exact frame it ended.
    public mutating func advance(frames: Int64) {
        var left = frames
        var starts = 0
        while left > 0 {
            var step = left
            if let c = current, let end = mixer.deck(c.deck)?.playback?.endFrame {
                let toEnd = end - mixer.transport.playFrame
                if toEnd >= 0, toEnd < step { step = toEnd }
            }
            mixer.advance(frames: step)
            left -= step
            guard let c = current else { continue }
            var ended = false
            for e in mixer.ended where e.deck == c.deck { ended = true }
            if ended {
                starts += 1
                guard starts <= Self.maxStartsPerAdvance else { current = nil; return }
                startSuccessor(of: c)
            } else if step == 0 {
                return      // not ended and no time to move: nothing more can happen
            }
        }
    }

    /// The track at `c` ended: what follows it, by its end action as it is NOW and its playlist's play mode.
    private mutating func startSuccessor(of c: Current) {
        // The track may have been moved or removed while it played: follow its id.
        var from = c.position
        if playlists.indices.contains(from.playlist), let i = playlists[from.playlist].index(of: c.track) {
            from.track = i
        } else {
            current = nil
            return
        }
        switch PlayOrder.successor(after: from, in: &playlists, using: &random) {
        case .stopped:
            current = nil
        case .same:
            play(from)
        case .track(let next):
            play(next)
        }
    }
}
