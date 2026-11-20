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
- The render-loop "late" counter reflects scheduling jitter that the card's buffer absorbs. Judge health by the
  card counters and `lowestBuffered`.

## Not yet tested

- 30 fps 4K clip, SmartView judder with 25 fps content, and the loop restart seam.
- Soak with real service load (ProPresenter/CueME running alongside), and one longer than 4 hours.
- Genlock / reference input.
