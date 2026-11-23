import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The Song editor's model against a real Studio store and the mock engine.
@MainActor
final class SongEditorTests: StudioEditTestCase {
    var editor: SongEditorModel!

    func openEditor(_ title: String = "Amazing Grace") async {
        await launch()
        let song = studio.songs.first { $0.title == title }!
        editor = SongEditorModel(target: SongEditorTarget(studioID: studio.id, songID: song.id), controller: controller)
        var clock = Date(timeIntervalSince1970: 0)
        editor.now = { clock = clock.addingTimeInterval(0.1); return clock }
    }

    var song: Song { editor.song! }

    // MARK: Lyrics

    func testTypingLyricsUpdatesTheSlidesAndTheServiceRow() async {
        await openEditor()
        let row = item("Amazing Grace")
        editor.typeLyrics("[Verse 1]\nOne\n\nTwo\n\n[Chorus]\nThree\nFour")
        XCTAssertEqual(song.slides.map(\.lines), [["One"], ["Two"], ["Three", "Four"]])
        XCTAssertEqual(song.groups?.map(\.name), ["Verse 1", "Chorus"])
        XCTAssertEqual(service.items.first { $0.id == row.id }?.slideCount, 3, "the service row follows")
        await until("the engine has the new slides") { [self] in stage.state.slides[row.id]?.count == 3 }
    }

    func testATrailingBlankLineOrAnEmptyHeadingSurvivesTyping() async {
        await openEditor()
        editor.typeLyrics("[Verse 1]\nOne\n\n")
        XCTAssertEqual(editor.lyricsText, "[Verse 1]\nOne\n\n", "the draft is kept while it means the same slides")
        editor.typeLyrics("[Verse 1]\nOne\n\n[Bridge]")
        XCTAssertEqual(editor.lyricsText, "[Verse 1]\nOne\n\n[Bridge]")
        XCTAssertEqual(song.slides.count, 1)
    }

    func testTheSlideTabEditsOneSlide() async {
        await openEditor()
        let first = song.slides[0].id
        editor.typeSlide(first, "Line A\nLine B\n")
        XCTAssertEqual(song.slides[0].lines, ["Line A", "Line B"])
        XCTAssertEqual(editor.slideText(first), "Line A\nLine B\n", "what was typed stays while it means the same lines")
        editor.setLabel(first, "Opening")
        XCTAssertEqual(song.slides[0].label, "Opening")
    }

    func testNewSlideGoesAfterTheSelectionInItsGroup() async {
        await openEditor()
        editor.selectedSlide = song.slides[0].id
        editor.addSlide()
        XCTAssertEqual(song.slides.count, 4)
        XCTAssertEqual(song.slides[1].lines, [])
        XCTAssertEqual(editor.selectedSlide, song.slides[1].id)
        XCTAssertEqual(editor.group(of: song.slides[1].id)?.name, "Verse 1")
        XCTAssertEqual(editor.slideInfo, "Slide 2 of 4 · Verse 1")
    }

    func testMovingASlideToAnotherGroup() async {
        await openEditor()
        let slide = song.slides[2].id
        let verse1 = editor.groups[0].id
        editor.setGroup(slide, to: verse1)
        XCTAssertEqual(editor.group(of: slide)?.name, "Verse 1")
        XCTAssertEqual(song.slides[2].label, "Verse 1", "the label followed the group name")
        XCTAssertEqual(song.groups?.map(\.name), ["Verse 1", "Verse 2"], "an emptied group goes")
    }

    // MARK: Text tab

    func testLinesPerSlide() async {
        await openEditor()
        editor.setLinesPerSlide(1)
        XCTAssertEqual(song.linesPerSlide, 1)
        XCTAssertEqual(song.slides.count, 6)
        editor.typeLyrics("[Verse]\na\nb\nc")
        XCTAssertEqual(song.slides.map(\.lines), [["a"], ["b"], ["c"]], "typed text is split too")
        editor.setLinesPerSlide(nil)
        XCTAssertNil(song.linesPerSlide)
        XCTAssertEqual(song.slides.count, 3, "off: slides as they are")
    }

    func testCapitalization() async throws {
        await openEditor()
        let row = item("Amazing Grace")
        editor.setCapitalization(.none)
        XCTAssertNil(song.capitalization, "None on a song that never had a setting leaves it unset")
        editor.setCapitalization(.allCaps)
        XCTAssertEqual(song.capitalization, .allCaps)
        XCTAssertEqual(song.slides[0].lines[0], "Amazing grace, how sweet the sound", "the typed text is kept")
        await until("the engine has the capitals") { [self] in
            stage.state.slides[row.id]?.first?.lines.first == "AMAZING GRACE, HOW SWEET THE SOUND"
        }
        editor.setCapitalization(.sentenceCase)
        XCTAssertEqual(song.capitalization, .sentenceCase)
        editor.setCapitalization(.none)
        XCTAssertEqual(song.capitalization, SongCapitalization.none)
    }

    // MARK: Song fields

    func testSongFields() async {
        await openEditor()
        editor.setTitle("Amazing Grace (My Chains)")
        editor.setText(\.author, "John Newton", key: "author")
        editor.setText(\.copyright, "Public domain", key: "copyright")
        editor.setText(\.ccliNumber, "22025", key: "ccli")
        editor.setKey("G")
        editor.setTempo("72 bpm")
        editor.setCollection(nil)
        XCTAssertEqual(song.title, "Amazing Grace (My Chains)")
        XCTAssertEqual(song.copyright, "Public domain")
        XCTAssertEqual(song.ccliNumber, "22025")
        XCTAssertEqual(song.key, "G")
        XCTAssertEqual(song.tempo, 72)
        XCTAssertNil(song.collectionID)
        XCTAssertEqual(item("Amazing Grace (My Chains)").content, .song(song.id), "the service row is renamed")
        editor.setText(\.copyright, "", key: "copyright")
        XCTAssertNil(song.copyright, "an emptied field is removed, not stored as \"\"")
        XCTAssertNil(editor.mediaChip(nil))
        XCTAssertEqual(editor.canvasSize, "1920 × 1080")
    }

    // MARK: Undo / Redo

    func testUndoRedo() async {
        await openEditor()
        let original = song
        XCTAssertFalse(editor.canUndo)
        editor.setTitle("A")
        editor.setTitle("Am") // typing in the same field within a second: one step
        editor.setKey("D")
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertNil(song.key)
        XCTAssertEqual(song.title, "Am")
        editor.undo()
        XCTAssertEqual(song, original, "both title keystrokes were one step")
        XCTAssertFalse(editor.canUndo)

        editor.redo()
        XCTAssertEqual(song.title, "Am")
        editor.redo()
        XCTAssertEqual(song.key, "D")
        XCTAssertFalse(editor.canRedo)

        editor.undo()
        editor.setKey("E")
        XCTAssertFalse(editor.canRedo, "a new edit clears Redo")
        XCTAssertEqual(service.items.first { $0.content == .song(song.id) }?.title, "Am", "undo goes through the Studio too")
    }

    func testUndoRestoresLyricsAndTheTextTab() async {
        await openEditor()
        let original = song
        editor.typeLyrics("[Verse 1]\nOnly one")
        XCTAssertEqual(song.slides.count, 1)
        editor.undo()
        XCTAssertEqual(song, original)
        XCTAssertEqual(editor.lyricsText, SongLyrics.text(of: original))
    }

    // MARK: Saving and the outputs

    func testAnEditWritesOnlyTheSongsFiles() async {
        await openEditor()
        let count = controller.studios.saveCount
        editor.setKey("G")
        XCTAssertFalse(editor.isSaved)
        let written = await saved(after: count)
        XCTAssertEqual(Set(written), ["library/\(song.id.uuidString).json", "manifest.json"])
        XCTAssertTrue(editor.isSaved)
    }

    /// The proof through the editor: editing the live song changes the engine's slides, never the outputs.
    func testEditingTheLiveSongDoesNotChangeTheOutputs() async throws {
        await openEditor()
        let row = item("Amazing Grace")
        stage.send(.go(itemID: row.id, slideIndex: 1))
        await until("live") { [self] in stage.state.primaryLive?.slideIndex == 1 }
        let screens = stage.state.screens
        editor.typeSlide(song.slides[1].id, "Edited while live")
        editor.setCapitalization(.allCaps)
        editor.setTitle("Renamed while live")
        await until("the engine reloads") { [self] in stage.state.slides[row.id]?[1].lines == ["EDITED WHILE LIVE"] }
        XCTAssertEqual(stage.state.screens, screens, "the outputs did not change")
        stage.send(.go(itemID: row.id, slideIndex: 1))
        await until("taken again") { [self] in stage.state.primaryLive?.lines == ["EDITED WHILE LIVE"] }
    }

    func testAnEditorOfASongThatIsGoneShowsNothing() async {
        await openEditor()
        let id = song.id
        controller.edit { $0.songs.removeAll { $0.id == id } }
        XCTAssertNil(editor.song)
        editor.setKey("G") // no crash, nothing happens
        XCTAssertFalse(editor.canUndo)
    }

    // MARK: Menus

    func testNewSongAndExportSelectedItem() async throws {
        await launch()
        let id = try XCTUnwrap(controller.newSong())
        XCTAssertEqual(studio.songs.first { $0.id == id }?.title, "Untitled Song")

        let row = item("Amazing Grace")
        let song = try XCTUnwrap(controller.song(for: row))
        let file = FileMenuModel(hasStudio: true, isModalOpen: false, selectedSong: song.id)
        XCTAssertTrue(file.canExportSelectedItem, "a selected song can be exported")
        XCTAssertTrue(file.canEditSelectedItem)
        XCTAssertNil(controller.song(for: item("Walk-in loop")), "media is not a song")
        XCTAssertFalse(FileMenuModel(hasStudio: true, isModalOpen: false, selectedSong: nil).canExportSelectedItem)
        XCTAssertFalse(FileMenuModel(hasStudio: true, isModalOpen: true, selectedSong: song.id).canExportSelectedItem)

        let target = temp.appendingPathComponent("Amazing Grace.stgitem")
        dialogs.saveAnswer = target
        controller.exportSong(song.id)
        let imported = try StudioItemCodec().decode(Data(contentsOf: target))
        XCTAssertEqual(imported.items, [.song(song)])
        XCTAssertEqual(controller.notice, "Exported “Amazing Grace” to Amazing Grace.stgitem.")
    }

    func testEditorShortcuts() {
        XCTAssertEqual(Shortcuts.newSong, KeyboardShortcut("n", modifiers: [.command, .option]), "MenuBar.dc.html: ⌥⌘N")
        XCTAssertEqual(Shortcuts.editSelectedItem, KeyboardShortcut("e", modifiers: .command), "MenuBarRef.dc.html: ⌘E")
        XCTAssertEqual(Shortcuts.undo, KeyboardShortcut("z", modifiers: .command))
        XCTAssertEqual(Shortcuts.redo, KeyboardShortcut("z", modifiers: [.command, .shift]))
        XCTAssertEqual(Set(Shortcuts.all).count, Shortcuts.all.count, "no shortcut used twice")
        XCTAssertFalse(Shortcuts.unmodified.contains(Shortcuts.editSelectedItem))
    }

    func testOnlyOneModelPerSong() {
        let delegate = AppDelegate()
        defer { delegate.studios.shutdown() }
        let target = SongEditorTarget(studioID: UUID(), songID: UUID())
        let a = delegate.editors.model(for: target, controller: delegate.studios)
        XCTAssertTrue(a === delegate.editors.model(for: target, controller: delegate.studios))
        delegate.editors.close(target)
        XCTAssertFalse(a === delegate.editors.model(for: target, controller: delegate.studios))
    }

    func testAnOpenEditorIsNotModalAndNotLive() async {
        await openEditor()
        let ui = OperatorUIState()
        editor.setKey("G")
        XCTAssertFalse(ui.isModalOpen, "an editor window is not a sheet")
        XCTAssertFalse(QuitWarning.isLive(stage.state), "an editor does not make the show live")
    }
}
