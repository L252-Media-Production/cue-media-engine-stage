# Audio conformance

The audio engine of CueME Stage (Swift / Core Audio) has to sound the same as the Python Cue Media Engine. The contract is
`docs/AUDIO-SPEC.md` in the Python repo plus its golden fixtures (JSON, and four reference WAVs). This repo holds a **copy** of the fixtures,
a test harness that reads them, and the first pieces of engine maths that pass them.

Everything lives in the Engine package and needs neither Desktop Video nor the NDI SDK:

| Where | What |
|---|---|
| `Packages/Engine/Sources/AudioCore/` | Pure maths (no state, no I/O, `Double`). Depends on nothing. |
| `Packages/Engine/Tests/AudioCoreTests/` | The harness and the tests. |
| `Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<N>/` | The synced fixtures of spec version N, plus `SPEC_VERSION` and `AUDIO-SPEC-LINE1.txt`. |
| `scripts/sync-audio-spec.sh` | Copies the fixtures from the Python repo. |

## Sync the fixtures

```
scripts/sync-audio-spec.sh /path/to/cue-media-engine
```

It reads the Python repo (never writes to it) and replaces `Fixtures/spec-<N>/`, where N is the number on the first line of the Python
`docs/AUDIO-SPEC.md` (`Spec version: N (...)`). It refuses to copy when any file says another `spec_version`. Commit the result (about 1.5 MB).
Sync from a clean, committed state of the Python repo: the fixtures are generated files and a working tree can hold a half-finished regeneration.

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

- Gains are compared within the file's `tolerance` (`tolerance_lufs` for LUFS, `tolerance_s` for times). Nothing is hard-coded, except the two documented
  allowances below. The fixtures hold the ideal `Deck.vol`, not a quantised mixer volume.
- Trigger and end times are compared with the `ideal_*` values, never with the measured Python values (they include the 50 ms tick).
- Shuffle: only the listed properties are checked, never the sequence.
- `duck_loop` rows are matched by index, not by time (two rows share t = 0.5).
- The quirks table of `AUDIO-SPEC.md` is not reproduced. Clipping is not in the spec and is not tested.
- The WAV renders are not used yet. `renders.json` is loaded and its version checked; an envelope comparison comes with the real mixer.

Two allowances on top of a file tolerance, both on one column and both named in the code:

- `duck_loop` `bg_multiplier`: `tolerance + 0.0005` (Python only writes the multiplier when it moved by more than that; quirk 9).
- `duck_curve` reductions: `tolerance + 2e-5` dB (`pythonFloat32KeyNoiseDb`). The Python key is float32 and its noise is larger than the file's 2e-6 on quiet windows.
  Remove it when the Python side computes the key in float64 or widens the tolerance.

## When the Python side bumps the spec

The Python rule is: a change to audio behaviour regenerates the fixtures and raises the spec version. Then, here:

1. Read the "Audio spec N" line in the Python `CHANGELOG.md` to see what changed.
2. `git rm -r Packages/Engine/Tests/AudioCoreTests/Fixtures/spec-<old>`, then run `scripts/sync-audio-spec.sh <python repo>`.
3. Run the tests. Until you change `AudioCore.implementedSpecVersion`, `SpecVersionTests` and every test fail with "spec_version N but the pinned version is M".
   That is on purpose: the pin is a statement that this code implements version N.
4. Look at the failing and the new cases. A new case name fails `testAllCasesHaveATest` of its file: add a test for it (and a protocol method if it needs one).
   A changed number fails the case that checks it: change `AudioCore` or the engine to match, or, if the Python change is a bug, say so on the Python side.
5. When everything that was passing passes again, set `AudioCore.implementedSpecVersion` to N and commit the fixtures, the code and the tests together.
