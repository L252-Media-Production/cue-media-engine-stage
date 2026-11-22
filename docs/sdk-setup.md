# SDK setup

The Blackmagic and NDI SDKs are used for **building only**. They are not committed (their licences
do not allow redistributing the SDK itself). End users do not need either SDK.

## What end users need
- **Blackmagic Desktop Video** (the free driver) for DeckLink cards. It provides the DeckLink API at runtime.
- **NDI runtime**, unless we bundle the NDI library under NDI's licence terms (to be decided).

Before shipping to other people, read both SDK licences to confirm what may be included in a distributed app.

## What developers need locally
1. Install Xcode (current version) and XcodeGen: `brew install xcodegen`.
2. Install Blackmagic Desktop Video and reboot, then check the card appears in Blackmagic Desktop Video Setup.
3. Download the **Blackmagic DeckLink SDK** (free, needs a Blackmagic developer sign-in) and copy its
   Mac `include` folder to `vendor/DeckLinkSDK/include`.
4. Download the **NDI SDK** (free) and copy its `include` and `lib` folders to `vendor/NDISDK/`.

The `vendor/` folder is git-ignored apart from its README.

## Thunderbolt chassis
DeckLink Duo 2 cards are PCIe. On these Macs they sit in a Sonnet Echo III Thunderbolt chassis.
Connect the chassis directly to the Mac and confirm the cards are listed before testing.

## Driver versions and API compatibility

The SDK headers can be newer than the Desktop Video driver installed on a machine. A driver rejects
interfaces newer than itself (`E_NOINTERFACE`, plus `dlsym cannot find symbol ...` lines in the log).

CueME Stage therefore uses the `*_v14_2_1` interfaces from the SDK and compiles
`DeckLinkAPIDispatch_v14_2_1.cpp`. Drivers from 14.x through 16.x understand them, so the same build
runs on the Mac Studio's Desktop Video 15.1 and on newer drivers. Frames are wrapped around the Metal
pixel buffer without copying (`PixelBufferFrame` in `DeckLinkOutputBridge.mm`).

Check a machine's driver version with:

    defaults read /Library/Frameworks/DeckLinkAPI.framework/Resources/Info CFBundleShortVersionString

## NDI

NDI is loaded at run time (`dlopen`), so the build needs only the SDK **headers** in `vendor/NDISDK/include`.
`libndi.dylib` is searched for in this order: `$STAGE_NDI_LIB`, `$NDI_RUNTIME_DIR_V6`,
`/usr/local/lib`, `/Library/NDI SDK for Apple/lib/macOS`, the app's Frameworks folder, then the default
library path. Installing the NDI SDK or NDI Tools is enough on a development Mac.

Test commands (StageEngine scheme arguments):

    --ndi-list                                        list sources on the network
    --video FILE --ndi-send "CueME Stage"             send a looping video as NDI
    --video FILE --decklink 4 --ndi-send "CueME Stage" SDI and NDI together
    --ndi-in "Camera" --decklink 4                    NDI input (for example IMAG) out of SDI

## SDI input (IMAG) loopback test

Set one connector to **Input** in Desktop Video Setup (each Duo 2 connector is its own device) and check that
`StageEngine --list-decklink` shows `input=yes` for it. Without a camera, loop an output into it:

```
# process A: play a loop out of connector 7 (route 7 -> input 1 on the video hub)
StageEngine --video "<file>" --decklink 7 --depth 6 --seconds 600

# process B: capture connector 1 and send it out of connector 4
StageEngine --sdi-in 1 --decklink 4 --depth 6 --seconds 300
```

Process B ends with `sdi input` (signal, detected format, frames captured, no-signal frames, format changes),
`sdi cadence` (repeated and skipped input frames) and `sdi` (GPU unpack time) lines. The source and the output
run on separate clocks, so an occasional repeated or skipped frame is expected until the clocks are locked;
the interval between them shows how far apart the clocks run. Only 1920x1080 input is handled.

## Canvas test (one big canvas, several screens)

```
# three 1080p screens side by side on a 5760x1080 canvas, three SDI outputs (first one sets the pace)
StageEngine --canvas 5760x1080 --decklink 4,0,5 --depth 6 --seconds 300

# a bigger canvas with a video covering it, screens placed by hand (x,y,w,h; separated by ;)
StageEngine --canvas 6000x1920 --video "<file>" --decklink 4,0 \
  --screens "0,0,1920,1080;1920,0,1920,1080" --seconds 300
```

Each output shows a 1920x1080 cut of the canvas. The test pattern has a numbered, coloured border per screen
(screen N has N squares at the top left), a 12-bit binary frame counter at the bottom left of each screen, and a
white bar that crosses the whole canvas every 4 seconds. Placed side by side, the bar should move across the
seams without a jump; a screen whose bar runs ahead or behind its neighbour shows the phase offset between cards.
The report's `gpu` line is the whole frame (canvas plus every screen cut).

### Compositions: master and per-screen layers

The canvas follows the design notes: one **master** composition spans the whole canvas, and every screen has its
**own composition** at the screen's size, drawn on top of the master slice beneath it. In code
(`Packages/Engine/Sources/Engine/Composition.swift`) a `CompositionLayer` has a content (video source, text layer or
the test pattern), a rectangle inside its composition, an opacity and a fit (stretch, cover, contain);
a `ScreenComposition` has a canvas rectangle, a `showMaster` switch and its own layers.

```
# each screen gets its own text layer (screen number and time) on top of the master
StageEngine --canvas 3970x1080 --decklink 4,0 --screens "0,0,1920,1080;1990,0,1920,1080" --screen-text --seconds 120

# screen 2 shows only its own layers (master off): it should be black with just its text
StageEngine --canvas 3970x1080 --decklink 4,0 --screens "0,0,1920,1080;1990,0,1920,1080" --screen-text --no-master 2 --seconds 120
```
