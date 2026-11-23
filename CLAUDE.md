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
