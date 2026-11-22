/// A track's identity inside a show. It does not change when the playlist is edited, unlike an index.
public struct TrackID: Hashable, Comparable {
    public var raw: Int

    public init(_ raw: Int) { self.raw = raw }

    public static func < (a: TrackID, b: TrackID) -> Bool { a.raw < b.raw }
}

/// What follows a track in a playlist (docs/audio-spec-1.md, "Play modes and shuffle bag"). Only consulted for a track whose end action is `followPlayMode` or `twice`.
public enum PlaylistMode: Equatable, CaseIterable {
    /// Nothing follows.
    case stop
    /// The next track, wrapping to the first after the last.
    case loopPlaylist
    /// To the end of the playlist, then the first track of the next playlist that has tracks. After the last playlist nothing follows.
    case nextPlaylist
    /// Every track once per round (a "bag"), never the same one twice in a row.
    case shuffle
}

/// One track of a playlist: what plays (a window of a file of `lengthSeconds`), and what happens when it ends. Plain data; no audio.
public struct PlaylistTrack: Equatable {
    public var id: TrackID
    public var lengthSeconds: Double
    public var trim: Trim
    public var end: TrackEnd
    /// The track's own crossfade time in ms (0...30000), nil = follow the master time. Stored for the crossfade rules; the auto-advance starts the next track with a cut.
    public var crossfadeMs: Int?
    /// Voice-overs fired from positions of this track's file.
    public var triggers = TriggerList()

    public init(id: TrackID, lengthSeconds: Double, trim: Trim = Trim(), end: TrackEnd = .followPlayMode, crossfadeMs: Int? = nil, triggers: TriggerList = TriggerList()) {
        self.triggers = triggers
        self.id = id
        self.lengthSeconds = lengthSeconds
        self.trim = trim
        self.end = end
        self.crossfadeMs = crossfadeMs
    }
}

/// A source of random numbers that a test can fix. The shuffle bag takes one; nothing in AudioCore reaches for a global generator.
public protocol RandomSource {
    /// A number in `0..<upperBound` (`upperBound` > 0), each value equally likely.
    mutating func next(below upperBound: Int) -> Int
}

/// A deterministic generator (SplitMix64) for tests and for a show that wants a repeatable shuffle. It does not reproduce Python's `random`.
public struct SeededRandomSource: RandomSource, Equatable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    private mutating func word() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func next(below upperBound: Int) -> Int {
        precondition(upperBound > 0, "an empty range has no random number")
        let n = UInt64(upperBound)
        // Rejection sampling: no modulo bias.
        let limit = UInt64.max - UInt64.max % n
        var w = word()
        while w >= limit { w = word() }
        return Int(w % n)
    }
}

/// The system's generator, for a show that is not under test.
public struct SystemRandomSource: RandomSource {
    private var generator = SystemRandomNumberGenerator()

    public init() {}

    public mutating func next(below upperBound: Int) -> Int {
        precondition(upperBound > 0, "an empty range has no random number")
        return Int.random(in: 0..<upperBound, using: &generator)
    }
}

/// The shuffle bag of one playlist: the tracks that have not been played in the current round, in the order they will come.
///
/// Real-time: `draw` allocates nothing as long as the bag was given `capacity` for the playlist (`Playlist` does that whenever its tracks change).
public struct ShuffleBag: Equatable {
    public private(set) var remaining: [TrackID] = []

    public init() {}

    /// Setup path: may allocate.
    mutating func reserve(_ capacity: Int) { remaining.reserveCapacity(capacity) }

    /// Forgets the round (the play mode changed). Keeps the storage.
    public mutating func reset() { remaining.removeAll(keepingCapacity: true) }

    /// The index in `tracks` of the track to play after `current` (nil: nothing played before). Tracks that left the playlist and `current` are dropped from the
    /// bag first; an empty bag is refilled with every other track in a random order, so no track repeats before the others have played and the same track never
    /// comes twice in a row. A playlist of one track plays that track again. Nil for an empty playlist.
    public mutating func draw<R: RandomSource>(after current: TrackID?, in tracks: [PlaylistTrack], using random: inout R) -> Int? {
        guard !tracks.isEmpty else { return nil }
        // Drop what is no longer in the playlist and the current track, in place.
        var keep = 0
        for i in remaining.indices {
            let id = remaining[i]
            if id != current, tracks.contains(where: { $0.id == id }) {
                remaining[keep] = id
                keep += 1
            }
        }
        remaining.removeLast(remaining.count - keep)
        if remaining.isEmpty {
            for t in tracks where t.id != current { remaining.append(t.id) }
            if remaining.isEmpty { for t in tracks { remaining.append(t.id) } }
            // Fisher-Yates, in place.
            var i = remaining.count - 1
            while i > 0 {
                remaining.swapAt(i, random.next(below: i + 1))
                i -= 1
            }
        }
        let pick = remaining.removeLast()
        return tracks.firstIndex { $0.id == pick }
    }
}

/// An ordered list of tracks with a play mode.
public struct Playlist: Equatable {
    public var tracks: [PlaylistTrack] {
        didSet { bag.reserve(tracks.count) }      // setup path: may allocate
    }
    /// Changing the mode forgets the shuffle round.
    public var mode: PlaylistMode {
        didSet { if mode != oldValue { bag.reset() } }
    }
    public private(set) var bag = ShuffleBag()

    public init(tracks: [PlaylistTrack], mode: PlaylistMode = .stop) {
        self.tracks = tracks
        self.mode = mode
        bag.reserve(tracks.count)
    }

    public func index(of id: TrackID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// The next track by the shuffle bag; see `ShuffleBag.draw`.
    public mutating func drawShuffle<R: RandomSource>(after current: TrackID?, using random: inout R) -> Int? {
        bag.draw(after: current, in: tracks, using: &random)
    }
}

/// Where a track is: the index of its playlist and its index in it.
public struct TrackPosition: Equatable {
    public var playlist: Int
    public var track: Int

    public init(playlist: Int, track: Int) {
        self.playlist = playlist
        self.track = track
    }
}

/// What follows a track that ends.
public enum NextTrack: Equatable {
    case stopped
    /// The same track again (it loops).
    case same
    case track(TrackPosition)
}

/// The rules for what follows a track, as pure functions.
public enum PlayOrder {
    /// Track indices to try, best first, for what follows track `from` of a playlist of `trackCount` tracks (docs/audio-spec-1.md; the spec's `next_in_order`).
    /// A looping track repeats itself; `stop` gives none; `loopPlaylist` gives the next track and then the rest in a ring; `nextPlaylist` gives the rest of the
    /// playlist (the next playlist is the caller's business: see `successor`). `shuffle` is not an order but a draw: it gives none here (see `ShuffleBag`).
    /// Allocates the result: a setup and test path, not for the audio thread (the audio thread uses `successor`).
    public static func nextInOrder(mode: PlaylistMode, from: Int, trackCount: Int, trackLoops: Bool) -> [Int] {
        guard trackCount > 0 else { return [] }
        if trackLoops { return [from] }
        switch mode {
        case .stop, .shuffle: return []
        case .loopPlaylist: return (0..<trackCount).map { (from + 1 + $0) % trackCount }
        case .nextPlaylist: return from + 1 < trackCount ? Array((from + 1)..<trackCount) : []
        }
    }

    /// What plays after the track at `from` ended by itself: its own end action first (`stop` ends the run, `loop` plays it again), then the play mode of
    /// its playlist. A shuffle draws from the playlist's bag with `random`. Nothing here allocates once the bags have their capacity.
    public static func successor<R: RandomSource>(after from: TrackPosition, in playlists: inout [Playlist], using random: inout R) -> NextTrack {
        guard playlists.indices.contains(from.playlist), playlists[from.playlist].tracks.indices.contains(from.track) else { return .stopped }
        let track = playlists[from.playlist].tracks[from.track]
        switch track.end {
        case .stop: return .stopped
        case .loop: return .same
        case .followPlayMode, .twice: break
        }
        let p = from.playlist
        let count = playlists[p].tracks.count
        switch playlists[p].mode {
        case .stop:
            return .stopped
        case .loopPlaylist:
            return .track(TrackPosition(playlist: p, track: (from.track + 1) % count))
        case .nextPlaylist:
            if from.track + 1 < count { return .track(TrackPosition(playlist: p, track: from.track + 1)) }
            var q = p + 1
            while q < playlists.count {
                if !playlists[q].tracks.isEmpty { return .track(TrackPosition(playlist: q, track: 0)) }
                q += 1
            }
            return .stopped
        case .shuffle:
            guard let i = playlists[p].drawShuffle(after: track.id, using: &random) else { return .stopped }
            return .track(TrackPosition(playlist: p, track: i))
        }
    }
}
