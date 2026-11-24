import SwiftUI
import StageKit

/// The bottom panel's Audio tab (Main.dc.html L415-L466; board "Operator view – Audio bin"): the LIBRARY folders with
/// counts, search and "+ Add" on the left, the track list (play, name, waveform, length), and the inspector on the
/// right (name, format, waveform, VOLUME, FADE, WHEN IT ENDS). The inspector reads and writes the track's stored
/// audio settings (audio.json, by media id).
struct AudioBinView: View {
    let studios: StudioController
    let state: StageState
    let send: (Command) -> Void
    @Bindable var ui: OperatorUIState
    @Environment(\.theme) private var theme
    @State private var selection: BinSelection = .all
    @State private var query = ""
    @State private var selectedItem: MediaItem.ID?
    @State private var dropTargeted = false

    private var library: MediaLibrary { studios.media }

    private var model: AudioBinModel {
        AudioBinModel(studio: studios.studios.studio, audio: state.audio, selection: selection, query: query, selectedItem: selectedItem,
                      isMissing: { [library, relink = studios.relinkReport] in library.isMissing($0, relink: relink) })
    }

    var body: some View {
        let model = model
        HStack(spacing: 0) {
            libraryColumn(model)
                .frame(width: BinLayout.sideWidth)
            theme.border.frame(width: 1)
            trackList(model)
                .frame(maxWidth: .infinity)
            theme.border.frame(width: 1)
            Group {
                if let entry = model.selected {
                    AudioInspectorView(entry: entry, studios: studios).id(entry.id)
                } else {
                    EmptyMessage(text: "Select a track").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: BinLayout.sideWidth)
        }
        .disabled(studios.studios.studio == nil)
    }

    // MARK: Library

    private func libraryColumn(_ model: AudioBinModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BinSearchField(prompt: AudioBinModel.searchPrompt, text: $query)
                Button(AudioBinModel.addTitle) { chooseFiles() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.accent)
                    .help("Add audio files (in place: nothing is copied)")
                    .accessibilityLabel("Add audio files")
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // The board's LIBRARY head has no "+ New": folders come from the column's right-click menu.
                    head(AudioBinModel.libraryLabel) { EmptyView() }
                    ForEach(model.rows) { row in
                        BinFolderRow(row: row, icon: row.selection == .all ? "square.grid.2x2" : row.hasChildren ? "chevron.down" : "folder",
                                     isSelected: row.selection == model.selection && query.isEmpty) {
                            selection = row.selection
                            selectedItem = nil
                            query = ""
                        }
                    }
                    head(AudioBinModel.playlistsLabel) {
                        Button("+ New") {}
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .disabled(true)
                            .opacity(0.5)
                            .help(BinHelp.playlists)
                    }
                    .help(BinHelp.playlists)
                }
                .padding(.horizontal, 8)
            }
            .contextMenu { Button("New Folder…") { ui.binDialog = .newFolder(.audio) } }
            BinDropHint(text: AudioBinModel.dropHint, targeted: dropTargeted)
                .padding(8)
        }
        .dropDestination(for: URL.self) { urls, _ in dropped(urls) } isTargeted: { dropTargeted = $0 }
    }

    /// A LIBRARY / PLAYLISTS head (L421): the label, then its "+ New".
    private func head(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            SectionLabel(text: label)
            Spacer()
            trailing()
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 3, trailing: 8))
    }

    // MARK: Tracks

    private func trackList(_ model: AudioBinModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.title).fontWeight(.bold).lineLimit(1)
                Spacer()
                SectionLabel(text: AudioBinModel.durationLabel)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
            let tracks = model.tracks
            if tracks.isEmpty {
                EmptyMessage(text: model.emptyText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            TrackRow(track: track, isSelected: track.id == model.selected?.id, library: library) {
                                selectedItem = track.id
                                send(AudioBinModel.playCommand(track.id, state.audio))
                            }
                            .onTapGesture(count: 2) { studios.addMediaToService(track.id) }
                            .onTapGesture { selectedItem = track.id }
                            .draggable(MediaDrag.payload(track.id))
                            .contextMenu { Button(MediaBinModel.addToShowTitle) { studios.addMediaToService(track.id) } }
                        }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in dropped(urls) }
    }

    // MARK: Adding

    private var currentFolderID: StudioBinFolder.ID? {
        if case let .folder(id) = model.selection { return id }
        return nil
    }

    private func chooseFiles() {
        let urls = studios.dialogs.chooseFiles(title: AddFilesModel.title, types: MediaFileKind.panelTypes(.audio))
        if !urls.isEmpty { ui.binDialog = .addFiles(.audio, urls, folder: currentFolderID) }
    }

    private func dropped(_ urls: [URL]) -> Bool {
        guard studios.studios.studio != nil else { return false }
        let files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        guard !files.isEmpty else { return false }
        ui.binDialog = .addFiles(.audio, files, folder: currentFolderID)
        return true
    }
}

/// One track (L440-L450): play button (26 pt circle; accent while it plays), name (200 pt), waveform bars, the songs
/// that use it, the length.
private struct TrackRow: View {
    let track: AudioBinModel.Track
    let isSelected: Bool
    let library: MediaLibrary
    let play: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let on = track.play == .playing
        HStack(spacing: 12) {
            Button(action: play) {
                Image(systemName: on ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(on ? theme.onAccent : theme.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(on ? theme.accent : theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .help(track.play == .paused ? "Resume" : on ? "Pause" : BinHelp.preview)
            .accessibilityLabel(track.play == .paused ? "Resume \(track.entry.name)" : track.playLabel)
            Text(track.entry.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).frame(width: 200, alignment: .leading)
            WaveformBars(peaks: library.peaks[track.id], hot: on, height: 22)
                .task(id: track.id) { library.requestPeaks(track.entry) }
            if track.isMissing {
                Text(MediaBinModel.missingLabel).font(.system(size: 11)).foregroundStyle(theme.warning).lineLimit(1)
            }
            if let used = track.usedLabel {
                Text(used)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                    .help("The track of this song")
            }
            Text(track.duration).font(ThemeTokens.mono(12)).foregroundStyle(theme.textSecondary).frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? theme.selection : .clear)
        .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Waveform bars (L444 `mkBars`): the file's real peaks, 4 pt plus the level. Until they are read (or when the file is
/// missing) a flat line: nothing made up.
struct WaveformBars: View {
    let peaks: [Float]?
    let hot: Bool
    let height: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let color = hot ? theme.accent : theme.textSecondary.opacity(0.55)
        HStack(alignment: .center, spacing: 1) {
            if let peaks, !peaks.isEmpty {
                ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                    RoundedRectangle(cornerRadius: 1).fill(color)
                        .frame(maxWidth: .infinity, minHeight: 1)
                        .frame(height: 4 + CGFloat(peak) * (height - 6))
                }
            } else {
                Rectangle().fill(theme.border).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The inspector (L452-L465). VOLUME, FADE In and Out write the track's audio settings (Studio autosave, then the
/// engine reloads); WHEN IT ENDS, "Add to slide" and "Add to timeline" have nothing behind them yet and are disabled.
private struct AudioInspectorView: View {
    let entry: MediaIndexEntry
    let studios: StudioController
    @Environment(\.theme) private var theme
    @State private var volumeDraft: Double?
    @State private var fadeInText = ""
    @State private var fadeOutText = ""
    @FocusState private var focus: Fade?

    private enum Fade: Hashable { case fadeIn, fadeOut }

    private var settings: AudioSettings { studios.studios.studio?.audioSettings(for: entry.id) ?? AudioSettings(mediaID: entry.id) }
    private var missing: Bool { studios.media.isMissing(entry.id, relink: studios.relinkReport) }

    var body: some View {
        let settings = settings
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).fontWeight(.bold).lineLimit(1).truncationMode(.middle)
                Text(AudioBinModel.formatLine(entry, probe: studios.media.probes[entry.id], missing: missing))
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            WaveformBars(peaks: studios.media.peaks[entry.id], hot: true, height: 32)
                .padding(.horizontal, 6)
                .frame(height: 44)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
            BinField(label: "VOLUME") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { volumeDraft ?? settings.levelDB }, set: { volumeDraft = $0 }),
                           in: AudioInspector.volumeRange) { editing in
                        if !editing, let v = volumeDraft {
                            studios.setAudioSettings(AudioInspector.setting(settings, volume: v))
                            volumeDraft = nil
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Volume")
                    .accessibilityValue(AudioInspector.volumeText(volumeDraft ?? settings.levelDB))
                    Text(AudioInspector.volumeText(volumeDraft ?? settings.levelDB))
                        .font(ThemeTokens.mono(12)).foregroundStyle(theme.textSecondary).frame(minWidth: 50, alignment: .trailing)
                }
            }
            BinField(label: "FADE") {
                HStack(spacing: 8) {
                    fadeBox("In", text: $fadeInText, field: .fadeIn)
                    fadeBox("Out", text: $fadeOutText, field: .fadeOut)
                }
            }
            BinField(label: "WHEN IT ENDS") { BinSegments(options: AudioBinModel.endOptions, selected: nil, help: BinHelp.audioEnd) }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(AudioBinModel.addToSlideTitle) {}
                    .buttonStyle(PanelButtonStyle(kind: .secondary, height: 28, font: .system(size: 12)))
                    .disabled(true)
                    .help(BinHelp.addToSlide)
                Button(AudioBinModel.addToTimelineTitle) {}
                    .buttonStyle(PanelButtonStyle(kind: .secondary, height: 28, font: .system(size: 12)))
                    .disabled(true)
                    .help(BinHelp.addToTimeline)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: entry.id) {
            studios.media.requestProbe(entry)
            studios.media.requestPeaks(entry)
        }
        .onAppear(perform: loadFades)
        .onChange(of: settings) { _, _ in if focus == nil { loadFades() } }
        .onChange(of: focus) { old, _ in if let old { commit(old) } }
    }

    private func loadFades() {
        fadeInText = AudioInspector.fadeText(settings.fadeIn).replacingOccurrences(of: " s", with: "")
        fadeOutText = AudioInspector.fadeText(settings.fadeOut).replacingOccurrences(of: " s", with: "")
    }

    private func commit(_ field: Fade) {
        let text = field == .fadeIn ? fadeInText : fadeOutText
        guard let value = AudioInspector.parseSeconds(text) else { loadFades(); return }
        let next = field == .fadeIn ? AudioInspector.setting(settings, fadeIn: value) : AudioInspector.setting(settings, fadeOut: value)
        if next != settings { studios.setAudioSettings(next) }
        loadFades()
    }

    /// "In 0.5 s" (L460): the label dim, the value editable, "s" after it.
    private func fadeBox(_ label: String, text: Binding<String>, field: Fade) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 2)
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .focused($focus, equals: field)
                .onSubmit { commit(field) }
                .accessibilityLabel("Fade \(label.lowercased()), seconds")
            Text("s")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(focus == field ? theme.accent : theme.border, lineWidth: 1))
        .help("0 is a cut; 0.1 to 10 s")
    }
}
