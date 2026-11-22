# Audio engine: real-time rules

**Status: nothing here has been run or proven on a real audio thread.** The engine (`Packages/Engine/Sources/AudioCore`) is pure Swift driven by `advance(frames:)` from tests. The rules below
are what the code is written to, what the tests check where they can (heap block counts around starts and advances, storage capacities that never change), and what the AudioUnit render callback
will be held to. No render callback exists yet, no thread has called this code, and no real-time safety tool (for example a sanitizer for real-time violations) has been run on it.

## Rules in force on the hot path

The hot path is `PlaylistPlayer.advance(frames:)` and everything it calls (`Mixer.advance`, `Mixer.start`, `Mixer.startOnTop`, `TriggerWatch.observe` / `nextEvent`, `PlayOrder.successor`,
`ShuffleBag.draw`, `Deck.gain(at:)`, `Playback` position maths).

- **No allocation.** Storage is allocated once in `init` (the deck pool, the ended buffer, the fired buffer, the trigger watch, the shuffle bags) and reused in place. Arrays on the hot path are only
  mutated within their reserved capacity or at a fixed count; none grows.
- **No locks, no waiting, no I/O, no logging, no Foundation, no `Date` or wall clock.** Time is the frame count given to `advance`.
- **Value types.** The engine is structs and enums. The only references are the arrays inside them and the two protocol values `readiness` and `ducking` (see "Risks").
- **No unbounded loops.** A pass over the pool is `poolCapacity` long (16); a trigger pass is at most `TriggerList.capacity` (64); chained starts in one call are capped (`maxStartsPerAdvance` 64); events
  at one frame are capped (8).
- **Failure is a counter, never a crash.** Things that do not fit are dropped and counted.

## The deck pool

`Mixer` holds `Mixer.defaultPoolCapacity` = **16** deck slots, allocated once in `init(sampleRate:poolCapacity:)`. A deck is addressed by a `DeckID` (slot and generation). When a deck has ended its
slot can be reused by a later start, oldest end first; the old handle is then refused (`Mixer.deck(_:)`, `gain(of:)`, `seek`, `finishCurrentPass` ignore it), so it can never read another deck.
What a finished deck leaves behind is its `Mixer.DeckEnded` record (exact end frame and the gain of the last frame it played), delivered in `Mixer.ended` by the `advance` that saw it end.

Why 16: a normal show needs 3 at once (the live track, the one fading out of a crossfade, a voice on top). The most the tests reach is 4 (the old track and its voice fade out together while the new
track fires its own voice: `AudioCorePoolTests.testCrossfadesTriggersAndLoopsStayInsideThePool`). The rest is headroom for several crossfades stacked on each other (the operator pressing Go again during a
crossfade) and for ended decks that have not been recycled yet.

If the pool is full of decks that play:
- a **cut** start always succeeds: it removes the decks that play, which frees their slots;
- a **crossfade** start or a **voice on top** needs a slot besides the decks that keep playing. It is refused: `Mixer.start` / `startOnTop` return `DeckID.none` (`isValid` false), nothing is started, faded or
  stopped, and `counters.poolExhausted` goes up. `PlaylistPlayer.play` returns false and the track that played keeps playing; a trigger whose voice has no slot is given up on.

## Counters

`EngineCounters` (monotonic, readable as `Mixer.counters` and `PlaylistPlayer.counters`): `droppedEnds` (ended decks that did not fit in the 32-slot `Mixer.ended`), `droppedFires` (trigger fires that did not fit
in the 32-slot `PlaylistPlayer.fired`), `poolExhausted` (refused starts). Also counted where they happen: `TriggerList.overflowCount` (a point refused because the track already has 64). `Mixer.droppedEnds`
and `PlaylistPlayer.droppedFires` are the same events for the last call only. None of them should ever be non-zero in a normal show.

## Allocations that remain (setup paths, never on the render callback)

- `Mixer.init`: the pool and the ended buffer. `PlaylistPlayer.init`: the fired buffer, the trigger watch (two fixed arrays of 64), a copy of the playlists, and the boxes of the `readiness` and `ducking`
  protocol values if they are larger than three words.
- `Playlist` / `ShuffleBag`: reserving the bag when the tracks of a playlist change (`Playlist.tracks` `didSet`); `Playlist.mode` change (resets the bag in place, no allocation).
- `TriggerList.add` (reserves 64 points on the first add), `remove`, `setEnabled`; `PlaylistPlayer.addTrigger` / `removeTrigger` / `setTrigger` (they also remap the watch, which does not allocate).
- `PlaylistPlayer.setMode` / `setEnd`, any edit of `Playlist.tracks` (array mutation, can allocate).
- `PlayOrder.nextInOrder` (returns an array; the audio thread uses `successor`).
- `Mixer.decks` (builds and sorts an array) and any test-side helper: for tests and UI only.
- `TrackPlan` / `Trim` construction does not allocate, but `Trim.apply` and the harness are setup code.

## What the AudioUnit render callback may and may not call

May call (after the setup above): `PlaylistPlayer.advance(frames:)` in steps of the block size; `play`, `stop`, `seekLive`, `skipNextTrigger`, `pause`, `resume` if the commands reach the callback through a
queue that is itself lock-free and allocation-free (that queue does not exist yet); reading `Mixer.live`, `playingCount`, `deck(_:)`, `gain(of:)`, `ended`, `fired`, `counters`.

May not call: anything in the list of remaining allocations above; anything of the resume slice (`Resume`, `PlaylistPlayer.resumeRecord` / `startResume`,
`ResumeController`, a `ResumeStore`, a `WallClock`: control thread only, see `docs/audio-conformance.md` "Slice 8"); `Mixer.decks`; anything that touches a file, the decode cache, a log, or an object with a lock. The readiness answer (`TargetReadiness`)
and the ducking hook (`DuckingHook`) are called from `advance`: their real implementations must obey the same rules (a readiness answer reads a flag the decoder thread has set; it never decodes or waits).

## Risks that look relevant for the audio thread (not measured)

- `readiness` and `ducking` are stored as `any` protocol values: calls go through witness tables; a value larger than three words is boxed (heap) at init. Keep the real ones small (a class reference).
- Reading `playlists[p].tracks[i].triggers` and copying a `Deck` out of the pool (`Mixer.deck(_:)` returns a copy) retain and release array buffers: atomic reference counting, not locks, but not proven
  free of contention if another thread holds the same buffers. The UI must not share the engine's arrays.
- Swift's runtime may fill lazy caches (type metadata, `swift_once`) the first time a path runs. The allocation test warms every path up first; the first render callback should be preceded by a warm-up run.
- Exclusivity checking and array uniqueness checks cost time on every mutation. Not a correctness issue; worth profiling.
- `PlaylistPlayer.advance` does a linear pass over 16 slots several times per event; fine at today's sizes, unmeasured.
