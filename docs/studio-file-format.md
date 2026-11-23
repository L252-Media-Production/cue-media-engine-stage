# Studio file format

Status: format version 1, written for UI-3a (2026-11-22). Owner: JC (L252 Media Production).

A **Studio** is a saved, reopenable set of show data: songs, services, looks, screens and their layouts, timers,
messages, per-track audio settings and the media index. One Studio is open at a time. The app opens the last one
at launch; on first launch it creates `~/Documents/CueME Stage/Studio.stg`, seeded from the sample data.

Code: models and codec in `Packages/StageKit/Sources/StageKit/Studio*.swift` (Foundation only, no file IO);
reading, writing, locking, hashing and zip in `Apps/CueMEStage/Studio/`.

## The package

A Studio is a macOS package (a folder the Finder shows as one file) named `<Name>.stg`:

```
<Name>.stg/
  manifest.json      identity and version (below)
  library/<id>.json  one file per library item (songs; "presentation" is reserved for UI-3b)
  services/<id>.json one file per service
  audio.json         per-track audio settings, keyed by MediaItem id
  media.json         the media index: [{ id, name, kind, duration, size, sha256, lastKnownPath }]
  looks.json
  screens.json       screens by id and name with their layouts; NO connector assignments
  timers.json
  messages.json
  lock.json          who has the Studio open (see Lock); not show data
  cache/             rebuildable (peaks, transcodes); never read for correctness; may be deleted
```

`manifest.json`:

```json
{
  "activeServiceID" : "…",          // optional: the service that opens with the Studio
  "appVersion" : "0.1",              // the CueME Stage version that last wrote it
  "created" : "2026-11-22T20:00:00.000Z",
  "format" : "cueme-stage-studio",
  "formatVersion" : 1,
  "id" : "…",                        // UUID, stable for the life of the Studio; a copy gets a new one
  "modified" : "2026-11-22T20:05:00.000Z",
  "name" : "Sunday"
}
```

Rules:

- **JSON** is pretty-printed with sorted keys (so a Studio diffs well in git), dates are ISO-8601 with milliseconds
  (readers also accept them without). A list file that is missing counts as empty.
- **One file per item** for the library and services, so changing one song rewrites that song's file (and the
  manifest, whose `modified` date moves). Saves write only the files whose bytes changed.
- **Media is never inside a Studio**, only its index. The files live in media folders on each machine (see Media).
- **No secrets in a Studio, ever**: no network passwords, tokens, licence or device keys. A Studio is meant to be
  copied, mailed and checked into git. Anything secret belongs to the machine (and the Keychain), not here.
- **Output assignments are not show data.** `screens.json` keeps each screen's id, name, type, look, canvas rect and
  rotation; which connector drives it belongs to the machine (see Machine folder).

## Versions

- `formatVersion` higher than the app knows: refused before anything else is read, with the message
  "This Studio was made by a newer CueME Stage (file format N; this version reads up to M). Update CueME Stage to
  open it."
- Lower: the migration hook (`StudioCodec.migrations`, keyed by version N, turning N into N + 1) rewrites the raw
  files before they are decoded. Version 1 is the first, so none ship yet; the hook is tested with a fake version 0.
  A version with no migration step is refused.

## Saving

- **Atomic**: each file goes to a temp file in the same folder, is flushed with `F_FULLFSYNC`, then `rename(2)`
  replaces the old file. A crash or full disk leaves either the old file or the new one, never half of one; the temp
  file is removed on failure.
- **Autosave** about 1 s after the last change, on Close Studio, on switching Studios and on quit. Data files are
  written before the manifest. A failed save is shown to the operator as a notice and retried every 5 s; it never
  stops the app.

## Lock (`lock.json`)

```json
{ "machineID": "…", "machineName": "Mac Studio", "pid": 4242, "openedAt": "…", "appVersion": "0.1" }
```

`machineID` is a UUID made once per install and kept in the machine folder. A lock warns; it never blocks.

| Lock found | What happens |
|---|---|
| none | open |
| this process | open |
| this machine, process no longer running | stale: replaced silently |
| this machine, another running CueME Stage | warning |
| another machine | warning |

The warning names who has it and since when, with **Cancel** (the default button), **Open Anyway** (takes the lock)
and **Open a Copy** (a new package `<Name> copy.stg` with a new id, opened instead). A clean close removes the lock,
but only if it is still ours; another machine's lock is never deleted unless the operator chose Open Anyway.
A reused pid on this machine can make a stale lock look live; the warning still lets the operator open it.

## Machine folder

`~/Library/Application Support/CueMEStage/Machine/` holds what belongs to the Mac, shared by all Studios:

- `machine.json`: this install's id.
- `outputs.json`: connector assignments, keyed by **Studio id, then screen id**:
  `{ "version": 1, "studios": { "<studio id>": { "<screen id>": "<connector id>" } } }`.
  Keyed by Studio id as well as screen id because screen ids travel with copies and imported bundles: keyed by
  screen id alone, a copy and its original (or two imports of one bundle) would share, and fight over, the same
  connectors. A Studio opened on a machine for the first time has no entry, so its screens show Unassigned in
  Output Setup with the usual warnings; nothing is guessed.
- `media-folders.json`: the folders media lives in. Two Studios may point at the same folder; a file is never copied.
- `hash-cache.json`: SHA-256 by path + size + modification time, so a rescan only hashes new or changed files.

## Media and relink

Each media item has a stable id; trims, triggers and end actions hang off that id, so they survive a move or a
missing file. File > Relink Media… scans the machine's media folders in the background (cancellable): each index
entry is matched by `sha256` first, then by file name (from `lastKnownPath`, else `name`) and size. Results: found
(at its last path), relinked (elsewhere; the index is updated), missing, ambiguous (more than one candidate; nothing
changed). Hashing reads 1 MiB at a time, so a file of any size is hashed in bounded memory.

## .stgbundle (one Studio as one file)

A zip of the package folder, made with `/usr/bin/ditto -c -k --sequesterRsrc --keepParent`, without media, `cache/`
or `lock.json`. Import checks, before anything is unpacked: the bundle size (256 MB limit), the unzipped size (1 GB
limit), every entry name (no absolute paths, no `..`, exactly one top-level `.stg` folder) and the manifest's format
and version (read straight from the zip). Then it unpacks into a temp folder with `ditto -x -k`, refuses symbolic
links, and reads the Studio there.

Import Studio asks **Open as New Studio** (default) or **Replace Current Studio**. A new Studio goes to
`~/Documents/CueME Stage/`; a name in use gets " 2", " 3" … (never an overwrite), and an id in use (the open
Studio's) gets a new id. Replace keeps the open Studio's id, name, place and creation date and takes everything else
from the bundle.

## .stgitem (library items as one file)

```json
{
  "format": "cueme-stage-item", "formatVersion": 1,
  "kind": "song" | "presentation" | "message" | "timer" | "look" | "collection",
  "exported": "…", "appVersion": "0.1",
  "mediaRefs": [ { "id": "…", "name": "…", "size": 123, "sha256": "…", "kind": "video" } ],
  "items": [ { "kind": "song", "id": "…", "name": "Amazing Grace", "data": { … } } ]
}
```

`kind` is "collection" when the items are of more than one kind. `mediaRefs[].kind` is optional (an import without
it guesses from the file extension). One reader checks the header (format, a too-new version is refused, a known
header kind), then hands each item to the decoder registered for its kind. An unknown kind or unreadable data is
skipped and reported, never fatal. Song, message, timer and look decoders exist; presentation has none yet.
Importing asks, for each item whose id is already in the Studio: **Skip** (default), **Replace** or **Keep Both**
(new id), with "do the same for the rest". Media refs not in the Studio's index are added to it.

## Engine follow-up

Not implemented here (the engine is not involved yet; the mock loads Studios):

- The engine's resume record must carry the **Studio id**, so a restart never resumes audio (or slides) from
  another Studio.
- `Command.openStudio(id)` will need a way for the engine to find the package (a path, or a registry it shares
  with the app); the mock is given a source by the app.
