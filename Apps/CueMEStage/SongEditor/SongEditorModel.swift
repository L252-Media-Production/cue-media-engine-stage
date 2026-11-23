import Foundation
import Observation
import StageKit
import SwiftUI

/// What a Song editor window edits: a song of a Studio. The window's value, so there is one window per song.
struct SongEditorTarget: Codable, Hashable {
    var studioID: UUID
    var songID: Song.ID
}

/// The Song editor's state and edits (SongEditor.dc.html). Every edit goes straight to the Studio through
/// `StudioController.updateSong` (autosave about a second later, then `reloadStudio`), so there is nothing to save on
/// close. Undo and Redo work on the song only, never on show control.
///
/// Undo steps: one per edit, except that typing into the same field within `coalesceWindow` of the last keystroke is
/// one step.
@MainActor
@Observable
final class SongEditorModel {
    enum CentreTab: String, CaseIterable, Identifiable {
        case slide = "Slide"
        case text = "Text edit"
        case chords = "Chords"
        case timeline = "Timeline"
        var id: Self { self }
        var isEnabled: Bool { self == .slide || self == .text }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case song = "Song"
        case slide = "Slide"
        case text = "Text"
        var id: Self { self }
    }

    static let notAvailable = "Not available yet"
    static let coalesceWindow: TimeInterval = 1

    let target: SongEditorTarget
    @ObservationIgnored let controller: StudioController
    @ObservationIgnored var now: () -> Date = Date.init

    var centreTab = CentreTab.slide
    var inspectorTab = InspectorTab.song
    var selectedSlide: Slide.ID?
    /// Collapsed groups in the slide list.
    var collapsed: Set<SongGroup.ID> = []

    private(set) var undoStack: [Song] = []
    private(set) var redoStack: [Song] = []
    @ObservationIgnored private var coalesceKey: String?
    @ObservationIgnored private var lastEdit = Date.distantPast
    /// What was typed in the Text edit tab, kept while it still means the song's slides (a trailing blank line or a
    /// heading not yet followed by lines would otherwise vanish while typing).
    private var lyricsDraft: String?
    private var slideDrafts: [Slide.ID: String] = [:]

    init(target: SongEditorTarget, controller: StudioController) {
        self.target = target
        self.controller = controller
    }

    // MARK: Reading

    /// The song, while the Studio it belongs to is open and still has it.
    var song: Song? {
        guard let studio = controller.studios.studio, studio.id == target.studioID else { return nil }
        return studio.songs.first { $0.id == target.songID }
    }

    var studio: Studio? { controller.studios.studio }
    var groups: [SongGroup] { song.map(SongLyrics.groups(of:)) ?? [] }
    /// Shown only while the autosave fails (it retries on its own); nil otherwise.
    var saveProblem: String? {
        controller.studios.notice?.hasPrefix(StudioStore.saveFailedPrefix) == true ? Self.notSaved : nil
    }

    static let notSaved = "Not saved, retrying"

    /// Closes the editor's window (set by the view once it is in one). Done: there is nothing left to save.
    @ObservationIgnored var closeWindow: (() -> Void)?
    func done() { closeWindow?() }
    var canUndo: Bool { !undoStack.isEmpty && song != nil }
    var canRedo: Bool { !redoStack.isEmpty && song != nil }

    /// The selected slide, else the first.
    var currentSlide: Slide? {
        guard let song else { return nil }
        return song.slides.first { $0.id == selectedSlide } ?? song.slides.first
    }

    var currentIndex: Int? {
        guard let song, let slide = currentSlide else { return nil }
        return song.slides.firstIndex { $0.id == slide.id }
    }

    func group(of slide: Slide.ID) -> SongGroup? { song.flatMap { SongLyrics.group(of: slide, in: $0) } }

    /// "Slide 3 of 8 · Chorus" (SongEditor.dc.html `slideInfo`).
    var slideInfo: String {
        guard let song, let index = currentIndex, let slide = currentSlide else { return "No slides" }
        let base = "Slide \(index + 1) of \(song.slides.count)"
        return group(of: slide.id).map { "\(base) · \($0.name)" } ?? base
    }

    /// Runs of neighbouring slides in one group, in song order: the left list's group headers and slides.
    struct Run: Identifiable, Equatable {
        var id: String
        var group: SongGroup?
        var slides: [(number: Int, slide: Slide)]
        static func == (a: Run, b: Run) -> Bool { a.id == b.id && a.group == b.group && a.slides.map(\.slide) == b.slides.map(\.slide) }
    }

    var runs: [Run] {
        guard let song else { return [] }
        var runs: [Run] = []
        for (i, slide) in song.slides.enumerated() {
            let group = SongLyrics.group(of: slide.id, in: song)
            if let last = runs.last, last.group?.id == group?.id {
                runs[runs.count - 1].slides.append((i + 1, slide))
            } else {
                runs.append(Run(id: "\(i)-\(group?.id.uuidString ?? "none")", group: group, slides: [(i + 1, slide)]))
            }
        }
        return runs
    }

    // MARK: Editing

    /// Applies an edit to the song and commits it. `coalesce` names the field being typed into.
    func change(coalesce key: String? = nil, _ body: (inout Song) -> Void) {
        guard var song else { return }
        let before = song
        body(&song)
        guard song != before else { return }
        let time = now()
        if key == nil || key != coalesceKey || time.timeIntervalSince(lastEdit) > Self.coalesceWindow {
            undoStack.append(before)
        }
        redoStack = []
        coalesceKey = key
        lastEdit = time
        controller.updateSong(song)
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = song else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = song else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ song: Song) {
        coalesceKey = nil
        lyricsDraft = nil
        slideDrafts = [:]
        controller.updateSong(song)
    }

    // Song fields

    func setTitle(_ text: String) { change(coalesce: "title") { $0.title = text } }
    func setText(_ path: WritableKeyPath<Song, String?>, _ text: String, key: String) {
        change(coalesce: key) { $0[keyPath: path] = text.isEmpty ? nil : text }
    }
    func setKey(_ key: String?) { change { $0.key = key } }
    func setTempo(_ text: String) {
        let digits = text.filter(\.isNumber)
        change(coalesce: "tempo") { $0.tempo = digits.isEmpty ? nil : Int(digits.prefix(3)) }
    }
    func setCollection(_ id: StudioCollection.ID?) { change { $0.collectionID = id } }

    // Text tab

    func setLinesPerSlide(_ n: Int?) {
        lyricsDraft = nil
        change { $0 = SongLyrics.settingLinesPerSlide(n, of: $0) }
    }

    func setCapitalization(_ mode: SongCapitalization) {
        // None on a song that never had a setting stays unset, so its file does not change.
        change { $0.capitalization = (mode == .none && $0.capitalization == nil) ? nil : mode }
    }

    // Lyrics (Text edit tab)

    /// The Text edit tab's text: what was typed while it still describes the song, else the song as text.
    var lyricsText: String {
        guard let song else { return "" }
        let current = SongLyrics.text(of: song)
        if let draft = lyricsDraft, SongLyrics.text(of: SongLyrics.applying(text: draft, to: song)) == current { return draft }
        return current
    }

    func typeLyrics(_ text: String) {
        lyricsDraft = text
        change(coalesce: "lyrics") { $0 = SongLyrics.applying(text: text, to: $0) }
    }

    // Slides

    /// The text of one slide as edited in the Slide tab's text box.
    func slideText(_ id: Slide.ID) -> String {
        guard let slide = song?.slides.first(where: { $0.id == id }) else { return "" }
        if let draft = slideDrafts[id], Self.lines(draft) == slide.lines { return draft }
        return slide.lines.joined(separator: "\n")
    }

    func typeSlide(_ id: Slide.ID, _ text: String) {
        slideDrafts[id] = text
        lyricsDraft = nil
        change(coalesce: "slide-\(id)") { song in
            guard let i = song.slides.firstIndex(where: { $0.id == id }) else { return }
            song.slides[i].lines = Self.lines(text)
        }
    }

    /// Lines of a slide's text: trimmed, with no blank lines at the start or end.
    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    func setLabel(_ id: Slide.ID, _ label: String) {
        change(coalesce: "label-\(id)") { song in
            guard let i = song.slides.firstIndex(where: { $0.id == id }) else { return }
            song.slides[i].label = label
        }
    }

    /// Moves a slide into another group. Its label follows when it was the old group's name.
    func setGroup(_ slideID: Slide.ID, to groupID: SongGroup.ID) {
        lyricsDraft = nil
        change { song in
            song = SongLyrics.materialized(song)
            guard var groups = song.groups, let target = groups.firstIndex(where: { $0.id == groupID }),
                  let i = song.slides.firstIndex(where: { $0.id == slideID }) else { return }
            let old = groups.firstIndex { $0.slideIDs.contains(slideID) }
            if let old, old == target { return }
            if let old { groups[old].slideIDs.removeAll { $0 == slideID } }
            groups[target].slideIDs.append(slideID)
            if old.map({ song.slides[i].label == groups[$0].name }) ?? song.slides[i].label.isEmpty {
                song.slides[i].label = groups[target].name
            }
            song.groups = groups.filter { !$0.slideIDs.isEmpty }
        }
    }

    /// "+ New slide" and the list's "+": an empty slide after the selected one, in its group.
    func addSlide() {
        guard song != nil else { return }
        let slide = Slide(label: currentSlide.flatMap { group(of: $0.id)?.name } ?? "", lines: [])
        let after = currentIndex
        lyricsDraft = nil
        change { song in
            song = SongLyrics.materialized(song)
            let at = after.map { $0 + 1 } ?? song.slides.count
            song.slides.insert(slide, at: at)
            if let previous = after.map({ song.slides[$0].id }),
               let g = song.groups?.firstIndex(where: { $0.slideIDs.contains(previous) }) {
                song.groups?[g].slideIDs.append(slide.id)
            }
        }
        selectedSlide = slide.id
    }

    // MARK: Read-only references

    /// A media library item's chip text ("Walk-in loop · 3:00"), or nil.
    func mediaChip(_ id: MediaItem.ID?) -> String? {
        guard let id else { return nil }
        guard let entry = studio?.media.first(where: { $0.id == id }) else { return "Missing media" }
        return entry.duration.map { "\(entry.name) · \(ServiceListModel.duration($0))" } ?? entry.name
    }

    /// The canvas size of the Studio's first audience screen ("1920 × 1080"), when there is one.
    var canvasSize: String? {
        guard let screen = studio?.screens.first(where: { $0.setup.type == .audience }) else { return nil }
        return "\(screen.setup.canvas.width) × \(screen.setup.canvas.height)"
    }

    /// Keys offered in the Key menu.
    static let keys = ["C", "C#", "Db", "D", "D#", "Eb", "E", "F", "F#", "Gb", "G", "G#", "Ab", "A", "A#", "Bb", "B",
                       "Cm", "C#m", "Dm", "D#m", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "A#m", "Bbm", "Bm"]
}

extension EnvironmentValues {
    /// Opens the Song editor for a song of the open Studio (one window per song). nil where no editor can be opened.
    @Entry var editSong: ((Song.ID, Slide.ID?) -> Void)?
}

extension SongEditorScene {
    /// Readies the editor of `song` before its window opens: with `slide`, that slide is selected in the Slide tab
    /// (also in an editor that is already open); without, a new editor starts on the first slide and an open one
    /// keeps its selection. Returns the window's value, nil when the song is not in the open Studio.
    @MainActor @discardableResult
    static func prepare(_ song: Song.ID, slide: Slide.ID? = nil, studios: StudioController) -> SongEditorTarget? {
        guard let studio = studios.studios.studio, let found = studio.songs.first(where: { $0.id == song }) else { return nil }
        let target = SongEditorTarget(studioID: studio.id, songID: song)
        let isNew = !studios.editors.openTargets.contains(target)
        let model = studios.editors.model(for: target, controller: studios)
        if let slide, found.slides.contains(where: { $0.id == slide }) {
            model.selectedSlide = slide
            model.centreTab = .slide
        } else if isNew {
            model.selectedSlide = found.slides.first?.id
        }
        return target
    }

    /// Opens the editor of `song` (see `prepare`), or brings its window to the front when it is open.
    @MainActor
    static func open(_ song: Song.ID, slide: Slide.ID? = nil, studios: StudioController, with openWindow: OpenWindowAction) {
        guard let target = prepare(song, slide: slide, studios: studios) else { return }
        openWindow(id: id, value: target)
    }
}

/// The open editors' models, one per song, kept while their window is open.
@MainActor
final class SongEditorRegistry {
    private var models: [SongEditorTarget: SongEditorModel] = [:]

    func model(for target: SongEditorTarget, controller: StudioController) -> SongEditorModel {
        if let model = models[target] { return model }
        let model = SongEditorModel(target: target, controller: controller)
        models[target] = model
        return model
    }

    func close(_ target: SongEditorTarget) { models[target] = nil }
    var openTargets: Set<SongEditorTarget> { Set(models.keys) }
}
