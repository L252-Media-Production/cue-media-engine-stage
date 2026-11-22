/// Pure audio maths for CueME Stage: no CoreAudio, no I/O, no dependency on the rest of the package.
/// It is checked against the golden fixtures of the Python Cue Media Engine (docs/audio-conformance.md).
public enum AudioCore {
    /// The version of docs/AUDIO-SPEC.md of the Python engine that this code implements. The conformance tests
    /// fail when a synced fixture says anything else. Change it only together with a new fixture sync.
    public static let implementedSpecVersion = 1
}

/// Constants of the spec's mixer format (docs/AUDIO-SPEC.md, "Decoding and rendering"): 48 kHz, 16-bit, stereo.
public enum AudioFormat {
    public static let sampleRate = 48_000
    public static let channels = 2
}
