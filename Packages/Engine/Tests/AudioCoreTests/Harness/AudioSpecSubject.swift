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

/// One field of a `set_trim` call: not in the call (keep what is stored), null (clear it), or a value.
enum SetField<Value: Equatable>: Equatable {
    case absent
    case clear
    case value(Value)

    static func read<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, as type: Value.Type = Value.self) throws -> SetField<Value> where Value: Decodable {
        guard c.contains(key) else { return .absent }
        return try c.decodeNil(forKey: key) ? .clear : .value(try c.decode(Value.self, forKey: key))
    }
}

/// What a `set_trim` call carries, as the fixtures write it (`set`). Lengths are as typed (99.4 ms is a valid thing to type).
struct TrimSet: Decodable, Equatable {
    var inPoint: SetField<Double> = .absent
    var outPoint: SetField<Double> = .absent
    var end: SetField<String> = .absent
    var fadeMs: SetField<Double> = .absent
    var fadeInMs: SetField<Double> = .absent
    var start: SetField<String> = .absent

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TrimFields.CodingKeys.self)
        inPoint = try .read(c, .inPoint)
        outPoint = try .read(c, .outPoint)
        end = try .read(c, .end)
        fadeMs = try .read(c, .fadeMs)
        fadeInMs = try .read(c, .fadeInMs)
        start = try .read(c, .start)
    }
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
    /// Length of the fade-in ramp in seconds (`fade_in_ramp_s`).
    var fadeInRampS: Double
    var startVol: Double
    var fresh: Bool
    /// The deck plays without end (`Deck.loop`).
    var loop: Bool
}

/// How a track is started besides its trim and the offset.
struct DeckStartContext: Equatable {
    var endAction: EndAction = .default
    var paused = false
    /// A crossfade into the track of this length (0: none).
    var crossfadeMs = 0
}

enum EndAction: String, CaseIterable {
    case `default`, once, loop, stop
}

enum PlayMode: String, CaseIterable {
    case stop
    case loopPlaylist = "loop_playlist"
    case nextPlaylist = "next_playlist"
    case shuffle
}

/// One track playing alone on a playlist, started with `endAction`.
struct EndActionScenario: Equatable {
    var trackLengthS: Double
    var playMode: PlayMode
    var endAction: EndAction
    /// The end action is changed at `atS` seconds after the start (nil: never).
    var switchOff: Switch?
    /// The trim of the track (none: it plays the whole file) and the player's fade defaults.
    var trim = TrimFields()
    var defaultFadeOutMs = 0
    var defaultFadeInMs = 0

    struct Switch: Equatable {
        var to: EndAction
        var atS: Double
    }
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
/// What is live right after a track ended: which track of the playlist and which pass of it.
struct LiveTrack: Equatable {
    var track: Int
    var passNo: Int
}

enum Successor: Equatable {
    case stopped
    case same
    case track(playlist: Int, track: Int)
}

/// When the voice-over targets are decoded, in seconds of play: from the start, at a time, or never.
enum TargetReadyAt: Equatable {
    case always
    case atS(Double)
    case never
}

struct TriggerScenario {
    var triggers: [TriggerCase.Point]
    var trim: TrimFields
    var fileDurationS: Double
    /// Length of each voice-over file by name.
    var voiceOverLengthsS: [String: Double]
    var endAction: EndAction
    /// Seek the live track to `toS` (a position in the file) at `atS` seconds of play, in order.
    var seeks: [(atS: Double, toS: Double)]
    /// Run the scenario this long.
    var runForS: Double
    /// The name of the track the points belong to (the other tracks are named in `otherTrack`).
    var mainName = "main"
    /// The track starts at this position of the file (an offset in file seconds; 0 = from the top).
    var offsetS = 0.0
    var targetReady = TargetReadyAt.always
    /// `top_track_pct`: the level of a trigger voice in percent.
    var topTrackPct = 100.0
    var armed = true
    /// A second track of the playlist and the moment it is started (a cut when `crossfadeMs` is 0), while whatever plays goes on.
    var otherTrack: (name: String, lengthS: Double)?
    var newTrack: (atS: Double, crossfadeMs: Int)?
}

/// A deck as it is listed at a moment: a track by name, or a voice-over by its file name.
struct DeckView: Equatable {
    var name: String
    var top: Bool
    /// The gain of the deck now (the spec's `Deck.vol`).
    var vol: Double
    /// A fade-out is running that removes the deck when it is done.
    var ending: Bool
    /// Any fade is running.
    var fading: Bool
    /// The level-match gain of the deck (`Deck.gain` of the spec), a factor besides `vol`.
    var levelGain: Double
}

/// What is playing at a moment of a trigger scenario.
struct TriggerSnapshot: Equatable {
    var atS: Double
    /// The deck that is "the" live one.
    var liveName: String?
    /// The decks that play, in the order they started.
    var decks: [DeckView]
    /// How many trigger fires there were up to now.
    var firesSoFar: Int
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
    /// The background deck plays from t = 0 and is this long.
    var backgroundLengthS: Double
    /// The voice-over starts on top this long after the background (`voiceOver.startsAtS`).
    var backgroundAloneS: Double
    /// The loop ticks once every this many steps.
    var tickEverySteps: Int
    /// The loop runs at most this many steps.
    var maxSteps: Int
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

enum LevelMatchMode: String, Decodable, CaseIterable {
    case off, track, lufs
}

struct LevelMatchResult: Equatable {
    /// nil: not applicable (mode off, or the track has no measurement).
    var gainDb: Double?
    /// 10^(dB/20); 1.0 when there is no gain.
    var linear: Double
}

/// What the level-match setting of a playlist is as TYPED: `track` names the reference by track index, `lufs` is the target as typed.
struct LevelMatchTyped: Decodable, Equatable {
    var mode: LevelMatchMode
    var ref: Int?
    var lufs: Double?
}

/// What is kept of it. `ref` is the reference track's file. `lufs` is the kept target; it only means something in `lufs` mode.
struct LevelMatchStored: Equatable {
    var mode: LevelMatchMode
    var ref: String?
    var lufs: Double
}

/// The range a fixed LUFS target is held to (`lufs_clamp_db` of the scenario).
struct LufsClamp: Equatable {
    var min: Double
    var max: Double
    var step: Double
}

/// The player settings the resume scenarios run with.
struct ResumeConfig: Equatable {
    var onStart: Bool
    var maxAgeS: Double
    var saveIntervalS: Double
}

/// The library and the settings a resume scenario runs in.
struct ResumeEnvironment {
    /// The playlist as library file ids (there is one).
    var playlist: [String]
    /// Length of each library file in seconds.
    var fileLengthsS: [String: Double]
    var config: ResumeConfig
    /// Trims by file id.
    var trims: [String: TrimFields]
}

/// How the fixtures bring the player into the state `resume.json` is written from.
struct ResumeSituation: Equatable {
    var playTrack: Int
    /// Position in the file when the record is written.
    var atS: Double
    var paused: Bool
    /// The clock when the record is written (a paused track keeps its position while the clock runs on). nil: right at `atS`.
    var clockAtSaveS: Double?
    var then: Then?

    enum Then: Equatable {
        case stopAll
        case fadeOut(ms: Int)
    }
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
    /// `set_trim` on a track that holds `previous` (empty: no trim): what is stored (or kept, when the call is refused), the derived window and fade lengths.
    func setTrim(_ set: TrimSet, previous: TrimFields, config: TrimConfig) throws -> TrimOutcome
    /// What starting a track (at file position `offsetS`; 0 = from the top) sets on its deck.
    func startDeck(trim: TrimFields, offsetS: Double, config: TrimConfig, context: DeckStartContext) throws -> DeckStart
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
    /// The level of the deck (`Deck.vol`) and whether it still plays, `atS` seconds after the track started (the scenario's trim and end action apply).
    func deckLevel(_ scenario: EndActionScenario, atS: Double) throws -> (vol: Double, live: Bool)
    /// A 2 s track, number 0 of a two-track playlist in `playMode`, started with end action `from` and switched to `to` at `atS`: what is live
    /// right after the deck of the running pass ended (nil: nothing).
    func liveAfterEndActionSwitch(playMode: PlayMode, from: EndAction, to: EndAction, atS: Double) throws -> LiveTrack?
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
    /// The same run, read at the given times (seconds of play). A start or a seek that falls on the same time happens before the reading.
    func triggerSnapshots(_ scenario: TriggerScenario, at times: [Double]) throws -> [TriggerSnapshot]

    // ducking.json
    /// RMS (0...1, louder channel) of each whole 10 ms of interleaved 48 kHz 16-bit stereo.
    func duckKey(pcm: [Int16]) throws -> [Double]
    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double]
    /// The depth (dB) the hold keeps from the first to the last active window: a PERCENTILE of the active reductions. The real engine must use
    /// one function for this in `duckCurve` and in `duckLoop`; only the fixture of this method can tell the 60th, 75th and 90th percentile apart.
    func duckHoldDepthDb(key: [Double], level: Double, ratio: Double, thresholdDb: Double) throws -> Double
    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double
    /// `10^(-gr/20)`.
    func backgroundMultiplier(reductionDb: Double) throws -> Double
    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double
    /// The real ducking loop: a background deck from t = 0 and a voice-over played on top, one row per 10 ms.
    func duckLoop(_ request: DuckLoopRequest) throws -> DuckLoopSeries

    // levelmatch.json
    /// Integrated loudness (BS.1770) of interleaved 48 kHz 16-bit stereo; nil = silent or shorter than 0.4 s.
    func measureLufs(pcm: [Int16]) throws -> Double?
    /// `set_norm`: what is kept of what was typed (a LUFS target is clamped to the range and rounded to the step; a reference is kept by file name).
    func storeLevelMatch(typed: LevelMatchTyped, playlist: [String], clamp: LufsClamp) throws -> LevelMatchStored
    /// `min(0, target - measured)` dB for one track. `targetLufs` is the fixed target (lufs mode) or the reference track's loudness (track mode).
    func levelMatchGain(mode: LevelMatchMode, targetLufs: Double?, measuredLufs: Double?) throws -> LevelMatchResult
    /// The gain of a deck that is already playing, right after the setting changed.
    func liveDeckGain(mode: LevelMatchMode, targetLufs: Double?, trackLufs: Double?) throws -> Double

    // resume_flow.json
    /// What `resume.json` holds in a situation; nil = no file.
    func resumeRecord(_ situation: ResumeSituation, environment: ResumeEnvironment) throws -> ResumeRecord?
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
    func setTrim(_ set: TrimSet, previous: TrimFields, config: TrimConfig) throws -> TrimOutcome { throw pending("set_trim rules and fade lengths") }
    func startDeck(trim: TrimFields, offsetS: Double, config: TrimConfig, context: DeckStartContext) throws -> DeckStart { throw pending("deck start (window, fades)") }
    func trimEndFade(trim: TrimFields, config: TrimConfig, atS: Double) throws -> FadeSample { throw pending("out-fade ahead of B") }
    func trimEndOutcome(trim: TrimFields, config: TrimConfig, afterS: Double) throws -> (ended: Bool, nothingLive: Bool) {
        throw pending("track end at B")
    }

    func endActionDeckStart(_ action: EndAction) throws -> EndActionDeckStart { throw pending("end action: passes and loop at start") }
    func endActionState(_ scenario: EndActionScenario, atS: Double) throws -> EndActionState { throw pending("end action: pass number and remaining time") }
    func endActionEndTimeS(_ scenario: EndActionScenario) throws -> Double? { throw pending("end action: end time") }
    func deckLevel(_ scenario: EndActionScenario, atS: Double) throws -> (vol: Double, live: Bool) { throw pending("deck level and liveness over time") }
    func liveAfterEndActionSwitch(playMode: PlayMode, from: EndAction, to: EndAction, atS: Double) throws -> LiveTrack? {
        throw pending("what plays after an end action was switched mid-play")
    }
    func nextEndAction(after action: EndAction) throws -> EndAction { throw pending("end action cycle") }

    func successor(mode: PlayMode, endAction: EndAction, playlistTrackCounts: [Int], from: (playlist: Int, track: Int)) throws -> Successor {
        throw pending("play mode successor")
    }
    func nextInOrder(mode: PlayMode, fromTrack: Int, trackCount: Int, loopingTracks: Set<Int>) throws -> [Int] { throw pending("next_in_order") }
    func shuffleDraws(trackCount: Int, startTrack: Int, count: Int) throws -> [Int] { throw pending("shuffle bag draws") }
    func shuffleTracksLeftAfterOneDraw(trackCount: Int, startTrack: Int) throws -> Int { throw pending("shuffle bag round size") }
    func shuffleForgetsRoundOnModeChange() throws -> Bool { throw pending("shuffle bag reset on mode change") }

    func triggerFireTimes(_ scenario: TriggerScenario) throws -> [TriggerFire] { throw pending("trigger point fire times") }
    func triggerSnapshots(_ scenario: TriggerScenario, at times: [Double]) throws -> [TriggerSnapshot] { throw pending("the decks of a trigger scenario over time") }

    func duckKey(pcm: [Int16]) throws -> [Double] { throw pending("duck_key") }
    func duckCurve(key: [Double], level: Double, ratio: Double, thresholdDb: Double, hold: Bool) throws -> [Double] { throw pending("duck_curve") }
    func duckHoldDepthDb(key: [Double], level: Double, ratio: Double, thresholdDb: Double) throws -> Double { throw pending("duck_curve hold percentile") }
    func duckSmooth(gr: Double, target: Double, dt: Double, attackMs: Double, releaseMs: Double) throws -> Double { throw pending("duck_smooth") }
    func backgroundMultiplier(reductionDb: Double) throws -> Double { throw pending("background gain multiplier") }
    func inputTargetDb(rms: Double, gainDb: Double, ratio: Double, thresholdDb: Double) throws -> Double { throw pending("input_target_db") }
    func duckLoop(_ request: DuckLoopRequest) throws -> DuckLoopSeries { throw pending("duck_loop series") }

    func measureLufs(pcm: [Int16]) throws -> Double? { throw pending("LUFS measurement (BS.1770)") }
    func storeLevelMatch(typed: LevelMatchTyped, playlist: [String], clamp: LufsClamp) throws -> LevelMatchStored { throw pending("level-match setting limits") }
    func levelMatchGain(mode: LevelMatchMode, targetLufs: Double?, measuredLufs: Double?) throws -> LevelMatchResult { throw pending("level-match gain") }
    func liveDeckGain(mode: LevelMatchMode, targetLufs: Double?, trackLufs: Double?) throws -> Double { throw pending("level match applied to a live deck") }

    func resumeRecord(_ situation: ResumeSituation, environment: ResumeEnvironment) throws -> ResumeRecord? { throw pending("resume record") }
    func tryResume(record: ResumeRecord, ageS: Double, environment: ResumeEnvironment) throws -> ResumeOutcome { throw pending("try_resume") }
}

/// Nothing is implemented: every test that asks it something is skipped.
struct PendingSubject: AudioSpecSubject {}

/// The subject the conformance tests run against. `AudioCoreSubject` does what AudioCore implements and leaves the rest pending;
/// switch this one line to the real engine when it exists, or to `PendingSubject()` to see everything skipped.
enum AudioSpecSubjects {
    static let current: AudioSpecSubject = AudioCoreSubject()
}
