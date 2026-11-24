import SwiftUI
import StageKit
import UniformTypeIdentifiers

/// The bottom panel's Media tab (Main.dc.html L259-L330; boards "Operator view – Media bin" and "Media bin – Add menu"):
/// folders with search and "+ Add ▾" on the left (250 pt), the grid of video and photos (four columns), and the item
/// settings on the right (250 pt). Double-click or drag a tile into the service to add it as a media row.
struct MediaBinView: View {
    let studios: StudioController
    @Bindable var ui: OperatorUIState
    @Environment(\.theme) private var theme
    @State private var selection: BinSelection = .all
    @State private var query = ""
    @State private var filter: MediaKindFilter = .all
    @State private var selectedItem: MediaItem.ID?
    @State private var dropTargeted = false

    init(studios: StudioController, ui: OperatorUIState, initialSelection: MediaItem.ID? = nil) {
        self.studios = studios
        _ui = Bindable(ui)
        _selectedItem = State(initialValue: initialSelection)
    }

    private var library: MediaLibrary { studios.media }

    private var model: MediaBinModel {
        MediaBinModel(studio: studios.studios.studio, selection: selection, query: query, filter: filter, selectedItem: selectedItem,
                      isMissing: { [library, relink = studios.relinkReport] in library.isMissing($0, relink: relink) },
                      isLinkedHere: { [studios] in studios.isLinkedHere($0) })
    }

    var body: some View {
        let model = model
        BinColumns(keys: .media, labels: ("Folder column width", "Inspector width"), probe: "media") {
            folderColumn(model)
        } middle: {
            grid(model)
        } trailing: {
            ColumnScroll {
                MediaInspector(model: model, entry: model.selected, studios: studios)
            }
        }
        .disabled(studios.studios.studio == nil)
    }

    // MARK: Folders

    private func folderColumn(_ model: MediaBinModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BinSearchField(prompt: MediaBinModel.searchPrompt, text: $query)
                Menu {
                    Button(MediaBinModel.addItems[0]) { ui.binDialog = .newFolder(.media) }
                    Button(MediaBinModel.addItems[1]) { chooseFiles() }
                    Button(MediaBinModel.addItems[2]) { ui.binDialog = .linkFolder(nil) }
                } label: {
                    Text("\(MediaBinModel.addTitle) ▾").fontWeight(.semibold).foregroundStyle(theme.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Add media")
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(model.rows) { row in
                        BinFolderRow(row: row, icon: folderIcon(row), isSelected: row.selection == model.selection && !model.isSearching,
                                     linkedDot: row.linkedPath.map { studios.isLinkedHere($0) ? theme.ok : theme.warning }) {
                            selection = row.selection
                            selectedItem = nil
                            query = ""
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            BinDropHint(text: MediaBinModel.dropHint, targeted: dropTargeted)
                .padding(8)
        }
        .dropDestination(for: URL.self) { urls, _ in dropped(urls) } isTargeted: { dropTargeted = $0 }
    }

    private func folderIcon(_ row: BinListing.FolderRow) -> String {
        if row.selection == .all { return "square.grid.2x2" }
        if row.linkedPath != nil { return "arrow.triangle.2.circlepath" }
        return row.hasChildren ? "chevron.down" : "folder"
    }

    // MARK: Grid

    private func grid(_ model: MediaBinModel) -> some View {
        VStack(spacing: 0) {
            header(model)
            let tiles = model.tiles
            if tiles.isEmpty {
                EmptyMessage(text: model.emptyText).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 40), spacing: 10), count: BinLayout.columns), spacing: 10) {
                        ForEach(tiles) { tile in
                            MediaTile(tile: tile, isSelected: tile.id == model.selected?.id, library: library)
                                .onTapGesture(count: 2) { studios.addMediaToService(tile.id) }
                                .onTapGesture { selectedItem = tile.id }
                                .draggable(MediaDrag.payload(tile.id))
                                .contextMenu {
                                    Button(MediaBinModel.addToShowTitle) { studios.addMediaToService(tile.id) }
                                }
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in dropped(urls) }
    }

    private func header(_ model: MediaBinModel) -> some View {
        HStack(spacing: 10) {
            Text(model.title).fontWeight(.bold).lineLimit(1)
            if let path = model.linkedPath {
                HStack(spacing: 6) {
                    Circle().fill(model.linkedHere ? theme.ok : theme.warning).frame(width: 6, height: 6)
                    Text(model.linkedHere ? MediaBinModel.linkedLabel : MediaBinModel.notHereLabel)
                }
                .font(.system(size: 11))
                .foregroundStyle(model.linkedHere ? theme.accent : theme.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(theme.selection, in: Capsule())
                Text(LinkFolderModel.displayPath(URL(fileURLWithPath: path)))
                    .font(ThemeTokens.mono(11)).foregroundStyle(theme.textSecondary).lineLimit(1).truncationMode(.middle)
            } else if !model.isSearching {
                Text(MediaBinModel.dragHint).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("Type", selection: $filter) {
                ForEach(MediaKindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Show all media, video only or photos only")
            .accessibilityLabel("Type filter")
            if let folder = model.currentFolder, folder.linkedPath != nil, !model.isSearching {
                Button(MediaBinModel.unlinkTitle) { studios.unlinkFolder(folder.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .help("Stop linking this folder. Its items stay; nothing on disk changes")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
    }

    // MARK: Adding

    private var currentFolderID: StudioBinFolder.ID? {
        if case let .folder(id) = model.selection { return id }
        return nil
    }

    private func chooseFiles() {
        let urls = studios.dialogs.chooseFiles(title: AddFilesModel.title, types: MediaFileKind.panelTypes(.media))
        if !urls.isEmpty { ui.binDialog = .addFiles(.media, urls, folder: currentFolderID) }
    }

    /// Files from Finder open Add files; a folder opens Link a folder.
    private func dropped(_ urls: [URL]) -> Bool {
        guard studios.studios.studio != nil, !urls.isEmpty else { return false }
        if let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            ui.binDialog = .linkFolder(folder)
        } else {
            ui.binDialog = .addFiles(.media, urls, folder: currentFolderID)
        }
        return true
    }
}

enum BinLayout {
    // The side columns' widths are `BinColumnSizes` (resizable, 250 by default).
    /// L287: four columns.
    static let columns = 4
}

/// A bin item dragged into the service: a plain string, so no type has to be declared.
enum MediaDrag {
    static let prefix = "cueme-media:"
    static func payload(_ id: MediaItem.ID) -> String { prefix + id.uuidString }
    static func id(from payload: String) -> MediaItem.ID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}

/// One tile (L288-L296): 16:9 picture (a Quick Look thumbnail, else the board's gradient), the kind chip top left,
/// "⚠ Missing" top right, the length bottom left; the name under it. Selected: accent border.
private struct MediaTile: View {
    let tile: MediaBinModel.Tile
    let isSelected: Bool
    let library: MediaLibrary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MediaPicture(entry: tile.entry, library: library)
                VStack {
                    HStack {
                        BinOverlayChip(text: tile.kindLabel, fill: Color.black.opacity(0.65), text: .white)
                        Spacer()
                        if tile.isMissing { BinOverlayChip(text: MediaBinModel.missingLabel, fill: theme.warning, text: theme.onWarning) }
                    }
                    Spacer()
                    HStack {
                        BinOverlayChip(text: tile.duration, fill: Color.black.opacity(0.6), text: .white, mono: true)
                        Spacer()
                    }
                }
                .padding(4)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            Text(tile.entry.name)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(isSelected ? theme.accent : theme.border, lineWidth: 2))
        .contentShape(Rectangle())
        .help("Double-click or drag into the service to add it")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.kindLabel.capitalized) \(tile.entry.name), \(tile.duration)\(tile.isMissing ? ", file missing" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The picture of a media item: its thumbnail when Quick Look made one, else the board's placeholder gradient.
struct MediaPicture: View {
    let entry: MediaIndexEntry
    let library: MediaLibrary
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.slideGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = library.thumbnails[entry.id] {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: entry.id) { library.requestThumbnail(entry) }
    }
}

/// The item settings column (L313-L329): picture, name and meta, TYPE, COMPOSITION, LAYER, WHEN IT ENDS (video), then
/// "Add to show" and "Go live". Only "Add to show" has something behind it; the rest are drawn and disabled.
private struct MediaInspector: View {
    let model: MediaBinModel
    let entry: MediaIndexEntry?
    let studios: StudioController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry {
                MediaPicture(entry: entry, library: studios.media)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).fontWeight(.bold).lineLimit(1).truncationMode(.middle)
                    Text(model.meta(entry)).font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                BinField(label: "TYPE") { BinSegments(options: MediaBinModel.typeOptions, selected: nil, help: BinHelp.mediaType) }
                BinField(label: "COMPOSITION") { BinMenuBox(text: "—", help: BinHelp.composition) }
                BinField(label: "LAYER") { BinMenuBox(text: "—", help: BinHelp.layer) }
                if entry.kind == .video {
                    BinField(label: "WHEN IT ENDS") { BinSegments(options: MediaBinModel.endOptions, selected: nil, help: BinHelp.mediaEnd) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(MediaBinModel.addToShowTitle) { studios.addMediaToService(entry.id) }
                        .buttonStyle(PanelButtonStyle(kind: .secondary, height: 28))
                        .disabled(studios.studios.studio?.activeService == nil)
                        .help("Add it to the end of the service")
                    Button(MediaBinModel.goLiveTitle) {}
                        .buttonStyle(PanelButtonStyle(kind: .primary, height: 28))
                        .disabled(true)
                        .help(BinHelp.goLive)
                }
            } else {
                EmptyMessage(text: "Select a video or photo").frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .layoutProbe("media.inspector")
    }
}

// MARK: Shared parts of both bins

/// 24 pt search field (L264).
struct BinSearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
    }
}

/// A folder row (L276-L281, `rowBase`): icon, name (bold when selected), a green dot for a linked folder, the count.
struct BinFolderRow: View {
    let row: BinListing.FolderRow
    let icon: String
    let isSelected: Bool
    var linkedDot: Color?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(theme.textSecondary).frame(width: 16)
                Text(row.name).fontWeight(isSelected ? .bold : .medium).lineLimit(1)
                Spacer(minLength: 4)
                if let linkedDot { Circle().fill(linkedDot).frame(width: 7, height: 7).help("Linked to a folder on this Mac") }
                Text("\(row.count)").font(ThemeTokens.mono(11)).foregroundStyle(theme.textSecondary)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .padding(.leading, 8 + CGFloat(row.depth) * 18)
            .background(isSelected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.name), \(row.count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The dashed drop box at the foot of the folder column (L284, L428).
struct BinDropHint: View {
    let text: String
    var targeted = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(targeted ? theme.accent : theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? theme.accent : theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// A small label on a picture (kind, length, missing).
struct BinOverlayChip: View {
    let text: String
    let fill: Color
    let textColor: Color
    var mono = false

    init(text: String, fill: Color, text textColor: Color, mono: Bool = false) {
        self.text = text
        self.fill = fill
        self.textColor = textColor
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(mono ? ThemeTokens.mono(9) : .system(size: 9, weight: .bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(fill, in: RoundedRectangle(cornerRadius: 3))
            .lineLimit(1)
    }
}

/// A labelled block of the settings column (`label` style over its control, 3 pt apart).
struct BinField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: label)
            content
        }
    }
}

/// The board's segmented row (`segStyle`). `selected` nil with a `help`: drawn and disabled (nothing backs it yet).
struct BinSegments: View {
    let options: [String]
    let selected: Int?
    var help: String?
    var pick: ((Int) -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, title in
                let on = index == selected
                Button { pick?(index) } label: {
                    Text(title)
                        .font(.system(size: 12, weight: on ? .bold : .regular))
                        .foregroundStyle(on ? theme.onAccent : theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(on ? theme.accent : theme.surfaceRaised)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        .disabled(pick == nil)
        .opacity(pick == nil ? 0.5 : 1)
        .help(help ?? "")
    }
}

/// A drop-down box drawn and disabled (COMPOSITION, LAYER).
struct BinMenuBox: View {
    let text: String
    let help: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            Text("▾").foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        .opacity(0.5)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}
