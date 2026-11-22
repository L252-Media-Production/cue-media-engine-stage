# CueME Stage

A native macOS presentation and visuals app for live AV work, from L252 Media Production. It combines
the content model of ProPresenter and FreeShow (songs, lyrics, scripture, timers, stage displays) with a
Resolume-style layered compositor and canvas, so one Mac can drive every display and cut out the latency of
chaining several computers together.

It sits alongside [CueME](https://github.com/L252-Media-Production/cue-media-engine), the audio cue player.

**Status:** engine spike. There is no operator UI yet (`CueMEStage` is a placeholder window), but the output
engine already drives SDI from Metal: 1080p59.94 output paced by the card clock, a canvas cut into screens for
several outputs, SDI input (IMAG) and NDI send and receive. Measured results, including a 4-hour two-card soak,
are in [docs/engine-spike-results.md](docs/engine-spike-results.md). Not built yet: audio, the app/engine IPC,
portrait output, and the editors. See [docs/design-v0.md](docs/design-v0.md).

## Layout

| Path | What it is |
|---|---|
| `Apps/StageEngine` | The output process (command-line tool). Runs the compositor and outputs. |
| `Apps/StageEngine/DeckLink` | Objective-C++ bridge to the DeckLink API: SDI output and input. |
| `Apps/StageEngine/NDI` | Objective-C++ bridge to the NDI SDK: send and receive. |
| `Apps/CueMEStage` | The operator UI app (SwiftUI). Placeholder for now. |
| `Packages/Engine` | Compositor, canvas, video loop and text layers, frame timing, the `OutputSink` protocol. Testable on its own. |
| `docs/` | Design notes, SDK setup and spike results. |
| `vendor/` | Local SDKs. Not committed. |
| `project.yml` | XcodeGen spec that generates the Xcode project. |

## Build

1. `brew install xcodegen`
2. Copy the SDKs into `vendor/` as described in [docs/sdk-setup.md](docs/sdk-setup.md).
3. `xcodegen generate` (creates `CueMEStage.xcodeproj`)
4. Open `CueMEStage.xcodeproj`, choose the `StageEngine` scheme and run.

With no arguments, StageEngine times a bare clock for a few seconds. Set arguments under
*Product > Scheme > Edit Scheme > Run > Arguments*, or pass them to the built tool in Terminal.
The common ones:

```
--list-decklink                              list DeckLink devices (index, output/input support)
--video /path/to/loop.mp4 --seconds 60       looping video with a text layer in Metal
--decklink 4 --depth 6                       send to a DeckLink output (one index per output)
--canvas 6000x1920 --screens "x,y,w,h;..."   canvas cut into screens, one per --decklink index
--sdi-in 0 --sdi-buffer 2                    use an SDI input as the video source
--ndi-list, --ndi-in NAME, --ndi-send NAME   NDI discovery, receive and send
--realtime                                   real-time scheduling for the render thread
```

Each run ends with a report of frame timing, GPU and CPU-encode time, skipped ticks and video underruns, plus
the card's own late and dropped counters when SDI is used. Run the package tests (they include a Metal shader
smoke test) with `swift test --package-path Packages/Engine`. StageKit has its own package tests (`swift test --package-path Packages/StageKit`); the app's
hosted tests (bundled fonts) run with `xcodebuild -project CueMEStage.xcodeproj -scheme CueMEStage test`.

SDK and driver notes (including why the bridge uses the v14.2.1 DeckLink interfaces) are in
[docs/sdk-setup.md](docs/sdk-setup.md).

## Requirements
macOS 14 or later, Apple Silicon, Xcode current. For SDI: Blackmagic Desktop Video.

## Licence
Not set yet.
