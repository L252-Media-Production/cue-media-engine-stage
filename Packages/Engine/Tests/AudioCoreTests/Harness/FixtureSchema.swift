import Foundation

/// What the harness knows about the fixture files: every top-level key, every case, every case key and every scenario key is either READ by a test
/// or IGNORED here on purpose. `FixtureGuardTests` fails when a file holds anything else, so new fixture content cannot be skipped silently.
/// Keys that start with `_info` are prose and are ignored everywhere.
///
/// Reading a key means a test uses its value. Ignoring one means it only describes how the Python generator drove its engine (`steps`, `input`,
/// tick lengths, random seeds, the files it played): it is not an input of the question the subject is asked.
enum FixtureSchema {
    struct CaseSchema {
        /// Keys of the case itself, besides `scenario` and `tolerance` (rows, expected values).
        let keys: Set<String>
        /// Scenario keys a test reads.
        let scenario: Set<String>
        /// Scenario keys that are not read, on purpose.
        let ignoredScenario: Set<String>
    }

    /// Keys at the top of every fixture file. `about` is prose.
    static let topLevelKeys: Set<String> = ["spec_version", "name", "about", "tolerance", "tolerance_lufs", "cases"]

    private static func c(_ keys: String, scenario: String = "", ignored: String = "") -> CaseSchema {
        CaseSchema(keys: set(keys), scenario: set(scenario), ignoredScenario: set(ignored))
    }

    private static func set(_ words: String) -> Set<String> {
        Set(words.split(separator: " ").map(String.init))
    }

    /// `file` -> case name -> schema. The nested cases of `ducking.duck_loop` are under `nested`.
    static let files: [String: [String: CaseSchema]] = {
        let fadeIgnored = "library_s playlist steps"
        let crossfade = c("fade_ms start rows", scenario: "sampled_at_fractions fade_ms", ignored: fadeIgnored)
        let endAction = c(
            "rows_at_s deck_at_start ended_at_s ideal_ended_at_s tolerance_s rows",
            scenario: "library_s playlist play_mode end_action", ignored: "tick_step_s run_s steps")
        let switchedOff = c(
            "rows_at_s ended_at_s ideal_ended_at_s tolerance_s rows",
            scenario: "library_s playlist play_mode end_action switch_off_to switch_off_at_s", ignored: "tick_step_s run_s")
        let trigger = c(
            "triggers trim fires ideal_fires tolerance_s",
            scenario: "library_s main_track main_track_length_s voice_over_lengths_s end_action run_s trim seek triggers",
            ignored: "playlist steps tick_s")
        // Cases with several seeks: `seek` is null in them and `seeks` lists the jumps.
        let triggerSeeks = c(
            "triggers trim fires ideal_fires tolerance_s",
            scenario: "library_s main_track main_track_length_s voice_over_lengths_s end_action run_s trim seek seeks triggers",
            ignored: "playlist steps tick_s")
        let triggerTarget = c(
            "triggers trim fires ideal_fires tolerance_s",
            scenario: "library_s main_track main_track_length_s voice_over_lengths_s end_action run_s triggers target_decoded_at_s",
            ignored: "playlist steps tick_s")
        // The new track, the voice-over (the constant sample value of its file) and the ducking settings in `config` are read from the scenario.
        let newTrack = c(
            "rows at_12_5_s", scenario: "library_s playlist config end_action triggers new_track voice_over", ignored: "tick_s steps")
        let trimBase = "file_length_s config"
        let trimIgnored = "library_s playlist track_under_test"
        let storedRows = c("rows", scenario: trimBase, ignored: "\(trimIgnored) input")
        let level = c(
            "ended_at_s ideal_ended_at_s tolerance_s rows",
            scenario: "\(trimBase) trim end_action sampled_at_s", ignored: "\(trimIgnored) steps tick_step_s")
        let overlap = c("deck", scenario: "\(trimBase) trim", ignored: "\(trimIgnored) steps tick_step_s")
        let curveWindows = "window_samples window_s windows"
        let resumeBase = "library_s playlist track_ids config age_limit_s"

        return [
            "fades": [
                "equal_power_formula": c("rows", scenario: "x_values"),
                "crossfade_1000ms": crossfade,
                "crossfade_3000ms": crossfade,
                "crossfade_0ms_is_a_cut": c("new_vol old_removed decks", scenario: "sampled_at_fractions fade_ms", ignored: fadeIgnored),
                "fade_out_2000ms": c("rows live_after", scenario: "sampled_at_fractions fade_ms", ignored: fadeIgnored),
                "pause_freezes_a_fade": c(
                    "at_0_25 after_5s_pause 0_25s_after_resume",
                    scenario: "fade_ms sample_1_at_s sample_2_at_s sample_3_at_s", ignored: "\(fadeIgnored) sampled_at_fractions"),
            ],
            "xfade": [
                "precedence": c("rows", scenario: "master_crossfade_ms", ignored: "library_s playlist target_track input"),
                "own_time_limits": c("rows", ignored: "library_s playlist target_track master_crossfade_ms input"),
                "play_default_uses_it": c(
                    "rows", scenario: "master_crossfade_ms default_transition row_inputs", ignored: "library_s playlist target_track steps"),
            ],
            "trim": [
                "trim_range_of_stored_data": c("rows", scenario: trimBase, ignored: "\(trimIgnored) input"),
                "windows": c("rows", scenario: trimBase, ignored: "\(trimIgnored) input"),
                "deck_start": c("rows", scenario: trimBase, ignored: "\(trimIgnored) input"),
                "fade_out_ahead_of_B": c(
                    "rows ended live_after", scenario: "\(trimBase) trim sampled_at_s ended_check_at_s", ignored: "\(trimIgnored) steps"),
                // `trim` only describes the signal (the fade-in is checked per fraction of the fade), so it is ignored here.
                "fade_in_at_A": c("rows", scenario: "\(trimBase) sampled_at_fractions", ignored: "\(trimIgnored) trim steps"),
                "short_window_stored": storedRows,
                "set_trim_rounding_a_b": storedRows,
                "set_trim_minimum_window": storedRows,
                "set_trim_out_vs_file_length": storedRows,
                "fade_length_limits": storedRows,
                "fade_length_held_to_window": storedRows,
                "fade_length_follows_window_changes": storedRows,
                "default_fade_longer_than_window": c(
                    "deck rows", scenario: "\(trimBase) trim sampled_at_s", ignored: "\(trimIgnored) steps tick_step_s"),
                "out_fade_placement_loop": level,
                "out_fade_placement_once": level,
                "out_fade_placement_default": level,
                "out_fade_placement_stop": level,
                "out_fade_once_switched_off_in_pass_1": c(
                    "ended_at_s ideal_ended_at_s tolerance_s rows",
                    scenario: "\(trimBase) trim end_action switch_off_to switch_off_at_s sampled_at_s", ignored: "\(trimIgnored) steps tick_step_s"),
                // Only the end is contract: the level in that last pass is a Python quirk (`_info_python_vol`, not read).
                "loop_switched_off_in_pass_1_end": c(
                    "ended_at_s ideal_ended_at_s tolerance_s",
                    scenario: "\(trimBase) trim end_action switch_off_to switch_off_at_s", ignored: "\(trimIgnored) steps tick_step_s"),
                "fade_in_start_threshold": c("rows", scenario: "\(trimBase) end_action", ignored: "\(trimIgnored) input"),
                "fade_in_cap": storedRows,
                // Only the deck values are contract: the level while the fades overlap is a Python quirk (`_info_python_vol`, not read).
                "fade_in_out_fade_overlap_901": overlap,
                "fade_in_out_fade_overlap_1000": overlap,
            ],
            "end_actions": [
                "track_2s_end_default": endAction,
                "track_2s_end_once": endAction,
                "track_2s_end_loop": endAction,
                "track_2s_end_stop": endAction,
                "once_switched_off_in_pass_1": switchedOff,
                "loop_switched_off_in_pass_2": switchedOff,
                "end_action_cycle": c("sequence", ignored: "playlist input"),
                "end_action_switched_mid_play": c(
                    "tolerance_s rows", scenario: "library_s playlist play_modes",
                    ignored: "tick_step_s run_s steps row_inputs"),
            ],
            "play_modes": [
                "after_a_track_ends": c(
                    "rows", scenario: "playlists playlist_under_test play_modes end_actions from_tracks",
                    ignored: "library_s mode_set_on_playlists tick_step_s max_ticks shuffle_random_seed steps"),
                "next_in_order": c("rows", scenario: "playlists playlist_under_test row_inputs", ignored: "library_s input"),
                "shuffle_bag": c(
                    "never_the_same_track_twice_in_a_row every_draw_is_a_track_of_the_playlist "
                        + "first_round_from_track_0_is_a_permutation_of_tracks_1_and_2 tracks_left_in_the_round_after_one_draw_from_track_0 "
                        + "changing_the_mode_forgets_the_round each_track_gets_a_fair_share_of_300_draws_60_to_140",
                    scenario: "playlists playlist_under_test start_track draws_for_sequence draws_for_fair_share fair_share_range",
                    // The Python random seeds only reproduce a sequence that is not compared.
                    ignored: "library_s play_mode python_random_seeds"),
            ],
            "triggers": Dictionary(uniqueKeysWithValues: [
                "simple", "two_in_order", "disabled", "trim_in_after_trigger", "trim_out_before_trigger", "trigger_inside_trim",
                "seek_over_does_not_fire", "seek_back_rearms", "loop_fires_every_pass", "once_flag", "top_already_playing_skips",
            ].map { ($0, trigger) } + [
                "once_seek_back_in_pass_1", "once_skipped_by_seek_forward_then_back", "once_loop_seek_back_in_lap_1", "once_loop_seek_back_in_lap_2",
            ].map { ($0, triggerSeeks) } + [
                ("target_ready_after_1s", triggerTarget),
                ("target_never_ready", triggerTarget),
                ("target_never_ready_does_not_block_next_point", triggerTarget),
                // Rows of `ideal_fired` (null = not compared); `fired`, `first_fire_t_s` and `python_differs` are what Python did and are not read.
                ("point_at_or_near_A_start_at_A", c("tolerance_s rows", scenario: "library_s main_track main_track_length_s voice_over end_action run_s", ignored: "playlist tick_s input")),
                ("point_near_A_start_with_offset", c(
                    "tolerance_s rows", scenario: "library_s main_track main_track_length_s voice_over trim end_action run_s", ignored: "playlist tick_s input")),
                ("voice_level_and_second_point", c(
                    "rows", scenario: "library_s main_track main_track_length_s voice_over_lengths_s end_action triggers", ignored: "playlist steps tick_s config")),
                ("new_track_cut_while_voice_on_top", newTrack),
                ("new_track_crossfade_while_voice_on_top", newTrack),
            ]),
            "ducking": [
                "duck_key": c("key", scenario: curveWindows, ignored: "format input"),
                "duck_curve": c("rows", scenario: curveWindows, ignored: "format input"),
                "duck_curve_hold_percentile": c(
                    "hold_depth_db reduction_db_hold_off reduction_db_hold_on",
                    scenario: "window_samples windows level ratio threshold_db", ignored: "format input"),
                "duck_smooth": c("rows", scenario: "initial_gr_db dt_s", ignored: "input"),
                "background_gain": c("rows", ignored: "input"),
                "input_target_db": c("rows", ignored: "input"),
                "duck_loop": c(
                    "cases", scenario: "background background_alone_s voice_over step_s tick_every_steps max_steps",
                    ignored: "settings_per_case"),
            ],
            "levelmatch": [
                "lufs_from_pcm": c("rows", scenario: "signals", ignored: "format synthesis"),
                "norm_gain": c("rows", scenario: "playlist measured_lufs lufs_clamp_db", ignored: "input"),
                "applied_to_deck": c("rows", scenario: "playlist measured_lufs playing_file row_inputs", ignored: "playing"),
            ],
            "resume_flow": [
                "record": c("rows", scenario: "\(resumeBase) row_inputs", ignored: "input"),
                "try_resume": c("rows", scenario: resumeBase, ignored: "input"),
                "resume_inside_a_trim": c("started", scenario: "\(resumeBase) trim_of_track_0 record age_s"),
            ],
        ]
    }()

    /// Nested cases of `ducking.json` `duck_loop`. The first two run the shared scenario of `duck_loop` (one voice-over, on the grid); the others carry a
    /// scenario of their own: the phase of the control grid (`loop_first_turn_delay_s`) and, in two of them, a second voice-over.
    static let duckLoopCases: [String: CaseSchema] = {
        let columns = "settings step_s look_ahead_s voice_over samples peak_reduction_db final_multiplier"
        let loop = CaseSchema(keys: set(columns), scenario: ["background", "voice_over_file"], ignoredScenario: ["see"])
        let ownScenario = "background background_alone_s first_voice_over loop_first_turn_delay_s step_s tick_every_steps"
        let phase = CaseSchema(keys: set(columns), scenario: set("\(ownScenario) phase_ms"), ignoredScenario: ["settings"])
        let second = CaseSchema(keys: set("\(columns) ducking_loop_tasks"), scenario: set("\(ownScenario) second_voice_over"), ignoredScenario: ["settings"])
        return [
            "production_defaults_hold_on": loop, "slow_attack_hold_off": loop,
            "voice_phase_2_5ms": phase, "voice_phase_7ms": phase, "voice_phase_9_9ms": phase,
            "second_voice_starts_off_grid_while_ducking": second, "second_voice_ends_first": second,
        ]
    }()

    /// Case names of a file as the harness knows them.
    static func caseNames(_ file: String) -> Set<String> {
        Set(files[file]?.keys.map { $0 } ?? [])
    }

    static func schema(file: String, caseName: String) -> CaseSchema? {
        let parts = caseName.split(separator: "/").map(String.init)
        if file == "ducking", parts.count == 2, parts[0] == "duck_loop" { return duckLoopCases[parts[1]] }
        guard parts.count == 1 else { return nil }
        return files[file]?[parts[0]]
    }

    /// What is wrong with one case of a fixture file against this schema: a case that is not listed, keys the harness neither reads nor ignores (in the case
    /// or in its scenario), and keys it expects that are gone. Empty when the case is covered. `FixtureGuardTests` runs it over every case of every file.
    static func problems(file: String, in c: FixtureCase) throws -> [String] {
        guard let schema = schema(file: file, caseName: c.name) else { return ["\(file).json: case '\(c.name)' is not in FixtureSchema"] }
        var out = [String]()
        let keys = Set(c.value.keys.filter { !$0.hasPrefix("_info") })
        let allowed = schema.keys.union(["scenario", "tolerance", "tolerance_by_key"])
        let unknown = keys.subtracting(allowed).sorted()
        if !unknown.isEmpty { out.append("\(file).json case '\(c.name)': keys the harness does not know: \(unknown)") }
        let gone = schema.keys.subtracting(keys).sorted()
        if !gone.isEmpty { out.append("\(file).json case '\(c.name)': keys the harness expects are gone: \(gone)") }

        let scenarioKeys = Set(try c.scenario().keys.filter { !$0.hasPrefix("_info") })
        let unknownScenario = scenarioKeys.subtracting(schema.scenario.union(schema.ignoredScenario)).sorted()
        if !unknownScenario.isEmpty { out.append("\(file).json case '\(c.name)': scenario keys the harness does not know: \(unknownScenario)") }
        let goneScenario = schema.scenario.subtracting(scenarioKeys).sorted()
        if !goneScenario.isEmpty { out.append("\(file).json case '\(c.name)': scenario keys the harness reads are gone: \(goneScenario)") }
        return out
    }
}
