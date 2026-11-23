# Operator view: app vs mockup

Compared 2026-11-22 on `origin/main` at `8003751`. Report only: nothing in the app was changed.

## How this was checked

- **Mockup.** The boards were read from the artifact link in [README.md](README.md). The live artifact is version
  `1795369998-1dcd`, and its file hashes match the snapshot in [source/project/](source/project/), so the line numbers
  below refer to those files. Mockup values come from the board HTML and CSS (inline styles and the `renderVals()`
  script). `Main.dc.html` is abbreviated `Main`.
- **App, rendered.** A temporary XCTest, run in the app's test host and not committed, rendered `OperatorView`
  offscreen in an `NSHostingView` (`cacheDisplay`) on the mock engine with the sample library. It rendered 1440x900
  and 1100x720, Dark Aqua and Aqua, in three states: idle; *live* (Walk-in loop playing, Amazing Grace Verse 2 live
  and selected); and *live + blackout*. These are offscreen renders, not screenshots of the running app. The window
  was borderless, so the title bar was not rendered.
- **App, menus.** The same test host dumped the real `NSApp.mainMenu` (titles, key equivalents, enabled state after
  `menu.update()`). The test host has no Studio and no window open, so enablement in the dump is for that state. The
  code ([StageMenuCommands.swift](../../Apps/CueMEStage/StageMenuCommands.swift)) gives the rest.
- **App, values.** Sizes, colours and fonts come from the code that drew the renders:
  [OperatorView.swift](../../Apps/CueMEStage/OperatorView.swift), [Theme.swift](../../Apps/CueMEStage/Theme.swift),
  [OperatorModel.swift](../../Apps/CueMEStage/OperatorModel.swift).
- **Sizes.** The mockup is drawn at 1440x900 only and has no responsive rules. At 1100x720 only the app's behaviour
  is described, so mockup proportions at that size are "not checked".
- **Skipped.** Boards tagged [After v0.1] or [v0.3]; the Scripture, Media, Looks and Activities tab contents; Output
  Setup.

Kind: Missing / Wrong value / Wording / Extra (in the app, not in the mockup) / Intentional (a recorded decision).
Severity: 1 = wrong or missing behaviour or a control, 2 = clearly visible difference, 3 = small polish.
"(not built)" in the fix column means the feature behind the control does not exist yet, so the fix is the feature,
or a disabled placeholder until then.

## 1. Operator view – dark (`Main.dc.html`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Overall layout | Three columns: service 280 px, slide grid (flex), right column 360 px holding the monitor, Previous/Next, Clear and Audio/Message/Timer tabs. The bottom panel spans only service and grid (Main L44–49, L512) | Service 240 pt, then one centre column: monitor row on top, slide grid, transport bar, bottom tabs (OperatorView.swift:30–80). No right column (render) | Wrong value | 2 | Move monitor, transport, Clear and the tabs into a 360 pt right column. Settle the monitor question first (see Contradictions 1) |
| Window title | Custom 38 px title bar: app icon 20 px + service name "Nov 22 Service", weight 600 (Main L30–37) | Standard title = Studio name or "No Studio" (OperatorView.swift:65, StudioController.swift:48). Not rendered (borderless) | Wording | 3 | Decide service name or Studio name; Studio is newer than the mockup |
| Service panel width | 280 px (Main L49) | 240 pt (OperatorView.swift:34); renders 240 at both sizes | Wrong value | 2 | 280 |
| Service panel background | `var(--chrome)` #202020 (Main L49, L844) | `theme.surface` #1A1C1F (OperatorView.swift:111, Theme.swift:23) | Wrong value | 3 | Map to the chrome token (see token rows) |
| Search collections | 28 px field with magnifier, "Search collections" (Main L51–54) | None | Missing | 1 | (not built) collections |
| COLLECTIONS list | Label, "+ New" in accent, tree: Worship Songs 142, Presentations 24, Announcements 18 (Main L55–58, L870–889) | None | Missing | 1 | (not built) |
| Service header | Picker button 30 px, `font-weight:700`, "Nov 22 Service ▾" (Main L62) | `PanelHeader`: "SUNDAY 10:00", JetBrains Mono 11 semibold, uppercase, secondary colour (OperatorView.swift:93, 729–742) | Wrong value | 2 | Service name as a 30 pt picker in body text, bold, with ▾ |
| "+ Add ▾" | Accent text button next to the picker (Main L63) | None in the panel | Missing | 1 | Add it (see MainAddMenu) |
| ITEMS row | "ITEMS" label + total "1:12:00", mono 11 dim (Main L76) | None | Missing | 3 | Add when item durations exist |
| Section headings | PRE-SERVICE, WORSHIP, WORD, CLOSING in the label style (Main L79, L900–915) | Flat list (render) | Missing | 2 | Sections in the service list |
| Row content | Two lines: title 13/600 + sub-line 11 dim (e.g. "Default · ♪ track_01"), meta on the right in mono 11 ("4:12", "→ Lobby TV" accent, "⚠ Missing" warn) (Main L84–86, L921–923) | One line, title regular, semibold when live; no sub-line or meta (OperatorView.swift:141–145); rows 28 pt apart (render) vs about 42 px | Missing | 2 | Add sub-line and meta |
| Drag handle | "⋮⋮" 10 px, dim, opacity .6 (Main L82) | None | Missing | 3 | (not built) reordering |
| Row icons | 15 px stroke SVGs per type: note, book, presentation, TV, film strip, camera, chat (Main L83) | SF Symbols `music.note.list`, `waveform`, `rectangle` in a 16 pt frame (OperatorView.swift:153–158) | Wrong value | 3 | Use the mockup's glyphs (Lucide-style) or the closest SF Symbols per type |
| LIVE row marker | `box-shadow: inset 3px 0 0 var(--live)` + chip "LIVE": 9 px/700, body font, padding 1×6, radius 4 (Main L85, L927) | 3 pt red bar + `Chip`: JetBrains Mono 9 bold, padding 5×1, radius 3 (OperatorView.swift:135–145, 761–775) | Wrong value | 3 | Chip in the body font, padding 6×1, radius 4 |
| Selected row | `background: var(--sel)` #1f3a29 (green tint), title weight 700 (Main L924, L927) | System `List` selection: grey when the list is not focused (render), no weight change | Wrong value | 2 | Custom selection background with a `sel` token |
| Footer hint | None | "Double-click or Return takes an item live", caption (OperatorView.swift:106) | Extra | 3 | Remove or keep as a tooltip |
| Slide grid header | Item title 15 px/700, file chips (11 px pills), "Send to ▾", "Edit ✎" (Main L95–104) | `PanelHeader` "AMAZING GRACE": mono 11 semibold uppercase, secondary colour (OperatorView.swift:353) | Wrong value | 2 | Title 15 pt bold in body text |
| File chips | "loop_blue_01.mov", "♪ track_02.wav", radius 10, 11 px (Main L98–99) | None | Missing | 3 | Show the item's background and track |
| Send to ▾ | "Send to Default (audience screens) ▾"; menu SEND THE NEXT GO TO with 4 targets (Main L103, L930–945) | None | Missing | 1 | (not built) per-Go targets |
| Edit ✎ | Accent link 12/600 (Main L104) | None | Missing | 1 | (not built) editors |
| Slide groups | Group labels "VERSE / CHORUS", "VERSE 2 / BRIDGE" above each block (Main L117–119, L1279) | One ungrouped grid | Missing | 2 | Group by song section |
| Grid columns | `repeat(4, minmax(0,1fr))`, gap 10, padding 14×18 (Main L116, L120) | `GridItem(.adaptive(minimum: 190))`, spacing 12, padding 12 (OperatorView.swift:349, 376, 384): 3 columns at 1440 and at 1100 (renders) | Wrong value | 2 | 4 fixed columns, gap 10, padding 14/18 |
| Slide card layout | Picture first, then a footer: label left, number right in mono, 11 px dim, padding 4×8 (Main L122–124) | Header first: number mono 11 bold + label caption semibold on `surfaceRaised`, then picture (OperatorView.swift:424–443) | Wrong value | 2 | Footer below the picture as in the mockup |
| Slide picture | `linear-gradient(135deg,#1c3a5e,#0d1b2e)`, text 12 px, line-height 1.35 (Main L123) | Black, 12 pt semibold (OperatorView.swift:440–443, 333) | Wrong value | 3 | Gradient only as a placeholder background; real slides show their background |
| Live slide marker | Border 2 px `var(--live)`, no chip (Main L851) | Border 3 pt live + "LIVE" chip in the header (OperatorView.swift:432–434, 448) | Wrong value | 3 | 2 pt border, no chip, or keep the chip and record it as a decision |
| Monitor | One 16:9 monitor in the right column, 336 px wide, border 2 px in the status colour; picker above it: 8 px status dot, name 600, status chip mono 10/700 "LIVE" red or "BLACK" amber, "⊞" Multiview toggle (Main L515–519, L541, L964–968) | One monitor per output screen in a row, 383 pt each at 1440 and 270 pt at 1100; titles mono 11 bold uppercase, red when on air; caption on the right (OperatorView.swift:171–301, renders) | Wrong value | 2 | Owner to decide (Contradictions 1). If the mockup wins: picker + one monitor + Multiview grid |
| Monitor in blackout | "BLACK", `var(--warn)` amber, mono 12, letter-spacing .1em (Main L562) | "BLACKOUT", `theme.live` red, mono 12 bold (OperatorView.swift:248, render) | Wrong value | 2 | "BLACK" in the warning colour |
| Stage monitor picture | Stage Screen 1 shows song, timer "04:12" and "Next: …"; Stage Screen 2 shows clock, "Next slide", message (Main L545–560) | STAGE monitor shows the audience slide text (render) | Intentional | – | design-v0.md "Operator (run) view": no next slide in the operator view. Showing the stage layout without "Next" stays open |
| Previous / Next | In the right column, 32 px, each `flex:1`; "◀ Previous" on panel; "Next ▶" accent fill, 700, text #0d0d0d (Main L574–575) | Transport bar under the grid: system bordered buttons, SF chevrons, "Previous" and "Next" styled alike, about 22 pt (OperatorView.swift:475–476, render) | Wrong value | 2 | Next as the primary accent button, 32 pt, full width pair |
| Clear controls | "CLEAR" label, scope picker, six buttons All / Slide / Media / Audio / Message / Black, 28 px, 12 px text (Main L589–596, L975–979) | "Clear Slide", "Clear All" only (OperatorView.swift:478–479) | Missing | 1 | Add Media, Audio, Message (commands exist for Audio and Messages) and Black |
| Clear wording | "All", "Slide" under a "CLEAR" label (Main L976) | "Clear Slide", "Clear All" (OperatorView.swift:478–479) | Wording | 3 | Label + short words |
| Clear button state | A button lights (accent border and text, `--sel` fill) when that layer is cleared on every screen in scope (Main L974–979) | No state | Missing | 2 | Show the cleared state |
| Blackout control | "Black" in the Clear row: amber border and text, amber fill when on (Main L976–979) | "Blackout" bordered button with `circle`; when on "BLACKOUT ON" in red fill, mono 12 bold (OperatorView.swift:481–493, render) | Wrong value | 2 | Amber "Black" button in the Clear row |
| Right column tabs | Audio / Message / Timer, `flex:1`, padding 9, 600, accent underline (Main L599–604, L993–998) | None; messages only in Service > Messages, no timers | Missing | 1 | Message and Timer tabs (see Contradictions 7 for tab state) |
| Audio cue panel (right column) | "track_02.wav" 700 + "[Song title]", "● Plays with slide", progress bar 6 px, "01:12" / "-03:00" mono 12, buttons ⏮ / "❚❚ Pause" (accent, 96×36) / ■ / ⏭, "Level" bar "-6 dB", "Up next: …" (Main L606–622) | Bottom Audio tab: track title `.title3` semibold, timecode mono 22 + state mono 11, Pause/Resume, Fade Out, Stop, Skip Trigger (OperatorView.swift:592–612) | Wrong value | 2 | Move now-playing to the right column, add the progress bar and remaining time |
| Track progress, prev/next, level | As above (Main L612–621) | None | Missing | 1 | Add progress, remaining time, previous/next track, level |
| Audio diagnostics grid | None | Voice, Ducking, Next trigger, Dropped ends, Dropped fires, Pool exhausted (OperatorView.swift:614–622) | Extra | 3 | Keep for v0.1 or move behind the Engine chip |
| Bottom tab style | Title case, body 13/600, padding 7×14, 32 px bar, 2 px accent underline (Main L169–171, L999–1003) | Uppercase, JetBrains Mono 11 semibold, padding 12×8, 2 pt accent underline (OperatorView.swift:553–559) | Wrong value | 2 | Title case, body font 600 |
| Disabled tabs | All five enabled; Scripture selected by default (Main L714 `ptab` 0) | Scripture, Media, Looks at 0.4 opacity and disabled; Audio by default (OperatorModel.swift:56–57, OperatorView.swift:519, 564–565) | Intentional | – | v0.1 scope (task brief; OperatorModel.swift:56). See Contradictions 7 for Activities |
| Bottom panel height | 330 px when Audio is open (Main L1327) | 210 pt (OperatorView.swift:79) | Wrong value | 2 | 330 |
| Status bar type | 28 px, body 12 px, dim; mono only for "Dropped 0" and "60.00 fps" (Main L680–687) | JetBrains Mono 11 for every item (OperatorView.swift:683) | Wrong value | 2 | Body font, mono only for numbers |
| Status items | 8 px dots + "Engine", "Outputs 3 / 3", "IMAG 1080p60", "Audio · 2 ch"; right: "Dropped 0", "60.00 fps" (Main L681–687) | "SDI 1 (A)" etc. per output with dot, "Audio: Playing" tinted chip, "Engine" chip without dot (OperatorView.swift:660–677, render) | Wrong value | 3 | Per-output chips were restored on purpose in 259e959; aggregate or per-output is the owner's call |
| IMAG status | "IMAG 1080p60" with dot (Main L683) | None | Missing | 1 | Add when the input exists (design-v0.md also asks for IMAG signal) |
| Frame rate and total dropped | "Dropped 0", "60.00 fps" mono (Main L686–687) | Dropped only per output and only above 0; no fps (OperatorView.swift:668–670) | Missing | 2 | Add both |
| Token: accent | `--accent` #47c86e (green) (Main L844) | `accent` #4C9EFF (blue) (Theme.swift:28): tab underline (render) | Wrong value | 2 | #47c86e |
| Token: neutrals | bg #161616, chrome #202020, panel #2b2b2b, line #3a3a3a, fg #f5f5f5, dim #a8a8a8 (Main L844) | background #111214, surface #1A1C1F, surfaceRaised #24272B, border #33373D, textPrimary #ECEDEE, textSecondary #9BA1A8 (Theme.swift:22–27) | Wrong value | 3 | Use the mockup values; add a chrome/panel split |
| Token: status | live #e5483f, ok #47c86e, warn #ffb020 (Main L844) | live #FF453A, ok #30D158, warning #FFD60A (Theme.swift:29–33) | Wrong value | 3 | Use the mockup values |
| Token: selection | `--sel` #1f3a29 (Main L844) | No token; system selection | Missing | 2 | Add `sel` |
| Label style | JetBrains Mono 11, weight 600, `letter-spacing:.06em`, dim (Main L845) | Mono 11 `.semibold`, no tracking (OperatorView.swift:735–736) | Wrong value | 3 | Add tracking 0.66 pt |
| Mono weight 600 | Board loads JetBrains Mono 400 and 600 (Main L11); labels use 600 | Bundled faces are Regular, Medium, Bold (Resources/Fonts); `.semibold` has no matching face | Wrong value | 3 | Bundle JetBrainsMono-SemiBold.ttf |
| Empty states | Not drawn | "Nothing live" dashed panel, "No Studio open", "Select an item…" (OperatorView.swift:179, 255, 368; idle render) | Extra | 3 | Keep; style with the mockup tokens |
| NEXT badge, NEXT monitor | None in the operator view (`isNext` is computed at Main L918–922 but never drawn) | None (OperatorView.swift:164–170, 412) | Intentional | – | Keep as is |
| 1100x720 | Not drawn | Minimum window (CueMEStageApp.swift:29). Service 240, 3 monitors × 270, 3 grid columns, bottom 210 (render) | not checked | – | The mockup has no layout at this size. With 280 + 360 columns the grid would have 460 pt left |

## 2. Operator view – light (`Light.dc.html` = `Main` with `theme="light"`, `bar="off"`)

Layout, wording and controls are the same as in section 1; they are not repeated. This table lists only what changes
with the theme.

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Token: accent | #17803c (green), text on accent #ffffff (Main L843, L1005) | #0A66D8 (blue) (Theme.swift:43) | Wrong value | 2 | #17803c |
| Service panel colour | `--chrome` #e8e8e5 (grey) (Main L49, L843) | `surface` #FFFFFF (white) (Theme.swift:38; light render) | Wrong value | 2 | Grey chrome as in the mockup |
| Token: neutrals | bg #f3f3f1, chrome #e8e8e5, panel #ffffff, line #cfcfca, fg #1a1a1a, dim #555555 (Main L843) | background #F4F5F7, surface #FFFFFF, surfaceRaised #ECEEF1, border #D5D9DE, textPrimary #16181B, textSecondary #5D646C (Theme.swift:37–42) | Wrong value | 3 | Use the mockup values |
| Token: status | live #c4231c, ok #17803c, warn #a85a00 (Main L843) | live #D70015, ok #248A3D, warning #B25000 (Theme.swift:44–48) | Wrong value | 3 | Use the mockup values |
| Selected row | `--sel` #d6eede (green tint) (Main L843, L927) | System grey selection (light render) | Wrong value | 2 | `sel` token |
| Theme choice | View > Theme: Dark, Light (Main L1227) | View > Theme: Auto, Dark, Light; fresh install Dark (OperatorModel.swift:35–44, menu dump) | Intentional | – | Recorded: ac3266c, 29af67e |
| Slide and monitor pictures | Gradient in both themes (Main L123) | Black in both themes (light render) | Wrong value | 3 | Same fix as section 1 |

## 3. Service menu (`MainServiceMenu.dc.html` = `Main` with `svc="open"`, `colx="open"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Service picker menu | Under the picker: "≡ Nov 22 Service 9" (bold, `--sel`), "≡ Nov 15 Service 7", "+ New service" in accent (Main L69–73, L890–897) | No picker; the header is static text (OperatorView.swift:93) | Missing | 1 | (not built) several services per Studio |
| Expanded collection | "▾ Worship Songs 142" and child rows "♪ Cristo Yo Te Amo 4:12" etc., indented 26 px (Main L56–57, L879–889) | None | Missing | 1 | (not built) |

## 4. Add menu (`MainAddMenu.dc.html` = `Main` with `addm="menu"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| "+ Add ▾" menu | 170 px menu, 12 px: "Section…" (enabled), "Activity…" (#6f6f6f, disabled) (Main L63, L65) | No menu in the panel. Service > Add Section… and Add Activity… are both disabled (StageMenuCommands.swift:133–134, dump) | Missing | 1 | Panel menu; enable Section… with the feature |

## 5. Add section (`MainAddItem.dc.html` = `Main` with `addm="open"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Section name popover | 220 px popover: "SECTION NAME" label, field with accent border, "Cancel", "Add" (accent, 700) (Main L68) | None | Missing | 1 | (not built) sections; count it in `isModalOpen` if it becomes a sheet |

## 6. Clear scope (`MainClearScope.dc.html` = `Main` with `smenu="open"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Scope picker | "All screens ▾" chip, 12 px, next to CLEAR (Main L589) | None; Clear always acts on every output (OperatorView.swift:478–479, StageMenuCommands.swift:96–104) | Missing | 1 | Scope picker |
| Scope menu | 190 px: ✓ All screens, Screen 1, Stage Screen 1, Stage Screen 2, Lobby TV; selected row `--sel` (Main L590, L981–983) | None | Missing | 1 | Screens from `state.outputScreens` |
| Black per scope | "Black" only blacks audience outputs in the scope (`isAudO`, Main L965–966) | Blackout is global (OperatorView.swift:484–491) | Missing | 1 | Per-screen black, or record global blackout as a decision |

## 7. Audio bin (`MainAudioBin.dc.html` = `Main` with `panel="audio"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Library column | 250 px: "Search audio" field + "+ Add"; LIBRARY: Worship Tracks 5, Pre-service 2, Stingers 2, Sermon Beds 2; PLAYLISTS "+ New": Sunday Service 6, Youth Night 3; "Drop audio files here" (Main L417–428, L1044–1056) | None | Missing | 1 | (not built) audio library |
| Track list | Header: folder name 700 + "DURATION" label. Rows: 26 px round play button, name 200 px/600, waveform bars, "♪ Song 1" chip, duration mono 12; selected row `--sel` (Main L430–449, L1062–1070) | None | Missing | 1 | (not built) |
| Inspector | 250 px: name, "4:30 · 48 kHz stereo", waveform, VOLUME "-6 dB", FADE In 0.5 s / Out 3 s, WHEN IT ENDS ↻ Loop / ■ Stop / ⏭ Next, "Add to slide", "Add to timeline" (Main L453–462) | None (fade and level exist in `AudioSettings` but are not shown) | Missing | 1 | (not built) |
| What the Audio tab shows | The library browser above | Now-playing, transport and engine counters (OperatorView.swift:585–638) | Extra | 2 | Move now-playing to the right column (section 1) |

## 8. Audio playlist (`MainAudioPlaylist.dc.html` = `Main` with `panel="audio"`, `alist="yes"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Playlist header | "Sunday Service", "6 tracks · 29 min", Shuffle toggle (off), Repeat toggle (on, accent), "▶ Play playlist" (accent, 24 px) (Main L431–438, L1058–1060) | None | Missing | 1 | (not built) playlists |
| Playlist rows | Drag handle "⋮⋮" + index mono 12 before the play button (Main L443) | None | Missing | 1 | (not built) |

## 9. Menu bar: CueME Stage menu (`MenuBarApp.dc.html` → `MenuBar` `menu="app"`)

App column: the `NSApp.mainMenu` dump.

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Check for Updates… | Second item (MenuBar L39 `app`) | None | Missing | 1 | (not built) updates |
| Preferences… ⌘, | After a separator (MenuBar L39) | None | Missing | 1 | (not built) Preferences window; add a disabled entry until then |
| Services, Show All | Not in the mockup | Present (system) | Extra | 3 | Leave (system) |
| About, Hide, Hide Others ⌥⌘H, Quit ⌘Q | Same labels and keys | Same | – | – | Match |

## 10. Menu bar: File (`MenuBarFile.dc.html`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Top group | New Service… ⌘N, New Collection… ⇧⌘N, New Song… ⌥⌘N, New Presentation… ⌃⌘N (MenuBar L39 `file`) | New Studio… ⌘N, Open Studio… ⌘O, Open Recent, Close Studio (StageMenuCommands.swift:19–39) | Intentional | – | Studio menus, e30dc23 (newer than the mockup) |
| New Collection…, New Song…, New Presentation… | As above | None | Missing | 1 | (not built) editors; disabled entries meanwhile |
| Import | "Import… ⇧⌘I" (disabled) | Import Studio…, Import Items… (no key) | Intentional | – | Studio menus, e30dc23 |
| Export Studio…, Export Selected Item…, Relink Media… | None | Present (StageMenuCommands.swift:45–51) | Intentional | – | Studio menus, e30dc23 |
| New Service | "New Service…" ⌘N, first item | "New Service", disabled, no ellipsis, no key, last group (StageMenuCommands.swift:53) | Wording | 3 | "New Service…" |
| Close Window ⌘W | Last item (MenuBar L39) | None: `CommandGroup(replacing: .saveItem) {}` also removes the system Close item (StageMenuCommands.swift:56); no Close in the dump | Missing | 1 | Add "Close Window" ⌘W back (it performs `performClose` on the key window) |

## 11. Menu bar: Service (`MenuBarService.dc.html`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Go Live ↩, Next Slide →, Previous Slide ← | Same labels and keys (MenuBar L39 `service`) | Same; off while a sheet is open (OperatorModel.swift:113–120) | Intentional | – | Modal guard, ac3266c |
| Clear ▸ items | All, Slide, Media, Audio, Message, Black, with ✓ when lit (Main L1222) | All ⇧⌘⌫, Slide ⌘⌫, Media (disabled), Audio, Message (StageMenuCommands.swift:96–104) | Missing | 1 | Clear Media has no command (disabled); add it |
| Clear ▸ Black | Present | None (Black Out is a separate item) | Missing | 3 | Add or drop from the mockup |
| Clear shortcuts | None | ⇧⌘⌫ and ⌘⌫ | Extra | 3 | Keep; record them |
| Black Out ⌘. | ✓ when on (Main L1231) | Title changes to "End Black Out" (OperatorModel.swift:122) | Wording | 3 | Pick one |
| Audio ▸ | Stop Playback, Shuffle ✓, Repeat ✓ (Main L1232) | Play/Pause ⌥⌘P, Stop ⌥⌘., Fade Out ⌥⌘F, Skip Next Trigger ⌥⌘S (StageMenuCommands.swift:108–122) | Missing | 1 | (not built) Shuffle and Repeat with playlists |
| Audio ▸ wording | "Stop Playback" | "Stop" | Wording | 3 | "Stop Playback" |
| Audio ▸ extras | None | Play/Pause, Fade Out, Skip Next Trigger | Extra | 3 | Keep; add to the mockup |
| Messages ▸ | "Hide All Messages", "Stop All Timers" (Main L1233) | One toggle per saved message (StageMenuCommands.swift:123–131) | Missing | 1 | Add Hide All Messages; Stop All Timers once timers run |
| Send Item to ▸ | Default (audience screens), Screen 1, Lobby TV, Screen 1 + Lobby TV (Main L1234) | None | Missing | 1 | (not built) targets |
| Add Section… | Enabled (Main L1235) | Disabled (StageMenuCommands.swift:133) | Missing | 1 | (not built) sections |
| Add Activity… | Disabled | Disabled | – | – | Match |

## 12. Menu bar: Output (`MenuBarOutput.dc.html`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Output Setup… ⇧⌘O, Visuals… ⇧⌘V (disabled) | Same (MenuBar L39 `output`) | Same (dump) | – | – | Match |
| Monitor ▸ | One entry per output with ✓ for the shown one (Main L1237) | Disabled (StageMenuCommands.swift:144–147) | Missing | 2 | Needed only with the single-monitor layout (Contradictions 1) |
| Test Pattern ▸ | List of outputs (Main L1238) | Bars ▸ / Grid ▸ → All Screens or one screen, then Off (StageMenuCommands.swift:148–163, dump) | Wrong value | 3 | Keep the app's version and update the mockup |
| Restart Engine… | Enabled; opens the restart confirmation (Main L1238) | Disabled (StageMenuCommands.swift:165) | Missing | 1 | Enable when the engine IPC exists, with the confirmation |

## 13. Menu bar: Edit, View, Window, Help (`MenuBarRef.dc.html`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Edit: Undo … Select All | Same labels; Delete has "⌫" (MenuBarRef L15) | Same labels; Delete has no key (dump) | Wording | 3 | Leave (system) |
| Edit: Find… ⌘F | Present (MenuBarRef L15) | None | Missing | 1 | (not built) scripture search |
| Edit: Edit Selected Item… ⌘E | Present | None | Missing | 1 | (not built) editors |
| Edit: Writing Tools, AutoFill, Dictation, Emoji & Symbols | None | Present (system) | Extra | 3 | Leave (system) |
| View: Operator, Editor | None | Both disabled (StageMenuCommands.swift:61–62) | Extra | 3 | Remove until there is an editor, or add to the mockup |
| View: Theme ▸ | Dark, Light | Auto, Dark, Light | Intentional | – | ac3266c |
| View: Show Multiview ⇧⌘M | Present (MenuBarRef L15) | None | Missing | 2 | Needed only with the single-monitor layout |
| View: Scripture … Activities ⌘1–⌘5 | Same labels and keys, all enabled | Same; Scripture, Media, Looks disabled (dump) | Intentional | – | v0.1 scope |
| View: Audio (right column) ⌥⌘1, Message ⌥⌘2, Timer ⌥⌘3 | Present | None | Missing | 1 | With the right-column tabs |
| View: Enter Full Screen ⌃⌘F | Present | Not in the dump (the test host had no window; macOS adds it to a windowed app) | not checked | – | Check in the running app |
| Window: Operator View ⌘0 ✓, Output Setup, Visuals (disabled) | Present (MenuBarRef L15) | None; the menu has Minimize, Zoom, Bring All to Front and the window list (dump) | Missing | 1 | Add Operator View ⌘0; Output Setup is a sheet in the app |
| Help: CueME Stage Help | No key | ⌘? (system) | Extra | 3 | Leave |
| Help: Keyboard Shortcuts…, Release Notes, Export Diagnostics…, Report a Problem… | Present (MenuBarRef L15) | None | Missing | 1 | (not built); Export Diagnostics matters for support |
| Help: Toggle Sidebar | None | Present, disabled (dump) | Extra | 3 | Remove with `CommandGroup(replacing: .sidebar) {}` |
| Help: Search field | Drawn | System adds it at run time; not in the dump | not checked | – | – |
| Menu bar look | Green #47c86e highlight, dropdown rgba(44,44,44,.97) (MenuBar L46, L64) | System-drawn NSMenu | not checked | – | Cannot be styled; the mockup imitates macOS |

## 14. Quit while live (`MainQuitLive.dc.html` → `QuitDialog.dc.html` `kind="quit"`)

| Element | Mockup (value, with the file and the line or selector) | App (value, with the file) | Kind | Severity | Suggested fix |
|---|---|---|---|---|---|
| Confirmation on quit while live | A dialog over the operator view (QuitDialog L19–27) | None: ⌘Q quits at once. There is no `applicationShouldTerminate`; `applicationWillTerminate` only saves (CueMEStageApp.swift:108–110) | Missing | 1 | `applicationShouldTerminate`: when `LiveSummary.text(state)` is not nil, ask; Cancel is the default |
| Wording | Title "Quit CueME Stage?"; body "Nov 22 Service is live. Quitting stops the engine too, so the displays and audio will stop."; buttons "Cancel", "Quit" (QuitDialog L41) | None. The nearest app alert says "Switch Studio while something is live?" / "Live now: …. Switch Studio stops it on every output." (StudioDialogs.swift:82–83) | Missing | 1 | Use the mockup's text, with the live summary for the name |
| Look | 420 px card, radius 12, 44 px app icon, title 15/700, body dim line-height 1.4, "Cancel" on panel, "Quit" red `--live` fill with white 700 text (QuitDialog L19–26, L46) | – (an NSAlert would be system-styled) | not checked | – | NSAlert with `hasDestructiveAction` on Quit gives the red button |

## Fifteen most visible differences

Ranked by how much of the screen they change, not by severity.

1. **Layout.** The app stacks a row of output monitors above the slide grid. The mockup has a 360 px right column
   with one monitor, Previous/Next, the Clear row and the Audio/Message/Timer tabs (section 1, "Overall layout",
   "Monitor").
2. **Accent colour.** Blue (#4C9EFF dark, #0A66D8 light) instead of green (#47c86e dark, #17803c light), on every
   tab underline and future primary button (sections 1 and 2).
3. **Audio tab.** The app shows now-playing and engine counters. The mockup's Audio tab is a library and playlist
   browser with waveforms and an inspector (sections 7, 8).
4. **Service panel top.** The mockup's search, COLLECTIONS tree, service picker and "+ Add ▾" are missing. The app
   shows a small mono header instead (sections 1, 3, 4).
5. **Clear controls.** "Clear Slide" and "Clear All" instead of the CLEAR row with a scope picker and six buttons
   All / Slide / Media / Audio / Message / Black (sections 1, 6).
6. **Message and Timer tabs.** They are missing; the mockup has them in the right column (section 1).
7. **Slide cards.** Header on top, black picture, LIVE chip, adaptive 3 columns. The mockup has picture first,
   gradient, footer label and number, 4 fixed columns in titled groups (section 1).
8. **Bottom tabs.** Uppercase JetBrains Mono 11 tabs instead of title-case body text. The panel is 210 pt instead of
   330 (section 1).
9. **Service rows.** Single-line rows without section headings, sub-lines or durations. The mockup has two-line rows
   under PRE-SERVICE / WORSHIP / WORD / CLOSING (section 1).
10. **Blackout.** A red "Blackout" / "BLACKOUT ON" button in the transport bar and red "BLACKOUT" on the monitors.
    The mockup has an amber "Black" in the Clear row and amber "BLACK" on the monitor (section 1).
11. **Previous / Next.** Small system buttons in a bar under the grid. The mockup has a full-width pair in the right
    column with Next as the green primary button (section 1).
12. **Status bar.** Everything in mono, per-output chips, "Audio: Playing" chip; no IMAG, frame rate or total
    dropped. The mockup uses body text with status dots, "Outputs 3 / 3", "IMAG 1080p60", "Dropped 0",
    "60.00 fps" (section 1).
13. **Slide grid header.** A small mono uppercase title instead of the 15 px bold item title with file chips,
    "Send to ▾" and "Edit ✎" (section 1).
14. **Selected service row.** System grey highlight instead of the green `--sel` tint with a bold title, in both
    themes (sections 1, 2).
15. **Light theme panels.** The service panel is white instead of grey chrome #e8e8e5, and all neutrals are shifted
    toward blue-grey (section 2).

Not visible, but severity 1: no confirmation when quitting while live (section 14), and no Close Window ⌘W
(section 10).

## Count by severity

Counted from the tables above (118 rows):

| Severity | Rows |
|---|---|
| 1 | 38 |
| 2 | 28 |
| 3 | 34 |
| Intentional (no severity) | 10 |
| not checked | 5 |
| Match (listed for completeness) | 3 |

21 of the 38 severity 1 rows are marked "(not built)": controls for features that do not exist yet, such as
collections, several services, targets, editors, the audio library and playlists, updates, preferences and the Help
items.

The other 17 rows:

- quit confirmation and its wording (section 14)
- Close Window ⌘W
- the Clear row's missing buttons and Clear ▸ Media
- clear scope picker, scope menu and per-scope black
- the Message/Timer tabs and View ⌥⌘1–3
- audio progress, previous/next and level
- IMAG status
- "+ Add ▾" in the panel and its menu
- Messages ▸ Hide All
- Restart Engine…
- Window ▸ Operator View

## Where the mockup disagrees with design-v0.md or the app's recorded decisions

1. **One monitor or one per screen.** design-v0.md, "UI priorities", item 1, asks for "a live monitor per output
   screen". The mockup shows one monitor with an output picker and a Multiview toggle (Main L515–541). The app
   follows design-v0.md: a row with one monitor per screen, 16:9, recorded in commit 259e959. Both documents are
   dated 2026-11-20, so the "mockup wins" rule does not settle it; the owner should.
2. **Status indicators.** design-v0.md asks for "outputs, IMAG signal, CueME connection, dropped frames". The
   mockup's status bar has no CueME connection item (Main L680–687), and neither does the app.
3. **Music playback.** design-v0.md says songs and music go through CueME, triggered over OSC/HTTP in v0. The
   mockup has an in-app audio library and playlists (Main L415–464), and the app already plays audio in-app
   (AudioCore, triggers, ducking). design-v0.md is behind both.
4. **Theme.** The mockup's View > Theme has Dark and Light only (Main L1227). The app has Auto, Dark and Light,
   with Dark for a fresh install (ac3266c, 29af67e).
5. **File menu.** The mockup's File menu is New Service ⌘N, New Collection, New Song, New Presentation, Import.
   The app's Studio menus (e30dc23, docs/studio-file-format.md) are newer and replace the top group and Import.
6. **Modal guard.** The mockup never shows Go Live, Next or Previous disabled. The app turns them, and the File
   menu's Studio entries, off while a sheet is open (ac3266c). This is not drawn in the mockup, not a conflict.
7. **Activities tab.** The task brief lists Activities as disabled in v0.1, and every Activities board is
   [After v0.1]. The app enables the Activities tab and View > Activities ⌘5 (OperatorModel.swift:57, menu dump),
   and the tab shows an "After v0.1" placeholder. One of them needs to change.
8. **Stage monitor content.** The mockup's stage-screen pictures show "Next: …" and "Next slide" (Main L549,
   L558). That is stage-output content, which design-v0.md allows. The app's STAGE monitor shows the audience slide
   text instead. The no-NEXT decision covers the operator view, so the question is whether a stage monitor should
   show the stage layout.
9. **Inside the mockup.** `QuitDialog.dc.html` uses light `--warn` #b45f06 and `--live` #c4221a (QuitDialog L37).
   `Main.dc.html` uses #a85a00 and #c4231c (Main L843).
