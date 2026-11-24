import SwiftUI
import StageKit

/// Fixed sizes of the operator view, from Main.dc.html.
enum OperatorLayout {
    /// L512.
    static let rightColumnWidth: CGFloat = 360
    /// L1327 (every v0.1 tab is 330 there).
    static let bottomPanelHeight: CGFloat = 330
    /// L169.
    static let tabBarHeight: CGFloat = 32
    /// L680.
    static let statusBarHeight: CGFloat = 28
    /// L512: padding 12, gap 10.
    static let columnPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 10
}

/// The right column's parts, top to bottom.
enum RightColumnPart: String, CaseIterable, Identifiable {
    case outputPicker, monitor, clear, previousNext, tabs
    var id: Self { self }
    static let order: [RightColumnPart] = allCases
}

/// The right column (Main.dc.html L511): the output picker, ONE monitor, the Clear block, Previous / Next, then the
/// Audio / Message / Timer tabs filling the rest. (The board has Clear below Previous / Next with worded buttons; the
/// owner moved it up and made it icons with a lit state, 2026-11-23.)
struct RightColumn: View {
    let state: StageState
    @Bindable var ui: OperatorUIState
    let studios: StudioController
    let send: (Command) -> Void
    @Environment(\.theme) private var theme
    /// Per Studio, on this machine; shared by every window and by Output > Monitor.
    @AppStorage(StorageKeys.monitorScreens) private var monitorRaw = ""

    private var choice: MonitorChoice { MonitorChoice(raw: monitorRaw) }

    var body: some View {
        let screen = choice.screen(in: state)
        let menu = ServiceMenuModel(state: state, selection: ui.selection, isModalOpen: ui.isModalOpen)
        VStack(spacing: OperatorLayout.columnSpacing) {
            ForEach(RightColumnPart.order) { part in
                switch part {
                case .outputPicker:
                    HStack(spacing: 6) {
                        OutputPicker(state: state, screen: screen, ui: ui) { id in
                            monitorRaw = choice.choosing(id, for: state.studio).raw
                        }
                        // The board's multiview toggle (MainMultiview.dc.html); one monitor in v0.1.
                        Button("⊞") {}
                            .buttonStyle(PanelButtonStyle(kind: .secondary, width: 30, height: 30, font: .system(size: 15)))
                            .disabled(true)
                            .help("Multiview is not available in v0.1")
                            .accessibilityLabel("Multiview")
                    }
                case .monitor:
                    ColumnMonitor(state: state, screen: screen)
                case .clear:
                    // Above its neighbours, so its hover label is drawn over Previous / Next when it flips below.
                    ClearBlock(model: ClearRowModel(state: state), send: send).zIndex(1)
                case .previousNext:
                    HStack(spacing: ThemeTokens.spacingS) {
                        // Also on ← / → (Service menu).
                        Button("◀ Previous") { send(.previous) }
                            .buttonStyle(PanelButtonStyle(kind: .secondary))
                            .disabled(!menu.canPrevious)
                            .accessibilityLabel("Previous slide")
                        Button("Next ▶") { send(.next) }
                            .buttonStyle(PanelButtonStyle(kind: .primary))
                            .disabled(!menu.canNext)
                            .accessibilityLabel("Next slide")
                    }
                case .tabs:
                    SideTabsPanel(state: state, studios: studios, ui: ui, send: send)
                }
            }
        }
        .padding(OperatorLayout.columnPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface) // --chrome
    }
}

// MARK: Output picker and monitor

/// The 30 pt picker above the monitor (Main.dc.html L515): status dot, screen name, status chip, ▾.
private struct OutputPicker: View {
    let state: StageState
    let screen: ScreenState?
    let ui: OperatorUIState
    let choose: (Screen.ID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let status = screen.map { MonitorStatus.of($0, in: state) }
        Menu {
            ForEach(OutputPickerModel(state: state).sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.screens) { entry in
                        Toggle(entry.name, isOn: Binding(
                            get: { entry.screenID == screen?.screenID },
                            set: { _ in choose(entry.screenID) }
                        ))
                    }
                }
            }
            Divider()
            Button("Output Setup…") { ui.showOutputSetup = true }
                .disabled(ui.isModalOpen)
        } label: {
            HStack(spacing: ThemeTokens.spacingS) {
                Circle().fill(status.map(theme.color) ?? theme.textSecondary).frame(width: 8, height: 8)
                Text(screen?.name ?? "No output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let status { StatusTag(status: status) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
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
        .help("Choose the output the monitor shows")
        .accessibilityLabel("Monitor output")
        .accessibilityValue([screen?.name, status?.rawValue].compactMap { $0 }.joined(separator: ", "))
    }
}

/// LIVE / BLACK / CLEAR / TEST in mono 10 bold, outlined in its colour (Main.dc.html L965 `chipS`).
private struct StatusTag: View {
    let status: MonitorStatus
    @Environment(\.theme) private var theme

    var body: some View {
        Text(status.rawValue)
            .font(ThemeTokens.mono(10, weight: .bold))
            .foregroundStyle(theme.color(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.color(status), lineWidth: 1))
    }
}

/// The single 16:9 monitor (Main.dc.html L541): 2 pt border in the status colour, BLACK in amber on black.
private struct ColumnMonitor: View {
    let state: StageState
    let screen: ScreenState?
    @Environment(\.theme) private var theme

    var body: some View {
        let status = screen.map { MonitorStatus.of($0, in: state) }
        content(status)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeTokens.radius)
                    .stroke(status.map(theme.color) ?? theme.border, lineWidth: 2)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Monitor: \(screen?.name ?? "no output")")
    }

    @ViewBuilder private func content(_ status: MonitorStatus?) -> some View {
        if let screen, let status {
            switch status {
            case .test:
                if let pattern = TestPatternMenuModel(state: state).pattern(on: screen.screenID) {
                    TestPatternView(pattern: pattern)
                }
            case .black:
                // The output is black; say so, so it cannot be mistaken for "nothing live".
                ZStack {
                    Color.black
                    Text("BLACK").font(ThemeTokens.mono(12)).tracking(1.2).foregroundStyle(theme.warning)
                }
            case .live:
                SlideText(lines: screen.live?.lines ?? [], size: 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            case .clear:
                NothingLive(text: "Nothing live")
            }
        } else {
            NothingLive(text: state.studio == nil ? "No Studio open" : "This Studio has no output screens")
        }
    }
}

extension ThemeTokens {
    /// Main.dc.html L964 `statCol`: LIVE red, BLACK amber, the rest dim. TEST is amber like its other markers.
    func color(_ status: MonitorStatus) -> Color {
        switch status {
        case .live: live
        case .black, .test: warning
        case .clear: textSecondary
        }
    }
}

// MARK: Clear block

/// Two rows: CLEAR with the scope chip, then six equal icon buttons filling the width (4 pt apart, 32 pt tall). Each
/// button has its own hover label (`HoverLabelTimer`, `HoverLabelPlacement`) instead of a native tooltip: drawn over
/// the column, never moving the layout or taking clicks.
struct ClearBlock: View {
    let model: ClearRowModel
    let send: (Command) -> Void
    @State private var hovered: ClearButton?
    @State private var timer = HoverLabelTimer()
    @State private var now = Date()
    @State private var frames: [ClearButton: CGRect] = [:]
    @State private var labelSize = CGSize.zero
    @State private var block = CGRect.zero
    private static let space = "clearBlock"

    var body: some View {
        VStack(alignment: .leading, spacing: ClearBlockLayout.rowSpacing) {
            HStack {
                SectionLabel(text: "CLEAR")
                Spacer(minLength: 8)
                ScopeChip(model: model)
            }
            HStack(spacing: ClearBlockLayout.buttonSpacing) {
                ForEach(ClearButton.allCases) { button in
                    ClearIconButton(model: model, button: button) {
                        timer.press()
                        model.commands(button).forEach(send)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[button] = $0 }
                    .onHover { inside in hover(button, inside) }
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { block = $0 }
        .overlay(alignment: .topLeading) {
            if let button = hovered, timer.isVisible(at: now), let frame = frames[button] {
                HoverLabel(text: model.help(button))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { labelSize = $0 }
                    .position(HoverLabelPlacement.center(
                        button: frame, label: labelSize, column: CGRect(x: 0, y: 0, width: block.width, height: block.height),
                        roomAbove: block.minY + frame.minY
                    ))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true) // the button's own label says the same
            }
        }
    }

    private func hover(_ button: ClearButton, _ inside: Bool) {
        if inside {
            hovered = button
            timer.enter(at: Date())
            Task {
                try? await Task.sleep(for: .milliseconds(Int(HoverLabelTimer.delay * 1000) + 10))
                now = Date()
            }
        } else if hovered == button {
            hovered = nil
            timer.leave()
        }
    }
}

/// The hover label: 11 pt on --panel with a --line border, radius 5, a soft shadow.
struct HoverLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// One icon button. Unlit: the neutral button with a dim icon. Lit: a red tint with a red icon. Black: neutral with an
/// amber icon while off, filled amber with a dark icon while on (no red, no amber border).
struct ClearIconButton: View {
    let model: ClearRowModel
    let button: ClearButton
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let look = model.look(button)
        Button(action: action) {
            Image(systemName: button.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.color(look.icon))
                .frame(minWidth: ClearBlockLayout.minButtonWidth, maxWidth: .infinity)
                .frame(height: ClearBlockLayout.buttonHeight)
                .background(theme.color(look.fill), in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.color(look.border), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled(button))
        .opacity(model.isEnabled(button) ? 1 : 0.4)
        .accessibilityHint(model.help(button))
        .accessibilityLabel(model.accessibilityLabel(button))
        .accessibilityValue(model.accessibilityValue(button))
    }
}

extension ThemeTokens {
    func color(_ role: ClearButtonLook.Role) -> Color {
        switch role {
        case .surfaceRaised: surfaceRaised
        case .border: border
        case .textSecondary: textSecondary
        case .live: live
        case .liveTint: live.opacity(0.18)
        case .warning: warning
        case .onWarning: onWarning
        }
    }
}

/// "All ▾" (was "All screens ▾", Main.dc.html L590). Only All can be picked in v0.1; a screen's name would be cut with
/// an ellipsis at `ClearBlockLayout.scopeMaxWidth`.
struct ScopeChip: View {
    let model: ClearRowModel
    var scope: ClearScope?
    @Environment(\.theme) private var theme

    var body: some View {
        let current = scope ?? model.scope
        let title = model.chipTitle(current)
        Menu {
            ForEach(model.scopes, id: \.scope) { entry in
                Toggle(entry.title, isOn: Binding(get: { entry.scope == current }, set: { _ in }))
                    .disabled(!model.canPick(entry.scope))
                    .help(model.canPick(entry.scope) ? "" : ClearRowModel.perScreenHelp)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(theme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Text("▾").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, ThemeTokens.spacingS)
            .padding(.vertical, 2)
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: ClearBlockLayout.scopeMaxWidth, alignment: .trailing)
        .help("What Clear acts on. \(ClearRowModel.perScreenHelp)")
        .accessibilityLabel("Clear scope")
        .accessibilityValue(model.scopeAccessibilityValue(current).lowercased())
    }
}

// MARK: Audio / Message / Timer

/// The tabbed panel at the bottom of the right column (Main.dc.html L598): rounded, on --bg, tabs sharing the width.
private struct SideTabsPanel: View {
    let state: StageState
    let studios: StudioController
    let ui: OperatorUIState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme
    @AppStorage(StorageKeys.sideTab) private var tabRaw = SideTab.audio.rawValue
    private var tab: SideTab { SideTab.resolve(tabRaw) }
    private var studio: Studio? { studios.studios.studio }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SideTab.allCases) { item in
                    TabButton(title: item.rawValue, isSelected: tab == item, isEnabled: true, fill: true) {
                        tabRaw = item.rawValue
                    }
                }
            }
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
            switch tab {
            case .audio: AudioCuePanel(state: state, send: send)
            case .message:
                MessagesPanel(model: MessagesPanelModel(messages: studio?.messages ?? [], state: state, hasStudio: studio != nil),
                              ui: ui, send: send, delete: studios.deleteMessage)
            case .timer:
                TimersPanel(model: TimersPanelModel(timers: studio?.timers ?? [], state: state, hasStudio: studio != nil),
                            ui: ui, send: send, delete: studios.deleteTimer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.background, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
    }
}

/// The Audio tab (Main.dc.html L606): what plays now and its transport. Only what `AudioState` holds: no duration,
/// level or playlist yet, so no progress bar, level or "Up next", and ⏮ / ⏭ are off.
private struct AudioCuePanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    private var audio: AudioState { state.audio }

    var body: some View {
        let toggle = ServiceMenuModel(state: state, selection: nil).audioToggle
        VStack(alignment: .leading, spacing: ThemeTokens.spacingM) {
            HStack(alignment: .top) {
                Text(state.mediaTitle(audio.liveTrack) ?? "No track")
                    .fontWeight(.bold)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(transportColor).frame(width: 8, height: 8)
                    Text(audio.transport.label)
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .accessibilityElement(children: .combine)
            }
            Text(timecode(audio.position))
                .font(ThemeTokens.mono(12))
                .foregroundStyle(theme.textSecondary)
                .accessibilityLabel("Position \(timecode(audio.position))")
            HStack(spacing: ThemeTokens.spacingS) {
                Button("⏮") {}
                    .buttonStyle(PanelButtonStyle(kind: .secondary, width: 44, height: 36))
                    .disabled(true)
                    .help("Previous track is not available in v0.1")
                    .accessibilityLabel("Previous track")
                Button(audio.transport == .playing ? "❚❚ Pause" : "▶ Play") { toggle.command.map(send) }
                    .buttonStyle(PanelButtonStyle(kind: .primary, width: 96, height: 36))
                    .disabled(toggle.command == nil)
                    .accessibilityLabel(toggle.title)
                Button("■") { send(.stopAudio) }
                    .buttonStyle(PanelButtonStyle(kind: .secondary, width: 44, height: 36))
                    .disabled(audio.liveTrack == nil)
                    .help("Stop playback")
                    .accessibilityLabel("Stop")
                Button("⏭") {}
                    .buttonStyle(PanelButtonStyle(kind: .secondary, width: 44, height: 36))
                    .disabled(true)
                    .help("Next track is not available in v0.1")
                    .accessibilityLabel("Next track")
            }
            .frame(maxWidth: .infinity)
            if let trigger = audio.nextTrigger {
                Text("Next trigger at \(timecode(trigger.at))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transportColor: Color {
        switch audio.transport {
        case .stopped: theme.textSecondary
        case .playing: theme.ok
        case .paused, .fading: theme.warning
        }
    }
}

// MARK: Shared

/// The mockup's section label (Main.dc.html L845).
struct SectionLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(ThemeTokens.mono(11, weight: .semibold))
            .tracking(ThemeTokens.labelTracking)
            .foregroundStyle(theme.textSecondary)
    }
}

/// The board's buttons: radius 6; secondary on --panel with a --line border; primary filled with the accent, bold,
/// `onAccent` text; Black outlined amber, filled amber while on; Hide outlined in --live. `width` nil fills the row.
struct PanelButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        case secondary, primary, hide
        /// Outlined in the accent, bold (MessageEditor.dc.html "Save and show").
        case accentOutline
        case black(on: Bool)
    }

    var kind: Kind
    var width: CGFloat? = nil
    var minWidth: CGFloat? = nil
    var height: CGFloat = 32
    var font: Font? = nil

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, style: self)
    }

    private struct PanelButtonBody: View {
        let configuration: Configuration
        let style: PanelButtonStyle
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(style.font ?? .system(size: 13, weight: [.primary, .accentOutline].contains(style.kind) ? .bold : .regular))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, style.minWidth == nil ? 0 : 10)
                .frame(minWidth: style.minWidth, maxWidth: style.width ?? (style.minWidth == nil ? .infinity : nil))
                .frame(width: style.width, height: style.height)
                .background(background, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(border ?? .clear, lineWidth: 1))
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var foreground: Color {
            switch style.kind {
            case .secondary: theme.textPrimary
            case .primary: theme.onAccent
            case .hide: theme.live
            case .accentOutline: theme.accent
            case let .black(on): on ? theme.onWarning : theme.warning
            }
        }

        private var background: Color {
            switch style.kind {
            case .secondary: theme.surfaceRaised
            case .primary: theme.accent
            case .hide, .accentOutline: .clear
            case let .black(on): on ? theme.warning : .clear
            }
        }

        private var border: Color? {
            switch style.kind {
            case .secondary: theme.border
            case .primary: nil
            case .hide: theme.live
            case .accentOutline: theme.accent
            case .black: theme.warning
            }
        }
    }
}
