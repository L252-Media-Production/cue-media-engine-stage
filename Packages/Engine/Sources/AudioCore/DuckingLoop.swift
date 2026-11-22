/// The settings of the sidechain: how the reduction is drawn from the voice (`Ducking.curve`) and how it moves (`Ducking.smooth`).
/// The defaults are the Python player's production defaults.
public struct DuckingSettings: Equatable {
    public var thresholdDb = -30.0
    public var ratio = 6.0
    public var attackMs = 10.0
    public var releaseMs = 500.0
    /// Keep the 75th-percentile depth from the first to the last active window of the voice.
    public var hold = true
    /// The level of the voice on top in percent (`top_track_pct`): the key is scaled by it before the curve.
    public var topTrackPercent = 100.0
    /// How far ahead of the control step the key is read (spec: 20 ms).
    public var lookAheadMs = 20

    public init(
        thresholdDb: Double = -30, ratio: Double = 6, attackMs: Double = 10, releaseMs: Double = 500, hold: Bool = true,
        topTrackPercent: Double = 100, lookAheadMs: Int = 20
    ) {
        self.thresholdDb = thresholdDb
        self.ratio = ratio
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.hold = hold
        self.topTrackPercent = topTrackPercent
        self.lookAheadMs = lookAheadMs
    }

    /// The level the curve scales the key by, as a gain.
    public var voiceLevel: Double { topTrackPercent / 100 }
}

/// What the control loop knew at one moment: the reduction it asked for from the key, the smoothed reduction and the factor that follows from it.
public struct DuckReading: Equatable {
    /// The reduction (dB) the curve gives for the key window read at this step (0 when no voice plays).
    public var targetDb = 0.0
    /// The smoothed reduction (dB).
    public var reductionDb = 0.0
    /// `10^(-reductionDb/20)`, the factor the background decks carry.
    public var multiplier = 1.0
    /// The key window the step read: the voice position of the step, floored to its 10 ms window, plus the look-ahead in windows (so 2 at the voice's
    /// first step). It can lie past the end of the curve (the target is 0 there). -1 when no voice drove the step.
    public var window = -1
}

/// The state of the 10 ms control loop of a sidechain. It lives in the `Mixer`, which cuts its time at the loop's steps, so the values do not depend on how big
/// the caller's steps are. Everything here is integers and doubles in fixed fields; the curve is an array made offline and only read.
///
/// Step `j` runs at the play frame `anchor + j * stepFrames` (the steps are counted in frames, never in seconds). It reads the curve at the key window that
/// holds the voice position of that frame plus the look-ahead, smooths the reduction one step and hands the factor to the background decks, where it
/// is in force from the NEXT step on: a render block that contains that frame ramps from the old factor to the new one. This one-step delay is what the
/// fixture rows show: the row at time t holds the value the step at t - 10 ms computed.
struct DuckControl {
    /// A voice drives the loop (it may have ended: the loop then only releases).
    var voice = Deck.ID.none
    var voiceStart: Int64 = 0
    /// Reduction (dB) per key window of the voice, hold already applied. Read only.
    var curve: [Double] = []
    var attackMs = 10.0
    var releaseMs = 500.0
    var lookAheadFrames: Int64 = 0
    var stepFrames: Int64 = 1
    var stepSeconds = 0.01

    /// The loop runs: it has a next step.
    var isRunning = false
    var nextStep: Int64 = 0
    var reductionDb = 0.0

    /// What is in force now and what is made current at `pendingAt`.
    var inForce = DuckReading()
    var pending = DuckReading()
    var pendingAt = Int64.min

    func reading(at frame: Int64) -> DuckReading { frame >= pendingAt ? pending : inForce }
}
