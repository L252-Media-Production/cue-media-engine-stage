import AppKit
import SwiftUI
import StageKit

/// The Song editor window (SongEditor.dc.html, boards "Song editor – Slide", "– Text edit", "– Slide inspector",
/// "– Sequence menu"): slides by group on the left (224 pt), the Slide / Text edit tabs in the centre, the Song / Slide /
/// Text inspector on the right (320 pt). The board's own title bar is the window's: title "Song Editor", the song as
/// subtitle, "Saved" and Done in the toolbar.
struct SongEditorView: View {
    let model: SongEditorModel
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let song = model.song {
                HStack(spacing: 0) {
                    SongSlideList(model: model, song: song)
                        .frame(width: 224)
                    theme.border.frame(width: 1)
                    SongEditorCentre(model: model, song: song)
                        .frame(maxWidth: .infinity)
                    theme.border.frame(width: 1)
                    SongInspector(model: model, song: song)
                        .frame(width: 320)
                }
            } else {
                EmptyMessage(text: "This song is not in the open Studio")
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .navigationTitle("Song Editor")
        .navigationSubtitle(model.song?.title ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Text(model.isSaved ? "Saved" : "Saving…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .help("Changes save themselves about a second after each edit")
                Button("Done") { dismiss() }
                    .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 28))
            }
        }
        .focusedSceneValue(\.songEditor, model)
        .background(ShortcutGuardWindowMarker(role: .editor))
        .onDisappear(perform: onClose)
    }
}

extension FocusedValues {
    /// The Song editor of the key window, for Undo and Redo.
    @Entry var songEditor: SongEditorModel?
}

// MARK: Left: groups and slides

private struct SongSlideList: View {
    let model: SongEditorModel
    let song: Song
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(song.title).fontWeight(.bold).lineLimit(1)
                Spacer()
                Button { model.addSlide() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .help("New slide")
                    .accessibilityLabel("New slide")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.runs) { run in
                        if let group = run.group {
                            let closed = model.collapsed.contains(group.id)
                            Button {
                                model.collapsed.formSymmetricDifference([group.id])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: closed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .frame(width: 12)
                                    Text(group.name).fontWeight(.bold).lineLimit(1)
                                    Spacer()
                                }
                                .foregroundStyle(theme.onGroup)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(groupHex: group.color))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(group.name)
                            .accessibilityValue(closed ? "Collapsed" : "Expanded")
                        }
                        if !(run.group.map { model.collapsed.contains($0.id) } ?? false) {
                            ForEach(run.slides, id: \.slide.id) { entry in
                                SlideThumbRow(number: entry.number, slide: entry.slide, song: song,
                                              tint: run.group.map { Color(groupHex: $0.color) },
                                              isSelected: model.currentSlide?.id == entry.slide.id) {
                                    model.selectedSlide = entry.slide.id
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Objects").fontWeight(.bold)
                    Spacer()
                    Text("+").fontWeight(.semibold).foregroundStyle(theme.accent).opacity(0.4)
                        .help(SongEditorModel.notAvailable)
                        .accessibilityLabel("Add object, not available yet")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Group {
                    if model.currentSlide?.lines.isEmpty == false {
                        HStack(spacing: 6) {
                            Text("T").font(.custom("Georgia", size: 13).weight(.bold)).frame(width: 16)
                            Text("Lyrics")
                            Spacer()
                            Text("Slide Text").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(theme.selection, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                    } else {
                        Text("No objects on this slide.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .frame(minHeight: 56, alignment: .top)
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .overlay(alignment: .top) { theme.border.frame(height: 1) }
        }
        .background(theme.surface)
    }
}

/// A slide in the list: a 16:9 picture of its text (as the outputs will show it), its number under it, on its
/// group's colour at 35 % (SongEditor.dc.html `sStyle`); the selected one has an accent border.
private struct SlideThumbRow: View {
    let number: Int
    let slide: Slide
    let song: Song
    let tint: Color?
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let lines = slide.lines.map { SongLyrics.capitalize($0, song.capitalization ?? .none) }
        Button(action: select) {
            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    LinearGradient(colors: theme.slideGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 8))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.slideText)
                        .padding(4)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(Rectangle().stroke(isSelected ? theme.accent : .clear, lineWidth: 2))
                Text("\(number).").font(.system(size: 11)).opacity(0.85)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
            .background((tint ?? .clear).opacity(0.35))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Slide \(number)")
        .accessibilityValue(lines.joined(separator: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Centre

private struct SongEditorCentre: View {
    @Bindable var model: SongEditorModel
    let song: Song
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SongEditorModel.CentreTab.allCases) { tab in
                    EditorTab(title: tab.rawValue, isSelected: model.centreTab == tab, isEnabled: tab.isEnabled) {
                        model.centreTab = tab
                    }
                }
            }
            .background(theme.surface)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }

            HStack(spacing: 12) {
                Text(song.title).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text("Sequence").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                SequenceMenu(slideCount: song.slides.count)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }

            switch model.centreTab {
            case .text: LyricsTextTab(model: model)
            default: SlideTab(model: model, song: song)
            }
        }
        .background(theme.background)
    }
}

/// The Sequence dropdown (SongEditor.dc.html L57–L66). The model has no sequences: the one order a song has is its
/// slide order, listed as Default and checked. "Edit sequences…" is off.
private struct SequenceMenu: View {
    let slideCount: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Toggle(isOn: .constant(true)) { Text("Default  \(slideCount)") }
            Divider()
            Button("Edit sequences…") {}
                .disabled(true)
                .help(SongEditorModel.notAvailable)
        } label: {
            HStack(spacing: 8) {
                Text("Default")
                Text("▾").foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose sequence")
        .accessibilityValue("Default")
    }
}

/// An equal-width tab with a 2 pt accent underline when selected (SongEditor.dc.html `tabs`, `rtabs`).
private struct EditorTab: View {
    let title: String
    let isSelected: Bool
    var isEnabled = true
    let pick: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: pick) {
            Text(title)
                .fontWeight(isSelected ? .bold : .regular)
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { (isSelected ? theme.accent : .clear).frame(height: 2) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(isEnabled ? "" : SongEditorModel.notAvailable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The Slide tab (SongEditor.dc.html L106–L127): the object tools (off), the slide at 16:9 with its text box
/// (editable: click and type), and "Slide n of m · Group", the canvas size and "+ New slide".
private struct SlideTab: View {
    let model: SongEditorModel
    let song: Song
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach([("T", "Text"), ("▢", "Shape"), ("▨", "Image"), ("▶", "Video")], id: \.1) { glyph, name in
                    HStack(spacing: 6) {
                        Text(glyph).font(.custom("Georgia", size: 15).weight(.bold))
                        Text(name).font(.system(size: 12))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .opacity(0.5)
                    .help(SongEditorModel.notAvailable)
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Object tools, not available yet")

            GeometryReader { area in
                let width = min(780, area.size.width, area.size.height * 16 / 9)
                let scale = width / 780
                VStack(spacing: 12) {
                    SlideCanvas(model: model, scale: scale)
                        .frame(width: width, height: width * 9 / 16)
                    HStack(spacing: 12) {
                        Text(model.slideInfo).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        if let size = model.canvasSize {
                            Text(size).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        Button("+ New slide") { model.addSlide() }
                            .buttonStyle(.plain)
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.accent, lineWidth: 1))
                    }
                    .frame(width: width)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.editorStage)
    }
}

private struct SlideCanvas: View {
    let model: SongEditorModel
    let scale: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.slideGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let slide = model.currentSlide {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text: Slide Text").font(ThemeTokens.mono(9)).foregroundStyle(theme.accent)
                    TextEditor(text: Binding(get: { model.slideText(slide.id) }, set: { model.typeSlide(slide.id, $0) }))
                        .font(.system(size: 34 * scale, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.slideText)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .padding(4)
                        .overlay(Rectangle().stroke(theme.accent, lineWidth: 1))
                        .accessibilityLabel("Slide text")
                }
                .padding(.horizontal, 50 * scale)
                .padding(.vertical, 80 * scale - 14)
            } else {
                Text("Empty slide").foregroundStyle(theme.textSecondary)
            }
        }
        .overlay(Rectangle().stroke(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
    }
}

/// The Text edit tab (SongEditor.dc.html L130–L139): the lyrics as text in mono 13. "[Verse 1]" starts a group, a
/// blank line starts a new slide; typing updates the slides.
private struct LyricsTextTab: View {
    let model: SongEditorModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { model.lyricsText }, set: { model.typeLyrics($0) }))
                .font(ThemeTokens.mono(13))
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Lyrics")
            Text("[Group] starts a group · a blank line starts a new slide")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Right: inspector

private struct SongInspector: View {
    @Bindable var model: SongEditorModel
    let song: Song
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SongEditorModel.InspectorTab.allCases) { tab in
                    EditorTab(title: tab.rawValue, isSelected: model.inspectorTab == tab) { model.inspectorTab = tab }
                }
            }
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.inspectorTab {
                    case .song: songTab
                    case .slide: slideTab
                    case .text: textTab
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surface)
    }

    @ViewBuilder private var songTab: some View {
        InspectorSection(title: "SONG") {
            InspectorField(label: "Title") {
                FieldBox { TextField("", text: Binding(get: { song.title }, set: model.setTitle)).textFieldStyle(.plain) }
            }
            textField("Author", \.author, key: "author")
            textField("Copyright", \.copyright, key: "copyright")
            textField("CCLI number", \.ccliNumber, key: "ccli")
            InspectorField(label: "Key") {
                SelectBox(value: song.key ?? "None") {
                    Button("None") { model.setKey(nil) }
                    Divider()
                    ForEach(SongEditorModel.keys, id: \.self) { key in Button(key) { model.setKey(key) } }
                }
            }
            InspectorField(label: "Tempo") {
                FieldBox {
                    HStack(spacing: 4) {
                        TextField("", text: Binding(get: { song.tempo.map(String.init) ?? "" }, set: model.setTempo))
                            .textFieldStyle(.plain)
                            .fixedSize()
                            .frame(minWidth: 24, alignment: .leading)
                        Text("BPM").foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                }
                .accessibilityLabel("Tempo in beats per minute")
            }
            InspectorField(label: "Collection") {
                SelectBox(value: model.studio?.collections.first { $0.id == song.collectionID }?.name ?? "None") {
                    Button("None") { model.setCollection(nil) }
                    Divider()
                    ForEach(model.studio?.collections ?? []) { c in Button(c.name) { model.setCollection(c.id) } }
                }
            }
        }
        InspectorSection(title: "AUDIO") {
            InspectorField(label: "Track") { ReadOnlyChip(text: model.mediaChip(song.audioTrackID)) }
            InspectorField(label: "Volume") { Unavailable { LevelBar() } }
            Unavailable { ToggleRow(name: "Slides follow audio") }
            Unavailable { Text("Open timeline ›").fontWeight(.semibold).foregroundStyle(theme.accent) }
        }
        InspectorSection(title: "BACKGROUND") {
            InspectorField(label: "Song background") { ReadOnlyChip(text: model.mediaChip(song.backgroundID)) }
        }
        InspectorSection(title: "SEQUENCE") {
            InspectorField(label: "Active sequence") { Unavailable { SelectBox(value: "Default") { EmptyView() } } }
            Unavailable { Text("Edit sequences ›").fontWeight(.semibold).foregroundStyle(theme.accent) }
        }
    }

    @ViewBuilder private var slideTab: some View {
        if let slide = model.currentSlide {
            InspectorSection(title: "SLIDE") {
                InspectorField(label: "Group") {
                    let group = model.group(of: slide.id)
                    SelectBox(value: group?.name ?? "None", swatch: group.map { Color(groupHex: $0.color) }) {
                        ForEach(model.groups) { g in Button(g.name) { model.setGroup(slide.id, to: g.id) } }
                    }
                    .disabled(model.groups.isEmpty)
                    .help(model.groups.isEmpty ? "Add a [Group] heading in Text edit first" : "")
                }
                InspectorField(label: "Label") {
                    FieldBox {
                        TextField("", text: Binding(get: { slide.label }, set: { model.setLabel(slide.id, $0) }), prompt: Text("None"))
                            .textFieldStyle(.plain)
                    }
                }
            }
        } else {
            Text("No slide selected").foregroundStyle(theme.textSecondary)
        }
        InspectorSection(title: "LOOK") {
            InspectorField(label: "Background") { Unavailable { SelectBox(value: "Use song background") { EmptyView() } } }
            InspectorField(label: "Transition") { Unavailable { SelectBox(value: "None") { EmptyView() } } }
            Unavailable { ToggleRow(name: "Auto-advance") }
        }
        InspectorSection(title: "AUDIO ON THIS SLIDE") {
            InspectorField(label: "Cue") { Unavailable { SelectBox(value: "None") { EmptyView() } } }
            InspectorField(label: "Mode") { Unavailable { Segments(options: ["Play", "Loop", "Stop"], selected: nil) { _ in } } }
            InspectorField(label: "Volume") { Unavailable { LevelBar() } }
        }
        InspectorSection(title: "NOTES") {
            InspectorField(label: "Operator notes") {
                Unavailable {
                    Text("").frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                }
            }
        }
    }

    @ViewBuilder private var textTab: some View {
        InspectorSection(title: "LYRICS") {
            InspectorField(label: "Lines per slide") {
                HStack(spacing: 8) {
                    FieldBox {
                        TextField("", text: Binding(
                            get: { song.linesPerSlide.map(String.init) ?? "" },
                            set: { text in
                                let digits = text.filter(\.isNumber)
                                model.setLinesPerSlide(digits.isEmpty ? nil : Int(digits.prefix(2)))
                            }
                        ), prompt: Text("Off"))
                        .textFieldStyle(.plain)
                    }
                    Stepper("", value: Binding(get: { song.linesPerSlide ?? 0 },
                                               set: { model.setLinesPerSlide($0 == 0 ? nil : $0) }), in: 0...12)
                        .labelsHidden()
                        .accessibilityLabel("Lines per slide")
                }
            }
            Unavailable { ToggleRow(name: "Split long verses automatically") }
            InspectorField(label: "Capitalization") {
                let modes: [(String, SongCapitalization)] = [("None", .none), ("ALL CAPS", .allCaps), ("Sentence case", .sentenceCase)]
                Segments(options: modes.map(\.0), selected: modes.firstIndex { $0.1 == (song.capitalization ?? .none) }) { i in
                    model.setCapitalization(modes[i].1)
                }
            }
        }
        InspectorSection(title: "TRANSLATION") {
            Unavailable { ToggleRow(name: "Second language") }
            InspectorField(label: "Language") { Unavailable { SelectBox(value: "Off") { EmptyView() } } }
        }
    }

    private func textField(_ label: String, _ path: WritableKeyPath<Song, String?>, key: String) -> some View {
        InspectorField(label: label) {
            FieldBox {
                TextField("", text: Binding(get: { song[keyPath: path] ?? "" }, set: { model.setText(path, $0, key: key) }))
                    .textFieldStyle(.plain)
                    .accessibilityLabel(label)
            }
        }
    }
}

// MARK: Inspector parts (SongEditor.dc.html L155–L177)

/// A section: its title in the label style (mono 10, letter-spacing .08em, --dim), then its rows 8 apart.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ThemeTokens.mono(10))
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            content
        }
    }
}

/// A 28 pt field on --panel with a --line border.
private struct FieldBox<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
    }
}

/// A select: the value, an optional colour swatch, and ▾; its menu holds the choices.
private struct SelectBox<Items: View>: View {
    let value: String
    var swatch: Color?
    @ViewBuilder let items: Items
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            items
        } label: {
            FieldBox {
                HStack(spacing: 8) {
                    if let swatch { Circle().fill(swatch).frame(width: 10, height: 10) }
                    Text(value).lineLimit(1)
                    Spacer()
                    Text("▾").foregroundStyle(theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A library item shown by name, not choosable here (choosing a track or background is a later step).
private struct ReadOnlyChip: View {
    let text: String?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(text ?? "None")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(text == nil ? theme.textSecondary : theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.surfaceRaised, in: Capsule())
                .overlay(Capsule().stroke(theme.border, lineWidth: 1))
            Spacer()
        }
        .help("Choosing it here is not available yet")
    }
}

private struct ToggleRow: View {
    let name: String
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

private struct LevelBar: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Capsule().fill(theme.surfaceRaised).frame(height: 4).frame(maxWidth: .infinity)
    }
}

/// Segmented buttons: the selected one filled with the accent (SongEditor.dc.html `seg`).
private struct Segments: View {
    let options: [String]
    let selected: Int?
    let pick: (Int) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { pick(i) } label: {
                    Text(option)
                        .font(.system(size: 12, weight: i == selected ? .bold : .regular))
                        .foregroundStyle(i == selected ? theme.onAccent : theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(i == selected ? theme.accent : theme.surfaceRaised)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == selected ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
    }
}

/// A control the model cannot back yet: drawn as on the board, off, with a tooltip.
private struct Unavailable<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .disabled(true)
            .opacity(0.45)
            .help(SongEditorModel.notAvailable)
            .accessibilityHint(SongEditorModel.notAvailable)
    }
}

extension Color {
    /// A group colour as stored ("#RRGGBB"); grey when unreadable.
    init(groupHex: String) {
        let hex = UInt32(groupHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x5F6B7A
        self.init(hex: hex)
    }
}
