import Foundation
import StageKit

// What the Media bin and the Audio bin show (Main.dc.html, media panel L259-L330 and audio bin L415-L466), and their
// dialogs (MediaDialog.dc.html). Pure, so wording, values and disabled controls are tested without the UI.

/// Tooltips of the controls the boards draw but the model or the engine cannot back yet. Each is drawn and disabled.
enum BinHelp {
    static let mediaType = "Background or foreground is not stored for media yet"
    static let composition = "Compositions are not available yet"
    static let layer = "Layers are not available yet"
    static let mediaEnd = "What a video does when it ends is not stored for media yet"
    static let goLive = "No command plays video or photos on the outputs yet"
    static let audioEnd = "What a track does when it ends is not stored in its audio settings yet"
    static let addToSlide = "The Song editor cannot set a song's track yet"
    static let addToTimeline = "The timeline is not available yet"
    static let playlists = "Playlists are not available yet"
    static let copyIntoLibrary = "CueME Stage never copies media: files stay where they are"
    static let optimize = "Optimizing (converting) files is not available yet"
    static let watch = "Watching a linked folder for changes is not available yet"
    static let preview = "Plays on the audio output: there is no preview or solo output yet"
}

/// Colour of a status chip or warning.
enum BinTone: Equatable { case accent, warning, live, dim }

/// "4:12"; a dash when the length is not known.
func binDuration(_ seconds: Double?) -> String { seconds.map(ServiceListModel.duration) ?? "—" }

// MARK: Media bin

struct MediaBinModel {
    struct Tile: Equatable, Identifiable {
        var entry: MediaIndexEntry
        /// The board's placeholder chip: the file kind.
        var kindLabel: String
        var duration: String
        var isMissing: Bool
        var id: MediaItem.ID { entry.id }
    }

    static let searchPrompt = "Search media"
    static let addTitle = "+ Add"
    static let addItems = ["New folder", "Add files…", "Link a folder…"]
    static let dropHint = "Drop files or folders from Finder here"
    static let dragHint = "Drag files in from Finder to add them"
    static let missingLabel = "⚠ Missing"
    static let linkedLabel = "Linked"
    static let notHereLabel = "Not linked on this Mac"
    static let unlinkTitle = "Unlink"
    static let addToShowTitle = "Add to show"
    static let goLiveTitle = "Go live"
    static let typeOptions = ["Background", "Foreground"]
    static let endOptions = ["↻ Loop", "■ Stop", "⏭ Next"]

    let listing: BinListing
    var selection: BinSelection
    var query: String
    var filter: MediaKindFilter
    var selectedItem: MediaItem.ID?
    var isMissing: (MediaItem.ID) -> Bool = { _ in false }
    var isLinkedHere: (String?) -> Bool = { _ in false }

    init(studio: Studio?, selection: BinSelection, query: String = "", filter: MediaKindFilter = .all, selectedItem: MediaItem.ID? = nil,
         isMissing: @escaping (MediaItem.ID) -> Bool = { _ in false }, isLinkedHere: @escaping (String?) -> Bool = { _ in false }) {
        listing = BinListing(studio: studio, bin: .media)
        self.selection = listing.resolve(selection)
        self.query = query
        self.filter = filter
        self.selectedItem = selectedItem
        self.isMissing = isMissing
        self.isLinkedHere = isLinkedHere
    }

    var rows: [BinListing.FolderRow] { listing.rows }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var currentFolder: StudioBinFolder? {
        if case let .folder(id) = selection { return listing.folder(id) }
        return nil
    }

    var title: String {
        if isSearching { return "Results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”" }
        return currentFolder?.name ?? BinListing.allTitle(.media)
    }

    /// The linked chip: nil for a folder that is not linked.
    var linkedPath: String? { isSearching ? nil : currentFolder?.linkedPath }
    var linkedHere: Bool { isLinkedHere(linkedPath) }

    var tiles: [Tile] {
        listing.items(in: selection, query: query, filter: filter).map { entry in
            Tile(entry: entry, kindLabel: entry.kind == .image ? "PHOTO" : "VIDEO",
                 duration: entry.kind == .image ? "—" : binDuration(entry.duration), isMissing: isMissing(entry.id))
        }
    }

    /// The selected item when it is shown, else the first one (the board selects the first).
    var selected: MediaIndexEntry? {
        let list = tiles
        return list.first { $0.id == selectedItem }?.entry ?? list.first?.entry
    }

    var emptyText: String {
        if listing.entries.isEmpty { return "No video or photos yet. Use + Add or drop files here." }
        return isSearching || filter != .all ? "Nothing found" : "This folder is empty"
    }

    /// "Video · 0:30 · Sunday Loops", "Photo · No folder", with "· file missing" when it is.
    func meta(_ entry: MediaIndexEntry) -> String {
        var parts = [entry.kind == .image ? "Photo" : "Video · \(binDuration(entry.duration))"]
        parts.append(entry.folderID.flatMap { listing.folder($0)?.name } ?? "No folder")
        if isMissing(entry.id) { parts.append("file missing") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Audio bin

struct AudioBinModel {
    struct Track: Equatable, Identifiable {
        enum Play: Equatable { case stopped, playing, paused }
        var entry: MediaIndexEntry
        var duration: String
        /// "♪ Amazing Grace": the songs that use it as their track; nil when none.
        var usedLabel: String?
        var isMissing: Bool
        var play: Play
        var id: MediaItem.ID { entry.id }
        var playLabel: String { (play == .playing ? "Pause " : "Play ") + entry.name }
    }

    static let searchPrompt = "Search audio"
    static let addTitle = "+ Add"
    static let dropHint = "Drop audio files here"
    static let libraryLabel = "LIBRARY"
    static let playlistsLabel = "PLAYLISTS"
    static let durationLabel = "DURATION"
    static let addToSlideTitle = "Add to slide"
    static let addToTimelineTitle = "Add to timeline"
    static let endOptions = ["↻ Loop", "■ Stop", "⏭ Next"]

    let listing: BinListing
    let studio: Studio?
    var selection: BinSelection
    var query: String
    var selectedItem: MediaItem.ID?
    let audio: AudioState
    var isMissing: (MediaItem.ID) -> Bool = { _ in false }

    init(studio: Studio?, audio: AudioState, selection: BinSelection, query: String = "", selectedItem: MediaItem.ID? = nil,
         isMissing: @escaping (MediaItem.ID) -> Bool = { _ in false }) {
        listing = BinListing(studio: studio, bin: .audio)
        self.studio = studio
        self.audio = audio
        self.selection = listing.resolve(selection)
        self.query = query
        self.selectedItem = selectedItem
        self.isMissing = isMissing
    }

    var rows: [BinListing.FolderRow] { listing.rows }

    var title: String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "Results for “\(q)”" }
        if case let .folder(id) = selection, let folder = listing.folder(id) { return folder.name }
        return BinListing.allTitle(.audio)
    }

    var tracks: [Track] {
        listing.items(in: selection, query: query).map { entry in
            let songs = (studio?.songs ?? []).filter { $0.audioTrackID == entry.id }.map(\.title).sorted()
            let used = songs.first.map { "♪ \($0)" + (songs.count > 1 ? " +\(songs.count - 1)" : "") }
            return Track(entry: entry, duration: binDuration(entry.duration), usedLabel: used, isMissing: isMissing(entry.id),
                         play: Self.playState(entry.id, audio))
        }
    }

    var selected: MediaIndexEntry? {
        let list = tracks
        return list.first { $0.id == selectedItem }?.entry ?? list.first?.entry
    }

    var emptyText: String {
        if listing.entries.isEmpty { return "No audio yet. Use + Add or drop audio files here." }
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? "This folder is empty" : "Nothing found"
    }

    static func playState(_ id: MediaItem.ID, _ audio: AudioState) -> Track.Play {
        guard audio.liveTrack == id else { return .stopped }
        switch audio.transport {
        case .playing, .fading: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        }
    }

    /// The play button: Pause while this track plays, Resume while it is paused, else Play with its stored settings.
    static func playCommand(_ id: MediaItem.ID, _ audio: AudioState) -> Command {
        switch playState(id, audio) {
        case .playing: .pauseAudio
        case .paused: .resumeAudio
        case .stopped: .playAudio(mediaID: id, options: AudioPlayOptions())
        }
    }

    /// The inspector's format line: "4:12 · 48 kHz stereo"; "file missing" or a dash for what is not known.
    static func formatLine(_ entry: MediaIndexEntry, probe: MediaProbe?, missing: Bool) -> String {
        let format = missing ? "file missing" : probe?.audioFormat ?? "—"
        return "\(binDuration(entry.duration ?? probe?.duration)) · \(format)"
    }
}

/// VOLUME and FADE of the Audio bin's inspector, kept to what the audio spec allows (docs/audio-spec-1.md): a level
/// that only turns down (-60 ... 0 dB) and fades of 0 (a cut) or 0.1 ... 10 s.
enum AudioInspector {
    static let volumeRange: ClosedRange<Double> = -60...0
    static let fadeRange: ClosedRange<Double> = 0.1...10

    static func clampVolume(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return (min(max(db, volumeRange.lowerBound), volumeRange.upperBound) * 10).rounded() / 10
    }

    /// 0 (or less) is a cut; anything else is held to 0.1 ... 10 s, to the millisecond.
    static func clampFade(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return (min(max(seconds, fadeRange.lowerBound), fadeRange.upperBound) * 1000).rounded() / 1000
    }

    /// "-6 dB", "-4.5 dB", "0 dB".
    static func volumeText(_ db: Double) -> String {
        let v = clampVolume(db)
        return (v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)) + " dB"
    }

    /// "0.5 s", "3 s", "0 s".
    static func fadeText(_ seconds: Double) -> String {
        let v = clampFade(seconds)
        return (v.rounded() == v ? "\(Int(v))" : String(format: "%g", v)) + " s"
    }

    /// Parses what the operator typed ("0.5", "3 s", "2,5"); nil when it is not a number.
    static func parseSeconds(_ text: String) -> Double? {
        let cleaned = text.lowercased().replacingOccurrences(of: "s", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    static func setting(_ base: AudioSettings, volume: Double? = nil, fadeIn: Double? = nil, fadeOut: Double? = nil) -> AudioSettings {
        var s = base
        if let volume { s.levelDB = clampVolume(volume) }
        if let fadeIn { s.fadeIn = clampFade(fadeIn) }
        if let fadeOut { s.fadeOut = clampFade(fadeOut) }
        return s
    }
}

// MARK: Dialogs (MediaDialog.dc.html)

extension AddFileRow {
    /// The Add files row's chip: Ready, Unsupported, Already in library; then the progress states.
    var statusText: String {
        switch status {
        case .ready: "Ready"
        case .unsupported: "Unsupported"
        case .alreadyInLibrary: "Already in library"
        case let .hashing(f): "Hashing \(Int((f * 100).rounded()))%"
        case .done: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    /// In the Adding files list (MediaDialog.dc.html `prog`): a file the bin cannot take shows as Skipped.
    var progressText: String { status == .unsupported ? "Skipped" : statusText }

    var statusTone: BinTone {
        switch status {
        case .ready, .done: .accent
        case .hashing: .warning
        case .unsupported, .skipped, .failed: .live
        case .alreadyInLibrary: .dim
        }
    }

    /// The progress bar, 0...1.
    var progress: Double {
        switch status {
        case let .hashing(f): f
        case .done, .alreadyInLibrary: 1
        default: 0
        }
    }

    var isPending: Bool { status == .ready }
}

struct AddFilesModel {
    static let title = "Add files"
    static let addToLabel = "ADD TO"
    static let storageLabel = "STORAGE"
    static let formatLabel = "PLAYBACK FORMAT"
    static let storageOptions = ["Copy into library", "Keep in place"]
    static let formatOptions = ["Optimize", "Keep original"]
    static let cancelTitle = "Cancel"
    static let addTitle = "Add"
    static let noFolder = "No folder"

    var rows: [AddFileRow]

    var ready: [AddFileRow] { rows.filter(\.isPending) }
    var canAdd: Bool { !ready.isEmpty }

    /// "4 files · 3.8 GB · original formats" (the files that will be added).
    var footer: String {
        let n = ready.count
        let bytes = ready.compactMap { $0.probe?.size }.reduce(0, +)
        return "\(n) file\(n == 1 ? "" : "s") · \(MediaProbe.size(bytes)) · original formats"
    }

    /// Folders of the bin for ADD TO, depth first ("Advent" indented under "Sunday Loops").
    static func folderChoices(_ listing: BinListing) -> [(id: StudioBinFolder.ID?, title: String)] {
        [(nil, noFolder)] + listing.rows.compactMap { row in
            guard case let .folder(id) = row.selection else { return nil }
            return (id, String(repeating: "   ", count: row.depth) + row.name)
        }
    }
}

struct AddProgressModel {
    static let backgroundTitle = "Run in background"
    static let doneTitle = "Done"

    var rows: [AddFileRow]
    var isFinished: Bool

    /// "Adding 4 files": every file the bin can take.
    var title: String {
        let n = rows.filter { $0.status != .unsupported }.count
        return "Adding \(n) file\(n == 1 ? "" : "s")"
    }

    /// "Hashing 1 of 2" while it runs; "3 added · 1 skipped" at the end.
    var footer: String {
        let work = rows.filter { $0.status != .unsupported }
        if !isFinished {
            let current = (work.firstIndex { if case .hashing = $0.status { true } else { false } } ?? 0) + 1
            return "Hashing \(min(current, max(work.count, 1))) of \(work.count)"
        }
        let added = rows.filter { $0.status == .done }.count
        let skipped = rows.filter { if case .failed = $0.status { true } else { [.skipped, .unsupported].contains($0.status) } }.count
        let known = rows.filter { $0.status == .alreadyInLibrary }.count
        var parts = ["\(added) added"]
        if known > 0 { parts.append("\(known) already in library") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }
}

struct LinkFolderModel {
    static let title = "Link a folder"
    static let chooseTitle = "Choose…"
    static let nameLabel = "NAME IN LIBRARY"
    static let options = ["Watch for changes", "Include subfolders", "Optimize new files automatically"]
    /// MediaDialog.dc.html's footer without "The library watches the folder.": watching is not built.
    static let footer = "Files stay where they are."
    static let linkTitle = "Link"
    static let noFolder = "No folder chosen"

    var folder: URL?
    var name = ""
    var includeSubfolders = true
    /// "12 videos · 4 photos · 5.8 GB"; nil while it is counted.
    var summary: String?

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canLink: Bool { folder != nil && !trimmedName.isEmpty }

    /// "~/Movies/Easter Services".
    static func displayPath(_ url: URL?) -> String {
        guard let path = url?.standardizedFileURL.path else { return noFolder }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    mutating func choose(_ url: URL) {
        folder = url
        if trimmedName.isEmpty { name = url.lastPathComponent }
        summary = nil
    }
}

struct NewBinFolderModel {
    static let title = "New folder"
    static let nameLabel = "NAME"
    static let insideLabel = "INSIDE"
    static let topLevel = "Top level"
    static let createTitle = "Create"

    var name = ""
    var parent: StudioBinFolder.ID?

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool { !trimmedName.isEmpty }

    static func parentChoices(_ listing: BinListing) -> [(id: StudioBinFolder.ID?, title: String)] {
        [(nil, topLevel)] + AddFilesModel.folderChoices(listing).dropFirst()
    }
}
