# Engine spike results (SDI output)

Machine: Mac Studio (M1 Max), Desktop Video 15.1 driver, two DeckLink Duo 2 cards in Sonnet Echo III
chassis, monitored on a rack SmartView. Release build, 1080p59.94, 8-bit YUV out (BT.709), card-clocked
pacing, `StageEngine` at commit `ed3de08` (2026-11-20). "late" and "dropped" are the card's own counters.

| Test | Result |
|---|---|
| 1 output, 1080p H.264 loop, 60 s | late=0 dropped=0 |
| 1 output, 4K H.264 25 fps, 60 s, depth 4 | late=0 dropped=0, lowest buffer 2/4, GPU 0.57 ms mean / 1.08 ms max, no decode underruns |
| 2 outputs, same card (101 + 102), 300 s, depth 6 | both late=0 dropped=0, lowest buffer 4/6, 0 follower skips/repeats |
| 2 outputs, two cards (101 + 205), 300 s, depth 6 | both late=0 dropped=0, lowest buffer 4/6, 0 follower skips/repeats |
| 2 outputs, two cards (101 + 205), **4 hours**, depth 6, 1080p H.264 loop | both 863,137 frames, late=0 dropped=0 flushed=0, lowest buffer 3/6, 0 follower skips/repeats, 0 video underruns, 0 render errors |
| SDI input (IMAG path), 300 s: source on card 205 (index 0) -> hub -> capture 207 (index 1) -> output 101 (index 4), depth 6, `--sdi-buffer 2` | capture 18,087 frames, 15 no-signal at start, 0 repeated / 0 skipped input frames, mean queue depth 2.00, output late=0 dropped=0 flushed=0, lowest buffer 3/6, GPU unpack 0.4 ms mean / 0.9 ms max |
| Canvas 3840x1080 (pattern only), 2 screens -> cards 101 + 205, 300 s, depth 6 | both late=0 dropped=0, lowest buffer 4/6, 0 follower skips/repeats, GPU 0.61 ms mean / 10.2 ms max, render loop 14 late (max 36 ms) |
| Canvas 6000x1920 (11.5 MP) with the 1080p "Art Alive Bits" video covering it + pattern, screens cut from opposite corners (0,0 and 4080,840) -> cards 101 + 205, 300 s, depth 6 | both late=0 dropped=0, lowest buffer 4/6, 0 follower skips/repeats, GPU 1.16 ms mean / 7.7 ms max, CPU encode 0.48 ms, render loop 7 late (max 37.5 ms) |

Earlier run at depth 4 (same card, before text drawing moved off the render thread): 1 dropped frame per
output, caused by a render-thread stall from redrawing text once a second.

## Findings

- SDI output is solid at these loads. Depth 6 (about 100 ms) gives plenty of margin; depth 4 was fine for one output.
- The Duo 2 takes YUV only at 1080p59.94 (no BGRA), so the compositor converts on the GPU in the same command buffer.
- Desktop Video 15.1 drivers reject the SDK 16.0 interfaces. The bridge uses the `*_v14_2_1` interfaces, which
  work with 14.x to 16.x drivers (see `sdk-setup.md`).
- Two cards without genlock showed no drift events in 5 minutes. Drift builds slowly, so a long soak test is still needed.
  Without genlock the two outputs also have a random phase offset (up to one frame), which would show as a
  seam between side-by-side displays showing one continuous canvas.
- 4-hour soak (2026-11-20): the frame count matches 4 h at 59.94 fps exactly (863,136 expected), so the card clock
  and the pacing agree. Neither card pulled more than one frame away from the other in 4 hours (no follower
  skips or repeats), so the two un-genlocked cards drift slowly enough for a typical service. The render loop
  logged 499 late frames (0.06%, max 61 ms, p99 19.8 ms) at random times; the queue absorbed all of them
  (lowest buffer 3/6) and no card counter moved.
- SDI input: taking the newest captured frame at render time gave 488 repeated + 488 skipped frames in 300 s
  (capture/render timing jitter, not clock drift). Passing captured frames through a short in-order queue
  (default 2 frames, about 33 ms) reduced that to 0 / 0. The source and output were on different cards, and no
  clock-drift event showed in 300 s; a longer run is needed to measure the real drift interval.
- Starting a second StageEngine process while another runs can stall the first for 50-75 ms (lowest buffer 2/6,
  no card counter moved).
- SmartView Duo (two 8 in, 800x480 panels): a canvas gap of 130 px between the two 1920x1080 screens (`--canvas 3970x1080
  --screens "0,0,1920,1080;1990,0,1920,1080"`) made the sweeping bar look continuous across the bezel. The photo-based
  estimate (340 px) was too large. 120 s run: both cards late=0 dropped=0, lowest buffer 5/6, GPU 0.62 ms mean.
- The render-loop "late" counter reflects scheduling jitter that the card's buffer absorbs. Judge health by the
  card counters and `lowestBuffered`.

## IMAG (SDI capture) latency, 2026-11-21

Setup: source `--canvas 1920x1080 --decklink 7 --depth 6` (stamps host uptime in ms into the picture), hub, capture
`--sdi-in 1 --decklink 4`, 120 s runs on the Mac Studio. Latency is computed inside the capture process from the stamp.

| Capture settings | Card | Capture queue wait | Cadence (repeat / skip / trim) | Engine-side IMAG estimate |
|---|---|---|---|---|
| depth 6, buffer 2 | late=0 dropped=0, lowest 4/6 | 21 ms | 0 / 0 / - | ~140 ms (8 frames) |
| depth 4, buffer 1 | late=0 dropped=0, lowest 2/4 | 21 ms | 3 / 2 / - | ~105 ms |
| depth 3, buffer 1 | late=0 dropped=0, lowest 2/3 | 21 ms | 1 / 0 / - | ~90 ms |
| depth 2, buffer 1 | late=5 dropped=13, lowest 0/2 | 21 ms | 2 / 1 / - | fails |
| depth 3, buffer 1, `--realtime` | late=0 dropped=0, lowest 1/3 | 14 ms | 26 / 0 / 25 | ~80 ms, judder |
| depth 2, buffer 1, `--realtime` | late=5015 (card falls behind) | 13 ms | 21 / 1 / 23 | fails |
| **depth 3, buffer 2, `--realtime`** | late=0 dropped=0, lowest 1/3 | 22 ms | **0 / 0 / 0** | **~88 ms (5 frames)** |

- Source render to capture arrival is about 101 ms, which is the source's own 6-frame output queue; the hub and the
  two card hops add under a frame. Panels read on an iPhone NDI feed showed about 6 frames between the source and
  the capture panel at depth 6 (within the phone's +/-2 frame accuracy).
- Engine-side IMAG estimate = capture queue wait + output depth x 16.7 ms + about one frame in the card.
- The capture queue never shrinks by itself (one pop per arrival), so one late render tick left `--sdi-buffer 1`
  stuck at 2 frames. The source now drops one frame after 2 s above target (`trimmed`).
- `--realtime` (time-constraint scheduling plus no App Nap) cut late render ticks from 11 to 4-6 per 120 s.
- Output depth 3 is the minimum that holds; depth 2 fails even with `--realtime`.
- Recommended IMAG setting for now: `--depth 3 --sdi-buffer 2 --realtime`.
- Open: occasional CPU encode spikes (13-18 ms) and late ticks up to 36 ms; needed before depth 2 / 3 frames is possible.

## Not yet tested

- 30 fps 4K clip, SmartView judder with 25 fps content, and the loop restart seam.
- Soak with real service load (ProPresenter/CueME running alongside), and one longer than 4 hours.
- SDI input over 30+ minutes (drift interval), and a real camera or ProPresenter feed instead of a loopback.
- Phase offset between cards: film both counters in slow motion (the 12-bit frame counter at the bottom left of each screen).
- Genlock / reference input.
