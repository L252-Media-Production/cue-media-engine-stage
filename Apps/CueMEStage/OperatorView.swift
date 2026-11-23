import SwiftUI
import StageKit

/// The operator (run) view (Main.dc.html): service on the left and the slide grid beside it, the bottom panel under
/// both, the right column (one monitor, Previous / Next, Clear, Audio / Message / Timer) and the status bar.
/// Reads `StageState` only; every control sends a `Command` through the store.
struct OperatorView: View {
    let store: StageStore
    /// Shared with the menu bar (Service > Go Live acts on the selected item).
    @Bindable var ui: OperatorUIState
    let studios: StudioController
    @Environment(\.theme) private var theme

    /// Which service item the slide grid shows; not engine state.
    private var selection: Item.ID? {
        get { ui.selection }
        nonmutating set { ui.selection = newValue }
    }

    private var state: StageState { store.state }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = studios.visibleNotice {
                NoticeBar(text: notice) {
                    if studios.studios.notice == notice { studios.studios.notice = nil } else { studios.notice = nil }
                }
                Divider()
            }
            HStack(spacing: 0) {
                // Main.dc.html L44: service and slide grid, the bottom panel under both; the right column beside them.
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ServicePanel(state: state, studio: studios.studios.studio, relink: studios.relinkReport,
                                     selection: $ui.selection) { id in
                            store.send(.go(itemID: id, slideIndex: 0))
                        }
                        .frame(width: ServicePanelLayout.width)
                        Divider()
                        SlideGrid(state: state, item: state.item(selection)) { item, index in
                            store.send(.go(itemID: item.id, slideIndex: index))
                        }
                    }
                    Divider()
                    BottomPanel(state: state, send: store.send)
                        .frame(height: OperatorLayout.bottomPanelHeight)
                }
                Divider()
                RightColumn(state: state, ui: ui, send: store.send)
                    .frame(width: OperatorLayout.rightColumnWidth)
            }
            Divider()
            StatusBar(state: state, lastEvent: store.lastEvent, send: store.send)
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        // When a different item goes live (Next across items, Go from elsewhere), the grid follows it; also when the
        // view appears with something already live.
        .onChange(of: state.primaryLive?.itemID, initial: true) { _, itemID in
            if let itemID { selection = itemID }
        }
        // Nothing picked yet (first snapshot of a service): show the item Next would start with.
        .onChange(of: state.service?.id, initial: true) { _, _ in
            if selection == nil { selection = state.primaryLive?.itemID ?? state.nextSlide?.itemID }
        }
        .sheet(isPresented: $ui.showOutputSetup) {
            OutputSetupSheet(store: store).modifier(Themed())
        }
        .sheet(isPresented: $ui.showRelink) {
            RelinkSheet(studios: studios).modifier(Themed())
        }
        .navigationTitle(studios.title)
        .onChange(of: ui.isModalOpen, initial: true) { _, open in ShortcutGuard.isModalOpen = open }
    }
}

// MARK: Monitor parts

/// The empty state of a monitor: a grey, dashed panel, deliberately unlike the black of a blackout or a live slide.
struct NothingLive: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.surfaceRaised
            RoundedRectangle(cornerRadius: ThemeTokens.radius)
                .strokeBorder(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .padding(ThemeTokens.spacingXS)
            Text(text)
                .font(ThemeTokens.mono(11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
    }
}

struct SlideText: View {
    let lines: [String]
    let size: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
        .padding(ThemeTokens.spacingS)
    }
}

// MARK: Slide grid

private struct SlideGrid: View {
    let state: StageState
    let item: Item?
    let go: (Item, Int) -> Void
    @Environment(\.theme) private var theme

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: ThemeTokens.spacingM)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: item?.title ?? "Slides")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        if let item {
            let slides = state.slides[item.id] ?? []
            if slides.isEmpty {
                EmptyMessage(text: emptyText(for: item))
            } else {
                grid(item: item, slides: slides)
            }
        } else {
            EmptyMessage(text: "Select an item in the service to see its slides")
        }
    }

    private func grid(item: Item, slides: [Slide]) -> some View {
        let live = state.primaryLive?.itemID == item.id ? state.primaryLive?.slideIndex : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: ThemeTokens.spacingM) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        SlideCard(number: index + 1, slide: slide, isLive: index == live) {
                            go(item, index)
                        }
                        .id(slide.id)
                    }
                }
                .padding(ThemeTokens.spacingM)
            }
            .onAppear { reveal(live, in: slides, proxy, animated: false) }
            .onChange(of: state.primaryLive?.slideID) { _, _ in reveal(live, in: slides, proxy, animated: true) }
        }
        // A new grid per item, so `onAppear` scrolls to the live slide when the item changes.
        .id(item.id)
    }

    private func reveal(_ index: Int?, in slides: [Slide], _ proxy: ScrollViewProxy, animated: Bool) {
        guard let index, slides.indices.contains(index) else { return }
        let id = slides[index].id
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }

    private func emptyText(for item: Item) -> String {
        switch item.content {
        case .song: "This song has no slides"
        case .media: "Media item: no slides. Double-click it in the service to play it"
        case .blank: "Blank item: no slides"
        }
    }
}

/// One slide. LIVE: solid red border and a filled chip. (No "next" marking: the operator view shows what is live.)
private struct SlideCard: View {
    let number: Int
    let slide: Slide
    let isLive: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: ThemeTokens.spacingXS) {
                    Text("\(number)")
                        .font(ThemeTokens.mono(11, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                    Text(slide.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isLive {
                        Chip(text: "LIVE", color: theme.live, filled: true)
                    }
                }
                .padding(.horizontal, ThemeTokens.spacingS)
                .padding(.vertical, ThemeTokens.spacingXS + 1)
                .background(theme.surfaceRaised)

                SlideText(lines: slide.lines, size: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
            }
            .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeTokens.radius)
                    .stroke(borderColor, lineWidth: isLive ? 3 : 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Take \(slide.label) live")
        .accessibilityLabel("Slide \(number), \(slide.label)")
        .accessibilityValue(isLive ? "Live" : "")
    }

    private var borderColor: Color {
        if isLive { return theme.live }
        return hovering ? theme.textSecondary : theme.border
    }
}

// MARK: Bottom panel

/// The bottom panel (Main.dc.html L167): 330 pt, title-case tabs on a 32 pt bar with a 2 pt accent underline.
private struct BottomPanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme
    /// Remembered across launches; View > Cmd-1 ... Cmd-5 write the same key.
    @AppStorage(StorageKeys.bottomTab) private var tabRaw = BottomTab.audio.rawValue
    private var tab: BottomTab { BottomTab.resolve(tabRaw) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: ThemeTokens.spacingXS) {
                ForEach(BottomTab.allCases) { item in
                    TabButton(title: item.rawValue, isSelected: tab == item, isEnabled: item.isEnabled,
                              help: item.isEnabled ? "" : "\(item.rawValue) is not available in v0.1") { tabRaw = item.rawValue }
                }
                Spacer()
            }
            .padding(.horizontal, ThemeTokens.spacingM)
            .frame(height: OperatorLayout.tabBarHeight, alignment: .bottom)
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }

            switch tab {
            case .audio:
                AudioPanel(state: state, send: send)
            case .activities, .scripture, .media, .looks:
                PlaceholderPanel(title: tab.rawValue)
            }
        }
        .background(theme.surface) // --chrome (Main.dc.html L1327)
    }
}

/// A tab of the bottom panel or the right column: weight 600, the selected one in the text colour over a 2 pt accent
/// line, the others dim. `fill` stretches it to share the bar (the right column's tabs, Main.dc.html L996).
struct TabButton: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    var help: String = ""
    var fill = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, fill ? 0 : 14)
                .padding(.vertical, fill ? 9 : 7)
                .frame(maxWidth: fill ? .infinity : nil)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? theme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlaceholderPanel: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: ThemeTokens.spacingS) {
            Text(title).font(.headline)
            Text("After v0.1").font(ThemeTokens.mono(12)).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(true)
    }
}

private struct AudioPanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    private var audio: AudioState { state.audio }

    var body: some View {
        HStack(alignment: .top, spacing: ThemeTokens.spacingL) {
            VStack(alignment: .leading, spacing: ThemeTokens.spacingS) {
                Text(state.mediaTitle(audio.liveTrack) ?? "No track")
                    .font(.title3.weight(.semibold))
                HStack(spacing: ThemeTokens.spacingM) {
                    Text(timecode(audio.position)).font(ThemeTokens.mono(22, weight: .medium))
                    Text(audio.transport.rawValue.uppercased())
                        .font(ThemeTokens.mono(11, weight: .bold))
                        .foregroundStyle(audio.transport == .playing ? theme.live : theme.textSecondary)
                }
                HStack(spacing: ThemeTokens.spacingS) {
                    Button(audio.transport == .paused ? "Resume" : "Pause") {
                        send(audio.transport == .paused ? .resumeAudio : .pauseAudio)
                    }
                    .disabled(audio.transport != .playing && audio.transport != .paused)
                    Button("Fade Out") { send(.fadeAudio(seconds: 3)) }.disabled(audio.liveTrack == nil)
                    Button("Stop") { send(.stopAudio) }.disabled(audio.liveTrack == nil)
                    Button("Skip Trigger") { send(.skipNextTrigger) }.disabled(audio.nextTrigger == nil)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: ThemeTokens.spacingM, verticalSpacing: ThemeTokens.spacingXS) {
                row("Voice", audio.voicePlaying ? "ON TOP" : "—", color: audio.voicePlaying ? theme.warning : nil)
                row("Ducking", audio.duckingText)
                row("Next trigger", audio.nextTrigger.map { timecode($0.at) } ?? "—")
                Divider().gridCellColumns(2)
                row("Dropped ends", "\(audio.counters.droppedEnds)", color: counterColor(audio.counters.droppedEnds))
                row("Dropped fires", "\(audio.counters.droppedFires)", color: counterColor(audio.counters.droppedFires))
                row("Pool exhausted", "\(audio.counters.poolExhausted)", color: counterColor(audio.counters.poolExhausted))
            }
            .frame(width: 240) // the spanning Divider would otherwise stretch the grid to the full width
            Spacer()
        }
        .padding(ThemeTokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.textSecondary)
            Text(value).font(ThemeTokens.mono(12)).foregroundStyle(color ?? theme.textPrimary)
        }
    }

    private func counterColor(_ n: Int) -> Color? { n > 0 ? theme.danger : nil }
}

// MARK: Status

/// The status bar (Main.dc.html L680): 28 pt, 12 pt dim text, 8 pt dots; Dropped and fps in mono on the right.
private struct StatusBar: View {
    let state: StageState
    let lastEvent: StageEvent?
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let outputs = OutputsStatusModel(state: state)
        HStack(spacing: ThemeTokens.spacingL) {
            if let description = TestPatternMenuModel(state: state).description {
                // First in the bar and amber, so a running pattern is never missed. Clicking turns it off.
                Button { send(.hideTestPattern) } label: {
                    StatusChip(text: "TEST PATTERN", color: theme.warning).fontWeight(.bold)
                }
                .buttonStyle(.plain)
                .help("\(description). Click to turn it off")
                .accessibilityLabel("Test pattern running: \(description)")
            }
            let engine = EngineChipModel(counters: state.audio.counters)
            StatusItem(text: "Engine", dot: engine.isAlert ? theme.warning : theme.ok)
                .help(engine.tooltip)
            StatusItem(text: outputs.text, dot: outputs.level.map(color) ?? theme.textSecondary)
                .help(outputs.tooltip)
            // No IMAG input state in StageState yet: the board's label with a dash.
            StatusItem(text: "IMAG —", dot: theme.textSecondary)
                .help("IMAG input: not reported by the engine in v0.1")
            StatusItem(text: "Audio · \(state.audio.transport.label)", dot: audioColor)
                .help("Audio transport")
            Spacer(minLength: 0)
            if case let .commandRejected(_, reason) = lastEvent {
                Text("Refused: \(reason)").foregroundStyle(theme.warning).lineLimit(1)
            }
            Text("Dropped \(outputs.dropped)")
                .font(ThemeTokens.mono(12))
                .foregroundStyle(outputs.dropped > 0 ? theme.danger : theme.textSecondary)
                .help("Dropped frames, all outputs")
                .accessibilityLabel("Dropped frames: \(outputs.dropped)")
            // No frame rate in StageState yet.
            Text("— fps")
                .font(ThemeTokens.mono(12))
                .help("Output frame rate: not reported by the engine in v0.1")
                .accessibilityLabel("Frame rate: not reported")
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: OperatorLayout.statusBarHeight)
        .background(theme.surface) // --chrome (Main.dc.html L680)
    }

    private var audioColor: Color {
        switch state.audio.transport {
        case .stopped: theme.textSecondary
        case .playing: theme.ok
        case .paused, .fading: theme.warning
        }
    }

    private func color(_ health: OutputStatus.Health) -> Color {
        switch health {
        case .ok: theme.ok
        case .degraded: theme.warning
        case .offline: theme.danger
        }
    }
}

/// A status-bar entry: an 8 pt dot and its text.
private struct StatusItem: View {
    let text: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Shared

/// A non-blocking notice under the toolbar (a save that failed and is being retried, a missing Studio, ...).
private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, ThemeTokens.spacingS)
        .background(theme.warning.opacity(0.12))
    }
}

struct PanelHeader: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title.uppercased())
            .font(ThemeTokens.mono(11, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, ThemeTokens.spacingM)
            .padding(.vertical, ThemeTokens.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceRaised)
    }
}

/// A status-bar chip: neutral (`color` nil) or tinted.
private struct StatusChip: View {
    let text: String
    let color: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .foregroundStyle(color ?? theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((color ?? theme.border).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color ?? theme.border, lineWidth: 1))
    }
}

struct Chip: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(ThemeTokens.mono(9, weight: .bold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(filled ? color : .clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: filled ? 0 : 1))
    }
}

struct EmptyMessage: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(ThemeTokens.spacingL)
    }
}

func timecode(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let rest = total - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, rest)
}

#Preview {
    let store = StageStore.mock()
    let studios = StudioController(
        studios: StudioStore(environment: .init(machine: MachinePaths(root: FileManager.default.temporaryDirectory), identity: .init(id: UUID(), name: "Preview"), appVersion: "preview")),
        stage: store, catalog: StudioCatalog(), defaults: .standard, documentsFolder: FileManager.default.temporaryDirectory, dialogs: AppKitStudioDialogs()
    )
    return OperatorView(store: store, ui: OperatorUIState(), studios: studios)
        .modifier(Themed())
        .frame(width: 1200, height: 780)
}
