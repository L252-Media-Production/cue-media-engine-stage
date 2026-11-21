/// The clock of the audio engine, counted in frames. It is injected, never read from the wall clock: whoever drives the engine
/// (a render callback later, a test now) calls `advance(frames:)`.
///
/// There are two counts. `wallFrame` always runs. `playFrame` stops while the transport is paused, so anything measured in play
/// frames (a fade) is frozen by a pause and resumes where it was; the pause time is not counted.
public struct Transport: Equatable {
    public let sampleRate: Int
    public private(set) var wallFrame: Int64 = 0
    public private(set) var playFrame: Int64 = 0
    public private(set) var isPaused = false

    public init(sampleRate: Int = AudioFormat.sampleRate) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
    }

    public mutating func advance(frames: Int64) {
        precondition(frames >= 0, "time does not run backwards")
        wallFrame += frames
        if !isPaused { playFrame += frames }
    }

    public mutating func pause() { isPaused = true }
    public mutating func resume() { isPaused = false }

    public var playSeconds: Double { Double(playFrame) / Double(sampleRate) }

    /// Whole frames in `seconds` (rounded to the nearest frame).
    public func frames(seconds: Double) -> Int64 { Int64((seconds * Double(sampleRate)).rounded()) }

    /// Whole frames in `milliseconds` (rounded to the nearest frame).
    public func frames(milliseconds: Int) -> Int64 { frames(seconds: Double(milliseconds) / 1000) }
}
