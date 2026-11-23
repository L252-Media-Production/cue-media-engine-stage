import SwiftUI
import StageKit

/// The operator (run) view: service on the left, the output monitors and the slide grid in the centre,
/// transport under them, the bottom tabs (Audio, Activities, ...) and the status bar. Reads `StageState` only;
/// every control sends a `Command` through the store.
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
                ServicePanel(state: state, selection: $ui.selection) { item in
                    store.send(.go(itemID: item.id, slideIndex: 0))
                }
                .frame(width: 240)
                Divider()
                GeometryReader { column in
                    VStack(spacing: 0) {
                        MonitorRow(state: state, monitorWidth: MonitorLayout.monitorWidth(
                            rowWidth: column.size.width, columnHeight: column.size.height, count: state.outputScreens.count))
                        Divider()
                        centre
                    }
                }
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

    /// The slide grid, transport and bottom tabs under the monitors.
    @ViewBuilder private var centre: some View {

        SlideGrid(state: state, item: state.item(selection)) { item, index in
            store.send(.go(itemID: item.id, slideIndex: index))
        }
        Divider()
        TransportBar(blackout: state.blackout, send: store.send)
        Divider()
        BottomPanel(state: state, send: store.send)
            .frame(height: 210)
    }
}

// MARK: Service

private struct ServicePanel: View {
    let state: StageState
    @Binding var selection: Item.ID?
    let go: (Item) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: state.service?.name ?? "No service")
            List(state.service?.items ?? [], selection: $selection) { item in
                ServiceRow(item: item, isLive: isLive(item))
                    .tag(item.id)
                    // The mockup's selected row is tinted `--sel` (Main.dc.html L927).
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: ThemeTokens.radius)
                            .fill(selection == item.id ? theme.selection : .clear)
                    )
            }
            // Double-click. Return is Service > Go Live: the menu's key equivalent takes it before the list sees it,
            // so a press of Return is one Go, never two.
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                Button("Go Live") { goFirst(of: ids) }.disabled(ids.isEmpty)
            } primaryAction: { ids in
                goFirst(of: ids)
            }
            .scrollContentBackground(.hidden)
            Text("Double-click or Return takes an item live")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .padding(ThemeTokens.spacingS)
        }
        .background(theme.surface)
    }

    private func goFirst(of ids: Set<Item.ID>) {
        guard let item = state.service?.items.first(where: { ids.contains($0.id) }) else { return }
        go(item)
    }

    private func isLive(_ item: Item) -> Bool {
        if state.primaryLive?.itemID == item.id { return true }
        guard case let .media(id) = item.content else { return false }
        return state.audio.liveTrack == id
    }
}

/// A service entry. Selection is the list's own highlight; LIVE is a red bar on the leading edge plus a chip,
/// so the two read differently also when the live item is the selected one.
private struct ServiceRow: View {
    let item: Item
    let isLive: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            Rectangle()
                .fill(isLive ? theme.live : .clear)
                .frame(width: 3)
            Image(systemName: icon)
                .foregroundStyle(isLive ? theme.live : theme.textSecondary)
                .frame(width: 16)
            Text(item.title)
                .fontWeight(isLive ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isLive { Chip(text: "LIVE", color: theme.live, filled: true) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? "Live" : "")
    }

    private var icon: String {
        switch item.content {
        case .song: "music.note.list"
        case .media: "waveform"
        case .blank: "rectangle"
        }
    }
}

// MARK: Monitors (current and next)

/// The monitors of the operator view: one per output screen, nothing else (no "Next").
enum MonitorRowTitles {
    static func titles(_ state: StageState) -> [String] { state.outputScreens.map(\.name) }
}

/// One monitor per output screen (what each output shows now). The next slide is not shown here: it is engine
/// state for stage displays and control surfaces, not for the operator view.
private struct MonitorRow: View {
    let state: StageState
    let monitorWidth: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        let screens = state.outputScreens
        if screens.isEmpty {
            Text(state.studio == nil ? "No Studio open" : "This Studio has no output screens")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            HStack(alignment: .top, spacing: MonitorLayout.spacing) {
                let testPattern = TestPatternMenuModel(state: state)
                ForEach(screens) { screen in
                    ScreenMonitor(
                        screen: screen, itemTitle: state.item(screen.live?.itemID)?.title, blackout: state.blackout,
                        testPattern: testPattern.pattern(on: screen.screenID)
                    )
                    .frame(width: monitorWidth)
                }
            }
            .padding(MonitorLayout.padding)
            // The height its width implies, so the stack below cannot squeeze the 16:9 pictures narrower than their
            // monitors (which left gaps between them).
            .frame(height: MonitorLayout.rowHeight(monitorWidth: monitorWidth))
            .frame(maxWidth: .infinity) // centred when the height cap leaves room at the sides
        }
    }
}

/// Sizes the operator monitors. They share the row's width equally at 16:9, so the row is filled, but the row may
/// only grow until the slide grid under it would be shorter than `minGridHeight`. Only an unusually wide, short window
/// (or a single output screen) hits that cap; the monitors then stay 16:9 and are centred.
struct MonitorLayout {
    static let padding: CGFloat = ThemeTokens.spacingM
    static let spacing: CGFloat = ThemeTokens.spacingM
    /// Title row above each picture, with its spacing.
    static let titleHeight: CGFloat = 20
    static let aspect: CGFloat = 16 / 9
    /// Under the monitors: the transport bar, the bottom tabs (210) and the dividers.
    static let reservedBelow: CGFloat = 255
    /// The slide grid keeps at least this much (one row of cards).
    static let minGridHeight: CGFloat = 160

    static func rowHeight(monitorWidth: CGFloat) -> CGFloat {
        monitorWidth / aspect + titleHeight + 2 * padding
    }

    static func monitorWidth(rowWidth: CGFloat, columnHeight: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let usable = rowWidth - 2 * padding - spacing * CGFloat(count - 1)
        let fill = usable / CGFloat(count)
        let maxRowHeight = columnHeight - reservedBelow - minGridHeight
        let maxPictureHeight = maxRowHeight - titleHeight - 2 * padding
        return max(80, min(fill, maxPictureHeight * aspect))
    }
}

private struct ScreenMonitor: View {
    let screen: ScreenState
    let itemTitle: String?
    let blackout: Bool
    /// While a test pattern runs on this screen the monitor shows it, as the output does. The caption and the red
    /// accent still tell what is live underneath.
    let testPattern: TestPattern?
    @Environment(\.theme) private var theme

    var body: some View {
        MonitorFrame(title: screen.name, caption: caption, accent: isOnAir ? theme.live : nil, badge: testPattern == nil ? nil : "TEST") {
            if let testPattern {
                TestPatternView(pattern: testPattern)
            } else if blackout {
                // The output is black; say so, so it cannot be mistaken for "nothing live".
                ZStack {
                    Color.black
                    Text("BLACKOUT").font(ThemeTokens.mono(12, weight: .bold)).foregroundStyle(theme.live)
                }
            } else if let live = screen.live {
                SlideText(lines: live.lines, size: 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                NothingLive(text: "Nothing live")
            }
        }
    }

    private var isOnAir: Bool { screen.live != nil && !blackout }

    private var caption: String? {
        guard let live = screen.live else { return nil }
        return [itemTitle, live.label].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A 16:9 monitor with a title row above it.
private struct MonitorFrame<Content: View>: View {
    let title: String
    let caption: String?
    let accent: Color?
    /// An amber chip after the title (the test pattern's "TEST").
    var badge: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingXS) {
            HStack(spacing: ThemeTokens.spacingXS) {
                Text(title.uppercased())
                    .font(ThemeTokens.mono(11, weight: .bold))
                    .foregroundStyle(accent ?? theme.textSecondary)
                if let badge { Chip(text: badge, color: theme.warning, filled: true) }
                Spacer(minLength: ThemeTokens.spacingXS)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            content
                .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: ThemeTokens.radius)
                        .stroke(accent ?? theme.border, lineWidth: 2)
                )
        }
    }
}

/// The empty state of a monitor: a grey, dashed panel, deliberately unlike the black of a blackout or a live slide.
private struct NothingLive: View {
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

private struct SlideText: View {
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

// MARK: Transport

private struct TransportBar: View {
    let blackout: Bool
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            // Next / Previous are also on → / ← (Show menu). Return belongs to the service list (Go).
            Button { send(.previous) } label: { Label("Previous", systemImage: "chevron.left") }
            Button { send(.next) } label: { Label("Next", systemImage: "chevron.right") }
            Divider().frame(height: 18)
            Button("Clear Slide") { send(.clear(.slide)) }
            Button("Clear All") { send(.clear(.all)) }
            Spacer()
            if blackout {
                // A custom style: `.borderedProminent` turns grey when the window is not key, and this state must
                // stay obvious whatever has focus.
                Button { send(.blackout(false)) } label: {
                    Label("BLACKOUT ON", systemImage: "circle.fill").font(ThemeTokens.mono(12, weight: .bold))
                }
                .buttonStyle(ActiveStateButtonStyle(color: theme.live))
                .help("Blackout is on. Click to end it")
                .accessibilityValue("On")
            } else {
                Button { send(.blackout(true)) } label: { Label("Blackout", systemImage: "circle") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, ThemeTokens.spacingS)
    }
}

private struct ActiveStateButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: Bottom panel

private struct BottomPanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme
    /// Remembered across launches; View > Cmd-4 / Cmd-5 write the same key.
    @AppStorage(StorageKeys.bottomTab) private var tabRaw = BottomTab.audio.rawValue
    private var tab: BottomTab { BottomTab.resolve(tabRaw) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { item in
                    TabButton(title: item.rawValue, isSelected: tab == item, isEnabled: item.isEnabled) { tabRaw = item.rawValue }
                }
                Spacer()
            }
            .padding(.horizontal, ThemeTokens.spacingS)
            .background(theme.surface) // the tab bar sits on the panel's --chrome (Main.dc.html L168)

            switch tab {
            case .audio:
                AudioPanel(state: state, send: send)
            case .activities, .scripture, .media, .looks:
                PlaceholderPanel(title: tab.rawValue)
            }
        }
        .background(theme.surface)
    }
}

private struct TabButton: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(ThemeTokens.mono(11, weight: .semibold))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, ThemeTokens.spacingM)
                .padding(.vertical, ThemeTokens.spacingS)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? theme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(isEnabled ? "" : "Not available yet")
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

private struct StatusBar: View {
    let state: StageState
    let lastEvent: StageEvent?
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
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
            // Output chips are machine data: the connectors this Mac drives for the open Studio.
            if state.outputs.isEmpty, state.studio != nil, !state.outputScreens.isEmpty {
                StatusChip(text: "Outputs: unassigned", color: nil)
                    .help("No screen of this Studio is assigned to a connector on this Mac (Output > Output Setup…)")
            }
            ForEach(state.outputs) { output in
                HStack(spacing: ThemeTokens.spacingXS) {
                    Circle().fill(color(output.health)).frame(width: 8, height: 8)
                    Text(output.name)
                    if output.droppedFrames > 0 {
                        Text("\(output.droppedFrames) dropped").foregroundStyle(theme.danger)
                    }
                }
            }
            StatusChip(text: "Audio: \(state.audio.transport.label)", color: audioColor)
                .help("Audio transport")
            let engine = EngineChipModel(counters: state.audio.counters)
            StatusChip(text: "Engine", color: engine.isAlert ? theme.warning : nil)
                .help(engine.tooltip)
            Spacer()
            if case let .commandRejected(_, reason) = lastEvent {
                Text("Refused: \(reason)").foregroundStyle(theme.warning)
            }
        }
        .font(ThemeTokens.mono(11))
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, ThemeTokens.spacingXS + 2)
        .background(theme.surface) // --chrome (Main.dc.html L680)
    }

    private var audioColor: Color? {
        switch state.audio.transport {
        case .stopped: nil
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

private struct PanelHeader: View {
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

private struct Chip: View {
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

private struct EmptyMessage: View {
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

private func timecode(_ seconds: Double) -> String {
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
