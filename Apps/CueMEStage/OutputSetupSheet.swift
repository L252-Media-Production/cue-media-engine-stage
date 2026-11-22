import SwiftUI
import StageKit

/// Output > Output Setup… (Shift-Cmd-O). One sheet, tabs Screens and Slices (Slices not available in v0.1).
/// Reads `StageState` only; edits go to a working copy and leave only as Commands, on Apply.
struct OutputSetupSheet: View {
    let store: StageStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @AppStorage(StorageKeys.outputSetupTab) private var tabRaw = OutputSetupTab.screens.rawValue
    /// `Screen.ID.uuidString` of the selected screen.
    @AppStorage(StorageKeys.outputSetupScreen) private var selectedRaw = ""
    @State private var draft = OutputSetupDraft()
    @State private var confirmClose = false

    private var state: StageState { store.state }
    private var hasEdits: Bool { draft.hasEdits(in: state) }

    /// The saved screen while it still exists, else the first screen.
    private var selection: Binding<Screen.ID?> {
        Binding(
            get: {
                let saved = UUID(uuidString: selectedRaw)
                return state.screens.contains { $0.screenID == saved } ? saved : state.screens.first?.screenID
            },
            set: { selectedRaw = $0?.uuidString ?? "" }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch OutputSetupTab.resolve(tabRaw) {
            case .screens: screensTab
            case .slices: EmptyView()
            }
            Divider()
            footer
        }
        .frame(minWidth: 1040, minHeight: 620)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .alert("Apply your changes?", isPresented: $confirmClose) {
            Button("Apply and Close") { apply(); dismiss() }
            Button("Discard Changes", role: .destructive) { draft = OutputSetupDraft(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Output Setup has edits that have not been sent to the engine.")
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 0) {
            Text("OUTPUT SETUP")
                .font(ThemeTokens.mono(12, weight: .bold))
                .padding(.horizontal, ThemeTokens.spacingM)
            ForEach(OutputSetupTab.allCases) { tab in
                let selected = OutputSetupTab.resolve(tabRaw) == tab
                Button { tabRaw = tab.rawValue } label: {
                    Text(tab.rawValue.uppercased())
                        .font(ThemeTokens.mono(11, weight: .semibold))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, ThemeTokens.spacingM)
                        .padding(.vertical, ThemeTokens.spacingS)
                        .overlay(alignment: .bottom) { Rectangle().fill(selected ? theme.accent : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!tab.isEnabled)
                .opacity(tab.isEnabled ? 1 : 0.4)
                .help(tab.isEnabled ? "" : "Slices: after v0.1")
            }
            Spacer()
        }
        .background(theme.surfaceRaised)
    }

    private var footer: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            if case let .commandRejected(command, reason) = store.lastEvent, command.isOutputSetup {
                Label("Refused: \(reason)", systemImage: "exclamationmark.circle").foregroundStyle(theme.warning)
            } else if hasEdits {
                Text("Unapplied changes").foregroundStyle(theme.warning)
            }
            Spacer()
            Button("Revert") { draft = OutputSetupDraft() }.disabled(!hasEdits)
            Button("Apply") { apply() }.disabled(!hasEdits)
            Button("Done") { if hasEdits { confirmClose = true } else { dismiss() } }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(ThemeTokens.spacingM)
    }

    private func apply() {
        for command in draft.commands(in: state) { store.send(command) }
        draft = OutputSetupDraft()
    }

    // MARK: Screens tab

    private var screensTab: some View {
        HStack(spacing: 0) {
            screenList.frame(width: 220)
            Divider()
            SignalOverview(state: state, draft: draft, selection: selection)
                .frame(maxWidth: .infinity)
            Divider()
            settings.frame(width: 300)
        }
    }

    private var screenList: some View {
        List(selection: selection) {
            ForEach(ScreenType.allCases, id: \.self) { type in
                let screens = state.screens.filter { draft.setup($0.screenID, in: state)?.type == type }
                Section(type.groupTitle) {
                    if screens.isEmpty {
                        Text("None").foregroundStyle(theme.textSecondary).selectionDisabled()
                    }
                    ForEach(screens) { screen in
                        HStack {
                            Text(screen.name)
                            Spacer()
                            Text(state.connector(draft.connectorID(screen.screenID, in: state))?.label ?? "Unassigned")
                                .font(ThemeTokens.mono(10))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .tag(screen.screenID)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.surface)
    }

    @ViewBuilder private var settings: some View {
        if let id = selection.wrappedValue, let setup = draft.setup(id, in: state) {
            ScreenSettings(
                name: state.screenName(id),
                setup: Binding(get: { setup }, set: { draft.set($0, for: id, in: state) }),
                connector: Binding(get: { draft.connectorID(id, in: state) }, set: { draft.assign($0, to: id, in: state) }),
                looks: state.looks,
                choices: draft.connectorChoices(for: id, in: state),
                current: state.connector(draft.connectorID(id, in: state))
            )
            .id(id)
        } else {
            Text("Select a screen").foregroundStyle(theme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Signal overview

/// The cards with their connectors, then NDI and displays: which screen is on each, free ones marked. The canvas
/// warnings sit on top as a banner.
private struct SignalOverview: View {
    let state: StageState
    let draft: OutputSetupDraft
    @Binding var selection: Screen.ID?
    @Environment(\.theme) private var theme

    private var cards: [(id: String, name: String, connectors: [Connector])] {
        var result: [(id: String, name: String, connectors: [Connector])] = []
        for connector in state.connectors {
            guard let card = connector.cardID else { continue }
            if let i = result.firstIndex(where: { $0.id == card }) {
                result[i].connectors.append(connector)
            } else {
                result.append((card, connector.cardName ?? card, [connector]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeTokens.spacingM) {
                let warnings = draft.warningTexts(in: state)
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: ThemeTokens.spacingXS) {
                        ForEach(warnings, id: \.self) { text in
                            Label(text, systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.warning)
                    .padding(ThemeTokens.spacingM)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.warning, lineWidth: 1))
                    .accessibilityElement(children: .combine)
                }
                ForEach(cards, id: \.id) { card in
                    group(card.name, card.connectors)
                }
                group("NDI sending", state.connectors.filter { $0.kind == .ndiOut })
                group("NDI receiving", state.connectors.filter { $0.kind == .ndiIn })
                group("Displays", state.connectors.filter { $0.kind == .display })
            }
            .padding(ThemeTokens.spacingM)
        }
    }

    private func group(_ title: String, _ connectors: [Connector]) -> some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingXS) {
            Text(title.uppercased()).font(ThemeTokens.mono(11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            if connectors.isEmpty {
                Text("None reported by the engine").font(.caption).foregroundStyle(theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: ThemeTokens.spacingS)], spacing: ThemeTokens.spacingS) {
                ForEach(connectors) { connector in
                    ConnectorTile(
                        connector: connector,
                        screen: draft.screen(on: connector.id, in: state),
                        onCanvas: draft.screen(on: connector.id, in: state).flatMap { draft.setup($0.screenID, in: state)?.onCanvas } ?? false,
                        selected: draft.screen(on: connector.id, in: state)?.screenID == selection
                    ) {
                        if let screen = draft.screen(on: connector.id, in: state) { selection = screen.screenID }
                    }
                }
            }
        }
    }
}

private struct ConnectorTile: View {
    let connector: Connector
    let screen: ScreenState?
    let onCanvas: Bool
    let selected: Bool
    let select: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ThemeTokens.spacingXS) {
                    Image(systemName: connector.kind.isInput ? "arrow.down.to.line" : "arrow.up.right")
                        .foregroundStyle(theme.textSecondary)
                    Text(connector.label).font(ThemeTokens.mono(11, weight: .bold))
                    Spacer(minLength: 0)
                    if onCanvas { Text("CANVAS").font(ThemeTokens.mono(9, weight: .bold)).foregroundStyle(theme.accent) }
                }
                Group {
                    if !connector.available {
                        Text("Unavailable").foregroundStyle(theme.danger)
                    } else if let screen {
                        Text(screen.name)
                    } else {
                        Text("Free").foregroundStyle(theme.textSecondary)
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
            .padding(ThemeTokens.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(screen == nil ? theme.surface : theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeTokens.radius)
                    .stroke(selected ? theme.accent : theme.border,
                            style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: screen == nil ? [4, 3] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(screen == nil)
        .accessibilityLabel("\(connector.label), \(screen?.name ?? (connector.available ? "free" : "unavailable"))")
    }
}

// MARK: Settings of the selected screen

private struct ScreenSettings: View {
    let name: String
    @Binding var setup: ScreenSetup
    @Binding var connector: Connector.ID?
    let looks: [Look]
    let choices: [Connector]
    /// The assigned connector, also when it is not among `choices` (unavailable).
    let current: Connector?
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: setup.type.groupTitle)
                Picker(setup.type.isInput ? "Input" : "Output", selection: $connector) {
                    Text("None").tag(Connector.ID?.none)
                    if let current, !choices.contains(current) {
                        Text("\(current.pickerTitle) (unavailable)").tag(Optional(current.id))
                    }
                    ForEach(choices) { c in Text(c.pickerTitle).tag(Optional(c.id)) }
                }
            } header: {
                Text(name).font(.headline)
            }

            if !setup.type.isInput {
                Section("Look") {
                    Picker("Look", selection: $setup.lookID) {
                        Text("Service default").tag(Look.ID?.none)
                        ForEach(looks) { look in Text(look.name).tag(Optional(look.id)) }
                    }
                    Picker("Rotation", selection: $setup.rotation) {
                        ForEach(ScreenRotation.allCases, id: \.self) { r in Text("\(r.rawValue)°").tag(r) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if setup.type == .audience {
                Section("Canvas") {
                    Toggle("On canvas", isOn: $setup.onCanvas)
                    Group {
                        TextField("X", value: $setup.canvas.x, format: .number.grouping(.never))
                        TextField("Y", value: $setup.canvas.y, format: .number.grouping(.never))
                        TextField("Width", value: positive(\.width), format: .number.grouping(.never))
                        TextField("Height", value: positive(\.height), format: .number.grouping(.never))
                    }
                    .font(ThemeTokens.mono(12))
                    .disabled(!setup.onCanvas)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.surface)
    }

    /// Width and height below 1 are kept at 1 (the engine refuses 0).
    private func positive(_ key: WritableKeyPath<CanvasRect, Int>) -> Binding<Int> {
        Binding(get: { setup.canvas[keyPath: key] }, set: { setup.canvas[keyPath: key] = max(1, $0) })
    }
}

extension Command {
    /// True for the commands Output Setup sends, so the sheet shows their refusals.
    var isOutputSetup: Bool {
        switch self {
        case .assignScreen, .setScreenSetup: true
        default: false
        }
    }
}
