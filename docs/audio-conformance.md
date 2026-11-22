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
- `duck_loop` rows are matched by index, not by time (two rows share t = 0.5).
- The quirks table of `AUDIO-SPEC.md` is not reproduced. Clipping is not in the spec and is not tested.
- The WAV renders are not used yet. `renders.json` is loaded and its version checked; an envelope comparison comes with the real mixer.

## Design notes

- **`AudioSpecSubject` is a test-side adapter** over the real Stage types. The engine must not expose it, conform to it in production code, or take on the
  shape of Python's API (`set_trim`, `try_resume`, ...). The adapter translates a fixture question into whatever Stage's types offer.
- **`resume_flow` is adapted, not copied.** Stage has no `resume.json`; it autosaves show state. Keep the behaviour the fixture states (what is restored, the age
  limit, a resumed start never fades in, a deliberate stop or a running fade-out leaves nothing to resume) and map it onto the show-state autosave.
- **`duck_loop` must call the same hold-percentile function as `duck_curve`.** The `duck_loop` fixture cannot tell the 60th, 75th and 90th percentile apart;
  only `duck_curve_hold_percentile` can (its `_info_alternatives` lists the three depths). The test for it is pending on the subject until the engine
  provides `duckHoldDepthDb`.
- **Open: clipping.** The spec leaves clipping unspecified, so no fixture tests it. The harness refuses to build a signal that would clip 16 bits instead of choosing a policy.
- **Source:** the fixtures in this repo come from the Python repo's commit `fb87930` (branch `audio-spec`, spec version 1); see `Fixtures/spec-1/SOURCE.txt`.

## Engine types so far (slice 1: fades and crossfade)

`AudioCore` holds the first engine types, pure Swift with no hardware: `Transport` (injected frame clock, pause freezes play time), `Fade`, `Deck`,
`Mixer` (decks, crossfade, fade-out) and `CrossfadeSettings` (time precedence, own-time limits). Time moves only by `advance(frames:)`. Gains are ideal
values; the 128-step quantising of the Python mixer is not reproduced. `AudioCoreSubject` maps the fixture questions of `fades.json` and `xfade.json`
onto these types; the types do not follow Python's method names. The next slices (trim, fade-in at A, end actions) extend `Deck` and reuse `Transport`.

## Engine types, slice 2 (trim, fades at A and B, passes, end actions)

`Trim` (stored A, B, edges, fade lengths; `apply(_:fileLength:)` refuses a bad edit and changes nothing), `TrimPolicy`, `TrackPlan` (a window of the
file in frames, never a copy of audio; fades at both edges; `TrackEnd`), `Playback` (passes, remaining time and the out-fade derived by arithmetic from the
play frame) and `Mixer.ended` (decks that ended, at the exact frame). The spec text is copied to `docs/audio-spec-1.md` by `scripts/sync-audio-spec.sh`.

Rules that slice 2 took from the fixtures before the spec text stated them. Python commit `fb87930` pins each of them with a fixture case (and the spec text says them now), so
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

## When the Python side bumps the spec

The Python rule is: a change to audio behaviour regenerates the fixtures and raises the spec version. Then, here:

1. Read the "Audio spec N" line in the Python `CHANGELOG.md` to see what changed.
2. `git rm -r Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<old>`, then run `scripts/sync-audio-spec.sh <python repo>`.
3. Run the tests. Until you change `AudioCore.implementedSpecVersion`, `SpecVersionTests` and every test fail with "spec_version N but the pinned version is M".
   That is on purpose: the pin is a statement that this code implements version N.
4. Look at the failing and the new cases. A new case name fails `testAllCasesHaveATest` of its file: add a test for it (and a protocol method if it needs one).
   A changed number fails the case that checks it: change `AudioCore` or the engine to match, or, if the Python change is a bug, say so on the Python side.
5. When everything that was passing passes again, set `AudioCore.implementedSpecVersion` to N and commit the fixtures, the code and the tests together.
