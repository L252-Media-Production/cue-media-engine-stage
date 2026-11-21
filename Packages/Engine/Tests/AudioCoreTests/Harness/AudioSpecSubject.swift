import XCTest

// What the golden fixtures need from an audio engine, and nothing else. Every method is one thing the fixtures
// ask a question about. The tests never reach past this protocol, so the real engine (the Swift transport) plugs in
// by conforming to it. A method that is not implemented yet throws `XCTSkip("pending: ...")`: the test is
// reported as skipped, so the skip count is the list of work that is left.
//
// Gains are the IDEAL float values (the spec's `Deck.vol`), never a quantised mixer volume.
// Times are seconds from the start of the scenario, exact (no 50 ms tick).

// MARK: value types

enum FadeDirection { case up, down }

/// Both decks of a crossfade at one moment. `oldStillPlaying` false means the old deck has been removed.
struct CrossfadeState: Equatable {
    var newGain: Double
    var oldGain: Double
    var oldStillPlaying: Bool
}

struct FadeOutState: Equatable {
    var vol: Double
    var playing: Bool
}

/// The out-fade ahead of B: `fading` is whether a fade is running at that moment.
struct FadeSample: Equatable {
    var vol: Double
    var fading: Bool
}

/// Settings around a trim that the fixtures take from the player's config and the file.
struct TrimConfig: Equatable {
    var fileDurationS: Double
    /// `trim_fade_ms`: the out-fade when the track has no `fade_ms` of its own.
    var defaultFadeOutMs: Int
    /// `trim_fadein_ms`: the fade-in when the track has no `fade_in_ms` of its own.
    var defaultFadeInMs: Int
}

struct TrimRange: Equatable {
    var a: Double
    var b: Double
}

struct TrimOutcome {
    var accepted: Bool
    var stored: TrimFields
    var range: TrimRange
    var durEffS: Double
    var fadeOutMs: Int
    var fadeInMsEff: Int
    var fadeInAppliedMs: Int
}

/// What starting a track sets on its deck.
struct DeckStart {
    var baseS: Double
    var loS: Double
    var hiS: Double
    var durationS: Double
    var endFadeMs: Int
    var fadeInMs: Int
    var startVol: Double
    var fresh: Bool
}

enum EndAction: String, CaseIterable {
    case `default`, once, loop, stop
}

enum PlayMode: String {
    case stop
    case loopPlaylist = "loop_playlist"
    case nextPlaylist = "next_playlist"
    case shuffle
}

/// One track playing alone on a playlist whose play mode is `stop`.
struct EndActionScenario: Equatable {
    var trackLengthS: Double
    var endAction: EndAction
    /// The end action is set back to `default` at this time (nil: never).
    var switchedToDefaultAtS: Double?
}

struct EndActionState: Equatable {
    var live: Bool
    var passNo: Int?
    var remainingS: Double?
}

struct EndActionDeckStart: Equatable {
    var passes: Int
    var loop: Bool
}

/// What plays after a track ends. For shuffle the subject names the track it drew.
enum Successor: Equatable {
    case stopped
    case same
    case track(playlist: Int, track: Int)
}

struct TriggerScenario {
    var triggers: [TriggerCase.Point]
    var trim: TrimFields
    var fileDurationS: Double
    /// Length of each voice-over file by name.
    var voiceOverLengthsS: [String: Double]
    /// The track's end action is `loop`.
    var loop: Bool
    /// Seek the live track to `toS` (a position in the file) at `atS` seconds of play.
    var seek: (atS: Double, toS: Double)?
    /// Run the scenario this long.
    var runForS: Double
}

struct TriggerFire: Equatable {
    var tS: Double
    var file: String
}

struct DuckLoopRequest {
    var settings: DuckSettings
    var voiceOver: VoiceOver
    var stepS: Double
    var lookAheadS: Double
    /// How many rows to return (the fixture's length): the start of the series is the background deck at t = 0.
    var sampleCount: Int
}

/// Columns of equal length, row i = loop step i. Row `voiceOver.startsAtS / step - 1` is the last background-only
/// sample and the next row is the voice-over starting at the same time.
struct DuckLoopSeries {
    var tS: [Double]
    var topPosS: [Double?]
    var targetDb: [Double?]
    var grDb: [Double]
    var bgMultiplier: [Double]
}

enum LevelMatchMode: String {
    case off, track, lufs
}

struct LevelMatchResult: Equatable {
    /// nil: not applicable (mode off, or the track has no measurement).
    var gainDb: Double?
    /// 10^(dB/20); 1.0 when there is no gain.
    var linear: Double
}

/// The situations in which the fixtures read `resume.json`.
enum ResumeRecordScenario {
    case playing(trackPT: [Int], id: String, atS: Double)
    case paused(trackPT: [Int], id: String, atS: Double, waitedS: Double)
    case afterDeliberateStop
    case whileFadingOut
}

struct ResumeEnvironment {
    /// Playlists as lists of library file ids.
    var playlists: [[String]]
    var fileDurationS: Double
    var maxAgeS: Double
    /// Trims by file id.
    var trims: [String: TrimFields]
}

struct ResumeOutcome {
    struct Pending: Equatable {
        var pt: [Int]
        var offsetS: Double
        var paused: Bool
        var xfadeMs: Int
    }

    struct Started: Equatable {
        var pt: [Int]
        var baseS: Double
        var loS: Double
        var hiS: Double
        var paused: Bool
        var startVol: Double
        var fadeInMs: Int
        var fresh: Bool
    }

    var pending: Pending?
    var started: Started?
    var recordKept: Bool
}

// MARK: the protocol

protocol AudioSpecSubject {
    // fades.json
    /// Gain `x` (0...1) of the way through an equal-power fade: up goes 0 -> 1, down goes 1 -> 0.
    func fadeGain(_ direction: FadeDirection, x: Double) throws -> Double
    /// Both decks `elapsedS` into a crossfade of `fadeMs` (0 is a cut: the old deck is gone at once).
    func crossfadeState(fadeMs: Int, elapsedS: Double) throws -> CrossfadeState
    /// The same, read at wall-clock `atWallS` when the transport was paused from `pausedAtS` for `pausedForS` (the pause is not counted).
    func crossfadeState(fadeMs: Int, pausedAtS: Double, pausedForS: Double, atWallS: Double) throws -> CrossfadeState
    /// The live deck `elapsedS` into a fade-out of `fadeMs`.
    func fadeOutState(fadeMs: Int, elapsedS: Double) throws -> FadeOutState
    /// After a fade-out has finished: is NOTHING live any more?
    func nothingLiveAfterFadeOut(fadeMs: Int) throws -> Bool

    // xfade.json
    /// Crossfade time into a track: explicit `?ms=` > the track's own time (0 allowed) > the master time.
    func crossfadeMs(explicitMs: Int?, ownMs: Int?, masterMs: Int) throws -> Int
    /// Store a track's own crossfade time, given in seconds as typed (0...30, stored in whole ms; anything else is refused).
    func storeOwnCrossfade(seconds: FixtureScalar) throws -> (accepted: Bool, storedMs: Int?)
    /// The fade length `play_default` starts when `default_transition` is crossfade.
    func playDefaultFadeLengthS(ownMs: Int?, masterMs: Int) throws -> Double

    // trim.json
    /// The (A, B) window of the file for data that is already stored (A held 0.5 s before the end; a window under 0.5 s falls back).
    func trimRange(stored: TrimFields, fileDurationS: Double) throws -> TrimRange
    /// `set_trim` on a track with no trim: refuses a window under 0.5 s or a bad fade; what is stored; the derived window and fade lengths.
    func setTrim(_ fields: TrimFields, config: TrimConfig) throws -> TrimOutcome
    /// What starting a track (at file position `offsetS`; 0 = at the start) sets on its deck.
    func startDeck(trim: TrimFields, offsetS: Double, config: TrimConfig) throws -> DeckStart
    /// The out-fade of a track with an Out point, `atS` seconds after it started at A.
    func trimEndFade(trim: TrimFields, config: TrimConfig, atS: Double) throws -> FadeSample
    /// After playing past B: did the track end by itself, and is nothing live any more?
    func trimEndOutcome(trim: TrimFields, config: TrimConfig, afterS: Double) throws -> (ended: Bool, nothingLive: Bool)

    // end_actions.json
    func endActionDeckStart(_ action: EndAction) throws -> EndActionDeckStart
    /// Deck state `atS` seconds after the track started (a time at which a pass ends belongs to the next pass).
    func endActionState(_ scenario: EndActionScenario, atS: Double) throws -> EndActionState
    /// When the track ends for good; nil = never.
    func endActionEndTimeS(_ scenario: EndActionScenario) throws -> Double?
    /// What setting the end action without a value gives: default > once > loop > stop > default.
    func nextEndAction(after action: EndAction) throws -> EndAction

    // play_modes.json
    /// What follows a track that ends. Shuffle names the track it drew.
    func successor(mode: PlayMode, endAction: EndAction, playlistTrackCounts: [Int], from: (playlist: Int, track: Int)) throws -> Successor
    /// Track indices to try, best first, after track `fromTrack` (stop: none; loop_playlist: next then the rest in a ring; a looping track repeats itself).
    func nextInOrder(mode: PlayMode, fromTrack: Int, trackCount: Int, loopingTracks: Set<Int>) throws -> [Int]
    /// `count` successive shuffle draws on one playlist, the first one after `startTrack` was playing.
    func shuffleDraws(trackCount: Int, startTrack: Int, count: Int) throws -> [Int]
    /// Tracks left in the round after one draw from `startTrack`.
    func shuffleTracksLeftAfterOneDraw(trackCount: Int, startTrack: Int) throws -> Int
    /// Does changing the play mode forget the shuffle round?
    func shuffleForgetsRoundOnModeChange() throws -> Bool

    // triggers.json
    /// When trigger points fire (seconds after the start), each fire being a Play on Top.
    func triggerFireTimes(_ scenario: TriggerScenario) throws -> [TriggerFire]

    // ducking.json
    /// RMS (0...1, louder channel) of each whole 10 ms of interleaved 48 kHz 16-bit stereo.
    func duckKey(pcm: [Int16]) throws -> [Double]
    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double]
    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double
    /// `10^(-gr/20)`.
    func backgroundMultiplier(reductionDb: Double) throws -> Double
    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double
    /// The real ducking loop: a background deck from t = 0 and a voice-over played on top, one row per 10 ms.
    func duckLoop(_ request: DuckLoopRequest) throws -> DuckLoopSeries

    // levelmatch.json
    /// Integrated loudness (BS.1770) of interleaved 48 kHz 16-bit stereo; nil = silent or shorter than 0.4 s.
    func measureLufs(pcm: [Int16]) throws -> Double?
    /// `min(0, target - measured)` dB for one track. `targetLufs` is the fixed target (lufs mode) or the reference track's loudness (track mode).
    func levelMatchGain(mode: LevelMatchMode, targetLufs: Double?, measuredLufs: Double?) throws -> LevelMatchResult
    /// The gain of a deck that is already playing, right after the setting changed.
    func liveDeckGain(mode: LevelMatchMode, targetLufs: Double?, trackLufs: Double?) throws -> Double

    // resume_flow.json
    /// What `resume.json` holds in a situation; nil = no file.
    func resumeRecord(_ scenario: ResumeRecordScenario) throws -> ResumeRecord?
    /// Start-up with a saved record that is `ageS` old.
    func tryResume(record: ResumeRecord, ageS: Double, environment: ResumeEnvironment) throws -> ResumeOutcome
}

// MARK: pending by default

/// Skips the running test with the name of what is missing.
func pending(_ what: String) -> XCTSkip {
    XCTSkip("pending: \(what)")
}

/// Every method of the protocol is "not implemented yet". A conforming engine overrides what it can do.
extension AudioSpecSubject {
    func fadeGain(_ direction: FadeDirection, x: Double) throws -> Double { throw pending("equal-power fade gain at x") }
    func crossfadeState(fadeMs: Int, elapsedS: Double) throws -> CrossfadeState { throw pending("crossfade gains") }
    func crossfadeState(fadeMs: Int, pausedAtS: Double, pausedForS: Double, atWallS: Double) throws -> CrossfadeState {
        throw pending("crossfade frozen by pause")
    }
    func fadeOutState(fadeMs: Int, elapsedS: Double) throws -> FadeOutState { throw pending("fade-out of the live deck") }
    func nothingLiveAfterFadeOut(fadeMs: Int) throws -> Bool { throw pending("live role after a fade-out") }

    func crossfadeMs(explicitMs: Int?, ownMs: Int?, masterMs: Int) throws -> Int { throw pending("crossfade time precedence") }
    func storeOwnCrossfade(seconds: FixtureScalar) throws -> (accepted: Bool, storedMs: Int?) { throw pending("per-track crossfade time limits") }
    func playDefaultFadeLengthS(ownMs: Int?, masterMs: Int) throws -> Double { throw pending("play_default fade length") }

    func trimRange(stored: TrimFields, fileDurationS: Double) throws -> TrimRange { throw pending("trim window of stored data") }
    func setTrim(_ fields: TrimFields, config: TrimConfig) throws -> TrimOutcome { throw pending("set_trim rules and fade lengths") }
    func startDeck(trim: TrimFields, offsetS: Double, config: TrimConfig) throws -> DeckStart { throw pending("deck start (window, fades)") }
    func trimEndFade(trim: TrimFields, config: TrimConfig, atS: Double) throws -> FadeSample { throw pending("out-fade ahead of B") }
    func trimEndOutcome(trim: TrimFields, config: TrimConfig, afterS: Double) throws -> (ended: Bool, nothingLive: Bool) {
        throw pending("track end at B")
    }

    func endActionDeckStart(_ action: EndAction) throws -> EndActionDeckStart { throw pending("end action: passes and loop at start") }
    func endActionState(_ scenario: EndActionScenario, atS: Double) throws -> EndActionState { throw pending("end action: pass number and remaining time") }
    func endActionEndTimeS(_ scenario: EndActionScenario) throws -> Double? { throw pending("end action: end time") }
    func nextEndAction(after action: EndAction) throws -> EndAction { throw pending("end action cycle") }

    func successor(mode: PlayMode, endAction: EndAction, playlistTrackCounts: [Int], from: (playlist: Int, track: Int)) throws -> Successor {
        throw pending("play mode successor")
    }
    func nextInOrder(mode: PlayMode, fromTrack: Int, trackCount: Int, loopingTracks: Set<Int>) throws -> [Int] { throw pending("next_in_order") }
    func shuffleDraws(trackCount: Int, startTrack: Int, count: Int) throws -> [Int] { throw pending("shuffle bag draws") }
    func shuffleTracksLeftAfterOneDraw(trackCount: Int, startTrack: Int) throws -> Int { throw pending("shuffle bag round size") }
    func shuffleForgetsRoundOnModeChange() throws -> Bool { throw pending("shuffle bag reset on mode change") }

    func triggerFireTimes(_ scenario: TriggerScenario) throws -> [TriggerFire] { throw pending("trigger point fire times") }

    func duckKey(pcm: [Int16]) throws -> [Double] { throw pending("duck_key") }
    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double] { throw pending("duck_curve") }
    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double { throw pending("duck_smooth") }
    func backgroundMultiplier(reductionDb: Double) throws -> Double { throw pending("background gain multiplier") }
    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double { throw pending("input_target_db") }
    func duckLoop(_ request: DuckLoopRequest) throws -> DuckLoopSeries { throw pending("duck_loop series") }

    func measureLufs(pcm: [Int16]) throws -> Double? { throw pending("LUFS measurement (BS.1770)") }
    func levelMatchGain(mode: LevelMatchMode, targetLufs: Double?, measuredLufs: Double?) throws -> LevelMatchResult { throw pending("level-match gain") }
    func liveDeckGain(mode: LevelMatchMode, targetLufs: Double?, trackLufs: Double?) throws -> Double { throw pending("level match applied to a live deck") }

    func resumeRecord(_ scenario: ResumeRecordScenario) throws -> ResumeRecord? { throw pending("resume record") }
    func tryResume(record: ResumeRecord, ageS: Double, environment: ResumeEnvironment) throws -> ResumeOutcome { throw pending("try_resume") }
}

/// Nothing is implemented: every test that asks it something is skipped.
struct PendingSubject: AudioSpecSubject {}

/// The subject the conformance tests run against. Change this one line when the real engine is ready.
enum AudioSpecSubjects {
    static let current: AudioSpecSubject = PendingSubject()
}
