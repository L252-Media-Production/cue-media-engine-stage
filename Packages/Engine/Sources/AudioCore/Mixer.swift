/// Counters of things the engine had to give up on instead of crashing or allocating. Monotonic: they only grow, so a health display can show the change
/// between two reads. All of them stand for a situation that should not happen in a normal show.
public struct EngineCounters: Equatable {
    /// Decks that ended in a call but did not fit in `Mixer.ended` (their ends still happened: see `Deck.endedAtFrame`).
    public var droppedEnds = 0
    /// Trigger fires that did not fit in `PlaylistPlayer.fired` (the voices still started).
    public var droppedFires = 0
    /// Starts that were refused because every slot of the deck pool held a deck that is still playing (a crossfade or a voice on top; a cut never is).
    public var poolExhausted = 0

    public init() {}
}

/// The decks and the clock. It starts decks, crossfades and fades out, and answers the gain of each deck at the current time.
/// No hardware, no threads: time moves only when `advance(frames:)` is called.
///
/// The decks live in a pool of `poolCapacity` slots that is allocated once, in `init`, and never grows. A deck is addressed by a `DeckID` (slot and
/// generation); the slot of a deck that has ended is reused by a later start, oldest end first, and the old handle is refused from then on. What a finished
/// deck left behind is in its `DeckEnded` record (frame and last gain), which is what to read after the end. If every slot holds a deck that is still
/// playing, a start is refused: it returns `DeckID.none`, changes nothing and is counted in `counters.poolExhausted`.
public struct Mixer {
    /// A deck that ended by itself, at the exact play frame (not the frame at which `advance` noticed), and the gain of the last frame it played.
    public struct DeckEnded: Equatable {
        public var deck: Deck.ID
        public var frame: Int64
        public var lastGain: Double

        public init(deck: Deck.ID, frame: Int64, lastGain: Double) {
            self.deck = deck
            self.frame = frame
            self.lastGain = lastGain
        }
    }

    public static let eventCapacity = 32

    /// How many decks the pool holds. At most 3 are ever needed at once by a normal show (the live track, the old one while it crossfades out, a trigger
    /// voice on top); the fixtures and tests need at most 3. The rest is headroom for several crossfades stacked on each other and for ended decks that
    /// have not been recycled yet. Documented in docs/audio-engine-realtime.md.
    public static let defaultPoolCapacity = 16

    private struct Slot {
        var deck: Deck?
        /// Raised on every reuse of the slot; 0 = never used.
        var generation: UInt32 = 0
        /// Start order, for `decks` and `live`.
        var serial: UInt64 = 0
    }

    public private(set) var transport: Transport
    private var slots: [Slot]
    private var nextSerial: UInt64 = 1
    /// The decks that ended during the last `advance`, in order of time. Filled without allocating (capacity `eventCapacity`).
    public private(set) var ended: [DeckEnded] = []
    /// Ends that did not fit in `ended` during the last `advance`.
    public private(set) var droppedEnds = 0
    public private(set) var counters = EngineCounters()

    /// Setup path: allocates the pool and the ended buffer, once.
    public init(sampleRate: Int = AudioFormat.sampleRate, poolCapacity: Int = Mixer.defaultPoolCapacity) {
        precondition(poolCapacity > 0 && poolCapacity < Int(Int32.max), "a pool needs at least one slot")
        transport = Transport(sampleRate: sampleRate)
        slots = [Slot](repeating: Slot(), count: poolCapacity)
        ended.reserveCapacity(Self.eventCapacity)
    }

    /// The number of slots in the pool. Never changes.
    public var poolCapacity: Int { slots.count }

    /// The capacity of the underlying storage (for the test that it never grows).
    var storageCapacities: (slots: Int, ended: Int) { (slots.capacity, ended.capacity) }

    // MARK: time

    /// Moves the clock and settles every deck, recording the decks that ended in `ended`.
    /// Real-time: no allocation (`ended` is preallocated and cleared in place), no closures, no locks.
    public mutating func advance(frames: Int64) {
        transport.advance(frames: frames)
        ended.removeAll(keepingCapacity: true)
        droppedEnds = 0
        let now = transport.playFrame
        for i in slots.indices {
            guard var d = slots[i].deck else { continue }
            let wasPlaying = d.isPlaying
            d.settle(at: now)
            if wasPlaying, !d.isPlaying, let f = d.endedAtFrame {
                if ended.count < Self.eventCapacity {
                    ended.append(DeckEnded(deck: d.id, frame: f, lastGain: d.lastGain))
                } else {
                    droppedEnds += 1
                    counters.droppedEnds += 1
                }
            }
            slots[i].deck = d
        }
    }

    public mutating func pause() { transport.pause() }
    public mutating func resume() { transport.resume() }

    // MARK: finding decks

    /// The slot a handle points at, or nil for a handle that is `none`, out of range, or of a generation the slot has left.
    private func index(of id: Deck.ID) -> Int? {
        guard id.isValid, id.slot >= 0, Int(id.slot) < slots.count, slots[Int(id.slot)].generation == id.generation, slots[Int(id.slot)].deck != nil else { return nil }
        return Int(id.slot)
    }

    /// The deck a handle points at (a copy); nil for a stale handle. A deck that has ended can be read until its slot is reused.
    public func deck(_ id: Deck.ID) -> Deck? { index(of: id).flatMap { slots[$0].deck } }

    /// The gain of a deck now (nil: no such deck).
    public func gain(of id: Deck.ID) -> Double? { deck(id)?.gain(at: transport.playFrame) }

    /// The deck that is audible as "the" track: the newest one still playing. During a fade-out it is still live; once the fade has finished nothing is.
    /// No allocation.
    public var live: Deck? {
        var best: Int?
        for i in slots.indices where slots[i].deck?.isPlaying == true {
            if best == nil || slots[i].serial > slots[best!].serial { best = i }
        }
        return best.flatMap { slots[$0].deck }
    }

    /// The number of decks that play. No allocation.
    public var playingCount: Int {
        var n = 0
        for s in slots where s.deck?.isPlaying == true { n += 1 }
        return n
    }

    /// Every deck the pool holds (playing, and ended ones that have not been recycled yet), in start order. Allocates: for tests and UI, never the audio thread.
    public var decks: [Deck] {
        slots.filter { $0.deck != nil }.sorted { $0.serial < $1.serial }.compactMap(\.deck)
    }

    // MARK: starting decks

    /// A slot for a new deck: one that was never used, else the one whose deck ended longest ago. nil when every slot holds a deck that is still playing.
    /// No allocation.
    private func freeSlot() -> Int? {
        var oldest: Int?
        for i in slots.indices {
            guard let d = slots[i].deck else { return i }
            guard !d.isPlaying else { continue }
            if oldest == nil || (d.endedAtFrame ?? 0, slots[i].serial) < (slots[oldest!].deck?.endedAtFrame ?? 0, slots[oldest!].serial) { oldest = i }
        }
        return oldest
    }

    /// Puts a new deck in slot `i` under a new generation and returns its handle.
    private mutating func place(_ deck: (Deck.ID) -> Deck, in i: Int) -> Deck.ID {
        slots[i].generation &+= 1
        if slots[i].generation == 0 { slots[i].generation = 1 }       // 0 is the handle of no deck
        let id = Deck.ID(slot: Int32(i), generation: slots[i].generation)
        slots[i].deck = deck(id)
        slots[i].serial = nextSerial
        nextSerial += 1
        return id
    }

    /// Starts a new deck. With `crossfadeMs` of 0 the decks that are playing are removed at once (a cut) and the new one starts at full level.
    /// Otherwise the new deck fades up from 0 and the playing ones fade down to 0 over the same time, then they are removed.
    /// A `plan` makes the deck play a window with passes and fades at its edges; without one the deck plays without end. A fade-in at A is dropped
    /// under a crossfade and while the transport is paused.
    /// Real-time: it does not allocate. A cut always finds a slot (the decks it removes free theirs). A crossfade needs a slot besides the decks that keep
    /// playing: if the pool is full of decks that play, nothing is started or changed, `DeckID.none` is returned and `counters.poolExhausted` goes up.
    @discardableResult
    public mutating func start(_ plan: TrackPlan? = nil, crossfadeMs: Int = 0) -> Deck.ID {
        let now = transport.playFrame
        let length = transport.frames(milliseconds: crossfadeMs)
        let paused = transport.isPaused
        var found = freeSlot()
        if found == nil, length <= 0 {
            for i in slots.indices where slots[i].deck?.isPlaying == true { slots[i].deck?.stop(at: now) }
            found = freeSlot()
        }
        guard let slot = found else {
            counters.poolExhausted += 1
            return .none
        }
        // The others are handled first: the slot holds no playing deck, so it is not among them.
        if length > 0 {
            for i in slots.indices where slots[i].deck?.isPlaying == true {
                slots[i].deck?.fade(.down, to: 0, at: now, lengthFrames: length, endsDeck: true)
            }
        } else {
            for i in slots.indices where slots[i].deck?.isPlaying == true { slots[i].deck?.stop(at: now) }
        }
        return place({ id in
            var new = Deck(id: id, level: length > 0 ? 0 : 1, playback: plan.map { Playback(plan: $0, startFrame: now) })
            if length > 0 || paused { new.dropFadeIn() }
            if length > 0 { new.fade(.up, to: 1, at: now, lengthFrames: length, endsDeck: false) }
            return new
        }, in: slot)
    }

    /// Starts a deck on top of the ones that play (a trigger voice): nothing is stopped or faded. It starts at full level.
    /// Real-time: it does not allocate. `DeckID.none` (and `counters.poolExhausted`) when the pool is full of decks that play.
    @discardableResult
    public mutating func startOnTop(_ plan: TrackPlan) -> Deck.ID {
        guard let slot = freeSlot() else {
            counters.poolExhausted += 1
            return .none
        }
        let now = transport.playFrame
        return place({ Deck(id: $0, level: 1, playback: Playback(plan: plan, startFrame: now), isTop: true) }, in: slot)
    }

    // MARK: changing decks

    /// Moves a playing deck to `seconds` of its file. Does nothing for a deck that is not playing or a stale handle.
    public mutating func seek(_ id: Deck.ID, toSeconds seconds: Double) {
        guard let i = index(of: id) else { return }
        slots[i].deck?.seek(toSeconds: seconds, at: transport.playFrame)
    }

    /// Stops every deck that plays, voices on top included (a cut).
    public mutating func stopAll() {
        let now = transport.playFrame
        for i in slots.indices where slots[i].deck?.isPlaying == true { slots[i].deck?.stop(at: now) }
    }

    /// Fades the live deck down to 0 over `milliseconds` and removes it. 0 is a cut. Does nothing when nothing is live.
    public mutating func fadeOutLive(milliseconds: Int) {
        guard let id = live?.id, let i = index(of: id) else { return }
        let length = transport.frames(milliseconds: milliseconds)
        if length > 0 {
            slots[i].deck?.fade(.down, to: 0, at: transport.playFrame, lengthFrames: length, endsDeck: true)
        } else {
            slots[i].deck?.stop(at: transport.playFrame)
        }
    }

    /// The running pass of a deck becomes its last: it ends at the end of that pass (a looping or twice-played track whose end action was switched off).
    public mutating func finishCurrentPass(of id: Deck.ID) {
        guard let i = index(of: id) else { return }
        slots[i].deck?.finishCurrentPass(at: transport.playFrame)
    }
}
