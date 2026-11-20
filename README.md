# CueME Stage

A native macOS presentation and visuals app for live AV work, from L252 Media Production. It combines
the content model of ProPresenter and FreeShow (songs, lyrics, scripture, timers, stage displays) with a
Resolume-style layered compositor and canvas, so one Mac can drive every display and cut out the latency of
chaining several computers together.

It sits alongside [CueME](https://github.com/L252-Media-Production/cue-media-engine), the audio cue player.

**Status:** early scaffold. Nothing here is usable yet. The first milestone is the *engine spike*:
prove a stable 1080p60 SDI output while compositing video and text in Metal. See
[docs/design-v0.md](docs/design-v0.md).

## Layout

| Path | What it is |
|---|---|
| `Apps/StageEngine` | The output process (command-line tool). Runs the compositor and outputs. |
| `Apps/CueMEStage` | The operator UI app (SwiftUI). Placeholder for now. |
| `Packages/Engine` | Compositor, frame timing, the `OutputSink` protocol. Testable on its own. |
| `Packages/DeckLinkBridge` | DeckLink SDI output (stub until the SDK wrapper is built). |
| `docs/` | Design notes and setup guides. |
| `vendor/` | Local SDKs. Not committed. |
| `project.yml` | XcodeGen spec that generates the Xcode project. |

## Build

1. `brew install xcodegen`
2. `xcodegen generate` (creates `CueMEStage.xcodeproj`)
3. Open `CueMEStage.xcodeproj`, choose the `StageEngine` scheme and run.

Without any hardware, StageEngine times a 60 Hz clock for 5 seconds and prints a summary. Run its package
tests with `swift test --package-path Packages/Engine`.

SDK setup for DeckLink and NDI is in [docs/sdk-setup.md](docs/sdk-setup.md).

## Requirements
macOS 14 or later, Apple Silicon, Xcode current. For SDI: Blackmagic Desktop Video.

## Licence
Not set yet.
