/// The decks and the clock. It starts decks, crossfades and fades out, and answers the gain of each deck at the current time.
/// No hardware, no threads: time moves only when `advance(frames:)` is called.
public struct Mixer {
    public private(set) var transport: Transport
    /// Every deck ever started, in start order. Ended decks stay (with `isPlaying` false) so their last gain can still be read.
    public private(set) var decks: [Deck] = []

    public init(sampleRate: Int = AudioFormat.sampleRate) {
        transport = Transport(sampleRate: sampleRate)
    }

    // MARK: time

    public mutating func advance(frames: Int64) {
        transport.advance(frames: frames)
        for i in decks.indices { decks[i].settle(at: transport.playFrame) }
    }

    public mutating func pause() { transport.pause() }
    public mutating func resume() { transport.resume() }

    // MARK: decks

    /// The deck that is audible as "the" track: the newest one still playing. During a fade-out it is still live; once the fade has finished nothing is.
    public var live: Deck? { decks.last { $0.isPlaying } }

    public var playingCount: Int { decks.filter(\.isPlaying).count }

    public func deck(_ id: Deck.ID) -> Deck? { decks.first { $0.id == id } }

    /// The gain of a deck now (nil: no such deck).
    public func gain(of id: Deck.ID) -> Double? { deck(id)?.gain(at: transport.playFrame) }

    /// Starts a new deck. With `crossfadeMs` of 0 the decks that are playing are removed at once (a cut) and the new one starts at full level.
    /// Otherwise the new deck fades up from 0 and the playing ones fade down to 0 over the same time, then they are removed.
    @discardableResult
    public mutating func start(crossfadeMs: Int = 0) -> Deck.ID {
        let now = transport.playFrame
        let length = transport.frames(milliseconds: crossfadeMs)
        let id = (decks.last?.id ?? 0) + 1
        var new = Deck(id: id, level: length > 0 ? 0 : 1)
        if length > 0 {
            for i in decks.indices where decks[i].isPlaying {
                decks[i].fade(.down, to: 0, at: now, lengthFrames: length, endsDeck: true)
            }
            new.fade(.up, to: 1, at: now, lengthFrames: length, endsDeck: false)
        } else {
            for i in decks.indices where decks[i].isPlaying { decks[i].stop() }
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
            decks[i].stop()
        }
    }
}
