# CLAUDE.md

## Mockups

The UI mockups are the "CueME Stage – Operator View Mockup" design artifact:
<https://claude.ai/code/artifact/0fc9aac3-e1bc-43f0-b2b3-88856b6987d5>.
[docs/mockups/README.md](docs/mockups/README.md) indexes its boards by column and file, and
`docs/mockups/source/` holds a snapshot of the board files.

For any UI task:

- Before writing code, find the matching boards in the index and read them from the link.
  Use the snapshot when the link can't be read.
- Match the boards' layout, spacing and wording. Build with this codebase's own components and
  conventions, not the mockup's HTML.
- When the mockup and the app differ, the mockup wins, unless `docs/design-v0.md` says the design
  changed after the mockup. Do not restore the NEXT badge or the NEXT monitor (removed 2026-11-22).
- Boards tagged [After v0.1] or [v0.3] are not built yet. Build them only when the task asks for them.
- In your report, name the boards you checked (title and file).

### Intended differences from the boards

These differences are deliberate. When comparing the app with the boards, treat them as intended.

- **Clear block** (decided 2026-11-23, merged in PR #15). The boards show a worded Clear row below
  Previous / Next. The app has an icon-only block directly under the monitor: a header row with
  "CLEAR" and a scope dropdown labelled "All", then six equal-width icon buttons (All, Slide, Media,
  Audio, Message, Black), then Previous / Next. A layer that is on air is lit in the LIVE red and
  clicking it clears it. All is never lit. Black is the only toggle (amber, no border when off).
  Clear Audio fades over 2 s. Do not change this to match the boards.
- **Song editor** (decided 2026-11-23, merged in PR #14). It is its own window, one per song, not a
  takeover of the main window. Keep it that way.

If a board and the app differ and the difference is not listed here, the board wins, as before.
