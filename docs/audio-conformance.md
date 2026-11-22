# Audio conformance

The audio engine of CueME Stage (Swift / Core Audio) has to sound the same as the Python Cue Media Engine. The contract is
`docs/AUDIO-SPEC.md` in the Python repo plus its golden fixtures (JSON, and four reference WAVs). This repo holds a **copy** of the fixtures,
a test harness that reads them, and the first pieces of engine maths that pass them.

Everything lives in the Engine package and needs neither Desktop Video nor the NDI SDK:

| Where | What |
|---|---|
| `Packages/Engine/Sources/AudioCore/` | Pure maths (no state, no I/O, `Double`). Depends on nothing. |
| `Packages/Engine/Tests/AudioCoreTests/` | The harness and the tests. |
| `Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<N>/` | The synced fixtures of spec version N, plus `SPEC_VERSION`, `AUDIO-SPEC-LINE1.txt` and `SOURCE.txt` (the Python commit they were copied from). |
| `scripts/sync-audio-spec.sh` | Copies the fixtures from the Python repo. |

## Sync the fixtures

```
scripts/sync-audio-spec.sh /path/to/cue-media-engine
```

It reads the Python repo (never writes to it) and replaces `Fixtures/spec-<N>/`, where N is the number on the first line of the Python
`docs/AUDIO-SPEC.md` (`Spec version: N (...)`). It refuses to copy when any file says another `spec_version`, and it refuses a Python working tree that is not clean (untracked files count): the fixtures are
generated files and a dirty tree can hold a half-finished regeneration. It writes `Fixtures/spec-<N>/SOURCE.txt` with `python_commit` (full hash of the Python
HEAD) and `spec_version`; `FixtureGuardTests` fails when the stamp is missing or its version differs from the fixtures. Commit the result (about 1.5 MB).

The fixtures are self-describing: every case has a `scenario` object with the inputs it was generated from, and the harness reads them from there (a missing
key fails with the file, case and key). Inputs are typed keys, never prose (`resume_flow` `then` is `{action, fade_ms}`, `levelmatch` `playing_file`, `shuffle_bag` `fair_share_range`); the harness parses no text. `FixtureSchema` lists every key the harness reads or ignores on purpose; a new key in a fixture fails
`testNoFixtureKeyIsUnknown` until someone decides which it is.

## Run

```
cd Packages/Engine
swift test --filter AudioCoreTests
```

or run the `AudioCoreTests` scheme / target in Xcode. Each fixture case is its own test, so a failure names the case and the row
(for example `duck_smooth row 1 attack=50.0 release=1000.0 [index 20]`).

## Read the result: passing, pending, failing

- **passed**: the engine under test reproduces that case within the tolerance of the fixture file.
- **skipped**: the report line says `pending: <what is missing>`. The engine cannot answer that question yet. This is the list of work that is left, not a
  problem; the suite stays green. The skip count goes down as the Swift engine grows.
- **failed**: something is wrong: the engine disagrees with a fixture, a fixture says a different spec version than the pinned one, a fixture has a case
  the harness does not know, or the `Fixtures/` folder holds more than the pinned `spec-<N>`.

The tests only talk to the protocol `AudioSpecSubject` (`Tests/AudioCoreTests/Harness/AudioSpecSubject.swift`). `AudioSpecSubjects.current` picks the
subject: `AudioCoreSubject` (what `AudioCore` implements, the rest pending) today, the real engine later, or `PendingSubject()` to see everything skipped.
Every method the protocol lists that is not overridden defaults to "pending".

Rules the harness follows (from the plan):

- Tolerances come from the fixtures. A `tolerance` on a case overrides the file's for that case and the cases nested in it (`duck_curve` and
  `duck_curve_hold_percentile` carry 2e-5 dB). `assertClose(_:_:in:)` applies it. There is no special allowance in the harness; if a case ever needs one, the
  fixture gets its own tolerance on the Python side. The fixtures hold the ideal `Deck.vol`, not a quantised mixer volume.
- Position and duration values in file seconds are compared within the case's `tolerance_by_key` (one sample, 2.5e-5 s); gains within the file tolerance. A key-level entry beats the case tolerance for that key only (`FixtureCase.tolerance(forKey:)`).
- Trigger and end times are compared with the `ideal_*` values, never with the measured Python values (they include the 50 ms tick).
- Shuffle: only the listed properties are checked, never the sequence.
- `duck_loop` rows are matched by index, not by time (two rows share t = 0.5). Both multiplier columns are compared: `ideal_bg_multiplier` at the file tolerance
  (the contract) and the measured `bg_multiplier` at the `tolerance_by_key` of `duck_loop` (6e-4), see quirk 9 below.
- The quirks table of `AUDIO-SPEC.md` is not reproduced. Clipping is not in the spec and is not tested.
- The WAV renders are not used yet. `renders.json` is loaded and its version checked; an envelope comparison comes with the real mixer.

## Design notes

- **`AudioSpecSubject` is a test-side adapter** over the real Stage types. The engine must not expose it, conform to it in production code, or take on the
  shape of Python's API (`set_trim`, `try_resume`, ...). The adapter translates a fixture question into whatever Stage's types offer.
- **`resume_flow` is adapted, not copied.** Stage keeps the behaviour the fixture states (what is restored, the age limit, a resumed start never fades in, a
  deliberate stop or a running fade-out leaves nothing to resume) behind its own types (`ResumeRecord`, `Resume.plan`, `ResumeStore`); see "Slice 8: resume" below.
- **`duck_loop` must call the same hold-percentile function as `duck_curve`.** The `duck_loop` fixture cannot tell the 60th, 75th and 90th percentile apart;
  only `duck_curve_hold_percentile` can (its `_info_alternatives` lists the three depths). The engine has one function for both
  (`Ducking.holdDepthDb`, used by `Ducking.curve`).
- **Open: clipping.** The spec leaves clipping unspecified, so no fixture tests it. The harness refuses to build a signal that would clip 16 bits instead of choosing a policy.
- **Source:** the fixtures in this repo come from the Python repo's commit `3d7cd36` (branch `audio-spec`, spec version 1; first synced at `1241963`); see `Fixtures/spec-1/SOURCE.txt`.

## Engine types so far (slice 1: fades and crossfade)

`AudioCore` holds the first engine types, pure Swift with no hardware: `Transport` (injected frame clock, pause freezes play time), `Fade`, `Deck`,
`Mixer` (decks, crossfade, fade-out) and `CrossfadeSettings` (time precedence, own-time limits). Time moves only by `advance(frames:)`. Gains are ideal
values; the 128-step quantising of the Python mixer is not reproduced. `AudioCoreSubject` maps the fixture questions of `fades.json` and `xfade.json`
onto these types; the types do not follow Python's method names. The next slices (trim, fade-in at A, end actions) extend `Deck` and reuse `Transport`.

## Engine types, slice 2 (trim, fades at A and B, passes, end actions)

`Trim` (stored A, B, edges, fade lengths; `apply(_:fileLength:)` refuses a bad edit and changes nothing), `TrimPolicy`, `TrackPlan` (a window of the
file in frames, never a copy of audio; fades at both edges; `TrackEnd`), `Playback` (passes, remaining time and the out-fade derived by arithmetic from the
play frame) and `Mixer.ended` (decks that ended, at the exact frame). The spec text is copied to `docs/audio-spec-1.md` by `scripts/sync-audio-spec.sh`.

Rules that slice 2 took from the fixtures before the spec text stated them. Python commit `1241963` pins each of them with a fixture case (and the spec text says them now), so
there is no "implicit" list any more:

| Rule | Pinned by (`trim.json` unless said) |
|---|---|
| A window under 0.5 s falls back to B = end of file, A kept; a fallen-back window has no out-fade | `short_window_stored` |
| Points round to 0.01 s | `set_trim_rounding_a_b` |
| An In that is <= 0.01 s after rounding is not stored | `set_trim_rounding_a_b` |
| An Out within 0.01 s of the end (compared with the real length) is not stored; one past the end is clipped first | `set_trim_rounding_a_b`, `set_trim_out_vs_file_length` |
| `set_trim` refuses a window under 0.5 s only when both In and Out are present | `set_trim_minimum_window` |
| A fade length is rounded to whole ms and must be 100...10000 ms | `fade_length_limits` |
| A fade length is held to the part that plays (never below 100 ms) and follows the window when it shrinks | `fade_length_held_to_window`, `fade_length_follows_window_changes` |
| The out-fade runs only in the last pass of a deck that ends (never while looping; `once` in pass 2) | `out_fade_placement_loop`, `_once`, `_default`, `_stop`, `out_fade_once_switched_off_in_pass_1` |
| A default out-fade longer than the window stays nominal on the deck and is held to one pass while running | `default_fade_longer_than_window` |
| The fade-in starts only when the raw `offset` (file seconds, not relative to A) is <= 0.05 s | `fade_in_start_threshold` |
| `fresh` (the gate for loop and a second pass) is `|start - A| < 0.06 s` | `fade_in_start_threshold` |
| The fade-in is capped to window - out-fade when that leaves >= 100 ms; otherwise it keeps min(stored, window) | `fade_in_cap`, `fade_in_out_fade_overlap_901`, `_1000` (deck values only) |
| A loop keeps reporting pass 1, also after it is switched off | `end_actions.json` `track_2s_end_loop`, `loop_switched_off_in_pass_2` |
| Switching an end action while a track plays: the running pass is played out, then the new action decides | `end_actions.json` `end_action_switched_mid_play` |

Python quirks 10, 11 and 12 of `docs/audio-spec-1.md` are NOT contract and are not reproduced (see "Stage decisions to make").

## Stage decisions to make

Behaviour the Python player has by accident, where the fixtures pin only part of the result. Stage has not chosen its own behaviour for these yet; until it does,
the tests compare only what the fixture says (`loop_switched_off_in_pass_1_end` the end time, `fade_in_out_fade_overlap_901` / `_1000` the deck values).

- **Quirk 10, a loop switched off mid-pass.** Python cuts hard at B instead of out-fading (the out-fade is decided from how the deck was started). The deck ends at the end of the running pass
  (contract). Stage has not chosen its own behaviour yet: the ideal is an out-fade in the pass that turns out to be the last one.
- **Quirk 11, fade-in and out-fade overlap.** When the window is too short for both, Python keeps the full fade-in and starts the out-fade at the first tick after it (or never). The deck values
  (fade-in length kept, out-fade not shortened) are contract. Stage has not chosen its own behaviour yet: multiplying the two envelopes is the likely one.
- **Quirk 12, switching to `once` mid-play.** Python adds no second pass (it is decided when the track starts). Not pinned by `end_action_switched_mid_play`. Stage has not chosen its own
  behaviour yet; the subject treats that switch as pending.

## Engine types, slice 3a (playlists, play modes, shuffle)

`Playlist` (tracks by stable `TrackID`, `PlaylistMode`, per-track `TrackEnd`, `Trim` and crossfade time; plain values), `PlayOrder` (pure `nextInOrder` and `successor`),
`ShuffleBag` with an injected `RandomSource` (`SeededRandomSource` for tests, `SystemRandomSource` for a show) and `PlaylistPlayer` (a `Mixer` plus playlists: `advance(frames:)` steps
to the exact frame a deck ends at and starts what follows there; `setEnd` plays the running pass out and lets the new action decide). Rules taken from the Python source where the
fixtures are silent: a `stop` end action beats every mode; a `loop` track is "same"; `next_playlist` skips empty playlists and does not wrap after the last one; the shuffle bag refills with
every track except the one just played (so a round is n - 1 draws, and a playlist of one track repeats it); the bag forgets its round when the mode changes. The successor starts with a cut.
The shuffle sequence is never compared with Python's, only the listed properties.

Allocation: `advance(frames:)`, `PlayOrder.successor` and `ShuffleBag.draw` allocate nothing once the bag has its capacity (reserved when a playlist's tracks change, a setup path).
Starting the next track appends a deck to `Mixer.decks`, which can allocate, and ended decks are never removed, so a long show grows that array by one deck per track. `PlayOrder.nextInOrder` and
the `Playlist`/`PlaylistPlayer` editing methods allocate and are setup or test paths.

## Engine types, slice 4 (trigger points)

`Trigger` / `TriggerID` / `TriggerList` (points of a track, sorted by `at`, fixed capacity 64, overflow counted), `TriggerWatch` (per watched deck: bitmasks `fired`, `due`, `skipped`, the
file position seen so far, the pass and the passes before a seek; pure arithmetic: `begin`, `seeked`, `observe`, `nextEvent`), `TargetReadiness` / `TargetState` (ready with a length,
loading, missing; driven by the tests from the fixture), `DuckingHook` with the no-op `NoDucking` (the ducking slice plugs in there; no ducking maths exists yet), `TriggerSettings`.
`PlaylistPlayer` runs them: the step is cut at every frame a point is reached or a pass begins, so a voice starts at the exact frame whatever the caller's step (the Python 50 ms tick is not
reproduced). The voice is a second `Deck` (`Mixer.startOnTop`, `Deck.isTop`) with no trim and no fade-in; starting a track removes it. `Mixer.seek` / `PlaylistPlayer.seekLive` move a
deck (held to [A, B - 0.3 s], loop and passes kept, the fade-in not replayed).

Rules (fixtures and spec text; the Python source was read only to confirm numbers): a point fires when the playhead crosses it, `(last, now]`; a point at A fires on a start at A; before A or
at or after B never; a start part-way in or a seek has everything at or behind the position done and everything ahead armed; a new pass re-arms; `once` fires only when no pass came before;
a Play on Top already running skips the point (not queued); disabled, disarmed (`TriggerSettings.armed`) and skipped points never fire; a seek while a voice plays on top is ignored.

Not contract, Stage's own choice: the wait for a target that is still loading. Neither the spec text nor a fixture mentions it (the Python player gives up after 30 s); `TriggerSettings.waitLimitSeconds`
defaults to 30 until a decision is made. The voice plays at full level (the "top track level" belongs to the ducking slice). Starting a track while a voice plays removes the voice.

Allocation: `advance`, `TriggerWatch.observe` / `nextEvent` and the firing check allocate nothing. A fire appends a deck to `Mixer.decks` (allocates; ended decks stay): a run adds at most one deck per
fired trigger, on top of one per track start. `TriggerWatch.init` allocates its fixed `dueSince` storage once per player; `TriggerList.add`, `PlaylistPlayer.addTrigger` / `removeTrigger` / `setTrigger`
and `TriggerWatch.remap` are setup paths. `fired` is preallocated (capacity 32, extra fires counted in `droppedFires`).

## Engine types, slice 5 (fixed deck pool)

`Mixer` keeps its decks in a fixed pool (16 slots, allocated once) addressed by `DeckID` handles with generations; ended decks are recycled oldest first and `DeckEnded` carries the last gain;
`EngineCounters` (`droppedEnds`, `droppedFires`, `poolExhausted`) replaces the loose counters as the thing to read. Behaviour of fades, trim, passes, playlists and triggers is unchanged. See
`docs/audio-engine-realtime.md` for the real-time rules, the setup-path allocations and what is not proven.

## Trigger boundary rules (Python 1241963)

Synced to Python `1241963` (spec text: "Margins at A", "`once` = first PASS", "A new track started while a voice-over is on top", "Level and overlap", "A target that is not decoded yet"; quirks 13, 14 and 15 are not contract).
Rules in the engine: a point is eligible when `A - 1e-6 s <= at < B - 1e-6 s`, `at` kept to 1 ms (`Trigger`); a start at A (an offset up to 0.05 s, or exactly on A: `TrackPlan.startsAtA`) fires every point from A on, a start part-way in has
everything behind it done (a point behind it never fires, one ahead fires when reached; a point inside the first tick is undefined and not compared: `ideal_fired: null`); `once` means first pass: a seek keeps the pass count, so
a seek back in pass 1 re-arms a once point, a seek over it and back leaves it unspent, and from pass 2 on it never fires again; a CUT removes the voice, the background and (later) the ducking state at once and the new track plays alone,
a CROSSFADE fades every deck, the voice included, over the crossfade time (the voice stays "on top", occupies an outgoing pool slot and skips points reached meanwhile, until its fade ends; the ducking hook hears its end then); a target
that is not ready makes the point wait and it fires on the first call after the target is ready; a target that never loads is given up on after `TriggerSettings.waitLimitSeconds` (Stage's own value, not contract); the voice plays at
`TriggerSettings.topTrackPercent / 100` as a plain volume (no fade-in) and becomes the live deck.

Compared by the harness: `ideal_fired` / `ideal_t_s` / `ideal_fires` within `tolerance_s`, `start_s` within `tolerance_by_key`, the decks of the new-track cases (which decks play, `live`, `top`, `vol`, `ending`) and the voice rows (`voice_vol`, `voice_is_live`,
`voice_fading`, `background_decks`, `tops`, `voice`, `trigger_fires_so_far`). Not compared: Python's `fires`, `fired`, `first_fire_t_s`, `_info_python_*` (the Python gr and multiplier), `voice_gain` (level match is not in the engine, so no
gain is applied to a trigger voice). `python_differs` rows are compared against `ideal_fired`, which is the contract; only the Python measurement is ignored.

What the top-track level does to the other decks (the background multiplier, the `ducked` flag of the decks, the release after a crossfade, quirk 14) is slice 7, below.

## Engine types, slice 6 (loudness and level match)

`Loudness.integratedLufs(interleaved:channels:)` (offline, a pure function of the buffer): BS.1770 K-weighting (the standard's 48 kHz shelf and high-pass coefficients), mean square over 400 ms blocks every 100 ms, absolute gate -70 LUFS,
relative gate 10 LU below; 1 or 2 channels with weight 1; nil for silence, for less than one block (0.4 s) and for any other channel count. Not rounded (the fixture values are rounded to 3 decimals and compared within 0.01 LU; the engine's values
are within 0.0005 LU of them). `LevelMatch` (mode `off` / `track` / `lufs`, a reference track by id, the stored target; `Clamp` min, max, step; typed -80 stores -60; gain `min(0, target - measured)`; linear `10^(dB/20)`, 1 with no gain),
`PlaylistTrack.measuredLufs`, `Playlist.levelMatch` / `levelGainDb(ofTrackAt:)` / `levelGain(ofTrackAt:)`. `Deck.levelGainNow` / `levelGain(at:)` is a factor of its own, multiplied into `Deck.gain(at:)` with the fade and the window edges;
it follows a change at once (the spec's "Deck.gain follows a change at once"), and `levelGain(at: blockStart)` / `levelGain(at: blockEnd)` give a render block that contains the change the two values to ramp between (no ramp length is
invented). `PlaylistPlayer.setLevelMatch` / `setMeasuredLufs` apply a change to the playing track; a track starts with its gain from the first frame. A trigger voice is never level matched (the spec text and the fixture: "no level match"),
so `voice_gain` is 1.0 and the voice volume is only the top-track level.

What the spec and fixtures do not pin (decided here): the K-weighting coefficients are the ITU-R BS.1770 values (the 100 Hz and 10 kHz rows of `lufs_from_pcm` confirm them); only whole blocks count (no padding of a last partial block); the filter
starts from rest; 3 or more channels (and their weights) are not specified; a typed target that is not a number keeps the default -18; rounding to the 0.1 step is to the nearest; an index outside the playlist keeps no reference track; a `track`
mode whose reference is not measured gives no gain; `stored.lufs` of the off and track modes is an unused default. A fixture that would pin the rest: a `lufs_from_pcm` row with a 3-channel or mono signal and one that ends in a partial block.

Allocation: the measurement allocates (offline). `Deck.setLevelGain`, `Mixer.setLevelGain`, `Deck.gain(at:)` and `levelGain(at:)` are arithmetic on stored numbers and allocate nothing (a test counts heap blocks around them). `setLevelMatch` and
`setMeasuredLufs` are setup/UI paths (they may copy a `LevelMatch`, a small value).

## Engine types, slice 7 (ducking)

`Ducking` (pure maths: `key`, `curve`, `holdDepthDb`, `smooth`, `backgroundMultiplier`, `inputTargetDb`), `DuckingSettings`, `DuckReading` (target, smoothed reduction, multiplier and the key `window` the step read), `DuckControl` (the state of the loop, inside the
`Mixer`), `Mixer.beginDucking(voice:curve:settings:)` / `endDucking(voice:)` / `duckReading(at:)` / `isDucking` / `duckVoice`, `Deck.duck(at:)` / `volume(at:)` / `followsDuck` (gain = fade x level x duck) and `SidechainDucking`, the `DuckingHook`
that the player calls when a voice starts (a voice whose target has no prepared key plays without ducking and is counted in `voicesWithoutKey`).

How it works: the curve (reduction in dB per 10 ms window of the voice, hold already applied) is made offline when a voice-over is imported and only read in the loop. `Mixer.advance` cuts time at every 10 ms control step, so results do not depend on the caller's block size.
The step at frame `anchor + j * 480` reads window `floor((position of the voice + 20 ms) / 10 ms)` (for the step at the voice's position `j * 10 ms`: window `j + 2`), smooths the reduction one step with attack or release, and the new factor is in force from the NEXT step on
(a render block that contains the step ramps from the old factor to the new one). Every playing deck that is not a voice on top is marked as background when a voice starts. The loop ends by itself when the voice is over and the reduction has been released. It allocates nothing
per block (a test counts heap blocks). `docs/audio-engine-realtime.md` has the rules for the hook.

Decisions (what the spec and the fixtures say, and what is Stage's own):

- **The look-ahead rounds DOWN (floor)** (quirk 16; contract as far as the phase cases pin it). The window is `floor(position / 10 ms) + 2`. `voice_phase_2_5ms`, `_7ms` and `_9_9ms` fix it: 2.5 ms rules out ceil, 7 and 9.9 ms rule out round (the engine run with round or ceil fails
  them; with floor the reduction is within 1.5e-6 dB of the fixture on every row). The on-grid cases cannot tell the rounding apart (the position is a multiple of the window).
- **A second voice-over replaces the first and keeps the loop, the reduction and the grid.** The loop is started once for the whole run (`ducking_loop_tasks` 1; the adapter counts the starts it sees), the reduction is not reset (it relaxes at the release rate through the new
  voice's silence, then follows the new curve read from the second voice's OWN position, origin 0), and the first voice, still audible while it fades out, no longer drives the ducking (`Mixer.duckVoice` is the second). When a shorter second voice ends first the release starts
  at once, although the first is still fading (`second_voice_ends_first`). The control grid stays where the first voice started it: the second voice's steps are at 7.5, 17.5 ... ms of its own position in `second_voice_starts_off_grid_while_ducking`.
- **A trigger voice gets no level match.** `voice_gain` is 1.0 and the voice volume is only the top-track level (slice 6, `voice_level_and_second_point`); the key of the voice is scaled by the same top-track level before the curve.
- **Quirk 9 is handled by the fixture's `ideal_bg_multiplier`, not by the engine.** Python rewrites a background deck's multiplier only when it moved by more than 0.0005, so the measured `bg_multiplier` column trails `10^(-gr_db/20)` by up to 5e-4 (worst row 4.98e-4). The engine does
  NOT emulate that write rule: its multiplier is the ideal one. The test compares it with `ideal_bg_multiplier` at the file tolerance (2e-6; worst difference 5.5e-7) and with the measured column at 6e-4 (worst 4.98e-4); every `duck_loop` case prints both (`DUCKCONF` lines).
- **A cut or a crossfade away from a voice-over leaves no residual depth** (quirk 14, not contract): the loop ends as soon as no deck of the old background plays any more (a cut: at once; a crossfade: when the fades are done) and the new track is never ducked by the old voice. A new track after a crossfade starts at its own level
  (`ducked` false); during the crossfade the voice and the old background fade out (`voice`, `old_background`, `new_track` of the `new_track_*` cases at 4.0 ... 5.1 s: present, level, ducked, fading out).

### Quirk 16: the phase of the control grid is not contract (and how the adapter reproduces it)

Python's loop is one asyncio timer that starts at the first voice-over and ticks every 10 ms, so the position it reads has an arbitrary phase against the 10 ms windows; the engine's grid is anchored where its loop starts. Phase and rounding are therefore NOT contract, only
floor is pinned (above). To compare row by row anyway, the test adapter (`AudioCoreSubject.duckVoices`; the engine has no phase parameter and nothing for it was added) reproduces Python's phase:

- **A phase is a delay of the hook.** The voice plays `loop_first_turn_delay_s` (2.5, 7, 9.9 ms: 120, 336, 475 frames) before it is handed to `SidechainDucking.voiceStarted`; the engine's first step is then at that position of the voice, and row `r` is the value step `r`
  computed (`duckReading(at: step + 10 ms)`). 9.9 ms is 475.2 frames: the engine runs on frame 475, and the instants `t_s` and `top_pos_s` of the rows are compared as the scenario's schedule (start + delay + 10 ms x row), not as frame counts.
- **The on-grid rows are not on the grid.** With no delay Python's later turns read the position a float rounding error BELOW the 10 ms grid (the rig's fake clock adds 0.01 per turn): the recorded `look_ahead_index` of row `k` is `k + 1`, not `k + 2`
  (`second_voice_*`, rows of the first voice and a second voice that starts on the grid). That is rig noise, not behaviour; the adapter models it as a loop that runs ONE FRAME (21 us) early: the hook is called 479 frames in, row 0 is the first turn before the loop (position 0,
  nothing to do) and row `r` is step `r - 1`. With an exact 480-frame grid the two second-voice cases fail (the engine reads one window further: `look_ahead_index` is 3 where Python recorded 2, and the reduction differs by up to 12.6 dB at the rise of the voice at 0.3 s).
  The column `look_ahead_index` checks this choice on every row; a fixture made with other rounding noise fails there instead of being absorbed. The older `production_defaults_hold_on` and `slow_attack_hold_off` need no phase (the engine's own grid, sampled with its one-step delay, is
  what they record).
- **Reporting only, not in the engine:** the player's 50 ms tick is what takes a finished voice-over away. Until it does the fixture keeps listing the voice-over (`top_n`, `top_pos_s` clamped to its length, `look_ahead_index`; the rows after the voice ended, e.g. rows 251-254 of
  `production_defaults_hold_on`). The adapter reproduces that listing from `tick_every_steps`; the engine releases at the exact frame and the reduction is the same either way.

What the fixtures do not pin about the engine's loop: the engine applies a factor one step AFTER the step that computed it, so its audible look-ahead is 10 ms (it reads 20 ms ahead and applies 10 ms later); Python with a positive phase applies at once and anticipates by 20 ms
(the on-grid rows of the fixtures, by rounding noise, anticipate by 10 ms like the engine). Whether Stage wants 20 ms audible (a 30 ms read) is open. Also not pinned: a second voice-over that starts exactly ON a control step (the engine runs that step with the first voice, Python with the second).

## Slice 8: resume

**Decision (owner, 2026-11-22): after an engine restart Stage resumes playing audio**, with the semantics of the spec's "Resume" row and `resume_flow.json`.

- **The record** (`ResumeRecord`, Codable: `pt`, `id`, `pos`, `paused`, the fields of Python's `resume.json` without its `saved` stamp): `pt` = `[playlist, track]`, `id` = the stable library
  file id, `pos` = seconds in the FILE (a paused track keeps its position: the play frame is frozen), the paused flag. It records the track the show is on (the background track when a voice-over
  is on top). Trigger voices are never recorded. Built by `PlaylistPlayer.resumeRecord(catalog:)` from `current`, `Mixer.deck`, `Deck.fade` and `Playback.filePositionFrames` (no new per-frame state).
- **No record (nil, the store entry is removed)** when nothing plays, after a deliberate stop (`stop()`), and while a fade-out runs on the track (`fadeOut(milliseconds:)`, a down fade on its deck).
- **At start-up** (`Resume.plan(record:ageSeconds:catalog:settings:)` -> `ResumeDecision`): the track starts at `pos` (paused if it was) unless the record is older than `resume_max_age_s`, its
  file is in no playlist, or `pos` is not a number; such a record is dropped (`recordKept` false). The place is found again by id (`ResumeCatalog.position(of:recordedPt:)`), so an edited
  playlist still resumes the right file. The age is `WallClock.nowSeconds - ResumeEntry.savedAt`: the frame clock does not survive a restart.
- **A resumed start never fades in**: `PlaylistPlayer.startResume(_:)` goes through `play` (the same start path: trim window, loop and once gate, trigger arming, level match) with a cut
  (`xfade_ms` 0) and `fadeIn: false` (start volume 1, fade-in 0), even when the track has a fade-in at A (`resume_inside_a_trim`).
- **Settings** (`ResumeSettings`): `resume_on_start` (default true), `resume_max_age_s` (default 1800), `resume_save_s` (default 5).
- **The periodic save** is a control-thread task. `Resume.isSaveDue(now:lastSave:settings:)` decides; `ResumeController.saveIfDue` writes the record or removes it. There is no timer in AudioCore.
- **The store** (`ResumeStore`: `load`, `save`, `remove`; `InMemoryResumeStore` for tests). The file-backed store is integration work and must write atomically (temp file in the same
  directory, flush, rename over the old one), be called from the control thread only (never from the render callback), and read a corrupt file as no record.

Everything in `Resume.swift` is control side: it allocates and may reach a store; the render callback never calls it (`docs/audio-engine-realtime.md`).

Choices where the fixtures are silent:

| | Situation | Choice | Why |
|---|---|---|---|
| a | A record whose `pos` is <= 0.05 s (the fade-in threshold) | Starts like any start from the top (at A, `fresh`, points from A fire) but WITHOUT a fade-in | The fixture says a resumed start never fades in; the start path is the normal one, so up to 50 ms before A are not replayed exactly (a start from the top is at A) |
| b | A crossfade runs when the record is built | The NEW track (the player's `current`), at its own position | The show has moved to it; the old one is fading away and would not be heard after a restart |
| c | The file is in more than one playlist | The recorded playlist if it still holds the id (its recorded track if that still holds the id, else the first track there that does), otherwise the first playlist in order that holds it | Stays where the operator was whenever possible; deterministic otherwise |
| d | A voice-over on top / a trigger voice running | The background track and its position; the voice never. In the engine a voice-over IS the trigger voice (one `topDeck`); if only the voice still plays (its background ended), nothing is recorded | The spec: "the background track when a top track is on"; voices are not resumable |

Also decided here (not pinned): exactly `resume_max_age_s` still resumes (only "older than" is dropped); a negative age (the wall clock went back) counts as 0; `resume_on_start` off keeps the record
(no start); a save interval that is not a positive number falls back to 5 s; a wall clock that went back makes a save due at once; the track's own out-fade at B is NOT a fade-out (the record is
written); `pos` outside the window is held to it by the normal start path (a `pos` at or after B ends the track at once and what follows starts).

Integration work, not in this slice: the file-backed store, the "resumed after restart" notice to the operator, and wiring `ResumeController` to a control-thread timer and the app's library ids.
A possible later option, not part of this slice: a short declick ramp (5 to 10 ms) on the output stage for the first block after a resumed start.

## When the Python side bumps the spec

The Python rule is: a change to audio behaviour regenerates the fixtures and raises the spec version. Then, here:

1. Read the "Audio spec N" line in the Python `CHANGELOG.md` to see what changed.
2. `git rm -r Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<old>`, then run `scripts/sync-audio-spec.sh <python repo>`.
3. Run the tests. Until you change `AudioCore.implementedSpecVersion`, `SpecVersionTests` and every test fail with "spec_version N but the pinned version is M".
   That is on purpose: the pin is a statement that this code implements version N.
4. Look at the failing and the new cases. A new case name fails `testAllCasesHaveATest` of its file: add a test for it (and a protocol method if it needs one).
   A changed number fails the case that checks it: change `AudioCore` or the engine to match, or, if the Python change is a bug, say so on the Python side.
5. When everything that was passing passes again, set `AudioCore.implementedSpecVersion` to N and commit the fixtures, the code and the tests together.
