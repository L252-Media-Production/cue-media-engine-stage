import Foundation

// Codable models of the fixture files, one section per file. Keys that start with `_info` are not modelled
// (a Codable struct ignores keys it does not name). Field names follow the JSON; Swift names are camel case.

// MARK: shared

/// What `set_trim` takes and stores (trim.json `set` / `stored` / `trim`, triggers.json `trim`).
struct TrimFields: Codable, Equatable {
    var inPoint: Double?
    var outPoint: Double?
    var end: String?
    var fadeMs: Int?
    var fadeInMs: Int?
    var start: String?

    init(inPoint: Double? = nil, outPoint: Double? = nil, end: String? = nil, fadeMs: Int? = nil, fadeInMs: Int? = nil, start: String? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.end = end
        self.fadeMs = fadeMs
        self.fadeInMs = fadeInMs
        self.start = start
    }

    enum CodingKeys: String, CodingKey {
        case inPoint = "in"
        case outPoint = "out"
        case end
        case fadeMs = "fade_ms"
        case fadeInMs = "fade_in_ms"
        case start
    }
}

// MARK: fades.json

struct FadesCases: Decodable {
    let equalPowerFormula: Rows<EqualPowerRow>
    let crossfade1000ms: CrossfadeCase
    let crossfade3000ms: CrossfadeCase
    let crossfade0msIsACut: CutCase
    let fadeOut2000ms: FadeOutCase
    let pauseFreezesAFade: PauseCase

    enum CodingKeys: String, CodingKey {
        case equalPowerFormula = "equal_power_formula"
        case crossfade1000ms = "crossfade_1000ms"
        case crossfade3000ms = "crossfade_3000ms"
        case crossfade0msIsACut = "crossfade_0ms_is_a_cut"
        case fadeOut2000ms = "fade_out_2000ms"
        case pauseFreezesAFade = "pause_freezes_a_fade"
    }

    struct EqualPowerRow: Decodable {
        let x: Double
        let up: Double
        let down: Double
    }

    struct NewOld: Decodable {
        let new: Double
        let old: Double
    }

    struct CrossfadeCase: Decodable {
        let fadeMs: Int
        let start: NewOld
        let rows: [Row]

        enum CodingKeys: String, CodingKey {
            case fadeMs = "fade_ms"
            case start, rows
        }

        struct Row: Decodable {
            let x: Double
            let tS: Double
            let new: Double
            let old: Double
            let oldStillPlaying: Bool

            enum CodingKeys: String, CodingKey {
                case x
                case tS = "t_s"
                case new, old
                case oldStillPlaying = "old_still_playing"
            }
        }
    }

    struct CutCase: Decodable {
        let newVol: Double
        let oldRemoved: Bool
        let decks: Int

        enum CodingKeys: String, CodingKey {
            case newVol = "new_vol"
            case oldRemoved = "old_removed"
            case decks
        }
    }

    struct FadeOutCase: Decodable {
        let rows: [Row]
        /// True means NOTHING is live after the fade (the generator writes `live() is None`).
        let liveAfter: Bool

        enum CodingKeys: String, CodingKey {
            case rows
            case liveAfter = "live_after"
        }

        struct Row: Decodable {
            let x: Double
            let vol: Double
            let playing: Bool
        }
    }

    struct PauseCase: Decodable {
        let atQuarter: NewOld
        let afterFiveSecondPause: NewOld
        let quarterAfterResume: NewOld

        enum CodingKeys: String, CodingKey {
            case atQuarter = "at_0_25"
            case afterFiveSecondPause = "after_5s_pause"
            case quarterAfterResume = "0_25s_after_resume"
        }
    }
}

// MARK: xfade.json

struct XfadeCases: Decodable {
    let precedence: Rows<PrecedenceRow>
    let ownTimeLimits: Rows<LimitRow>
    let playDefaultUsesIt: Rows<PlayDefaultRow>

    enum CodingKeys: String, CodingKey {
        case precedence
        case ownTimeLimits = "own_time_limits"
        case playDefaultUsesIt = "play_default_uses_it"
    }

    struct PrecedenceRow: Decodable {
        let label: String
        let explicitMs: Int?
        let ownMs: Int?
        let masterMs: Int
        let resultMs: Int

        enum CodingKeys: String, CodingKey {
            case label = "case"
            case explicitMs = "explicit_ms"
            case ownMs = "own_ms"
            case masterMs = "master_ms"
            case resultMs = "result_ms"
        }
    }

    struct LimitRow: Decodable {
        let seconds: FixtureScalar
        let accepted: Bool
        let storedMs: Int?

        enum CodingKeys: String, CodingKey {
            case seconds, accepted
            case storedMs = "stored_ms"
        }
    }

    struct PlayDefaultRow: Decodable {
        let label: String
        let fadeLenS: Double

        enum CodingKeys: String, CodingKey {
            case label = "case"
            case fadeLenS = "fade_len_s"
        }
    }
}

// MARK: trim.json

struct TrimCases: Decodable {
    let trimRangeOfStoredData: Rows<StoredRangeRow>
    let windows: Rows<WindowRow>
    let deckStart: Rows<DeckStartRow>
    let fadeOutAheadOfB: FadeOutAheadOfB
    let fadeInAtA: Rows<FadeInRow>

    enum CodingKeys: String, CodingKey {
        case trimRangeOfStoredData = "trim_range_of_stored_data"
        case windows
        case deckStart = "deck_start"
        case fadeOutAheadOfB = "fade_out_ahead_of_B"
        case fadeInAtA = "fade_in_at_A"
    }

    struct StoredRangeRow: Decodable {
        let stored: TrimFields
        let rangeS: [Double]

        enum CodingKeys: String, CodingKey {
            case stored
            case rangeS = "range_s"
        }
    }

    struct WindowRow: Decodable {
        let set: TrimFields
        let accepted: Bool
        let stored: TrimFields
        let rangeS: [Double]
        let durEffS: Double
        let fadeOutMs: Int
        let fadeInMsEff: Int
        let fadeInAppliedMs: Int

        enum CodingKeys: String, CodingKey {
            case set, accepted, stored
            case rangeS = "range_s"
            case durEffS = "dur_eff_s"
            case fadeOutMs = "fade_out_ms"
            case fadeInMsEff = "fade_in_ms_eff"
            case fadeInAppliedMs = "fade_in_applied_ms"
        }
    }

    struct DeckStartRow: Decodable {
        let label: String
        let trim: TrimFields
        let offset: Double
        let deck: Deck

        enum CodingKeys: String, CodingKey {
            case label = "case"
            case trim, offset, deck
        }

        struct Deck: Decodable {
            let baseS: Double
            let loS: Double
            let hiS: Double
            let durationS: Double
            let endFadeMs: Int
            let fadeInMs: Int
            let startVol: Double
            let fresh: Bool

            enum CodingKeys: String, CodingKey {
                case baseS = "base_s"
                case loS = "lo_s"
                case hiS = "hi_s"
                case durationS = "duration_s"
                case endFadeMs = "end_fade_ms"
                case fadeInMs = "fade_in_ms"
                case startVol = "start_vol"
                case fresh
            }
        }
    }

    struct FadeOutAheadOfB: Decodable {
        let rows: [Row]
        let ended: Bool
        /// True means nothing is live after the track ended (see FadesCases.FadeOutCase.liveAfter).
        let liveAfter: Bool

        enum CodingKeys: String, CodingKey {
            case rows, ended
            case liveAfter = "live_after"
        }

        struct Row: Decodable {
            let tS: Double
            let vol: Double
            let fading: Bool

            enum CodingKeys: String, CodingKey {
                case tS = "t_s"
                case vol, fading
            }
        }
    }

    struct FadeInRow: Decodable {
        let x: Double
        let vol: Double
    }
}

// MARK: end_actions.json

struct EndActionsCases: Decodable {
    let track2sEndDefault: EndCase
    let track2sEndOnce: EndCase
    let track2sEndLoop: EndCase
    let track2sEndStop: EndCase
    let onceSwitchedOffInPass1: EndCase
    let loopSwitchedOffInPass2: EndCase
    let endActionCycle: Cycle

    enum CodingKeys: String, CodingKey {
        case track2sEndDefault = "track_2s_end_default"
        case track2sEndOnce = "track_2s_end_once"
        case track2sEndLoop = "track_2s_end_loop"
        case track2sEndStop = "track_2s_end_stop"
        case onceSwitchedOffInPass1 = "once_switched_off_in_pass_1"
        case loopSwitchedOffInPass2 = "loop_switched_off_in_pass_2"
        case endActionCycle = "end_action_cycle"
    }

    struct EndCase: Decodable {
        /// Absent in the two "switched off" cases.
        let deckAtStart: DeckAtStart?
        /// The value the Python player measured (includes its 50 ms tick). Decoded for completeness, never compared.
        let endedAtS: Double?
        let idealEndedAtS: Double?
        let toleranceS: Double
        let rows: [Row]

        enum CodingKeys: String, CodingKey {
            case deckAtStart = "deck_at_start"
            case endedAtS = "ended_at_s"
            case idealEndedAtS = "ideal_ended_at_s"
            case toleranceS = "tolerance_s"
            case rows
        }

        struct DeckAtStart: Decodable {
            let passes: Int
            let loop: Bool
        }

        struct Row: Decodable {
            let tS: Double
            let live: Bool
            let passNo: Int?
            let remainingS: Double?

            enum CodingKeys: String, CodingKey {
                case tS = "t_s"
                case live
                case passNo = "pass_no"
                case remainingS = "remaining_s"
            }
        }
    }

    struct Cycle: Decodable {
        let sequence: [String]
    }
}

// MARK: play_modes.json

struct PlayModesCases: Decodable {
    let afterATrackEnds: Rows<AfterRow>
    let nextInOrder: Rows<NextInOrderRow>
    let shuffleBag: ShuffleBag

    enum CodingKeys: String, CodingKey {
        case afterATrackEnds = "after_a_track_ends"
        case nextInOrder = "next_in_order"
        case shuffleBag = "shuffle_bag"
    }

    struct AfterRow: Decodable {
        let mode: String
        let endAction: String
        let track: Int
        let after: After

        enum CodingKeys: String, CodingKey {
            case mode
            case endAction = "end_action"
            case track, after
        }
    }

    /// "stopped" | "same" | { playlist, track } | { playlist, any_other_track_of_the_playlist: true }
    enum After: Decodable, Equatable {
        case stopped
        case same
        case track(playlist: Int, track: Int)
        case anyOtherTrackOfPlaylist(playlist: Int)

        enum Keys: String, CodingKey {
            case playlist, track
            case anyOther = "any_other_track_of_the_playlist"
        }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                switch text {
                case "stopped": self = .stopped
                case "same": self = .same
                default:
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown `after` value \(text)"))
                }
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            let playlist = try c.decode(Int.self, forKey: .playlist)
            if (try c.decodeIfPresent(Bool.self, forKey: .anyOther)) == true {
                self = .anyOtherTrackOfPlaylist(playlist: playlist)
            } else {
                self = .track(playlist: playlist, track: try c.decode(Int.self, forKey: .track))
            }
        }
    }

    struct NextInOrderRow: Decodable {
        let mode: String
        let fromTrack: [Int]
        let nextInOrder: [[Int]]

        enum CodingKeys: String, CodingKey {
            case mode
            case fromTrack = "from_track"
            case nextInOrder = "next_in_order"
        }
    }

    struct ShuffleBag: Decodable {
        let neverTheSameTrackTwiceInARow: Bool
        let everyDrawIsATrackOfThePlaylist: Bool
        let firstRoundFromTrack0IsAPermutationOfTracks1And2: Bool
        let tracksLeftInTheRoundAfterOneDrawFromTrack0: Int
        let changingTheModeForgetsTheRound: Bool
        let eachTrackGetsAFairShareOf300Draws60To140: Bool

        enum CodingKeys: String, CodingKey {
            case neverTheSameTrackTwiceInARow = "never_the_same_track_twice_in_a_row"
            case everyDrawIsATrackOfThePlaylist = "every_draw_is_a_track_of_the_playlist"
            case firstRoundFromTrack0IsAPermutationOfTracks1And2 = "first_round_from_track_0_is_a_permutation_of_tracks_1_and_2"
            case tracksLeftInTheRoundAfterOneDrawFromTrack0 = "tracks_left_in_the_round_after_one_draw_from_track_0"
            case changingTheModeForgetsTheRound = "changing_the_mode_forgets_the_round"
            case eachTrackGetsAFairShareOf300Draws60To140 = "each_track_gets_a_fair_share_of_300_draws_60_to_140"
            // `_info_sequence` and `_info_python` are examples, not contract: not modelled.
        }
    }
}

// MARK: triggers.json

struct TriggerCase: Decodable {
    let triggers: [Point]
    let trim: TrimFields
    /// What the Python player measured (includes its 50 ms tick). Decoded for completeness, never compared.
    let fires: [Fire]
    let idealFires: [Fire]
    let toleranceS: Double

    enum CodingKeys: String, CodingKey {
        case triggers, trim, fires
        case idealFires = "ideal_fires"
        case toleranceS = "tolerance_s"
    }

    struct Point: Decodable, Equatable {
        let at: Double
        let file: String
        let enabled: Bool?
        let once: Bool?
    }

    struct Fire: Decodable {
        let tS: Double
        let file: String

        enum CodingKeys: String, CodingKey {
            case tS = "t_s"
            case file
        }
    }
}

// MARK: ducking.json

struct DuckSettings: Decodable, Equatable {
    let thresholdDb: Double
    let ratio: Double
    let attackMs: Double
    let releaseMs: Double
    let hold: Bool
    let topTrackPct: Double

    enum CodingKeys: String, CodingKey {
        case thresholdDb = "duck_threshold_db"
        case ratio = "duck_ratio"
        case attackMs = "duck_attack_ms"
        case releaseMs = "duck_release_ms"
        case hold = "duck_hold"
        case topTrackPct = "top_track_pct"
    }
}

struct VoiceOver: Decodable, Equatable {
    let file: String
    let startsAtS: Double
    let lengthS: Double
    let levelPct: Double
    /// (seconds, constant sample value) segments, in order.
    let segments: [Segment]

    struct Segment: Equatable {
        let seconds: Double
        let sampleValue: Int
    }

    enum CodingKeys: String, CodingKey {
        case file
        case startsAtS = "starts_at_s"
        case lengthS = "length_s"
        case levelPct = "level_pct"
        case segments = "segments_s_and_sample_value"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        startsAtS = try c.decode(Double.self, forKey: .startsAtS)
        lengthS = try c.decode(Double.self, forKey: .lengthS)
        levelPct = try c.decode(Double.self, forKey: .levelPct)
        segments = try c.decode([[Double]].self, forKey: .segments).map {
            Segment(seconds: $0[0], sampleValue: Int($0[1]))
        }
    }
}

struct DuckingCases: Decodable {
    let duckKey: KeyCase
    let duckCurve: Rows<CurveRow>
    let duckCurveHoldPercentile: HoldPercentile
    let duckSmooth: Rows<SmoothRow>
    let backgroundGain: Rows<GainRow>
    let inputTargetDb: Rows<InputRow>
    let duckLoop: DuckLoop

    enum CodingKeys: String, CodingKey {
        case duckKey = "duck_key"
        case duckCurve = "duck_curve"
        case duckCurveHoldPercentile = "duck_curve_hold_percentile"
        case duckSmooth = "duck_smooth"
        case backgroundGain = "background_gain"
        case inputTargetDb = "input_target_db"
        case duckLoop = "duck_loop"
    }

    struct KeyCase: Decodable {
        let key: [Double]
    }

    struct CurveRow: Decodable {
        let level: Double
        let ratio: Double
        let thresholdDb: Double
        let hold: Bool
        let reductionDb: [Double]

        enum CodingKeys: String, CodingKey {
            case level, ratio, hold
            case thresholdDb = "threshold_db"
            case reductionDb = "reduction_db"
        }
    }

    /// `_info_alternatives` (the depths of the 60th and 90th percentile) is prose and is not modelled.
    struct HoldPercentile: Decodable {
        let holdDepthDb: Double
        let reductionDbHoldOff: [Double]
        let reductionDbHoldOn: [Double]

        enum CodingKeys: String, CodingKey {
            case holdDepthDb = "hold_depth_db"
            case reductionDbHoldOff = "reduction_db_hold_off"
            case reductionDbHoldOn = "reduction_db_hold_on"
        }
    }

    struct SmoothRow: Decodable {
        let attackMs: Double
        let releaseMs: Double
        let dtS: Double
        let targetDb: Target
        let grDb: [Double]

        enum CodingKeys: String, CodingKey {
            case attackMs = "attack_ms"
            case releaseMs = "release_ms"
            case dtS = "dt_s"
            case targetDb = "target_db"
            case grDb = "gr_db"
        }

        /// Either an explicit list, or `{ "pattern": "constant segments", "segments": [{ "db", "steps" }] }`.
        struct Target: Decodable {
            let values: [Double]

            struct Segment: Decodable {
                let db: Double
                let steps: Int
            }

            private struct Pattern: Decodable {
                let pattern: String
                let segments: [Segment]
            }

            init(from decoder: Decoder) throws {
                if let list = try? decoder.singleValueContainer().decode([Double].self) {
                    values = list
                    return
                }
                let p = try Pattern(from: decoder)
                guard p.pattern == "constant segments" else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown target_db pattern \(p.pattern)"))
                }
                values = p.segments.flatMap { Array(repeating: $0.db, count: $0.steps) }
            }
        }
    }

    struct GainRow: Decodable {
        let grDb: Double
        let multiplier: Double

        enum CodingKeys: String, CodingKey {
            case grDb = "gr_db"
            case multiplier
        }
    }

    struct InputRow: Decodable {
        let rms: Double
        let gainDb: Double
        let ratio: Double
        let thresholdDb: Double
        let reductionDb: Double

        enum CodingKeys: String, CodingKey {
            case rms, ratio
            case gainDb = "gain_db"
            case thresholdDb = "threshold_db"
            case reductionDb = "reduction_db"
        }
    }

    struct DuckLoop: Decodable {
        let cases: InfoFilteredDictionary<LoopCase>
    }

    struct LoopCase: Decodable {
        let settings: DuckSettings
        let stepS: Double
        let lookAheadS: Double
        let voiceOver: VoiceOver
        let samples: Samples
        let peakReductionDb: Double
        let finalMultiplier: Double

        enum CodingKeys: String, CodingKey {
            case settings
            case stepS = "step_s"
            case lookAheadS = "look_ahead_s"
            case voiceOver = "voice_over"
            case samples
            case peakReductionDb = "peak_reduction_db"
            case finalMultiplier = "final_multiplier"
        }

        /// Columns of equal length. Rows are matched by INDEX: two rows share t = 0.5 on purpose.
        struct Samples: Decodable {
            let tS: [Double]
            let topPosS: [Double?]
            let targetDb: [Double?]
            let grDb: [Double]
            let bgMultiplier: [Double]

            enum CodingKeys: String, CodingKey {
                case tS = "t_s"
                case topPosS = "top_pos_s"
                case targetDb = "target_db"
                case grDb = "gr_db"
                case bgMultiplier = "bg_multiplier"
            }
        }
    }
}

// MARK: levelmatch.json

struct LevelMatchCases: Decodable {
    let lufsFromPcm: Rows<LufsRow>
    let normGain: Rows<NormRow>
    let appliedToDeck: Rows<DeckRow>

    enum CodingKeys: String, CodingKey {
        case lufsFromPcm = "lufs_from_pcm"
        case normGain = "norm_gain"
        case appliedToDeck = "applied_to_deck"
    }

    struct LufsRow: Decodable {
        let signal: String
        let lufs: Double?
    }

    struct NormRow: Decodable {
        let setting: String
        let measuredLufs: [Double?]
        let gainDb: [Double?]
        let gainLinear: [Double]
        let typed: LevelMatchTyped
        let stored: Stored

        enum CodingKeys: String, CodingKey {
            case setting, typed, stored
            case measuredLufs = "measured_lufs"
            case gainDb = "gain_db"
            case gainLinear = "gain_linear"
        }

        struct Stored: Decodable {
            let mode: LevelMatchMode
            let ref: String?
            let lufs: Double
        }
    }

    struct DeckRow: Decodable {
        let track: String
        let deckGain: Double
        let deckGainDb: Double?

        enum CodingKeys: String, CodingKey {
            case track
            case deckGain = "deck_gain"
            case deckGainDb = "deck_gain_db"
        }
    }
}

// MARK: resume_flow.json

struct ResumeRecord: Codable, Equatable {
    let pt: [Int]
    let id: String
    let pos: Double
    let paused: Bool
}

struct ResumeCases: Decodable {
    let record: Rows<RecordRow>
    let tryResume: Rows<TryRow>
    let resumeInsideATrim: InsideTrim

    enum CodingKeys: String, CodingKey {
        case record
        case tryResume = "try_resume"
        case resumeInsideATrim = "resume_inside_a_trim"
    }

    struct RecordRow: Decodable {
        let label: String
        let record: ResumeRecord?

        enum CodingKeys: String, CodingKey {
            case label = "case"
            case record
        }
    }

    struct TryRow: Decodable {
        let label: String
        let record: ResumeRecord
        let ageS: Double
        let pending: Pending?
        let started: Started?
        let recordKept: Bool

        enum CodingKeys: String, CodingKey {
            case label = "case"
            case record
            case ageS = "age_s"
            case pending, started
            case recordKept = "record_kept"
        }

        struct Pending: Decodable {
            let pt: [Int]
            let offsetS: Double
            let paused: Bool
            let xfadeMs: Int

            enum CodingKeys: String, CodingKey {
                case pt, paused
                case offsetS = "offset_s"
                case xfadeMs = "xfade_ms"
            }
        }

        struct Started: Decodable {
            let pt: [Int]
            let baseS: Double
            let paused: Bool
            let startVol: Double
            let fadeInMs: Int

            enum CodingKeys: String, CodingKey {
                case pt, paused
                case baseS = "base_s"
                case startVol = "start_vol"
                case fadeInMs = "fade_in_ms"
            }
        }
    }

    struct InsideTrim: Decodable {
        let started: Started

        struct Started: Decodable {
            let baseS: Double
            let loS: Double
            let hiS: Double
            let startVol: Double
            let fadeInMs: Int
            let fresh: Bool

            enum CodingKeys: String, CodingKey {
                case baseS = "base_s"
                case loS = "lo_s"
                case hiS = "hi_s"
                case startVol = "start_vol"
                case fadeInMs = "fade_in_ms"
                case fresh
            }
        }
    }
}

// MARK: renders/renders.json

/// Only the manifest is read in this step; the WAVs themselves are not used yet.
struct RendersManifest: Decodable {
    let specVersion: Int
    let sampleRate: Int
    let channels: Int
    let bits: Int
    let tolerance: Tolerance
    let renders: [String: Render]

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case sampleRate = "sample_rate"
        case channels, bits, tolerance, renders
    }

    struct Tolerance: Decodable {
        let windowMs: Double
        let amplitudeAbs: Double
        let maxShiftWindows: Int

        enum CodingKeys: String, CodingKey {
            case windowMs = "window_ms"
            case amplitudeAbs = "amplitude_abs"
            case maxShiftWindows = "max_shift_windows"
        }
    }

    struct Render: Decodable {
        let file: String
        let frames: Int
        let lengthS: Double

        enum CodingKeys: String, CodingKey {
            case file, frames
            case lengthS = "length_s"
        }
    }
}
