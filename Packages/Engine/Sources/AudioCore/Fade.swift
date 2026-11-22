/// A ramp of a gain between two values, started at a play frame and `lengthFrames` long. Up and down use the two equal-power curves of the
/// spec (docs/AUDIO-SPEC.md, "Fades and equal-power curves"); a length of 0 is a cut.
public struct Fade: Equatable {
    public enum Direction: Equatable { case up, down }

    public let direction: Direction
    public let from: Double
    public let to: Double
    public let startFrame: Int64
    public let lengthFrames: Int64

    public init(direction: Direction, from: Double, to: Double, startFrame: Int64, lengthFrames: Int64) {
        self.direction = direction
        self.from = from
        self.to = to
        self.startFrame = startFrame
        self.lengthFrames = max(0, lengthFrames)
    }

    /// Fraction of the fade that has run at `frame`, 0...1. A fade of length 0 has always run completely.
    public func progress(at frame: Int64) -> Double {
        guard lengthFrames > 0 else { return 1 }
        return min(1, max(0, Double(frame - startFrame) / Double(lengthFrames)))
    }

    /// The gain `x` (0...1) of the way through the fade.
    public func gain(progress x: Double) -> Double {
        switch direction {
        case .up: return EqualPower.rampUp(x: x, from: from, to: to)
        case .down: return EqualPower.rampDown(x: x, from: from, to: to)
        }
    }

    public func gain(at frame: Int64) -> Double { gain(progress: progress(at: frame)) }

    public func isFinished(at frame: Int64) -> Bool { progress(at: frame) >= 1 }

    public func lengthSeconds(sampleRate: Int) -> Double { Double(lengthFrames) / Double(sampleRate) }
}
