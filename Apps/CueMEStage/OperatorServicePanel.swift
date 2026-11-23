import SwiftUI
import StageKit

/// The service panel (Main.dc.html L48–L91), 280 pt on --chrome: search, COLLECTIONS, the service picker with
/// "+ Add ▾", then the ITEMS list under its section headers. Click selects, double-click or Return (Service > Go Live)
/// takes the selection live, ↑ / ↓ move the selection while the list has focus.
struct ServicePanel: View {
    let state: StageState
    let studio: Studio?
    let relink: RelinkReport?
    @Bindable var ui: OperatorUIState
    let go: (Item.ID) -> Void
    /// Adds a section header above the given item (nil = at the end).
    let addSection: (String, Item.ID?) -> Void
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SearchField(text: $query)
                HStack {
                    SectionLabel(text: "COLLECTIONS")
                    Spacer()
                    Button("+ New") { ui.showNewCollection = true }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme.accent)
                        .disabled(studio == nil)
                        .help("New collection (⇧⌘N)")
                        .accessibilityLabel("New collection")
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
                CollectionsList(model: CollectionsModel(studio: studio, query: query, expanded: expanded)) { id in
                    expanded = expanded.symmetricDifference([id])
                }
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))

            ServiceHeader(model: ServicePickerModel(state: state, studio: studio), canAddSection: studio != nil && state.service != nil,
                          showAddSection: $ui.showAddSection) { name in
                addSection(name, NewSectionModel.anchor(selection: ui.selection, in: state.service))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ItemList(model: ServiceListModel(state: state, studio: studio, relink: relink), selection: $ui.selection, go: go)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface) // --chrome (Main.dc.html L49)
    }
}

// MARK: Search and collections

/// 28 pt field with a magnifier (Main.dc.html L51).
private struct SearchField: View {
    @Binding var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            TextField("Search collections", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search collections")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
    }
}

private struct CollectionsList: View {
    let model: CollectionsModel
    let toggle: (String) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.editSong) private var editSong

    var body: some View {
        let rows = model.rows
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    Text(model.studio == nil ? "No Studio open" : model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "No collections" : "Nothing found")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case let .collection(id, title, count, isExpanded):
                        Button { toggle(id) } label: {
                            CollectionLine(icon: isExpanded ? "chevron.down" : "chevron.right", title: title,
                                           meta: "\(count)", weight: .semibold, indent: 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.query.isEmpty) // a search keeps every match open
                        .accessibilityLabel("\(title), \(count)")
                        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    case let .entry(entry):
                        CollectionLine(icon: entry.icon, title: entry.title, meta: entry.meta, weight: .regular, indent: 18)
                            .accessibilityElement(children: .combine)
                            .contextMenu {
                                if let song = entry.songID {
                                    Button("Edit…") { editSong?(song) }.disabled(editSong == nil)
                                }
                            }
                    }
                }
            }
        }
        .frame(height: min(CGFloat(max(rows.count, 1)) * ServicePanelLayout.collectionRowHeight,
                           ServicePanelLayout.collectionsMaxHeight))
    }
}

private struct CollectionLine: View {
    let icon: String
    let title: String
    let meta: String?
    let weight: Font.Weight
    let indent: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 16)
            Text(title).fontWeight(weight).lineLimit(1)
            Spacer(minLength: 4)
            if let meta {
                Text(meta).font(ThemeTokens.mono(11)).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }
}

// MARK: Service picker and Add

/// The 30 pt service picker, bold, with ▾ (Main.dc.html L62), and "+ Add ▾" in the accent (L63).
private struct ServiceHeader: View {
    let model: ServicePickerModel
    let canAddSection: Bool
    @Binding var showAddSection: Bool
    let addSection: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            Menu {
                ForEach(model.services, id: \.id) { service in
                    Toggle(isOn: Binding(get: { model.isCurrent(service.id) }, set: { _ in })) {
                        Text("\(service.name)  \(service.count)")
                    }
                    .disabled(!model.canPick(service.id))
                    .help(model.canPick(service.id) ? "" : ServicePickerModel.switchHelp)
                }
                Divider()
                Button("+ New service") {}
                    .disabled(true)
                    .help(ServicePickerModel.newServiceHelp)
            } label: {
                HStack {
                    Text(model.title).fontWeight(.bold).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("▾").foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Choose service")
            .accessibilityValue(model.title)

            Menu {
                Button("Section…") { showAddSection = true }
                    .disabled(!canAddSection)
                Button("Activity…") {}
                    .disabled(true)
                    .help(ServicePickerModel.activityHelp)
            } label: {
                Text("+ Add ▾").fontWeight(.semibold).foregroundStyle(theme.accent)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add to service")
            .popover(isPresented: $showAddSection, arrowEdge: .bottom) {
                SectionPopover { name in
                    addSection(name)
                    showAddSection = false
                } cancel: { showAddSection = false }
                .modifier(Themed())
            }
        }
    }
}

/// The Section popover (Main.dc.html L68): 220 pt on --panel, SECTION NAME, a field, Cancel and Add.
private struct SectionPopover: View {
    let add: (String) -> Void
    let cancel: () -> Void
    @State private var model = NewSectionModel()
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: NewSectionModel.label)
            TextField("", text: $model.name, prompt: Text("Offering"))
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.background, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.accent, lineWidth: 1))
                .onSubmit { if model.canAdd { add(model.trimmedName) } }
                .accessibilityLabel("Section name")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 28, font: .system(size: 12)))
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add(model.trimmedName) }
                    .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 28, font: .system(size: 12, weight: .bold)))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdd)
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(theme.surfaceRaised)
        .onAppear { focused = true }
    }
}

// MARK: Items

private struct ItemList: View {
    let model: ServiceListModel
    @Binding var selection: Item.ID?
    let go: (Item.ID) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.editSong) private var editSong
    @FocusState private var focused: Bool

    var body: some View {
        let sections = model.sections
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: ServiceListModel.itemsLabel)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if sections.isEmpty {
                            EmptyMessage(text: model.state.service == nil ? "No service" : "This service has no items")
                        }
                        // Main.dc.html L74: a header row is the section's name in the label style, padding 8 8 2.
                        ForEach(sections) { section in
                            if let title = section.title {
                                SectionLabel(text: title.uppercased())
                                    .padding(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityLabel("Section \(title)")
                            }
                            ForEach(section.rows) { row in
                                ServiceRowView(row: row, isSelected: selection == row.id)
                                    .id(row.id)
                                    .onTapGesture(count: 2) { go(row.id) }
                                    .simultaneousGesture(TapGesture().onEnded {
                                        selection = row.id
                                        focused = true
                                    })
                                    .contextMenu {
                                        Button("Go Live") { go(row.id) }
                                        if let song = row.songID {
                                            Button("Edit…") { editSong?(song) }.disabled(editSong == nil)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { selection = model.moving(selection, by: -1); return .handled }
        .onKeyPress(.downArrow) { selection = model.moving(selection, by: 1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Service items")
    }
}

/// Two-line row (Main.dc.html L80–L86): drag handle, type icon, title 13/600 (700 when selected), sub-line 11 dim,
/// LIVE chip, meta in mono 11. Selected: --sel background whether or not the list has focus. Live: 3 pt inset red bar.
struct ServiceRowView: View {
    let row: ServiceRowInfo
    let isSelected: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            // Drawn as on the board; reordering by drag is not built.
            Text("⋮⋮")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .opacity(0.6)
                .frame(width: 10)
                .accessibilityHidden(true)
            Image(systemName: row.icon)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                    .lineLimit(1)
                if let sub = row.sub {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.isLive { LiveChip() }
            if let meta = row.meta {
                Text(meta).font(ThemeTokens.mono(11)).foregroundStyle(color(row.metaTone))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(alignment: .leading) {
            if row.isLive {
                theme.live.frame(width: 3)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: ThemeTokens.radius, bottomLeadingRadius: ThemeTokens.radius))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(row.isLive ? "Live" : "")
        .accessibilityHint("Double-click or Return takes it live")
    }

    private func color(_ tone: RowMetaTone) -> Color {
        switch tone {
        case .dim: theme.textSecondary
        case .accent: theme.accent
        case .warning: theme.warning
        }
    }
}

/// "LIVE" in the body font, 9/700, padding 6×1, radius 4, white on --live (Main.dc.html L85).
struct LiveChip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("LIVE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.onLive)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.live, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}
