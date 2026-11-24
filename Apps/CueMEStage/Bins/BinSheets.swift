import SwiftUI
import StageKit

/// The bins' dialogs (MediaDialog.dc.html): a title row, the body, then a footer note with Cancel and the action.
/// 440 pt for New folder and Link a folder, 640 pt for Add files and Adding files.
struct BinDialogSheet: View {
    let dialog: BinDialog
    let studios: StudioController
    @Bindable var ui: OperatorUIState

    var body: some View {
        switch dialog {
        case let .newFolder(bin): NewBinFolderSheet(bin: bin, studios: studios, ui: ui)
        case let .addFiles(bin, urls, folder): AddFilesSheet(bin: bin, urls: urls, initialFolder: folder, studios: studios, ui: ui)
        case .progress: AddProgressSheet(library: studios.media, ui: ui)
        case let .linkFolder(url): LinkFolderSheet(initial: url, studios: studios, ui: ui)
        }
    }
}

/// The frame every bin dialog shares (MediaDialog.dc.html L23-L25, L94-L100).
private struct BinDialogFrame<Content: View, Buttons: View>: View {
    let title: String
    let width: CGFloat
    var footNote = ""
    @ViewBuilder let content: Content
    @ViewBuilder let buttons: Buttons
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            HStack(spacing: 8) {
                Text(footNote).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(2)
                Spacer()
                buttons
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { theme.border.frame(height: 1) }
        }
        .frame(width: width)
        .background(theme.surface)
        .foregroundStyle(theme.textPrimary)
    }
}

/// A 32 pt text box of the dialogs (NAME, NAME IN LIBRARY).
private struct DialogTextField: View {
    let prompt: String
    @Binding var text: String
    var accent = false
    let label: String
    var submit: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(accent ? theme.accent : theme.border, lineWidth: 1))
            .onSubmit(submit)
            .accessibilityLabel(label)
    }
}

/// A folder pop-up (INSIDE, ADD TO).
private struct FolderPicker: View {
    let choices: [(id: StudioBinFolder.ID?, title: String)]
    @Binding var selection: StudioBinFolder.ID?
    let label: String

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                Text(choice.title).tag(choice.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
    }
}

// MARK: New folder

/// Board "Media bin – New folder": NAME (focused, accent border), INSIDE (Top level or a folder of the bin), Create.
private struct NewBinFolderSheet: View {
    let bin: StudioBinFolder.Bin
    let studios: StudioController
    @Bindable var ui: OperatorUIState
    @State private var model = NewBinFolderModel()
    @FocusState private var focused: Bool

    var body: some View {
        BinDialogFrame(title: NewBinFolderModel.title, width: 440) {
            VStack(alignment: .leading, spacing: 12) {
                BinField(label: NewBinFolderModel.nameLabel) {
                    DialogTextField(prompt: "Easter", text: $model.name, accent: true, label: "Folder name", submit: create)
                        .focused($focused)
                }
                BinField(label: NewBinFolderModel.insideLabel) {
                    FolderPicker(choices: NewBinFolderModel.parentChoices(BinListing(studio: studios.studios.studio, bin: bin)),
                                 selection: $model.parent, label: "Inside")
                }
            }
        } buttons: {
            Button(AddFilesModel.cancelTitle) { ui.binDialog = nil }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 30))
                .keyboardShortcut(.cancelAction)
            Button(NewBinFolderModel.createTitle, action: create)
                .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 30))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
        }
        .onAppear { focused = true }
    }

    private func create() {
        guard model.canCreate else { return }
        studios.addBinFolder(named: model.trimmedName, in: bin, parent: model.parent)
        ui.binDialog = nil
    }
}

// MARK: Add files

/// Board "Media bin – Add files": the chosen files (picture, name, format, size, status), ADD TO, STORAGE (Keep in
/// place; Copy into library is off: files are never copied), PLAYBACK FORMAT (Keep original; Optimize is off), Add.
private struct AddFilesSheet: View {
    let bin: StudioBinFolder.Bin
    let urls: [URL]
    let initialFolder: StudioBinFolder.ID?
    let studios: StudioController
    @Bindable var ui: OperatorUIState
    @State private var rows: [AddFileRow] = []
    @State private var folder: StudioBinFolder.ID?
    @Environment(\.theme) private var theme

    var body: some View {
        let model = AddFilesModel(rows: rows)
        BinDialogFrame(title: AddFilesModel.title, width: 640, footNote: model.footer) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            FileRowView(row: row, meta: row.probe?.metaLine(kind: row.kind) ?? "—", size: MediaProbe.size(row.probe?.size))
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(alignment: .top, spacing: 14) {
                    BinField(label: AddFilesModel.addToLabel) {
                        FolderPicker(choices: AddFilesModel.folderChoices(BinListing(studio: studios.studios.studio, bin: bin)),
                                     selection: $folder, label: "Add to")
                    }
                    .frame(maxWidth: .infinity)
                    BinField(label: AddFilesModel.storageLabel) {
                        OneOnSegments(options: AddFilesModel.storageOptions, on: 1, offHelp: BinHelp.copyIntoLibrary)
                    }
                    .frame(maxWidth: .infinity)
                    BinField(label: AddFilesModel.formatLabel) {
                        OneOnSegments(options: AddFilesModel.formatOptions, on: 1, offHelp: BinHelp.optimize)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } buttons: {
            Button(AddFilesModel.cancelTitle) { ui.binDialog = nil }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 30))
                .keyboardShortcut(.cancelAction)
            Button(AddFilesModel.addTitle) {
                studios.media.startAdding(rows, bin: bin, folder: folder, studios: studios)
                ui.binDialog = .progress
            }
            .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 30))
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canAdd)
        }
        .onAppear {
            folder = initialFolder
            rows = urls.map { AddFileRow.make($0, bin: bin, index: studios.studios.studio?.media ?? []) }
        }
        .task {
            // Sizes and formats, read off the main thread.
            for i in rows.indices {
                let (url, kind) = (rows[i].url, rows[i].kind)
                let probe = await Task.detached(priority: .utility) { await MediaProbe.read(url, kind: kind) }.value
                if i < rows.count, rows[i].url == url { rows[i].probe = probe }
            }
        }
    }
}

/// Two segments with one fixed on: the other is drawn and disabled with its reason.
private struct OneOnSegments: View {
    let options: [String]
    let on: Int
    let offHelp: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, title in
                let isOn = index == on
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .bold : .regular))
                    .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isOn ? theme.accent : theme.surfaceRaised)
                    .opacity(isOn ? 1 : 0.5)
                    .help(isOn ? "" : offHelp)
                    .accessibilityLabel(title)
                    .accessibilityValue(isOn ? "Selected" : "Not available")
                    .accessibilityHint(isOn ? "" : offHelp)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
    }
}

/// A file of the Add files list: 44x25 picture, name and format, size, status chip.
private struct FileRowView: View {
    let row: AddFileRow
    let meta: String
    let size: String
    var showsBar = false
    @Environment(\.theme) private var theme
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                LinearGradient(colors: theme.slideGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            }
            .frame(width: 44, height: 25)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: showsBar ? 5 : 0) {
                Text(row.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                if showsBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            theme.border
                            tone.frame(width: geo.size.width * row.progress)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    Text(meta).font(ThemeTokens.mono(11)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !showsBar {
                Text(size).font(.system(size: 12)).foregroundStyle(theme.textSecondary).frame(width: 90, alignment: .trailing)
            }
            Text(showsBar ? row.progressText : row.statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(tone, lineWidth: 1))
                .fixedSize()
                .help(row.failureReason ?? "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsBar ? 8 : 7)
        .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
        .accessibilityElement(children: .combine)
        .task(id: row.url) {
            if row.kind == .video || row.kind == .image { image = await MediaThumbnails.make(row.url, size: CGSize(width: 88, height: 50)) }
        }
    }

    private var tone: Color {
        switch row.statusTone {
        case .accent: theme.accent
        case .warning: theme.warning
        case .live: theme.live
        case .dim: theme.textSecondary
        }
    }
}

extension AddFileRow {
    var failureReason: String? {
        if case let .failed(reason) = status { return reason }
        return nil
    }
}

// MARK: Adding progress

/// Board "Media bin – Adding files": each file with a bar and its state; "Run in background" closes the dialog and the
/// add goes on; Done once it is over.
private struct AddProgressSheet: View {
    let library: MediaLibrary
    @Bindable var ui: OperatorUIState
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = library.job?.rows ?? []
        let model = AddProgressModel(rows: rows, isFinished: library.job?.isFinished ?? true)
        BinDialogFrame(title: model.title, width: 640, footNote: model.footer) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in FileRowView(row: row, meta: "", size: "", showsBar: true) }
                }
            }
            .frame(maxHeight: 300)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } buttons: {
            Button(AddProgressModel.backgroundTitle) { ui.binDialog = nil }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 30))
                .keyboardShortcut(.cancelAction)
                .disabled(model.isFinished)
            Button(AddProgressModel.doneTitle) { ui.binDialog = nil }
                .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 30))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isFinished)
        }
    }
}

// MARK: Link a folder

/// Board "Media bin – Link a folder": the folder (path, what is in it, Choose…), NAME IN LIBRARY, and three switches:
/// Include subfolders works; Watch for changes and Optimize new files automatically are off (not built).
private struct LinkFolderSheet: View {
    let initial: URL?
    let studios: StudioController
    @Bindable var ui: OperatorUIState
    @State private var model = LinkFolderModel()
    @State private var files: [MediaFolderListing.File] = []
    @Environment(\.theme) private var theme

    var body: some View {
        BinDialogFrame(title: LinkFolderModel.title, width: 440, footNote: LinkFolderModel.footer) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16)).foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LinkFolderModel.displayPath(model.folder))
                            .font(ThemeTokens.mono(12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(model.folder == nil ? "—" : model.summary ?? "Counting…")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(LinkFolderModel.chooseTitle) {
                        if let url = studios.dialogs.chooseFolder(title: LinkFolderModel.title) { model.choose(url) }
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 26))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                BinField(label: LinkFolderModel.nameLabel) {
                    DialogTextField(prompt: "Easter Services", text: $model.name, label: "Name in library", submit: link)
                }
                option(LinkFolderModel.options[0], isOn: .constant(false), help: BinHelp.watch)
                option(LinkFolderModel.options[1], isOn: $model.includeSubfolders, help: nil)
                option(LinkFolderModel.options[2], isOn: .constant(false), help: BinHelp.optimize)
            }
        } buttons: {
            Button(AddFilesModel.cancelTitle) { ui.binDialog = nil }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 30))
                .keyboardShortcut(.cancelAction)
            Button(LinkFolderModel.linkTitle, action: link)
                .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 30))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canLink || model.summary == nil)
        }
        .onAppear { if let initial, model.folder == nil { model.choose(initial) } }
        .task(id: "\(model.folder?.path ?? "")|\(model.includeSubfolders)") { await count() }
    }

    private func option(_ title: String, isOn: Binding<Bool>, help: String?) -> some View {
        HStack(spacing: 10) {
            Text(title).fontWeight(.semibold)
            Spacer()
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        .disabled(help != nil)
        .opacity(help != nil ? 0.5 : 1)
        .help(help ?? "")
    }

    /// Lists the folder's video and photos off the main thread (reads only).
    private func count() async {
        model.summary = nil
        files = []
        guard let folder = model.folder else { return }
        let deep = model.includeSubfolders
        let listed = await Task.detached(priority: .utility) {
            (try? MediaFolderListing.files(in: folder, includeSubfolders: deep, kinds: [.video, .image])) ?? []
        }.value
        guard !Task.isCancelled else { return }
        files = listed
        model.summary = MediaFolderListing.summary(listed)
    }

    private func link() {
        guard model.canLink, model.summary != nil, let folder = model.folder,
              let id = studios.linkFolder(folder, name: model.trimmedName) else { return }
        let index = studios.studios.studio?.media ?? []
        let rows = files.map { AddFileRow.make($0.url, bin: .media, index: index) }
        if rows.isEmpty {
            ui.binDialog = nil
        } else {
            studios.media.startAdding(rows, bin: .media, folder: id, studios: studios)
            ui.binDialog = .progress
        }
    }
}
