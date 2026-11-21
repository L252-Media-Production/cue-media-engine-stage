/// The decks and the clock. It starts decks, crossfades and fades out, and answers the gain of each deck at the current time.
/// No hardware, no threads: time moves only when `advance(frames:)` is called.
public struct Mixer {
    /// A deck that ended by itself, at the exact play frame (not the frame at which `advance` noticed).
    public struct DeckEnded: Equatable {
        public var deck: Deck.ID
        public var frame: Int64
    }

    public static let eventCapacity = 32

    public private(set) var transport: Transport
    /// Every deck ever started, in start order. Ended decks stay (with `isPlaying` false) so their last gain can still be read.
    public private(set) var decks: [Deck] = []
    /// The decks that ended during the last `advance`, in order of time. Filled without allocating (capacity `eventCapacity`).
    public private(set) var ended: [DeckEnded] = []
    /// Ends that did not fit in `ended` during the last `advance` (they still happened: see `Deck.endedAtFrame`).
    public private(set) var droppedEnds = 0

    public init(sampleRate: Int = AudioFormat.sampleRate) {
        transport = Transport(sampleRate: sampleRate)
        ended.reserveCapacity(Self.eventCapacity)
    }

    // MARK: time

    /// Moves the clock and settles every deck, recording the decks that ended in `ended`.
    /// Real-time: no allocation (`ended` is preallocated and cleared in place), no closures, no locks.
    public mutating func advance(frames: Int64) {
        transport.advance(frames: frames)
        ended.removeAll(keepingCapacity: true)
        droppedEnds = 0
        let now = transport.playFrame
        for i in decks.indices {
            let wasPlaying = decks[i].isPlaying
            decks[i].settle(at: now)
            if wasPlaying, !decks[i].isPlaying, let f = decks[i].endedAtFrame {
                if ended.count < Self.eventCapacity {
                    ended.append(DeckEnded(deck: decks[i].id, frame: f))
                } else {
                    droppedEnds += 1
                }
            }
        }
    }

    public mutating func pause() { transport.pause() }
    public mutating func resume() { transport.resume() }

    // MARK: decks

    /// The deck that is audible as "the" track: the newest one still playing. During a fade-out it is still live; once the fade has finished nothing is.
    public var live: Deck? { decks.last { $0.isPlaying } }

    /// Allocates (it builds an array): for tests and UI, not for the audio thread. (Slice-1 code, left as it is.)
    public var playingCount: Int { decks.filter(\.isPlaying).count }

    public func deck(_ id: Deck.ID) -> Deck? { decks.first { $0.id == id } }

    /// The gain of a deck now (nil: no such deck).
    public func gain(of id: Deck.ID) -> Double? { deck(id)?.gain(at: transport.playFrame) }

    /// Starts a new deck. With `crossfadeMs` of 0 the decks that are playing are removed at once (a cut) and the new one starts at full level.
    /// Otherwise the new deck fades up from 0 and the playing ones fade down to 0 over the same time, then they are removed.
    /// Setup path, not real-time: appending a deck can allocate. (A render thread will start decks from preallocated storage in a later slice.)
    /// A `plan` makes the deck play a window with passes and fades at its edges; without one the deck plays without end. A fade-in at A is dropped
    /// under a crossfade and while the transport is paused.
    @discardableResult
    public mutating func start(_ plan: TrackPlan? = nil, crossfadeMs: Int = 0) -> Deck.ID {
        let now = transport.playFrame
        let length = transport.frames(milliseconds: crossfadeMs)
        let id = (decks.last?.id ?? 0) + 1
        var new = Deck(id: id, level: length > 0 ? 0 : 1, playback: plan.map { Playback(plan: $0, startFrame: now) })
        if length > 0 || transport.isPaused { new.dropFadeIn() }
        if length > 0 {
            for i in decks.indices where decks[i].isPlaying {
                decks[i].fade(.down, to: 0, at: now, lengthFrames: length, endsDeck: true)
            }
            new.fade(.up, to: 1, at: now, lengthFrames: length, endsDeck: false)
        } else {
            for i in decks.indices where decks[i].isPlaying { decks[i].stop(at: now) }
        }
        decks.append(new)
        return id
    }

    /// Fades the live deck down to 0 over `milliseconds` and removes it. 0 is a cut. Does nothing when nothing is live.
    public mutating func fadeOutLive(milliseconds: Int) {
        guard let id = live?.id, let i = decks.firstIndex(where: { $0.id == id }) else { return }
        let length = transport.frames(milliseconds: milliseconds)
        if length > 0 {
            decks[i].fade(.down, to: 0, at: transport.playFrame, lengthFrames: length, endsDeck: true)
        } else {
            decks[i].stop(at: transport.playFrame)
        }
    }

    /// The running pass of a deck becomes its last: it ends at the end of that pass (a looping or twice-played track whose end action was switched off).
    public mutating func finishCurrentPass(of id: Deck.ID) {
        guard let i = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[i].finishCurrentPass(at: transport.playFrame)
    }
}
