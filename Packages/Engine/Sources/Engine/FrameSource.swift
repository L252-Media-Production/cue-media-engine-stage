import CoreVideo

/// Something that supplies video frames to the compositor: a looping file, an NDI source, an SDI input.
public protocol FrameSource: AnyObject {
    /// Begin decoding or receiving.
    func start()

    /// Stop and release resources.
    func stop()

    /// The frame to show at playback time `t` seconds. Live sources ignore `t` and return their newest
    /// frame. Returns nil until the first frame has arrived.
    func frame(at t: Double) -> CVPixelBuffer?

    /// How many times the source could not keep up (for a file: the decoder fell behind).
    var underruns: Int { get }
}

extension VideoLoopSource: FrameSource {}
