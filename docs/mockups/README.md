# UI mockups

The CueME Stage UI mockup is a claude.ai Design artifact: 142 boards on one canvas showing every
operator screen, editor, sheet, menu and dialog the app is meant to have.

- **Editable original:** the artifact "CueME Stage – Operator View Mockup"
  <https://claude.ai/code/artifact/0fc9aac3-e1bc-43f0-b2b3-88856b6987d5>.
  The design doc `design-v0.md` in the Claude Project describes it (the repo copy is
  [../design-v0.md](../design-v0.md)).
- **Snapshot in this repo:** [source/project/](source/project/) holds the board files and
  `canvas.json` byte for byte, as of artifact version `1795369998-1dcd` (fetched 2026-11-22).
  The files load `support.js` and the artifact runtime, which are not copied, so they do not
  render on their own. Open the link to view them. Refresh the snapshot when the artifact changes.

## Which one wins

When the mockup and the app differ, **the mockup wins**, unless `design-v0.md` says the
design changed after the mockup was made.

Known difference: the NEXT badge on slide cards and the NEXT monitor in the operator view
were removed from the app on 2026-11-22 by the owner's decision (see design-v0.md, "Operator
(run) view"). If a board, an older copy or a screenshot shows them, ignore it. **Do not restore them.**

## Reading the index

- The canvas has 13 columns. Each starts with a group header board (`Group*.dc.html`).
- **Not built yet:** boards whose titles start with **[After v0.1]** or **[v0.3]**.
  They are planned and are not part of the current app. The Visuals, Import and Activities
  columns are entirely not built yet.
- "Drawn by" names the file that holds the layout. Most boards are thin wrappers that import a
  base file with a few props (shown in the table). Change or read the base file for the layout.

## 1. Operator view

Main window, panels and service menus · 10 boards. Header: `GroupOperatorview.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Operator view – dark | [Main.dc.html](source/project/Main.dc.html) | itself |
| Operator view – light | [Light.dc.html](source/project/Light.dc.html) | `Main.dc.html` (bar="off" theme="light") |
| Operator view – Multiview | [MainMultiview.dc.html](source/project/MainMultiview.dc.html) | `Main.dc.html` (bar="off" view="multi" black="lobby") |
| Operator view – Clear scope | [MainClearScope.dc.html](source/project/MainClearScope.dc.html) | `Main.dc.html` (bar="off" smenu="open") |
| Operator view – Presentation selected | [MainPresentation.dc.html](source/project/MainPresentation.dc.html) | `Main.dc.html` (bar="off" item="6") |
| Operator view – Service menu | [MainServiceMenu.dc.html](source/project/MainServiceMenu.dc.html) | `Main.dc.html` (bar="off" svc="open" colx="open") |
| Service panel – Add menu | [MainAddMenu.dc.html](source/project/MainAddMenu.dc.html) | `Main.dc.html` (bar="off" addm="menu" colx="open") |
| Service panel – Add section | [MainAddItem.dc.html](source/project/MainAddItem.dc.html) | `Main.dc.html` (bar="off" addm="open" colx="open") |
| New collection | [ServiceNewCollection.dc.html](source/project/ServiceNewCollection.dc.html) | `ServiceDialog.dc.html` (kind="collection") |
| New service | [ServiceNewService.dc.html](source/project/ServiceNewService.dc.html) | `ServiceDialog.dc.html` (kind="service") |

## 2. Scripture

Bottom panel tab · 9 boards. Header: `GroupScripture.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Operator view – Scripture | [MainScripture.dc.html](source/project/MainScripture.dc.html) | `Main.dc.html` (bar="off" scr="normal") |
| Scripture – Search | [MainScriptureSearch.dc.html](source/project/MainScriptureSearch.dc.html) | `Main.dc.html` (bar="off" scr="search") |
| Scripture – Verse range, 2 slides | [MainScriptureRange.dc.html](source/project/MainScriptureRange.dc.html) | `Main.dc.html` (bar="off" scr="range") |
| Scripture – Two translations | [MainScriptureDual.dc.html](source/project/MainScriptureDual.dc.html) | `Main.dc.html` (bar="off" scr="dual") |
| Scripture – Speech suggestions | [MainScriptureSpeech.dc.html](source/project/MainScriptureSpeech.dc.html) | `Main.dc.html` (bar="off" scr="speech") |
| Operator view – Translation menu | [MainTranslation.dc.html](source/project/MainTranslation.dc.html) | `Main.dc.html` (bar="off" trmenu="open") |
| Operator view – Looks menu | [MainTemplate.dc.html](source/project/MainTemplate.dc.html) | `Main.dc.html` (bar="off" tpmenu="open") |
| Bible translations | [BibleSheet.dc.html](source/project/BibleSheet.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}") |
| Bible translations – Import file | [BibleImport.dc.html](source/project/BibleImport.dc.html) | `BibleSheet.dc.html` (view="import") |

## 3. Media and audio bins

Bottom panel tabs · 10 boards. Header: `GroupMediaandaudiobins.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Operator view – Media bin | [MainMedia.dc.html](source/project/MainMedia.dc.html) | `Main.dc.html` (bar="off" panel="media") |
| Media bin – Add menu | [MainMediaAdd.dc.html](source/project/MainMediaAdd.dc.html) | `Main.dc.html` (bar="off" panel="media" madd="open") |
| Media bin – Add files | [MediaDialog.dc.html](source/project/MediaDialog.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}" panel="media") |
| Media bin – Adding files | [MediaAddProgress.dc.html](source/project/MediaAddProgress.dc.html) | `MediaDialog.dc.html` (kind="progress") |
| Media bin – New folder | [MediaNewFolder.dc.html](source/project/MediaNewFolder.dc.html) | `MediaDialog.dc.html` (kind="folder") |
| Media bin – Link a folder | [MediaLinkFolder.dc.html](source/project/MediaLinkFolder.dc.html) | `MediaDialog.dc.html` (kind="link") |
| Operator view – Media layer | [MainMediaLayer.dc.html](source/project/MainMediaLayer.dc.html) | `Main.dc.html` (bar="off" panel="media" lmenu="open") |
| Operator view – Media composition | [MainMediaComp.dc.html](source/project/MainMediaComp.dc.html) | `Main.dc.html` (bar="off" panel="media" cmenu="open") |
| Operator view – Audio bin | [MainAudioBin.dc.html](source/project/MainAudioBin.dc.html) | `Main.dc.html` (bar="off" panel="audio") |
| Operator view – Audio playlist | [MainAudioPlaylist.dc.html](source/project/MainAudioPlaylist.dc.html) | `Main.dc.html` (bar="off" panel="audio" alist="yes") |

## 4. Messages and timers

Right column tabs · 6 boards. Header: `GroupMessagesandtimers.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Operator view – Messages (multiple) | [MainMessages.dc.html](source/project/MainMessages.dc.html) | `Main.dc.html` (bar="off" tab="message") |
| Message editor – New message | [MessageEditor.dc.html](source/project/MessageEditor.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}" tab="message") |
| Message editor – Style menu | [MessageEditorStyle.dc.html](source/project/MessageEditorStyle.dc.html) | `MessageEditor.dc.html` (menu="open") |
| Operator view – Timers (multiple) | [MainTimers.dc.html](source/project/MainTimers.dc.html) | `Main.dc.html` (bar="off" tab="timer") |
| Timer editor – Count down from | [TimerEditor.dc.html](source/project/TimerEditor.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}" tab="timer") |
| Timer editor – Count down to time | [TimerEditorTo.dc.html](source/project/TimerEditorTo.dc.html) | `TimerEditor.dc.html` (type="to") |

## 5. Looks and templates

Looks tab and template editors · 12 boards. Header: `GroupLooksandtemplates.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Operator view – Looks tab | [MainLooks.dc.html](source/project/MainLooks.dc.html) | `Main.dc.html` (bar="off" panel="looks") |
| Operator view – Looks tab (lower third) | [MainLooksLower.dc.html](source/project/MainLooksLower.dc.html) | `Main.dc.html` (bar="off" panel="looks" look="lower") |
| Operator view – Looks tab (template menu) | [MainLooksTemplate.dc.html](source/project/MainLooksTemplate.dc.html) | `Main.dc.html` (bar="off" panel="looks" tdd="messages") |
| Song templates – Full screen lyrics | [SongTemplate.dc.html](source/project/SongTemplate.dc.html) | itself |
| Song templates – Lower third lyrics | [SongTemplateLower.dc.html](source/project/SongTemplateLower.dc.html) | `SongTemplate.dc.html` (view="lower") |
| Song templates – Two-language lyrics | [SongTemplateDual.dc.html](source/project/SongTemplateDual.dc.html) | `SongTemplate.dc.html` (view="dual") |
| Bible templates – Full screen | [BibleTemplate.dc.html](source/project/BibleTemplate.dc.html) | itself |
| Bible templates – Lower third | [BibleTemplateLower.dc.html](source/project/BibleTemplateLower.dc.html) | `BibleTemplate.dc.html` (view="lower") |
| Bible templates – Dual translation | [BibleTemplateDual.dc.html](source/project/BibleTemplateDual.dc.html) | `BibleTemplate.dc.html` (view="dual") |
| Bible templates – Credit line (CC BY-SA) | [BibleTemplateCredit.dc.html](source/project/BibleTemplateCredit.dc.html) | `BibleTemplate.dc.html` (view="full" select="3" preview="1") |
| Message templates – Top banner | [MessageTemplate.dc.html](source/project/MessageTemplate.dc.html) | itself |
| Message templates – Full-screen takeover | [MessageTemplateFull.dc.html](source/project/MessageTemplateFull.dc.html) | `MessageTemplate.dc.html` (template="full") |

## 6. Song and presentation editors

Editor windows · 10 boards. Header: `GroupSongandpresentationeditors.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Song editor – Slide | [SongEditor.dc.html](source/project/SongEditor.dc.html) | itself |
| Song editor – Text edit | [SongEditorText.dc.html](source/project/SongEditorText.dc.html) | `SongEditor.dc.html` (tab="text" select="3") |
| Song editor – Slide inspector | [SongEditorSlide.dc.html](source/project/SongEditorSlide.dc.html) | `SongEditor.dc.html` (tab="slide" rtab="slide" select="3") |
| Song editor – Timeline | [SongEditorTimeline.dc.html](source/project/SongEditorTimeline.dc.html) | `SongEditor.dc.html` (tab="timeline" rtab="song") |
| Song editor – Timeline cue | [SongEditorCue.dc.html](source/project/SongEditorCue.dc.html) | `SongEditor.dc.html` (tab="timeline" rtab="song" cue="open") |
| Song editor – Sequence menu | [SongEditorSeqMenu.dc.html](source/project/SongEditorSeqMenu.dc.html) | `SongEditor.dc.html` (seq="menu") |
| Song editor – Sequences | [SongEditorSequences.dc.html](source/project/SongEditorSequences.dc.html) | `SongEditor.dc.html` (seq="edit" rtab="song") |
| Presentation editor – Slide | [PresentationEditor.dc.html](source/project/PresentationEditor.dc.html) | itself |
| Presentation editor – Outline | [PresentationEditorOutline.dc.html](source/project/PresentationEditorOutline.dc.html) | `PresentationEditor.dc.html` (tab="outline" select="1") |
| Presentation editor – New slide menu | [PresentationEditorMenu.dc.html](source/project/PresentationEditorMenu.dc.html) | `PresentationEditor.dc.html` (menu="open" rtab="presentation") |

## 7. Stage editor

Stage layout editor · 9 boards. Header: `GroupStageeditor.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Stage Editor | [StageEditor.dc.html](source/project/StageEditor.dc.html) | itself |
| Stage Editor – Variable menu | [StageEditorMenu.dc.html](source/project/StageEditorMenu.dc.html) | `StageEditor.dc.html` (menu="open") |
| Stage Editor – Timer object | [StageEditorTimer.dc.html](source/project/StageEditorTimer.dc.html) | `StageEditor.dc.html` (pick="timer" tmenu="open") |
| Stage Editor – Timer overrun | [StageEditorOverrun.dc.html](source/project/StageEditorOverrun.dc.html) | `StageEditor.dc.html` (pick="overrun") |
| Stage Editor – Color triggers | [StageEditorTriggers.dc.html](source/project/StageEditorTriggers.dc.html) | `StageEditor.dc.html` (pick="triggers") |
| Stage Editor – Color triggers (video countdown) | [StageEditorTriggersVideo.dc.html](source/project/StageEditorTriggersVideo.dc.html) | `StageEditor.dc.html` (pick="videotrig") |
| Stage Editor – Text settings | [StageEditorScaling.dc.html](source/project/StageEditorScaling.dc.html) | `StageEditor.dc.html` (pick="videotrig" scmenu="open") |
| Stage Editor – Font menu | [StageEditorFont.dc.html](source/project/StageEditorFont.dc.html) | `StageEditor.dc.html` (pick="default" dd="font") |
| Stage Editor – Capitalization menu | [StageEditorCaps.dc.html](source/project/StageEditorCaps.dc.html) | `StageEditor.dc.html` (pick="default" dd="caps") |

## 8. Output Setup

Screens, outputs, canvas and slices · 15 boards. Header: `GroupOutputSetup.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Output setup | [OutputSetup.dc.html](source/project/OutputSetup.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}") |
| Output Setup – Four screens | [OutputSetupQuad.dc.html](source/project/OutputSetupQuad.dc.html) | `OutputSetup.dc.html` (rig="quad" select="9") |
| Output setup – Rotated speaker screen | [OutputRotated.dc.html](source/project/OutputRotated.dc.html) | `OutputSetup.dc.html` (select="6") |
| Output setup – Lower third screen | [OutputLowerThird.dc.html](source/project/OutputLowerThird.dc.html) | `OutputSetup.dc.html` (select="7") |
| Output setup – New screen type | [OutputNewType.dc.html](source/project/OutputNewType.dc.html) | `OutputSetup.dc.html` (view="newType") |
| Output setup – Add input | [OutputInput.dc.html](source/project/OutputInput.dc.html) | `OutputSetup.dc.html` (view="input") |
| Output setup – Add SDI | [OutputSdi.dc.html](source/project/OutputSdi.dc.html) | `OutputSetup.dc.html` (view="sdi") |
| Output setup – Add NDI | [OutputNdi.dc.html](source/project/OutputNdi.dc.html) | `OutputSetup.dc.html` (view="ndi") |
| Output setup – Add External Display | [OutputDisplay.dc.html](source/project/OutputDisplay.dc.html) | `OutputSetup.dc.html` (view="display") |
| Output setup – Format list | [OutputFormat.dc.html](source/project/OutputFormat.dc.html) | `OutputSetup.dc.html` (view="format") |
| **[After v0.1]** Output setup – Slices (input selection) — *not built yet* | [OutputSetupSlices.dc.html](source/project/OutputSetupSlices.dc.html) | `OutputSetup.dc.html` (pane="slices") |
| **[After v0.1]** Output setup – Slices (output transformation) — *not built yet* | [OutputSetupSlicesTransform.dc.html](source/project/OutputSetupSlicesTransform.dc.html) | `OutputSetup.dc.html` (pane="slices" stab="output" ssel="tv1") |
| **[After v0.1]** Output setup – Slices (soft edge) — *not built yet* | [OutputSetupSlicesSoftEdge.dc.html](source/project/OutputSetupSlicesSoftEdge.dc.html) | `OutputSetup.dc.html` (pane="slices" ssel="tv1" ssoft="on") |
| **[After v0.1]** Output setup – Slices (add menu) — *not built yet* | [OutputSetupSlicesAdd.dc.html](source/project/OutputSetupSlicesAdd.dc.html) | `OutputSetup.dc.html` (pane="slices" smenu="open") |
| Output setup – Slices pane (component used inside the sheet) | [OutputSlices.dc.html](source/project/OutputSlices.dc.html) | itself |

## 9. Visuals

Greyed out in v0.1 · 4 boards. Header: `GroupVisuals.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| **[After v0.1]** Visuals – Clip — *not built yet* | [Visuals.dc.html](source/project/Visuals.dc.html) | itself |
| **[After v0.1]** Visuals – Layer — *not built yet* | [VisualsLayer.dc.html](source/project/VisualsLayer.dc.html) | `Visuals.dc.html` (scope="layer") |
| **[After v0.1]** Visuals – Add effect — *not built yet* | [VisualsMenu.dc.html](source/project/VisualsMenu.dc.html) | `Visuals.dc.html` (menu="open") |
| **[After v0.1]** Visuals – Screen comp (slides layer) — *not built yet* | [VisualsScreen.dc.html](source/project/VisualsScreen.dc.html) | `Visuals.dc.html` (comp="tv1" scope="layer") |

## 10. Preferences

Settings window · 14 boards. Header: `GroupPreferences.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Preferences – Network | [Preferences.dc.html](source/project/Preferences.dc.html) | itself |
| Preferences – Audio | [PrefsAudio.dc.html](source/project/PrefsAudio.dc.html) | `Preferences.dc.html` (pane="audio") |
| Preferences – Video (variation B of Output) | [PrefsVideo.dc.html](source/project/PrefsVideo.dc.html) | `Preferences.dc.html` (pane="video") |
| **[After v0.1]** Preferences: Video, wire badges and pass-through screen — *not built yet* | [PrefsVideoBadges.dc.html](source/project/PrefsVideoBadges.dc.html) | `Preferences.dc.html` (pane="video" vx="badges") |
| **[After v0.1]** Preferences: Video, scaler popover on a wire — *not built yet* | [PrefsVideoScaler.dc.html](source/project/PrefsVideoScaler.dc.html) | `Preferences.dc.html` (pane="video" vx="popover") |
| **[After v0.1]** Preferences: Video, 50 fps input into a 59.94 screen — *not built yet* | [PrefsVideoMismatch.dc.html](source/project/PrefsVideoMismatch.dc.html) | `Preferences.dc.html` (pane="video" vx="mismatch") |
| Preferences – Media | [PrefsMedia.dc.html](source/project/PrefsMedia.dc.html) | `Preferences.dc.html` (pane="media") |
| Preferences – Updates | [PrefsUpdates.dc.html](source/project/PrefsUpdates.dc.html) | `Preferences.dc.html` (pane="updates") |
| Preferences – Groups & Labels | [PrefsGroups.dc.html](source/project/PrefsGroups.dc.html) | `Preferences.dc.html` (pane="groups") |
| Preferences – Edit group | [PrefsGroupEdit.dc.html](source/project/PrefsGroupEdit.dc.html) | `Preferences.dc.html` (pane="groups" dlg="group") |
| Preferences – Edit label | [PrefsLabelEdit.dc.html](source/project/PrefsLabelEdit.dc.html) | `Preferences.dc.html` (pane="groups" dlg="label") |
| **[After v0.1]** Preferences: Integrations, CueME Stage relay — *not built yet* | [PrefsIntegrations.dc.html](source/project/PrefsIntegrations.dc.html) | `Preferences.dc.html` (pane="integrations") |
| **[After v0.1]** Preferences: Integrations, own relay domain — *not built yet* | [PrefsIntegrationsOwn.dc.html](source/project/PrefsIntegrationsOwn.dc.html) | `Preferences.dc.html` (pane="integrations" relay="own") |
| **[After v0.1]** Preferences: Integrations, relay setup guide — *not built yet* | [PrefsIntegrationsGuide.dc.html](source/project/PrefsIntegrationsGuide.dc.html) | `Preferences.dc.html` (pane="integrations" relay="guide") |

## 11. Menu bar and dialogs

macOS menus and confirmations · 7 boards. Header: `GroupMenubaranddialogs.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| Menu bar – CueME Stage menu | [MenuBarApp.dc.html](source/project/MenuBarApp.dc.html) | `MenuBar.dc.html` (menu="app") |
| Menu bar – File menu | [MenuBarFile.dc.html](source/project/MenuBarFile.dc.html) | `MenuBar.dc.html` (menu="file") |
| Menu bar – Service menu | [MenuBarService.dc.html](source/project/MenuBarService.dc.html) | `MenuBar.dc.html` (menu="service") |
| Menu bar – Output menu | [MenuBarOutput.dc.html](source/project/MenuBarOutput.dc.html) | `MenuBar.dc.html` (menu="output") |
| Menu bar – Edit, View, Window, Help | [MenuBarRef.dc.html](source/project/MenuBarRef.dc.html) | itself |
| Confirm – Quit while live | [MainQuitLive.dc.html](source/project/MainQuitLive.dc.html) | `QuitDialog.dc.html` (kind="quit") |
| Confirm – Restart engine | [MainRestartEngine.dc.html](source/project/MainRestartEngine.dc.html) | `QuitDialog.dc.html` (kind="restart") |

## 12. Import

File → Import… · 4 boards. Header: `GroupImport.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| **[v0.3]** Import – Choose source — *not built yet* | [ImportSheet.dc.html](source/project/ImportSheet.dc.html) | `Main.dc.html` (bar="off" theme="{{theme}}") |
| **[v0.3]** Import – ProPresenter review — *not built yet* | [ImportReviewPro.dc.html](source/project/ImportReviewPro.dc.html) | `ImportSheet.dc.html` (step="review" src="pro") |
| **[v0.3]** Import – PowerPoint review — *not built yet* | [ImportReviewPpt.dc.html](source/project/ImportReviewPpt.dc.html) | `ImportSheet.dc.html` (step="review" src="ppt") |
| **[v0.3]** Import – Finished — *not built yet* | [ImportDone.dc.html](source/project/ImportDone.dc.html) | `ImportSheet.dc.html` (step="done" src="pro") |

## 13. Activities

Tab, running Activity, editor, service item · 16 boards. Header: `GroupActivities.dc.html`.

| Board | File | Drawn by |
|---|---|---|
| **[After v0.1]** Activities tab: list — *not built yet* | [MainFunctions.dc.html](source/project/MainFunctions.dc.html) | `Main.dc.html` (bar="off" panel="functions") |
| **[After v0.1]** Activities tab: hide a question — *not built yet* | [MainActivityHidden.dc.html](source/project/MainActivityHidden.dc.html) | `Main.dc.html` (panel="functions" act="list" slides="hidden") |
| **[After v0.1]** Activity running: question open — *not built yet* | [MainActivityRun.dc.html](source/project/MainActivityRun.dc.html) | `Main.dc.html` (panel="functions" act="question") |
| **[After v0.1]** Activity running: answer revealed — *not built yet* | [MainActivityReveal.dc.html](source/project/MainActivityReveal.dc.html) | `Main.dc.html` (panel="functions" act="reveal") |
| **[After v0.1]** Activity running: leaderboard — *not built yet* | [MainActivityBoard.dc.html](source/project/MainActivityBoard.dc.html) | `Main.dc.html` (panel="functions" act="board") |
| **[After v0.1]** Activity running: players list (Kick, Rename) — *not built yet* | [MainActivityPlayers.dc.html](source/project/MainActivityPlayers.dc.html) | `Main.dc.html` (panel="functions" act="players") |
| **[After v0.1]** Activity running: target screens picker — *not built yet* | [MainActivityTargets.dc.html](source/project/MainActivityTargets.dc.html) | `Main.dc.html` (panel="functions" act="targets") |
| **[After v0.1]** Activity editor — *not built yet* | [ActivityEditor.dc.html](source/project/ActivityEditor.dc.html) | itself |
| **[After v0.1]** Activity editor: Results tab — *not built yet* | [ActivityEditorResults.dc.html](source/project/ActivityEditorResults.dc.html) | `ActivityEditor.dc.html` (tab="results") |
| **[After v0.1]** Activities item: slides (Game, lobby) — *not built yet* | [MainActivitySlides.dc.html](source/project/MainActivitySlides.dc.html) | `Main.dc.html` (slides="game") |
| **[After v0.1]** Activities item: slides (Game, question selected) — *not built yet* | [MainActivitySlidesQuestion.dc.html](source/project/MainActivitySlidesQuestion.dc.html) | `Main.dc.html` (slides="gameq") |
| **[After v0.1]** Activities item: slides (Poll) — *not built yet* | [MainActivitySlidesPoll.dc.html](source/project/MainActivitySlidesPoll.dc.html) | `Main.dc.html` (slides="poll") |
| **[After v0.1]** Add Activity: choose which activity to link — *not built yet* | [MainActivityPicker.dc.html](source/project/MainActivityPicker.dc.html) | `Main.dc.html` (slides="picker") |
| **[After v0.1]** Service list: right-click an Activities item — *not built yet* | [MainActivityRightClick.dc.html](source/project/MainActivityRightClick.dc.html) | `Main.dc.html` (slides="ctx") |
| **[After v0.1]** Right-click while a session is running (Change blocked) — *not built yet* | [MainActivityRightClickLive.dc.html](source/project/MainActivityRightClickLive.dc.html) | `Main.dc.html` (slides="ctxlive") |
| **[After v0.1]** Change Activity: relink the item — *not built yet* | [MainActivityChange.dc.html](source/project/MainActivityChange.dc.html) | `Main.dc.html` (slides="change") |

## Base components outside the columns

These untitled boards sit to the right of the 13 columns. They are the base files that other
boards import, not screens of their own:

- [MenuBar.dc.html](source/project/MenuBar.dc.html)
- [QuitDialog.dc.html](source/project/QuitDialog.dc.html)
- [ServiceDialog.dc.html](source/project/ServiceDialog.dc.html)
