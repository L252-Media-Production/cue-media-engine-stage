import SwiftUI
import StageKit

/// Placeholder operator layout: service list, live screens, audio and status. Reads `StageState` only;
/// every control sends a `Command` through the store.
struct OperatorView: View {
    let store: StageStore
    @Environment(\.theme) private var theme
    /// Pure UI selection (which row is highlighted); not engine state.
    @State private var selection: Item.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ServicePanel(state: store.state, selection: $selection) { item in
                    store.send(.go(itemID: item.id, slideIndex: 0))
                }
                .frame(width: 240)
                Divider()
                VStack(spacing: 0) {
                    LivePanel(state: store.state, send: store.send)
                    Divider()
                    AudioPanel(state: store.state, send: store.send)
                        .frame(height: 210)
                }
            }
            Divider()
            StatusBar(state: store.state, lastEvent: store.lastEvent)
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
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
                HStack {
                    Image(systemName: icon(for: item))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 16)
                    Text(item.title)
                    Spacer()
                    if state.primaryLive?.itemID == item.id || isLiveTrack(item) {
                        Circle().fill(theme.live).frame(width: 8, height: 8)
                    }
                }
                .tag(item.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { go(item) }
                .onTapGesture { selection = item.id }
            }
            .scrollContentBackground(.hidden)
            Text("Double-click an item to take it live")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .padding(ThemeTokens.spacingS)
        }
        .background(theme.surface)
    }

    private func icon(for item: Item) -> String {
        switch item.content {
        case .song: "music.note.list"
        case .media: "waveform"
        case .blank: "rectangle"
        }
    }

    private func isLiveTrack(_ item: Item) -> Bool {
        guard case let .media(id) = item.content else { return false }
        return state.audio.liveTrack == id
    }
}

// MARK: Live

private struct LivePanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Live")
            HStack(alignment: .top, spacing: ThemeTokens.spacingM) {
                ForEach(state.screens) { screen in
                    ScreenMonitor(screen: screen, itemTitle: state.item(screen.live?.itemID)?.title, blackout: state.blackout)
                }
            }
            .padding(ThemeTokens.spacingM)
            Spacer(minLength: 0)
            HStack(spacing: ThemeTokens.spacingS) {
                Button("Previous") { send(.previous) }
                Button("Next") { send(.next) }
                    .keyboardShortcut(.defaultAction)
                Divider().frame(height: 18)
                Button("Clear Slide") { send(.clear(.slide)) }
                Button("Clear All") { send(.clear(.all)) }
                Spacer()
                Toggle("Blackout", isOn: Binding(get: { state.blackout }, set: { send(.blackout($0)) }))
                    .toggleStyle(.button)
                    .tint(theme.live)
            }
            .padding(ThemeTokens.spacingM)
        }
    }
}

private struct ScreenMonitor: View {
    let screen: ScreenState
    let itemTitle: String?
    let blackout: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingXS) {
            HStack {
                Text(screen.name).font(.headline)
                Spacer()
                if let live = screen.live {
                    Text("\(itemTitle ?? "") · \(live.label)")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: ThemeTokens.radius).fill(Color.black)
                if blackout {
                    Text("BLACKOUT").font(ThemeTokens.mono(12, weight: .bold)).foregroundStyle(theme.live)
                } else if let live = screen.live {
                    VStack(spacing: 4) {
                        ForEach(Array(live.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(ThemeTokens.spacingS)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: ThemeTokens.radius)
                    .stroke(screen.live != nil && !blackout ? theme.live : theme.border, lineWidth: 2)
            )
        }
        .frame(maxWidth: 360)
    }
}

// MARK: Audio

private struct AudioPanel: View {
    let state: StageState
    let send: (Command) -> Void
    @Environment(\.theme) private var theme

    private var audio: AudioState { state.audio }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Audio")
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
                Spacer()
            }
            .padding(ThemeTokens.spacingM)
        }
        .background(theme.surface)
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
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingL) {
            ForEach(state.outputs) { output in
                HStack(spacing: ThemeTokens.spacingXS) {
                    Circle().fill(color(output.health)).frame(width: 8, height: 8)
                    Text(output.name)
                    if output.droppedFrames > 0 {
                        Text("\(output.droppedFrames) dropped").foregroundStyle(theme.danger)
                    }
                }
            }
            Spacer()
            if case let .commandRejected(_, reason) = lastEvent {
                Text("Refused: \(reason)").foregroundStyle(theme.warning)
            }
        }
        .font(ThemeTokens.mono(11))
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, ThemeTokens.spacingXS + 2)
        .background(theme.surfaceRaised)
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

private struct PanelHeader: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title.uppercased())
            .font(ThemeTokens.mono(11, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, ThemeTokens.spacingM)
            .padding(.vertical, ThemeTokens.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceRaised)
    }
}

private func timecode(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let rest = total - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, rest)
}

#Preview {
    OperatorView(store: .mock())
        .modifier(Themed())
        .frame(width: 1100, height: 680)
}
