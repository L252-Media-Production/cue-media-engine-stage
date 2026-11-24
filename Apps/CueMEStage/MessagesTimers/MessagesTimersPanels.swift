import SwiftUI
import StageKit

/// The Message tab (Main.dc.html L625, board MainMessages.dc.html): MESSAGES, "n live", Hide all, + New; one row per
/// saved message with Show / Hide, ✎ and 🗑 (click twice). A row is lit in the LIVE red while the message is showing,
/// from `StageState.visibleMessages` only. Right-click a row for the same actions.
struct MessagesPanel: View {
    let model: MessagesPanelModel
    let ui: OperatorUIState
    let send: (Command) -> Void
    let delete: (Message.ID) -> Void
    @Environment(\.theme) private var theme
    @State private var armed: Message.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingS) {
            ListTabHeader(title: "MESSAGES", note: model.liveNote, actionTitle: "Hide all", canAct: model.canHideAll,
                        actionLabel: "Hide all messages", act: { send(model.hideAllCommand) },
                        canAdd: model.canAdd && !ui.isModalOpen, addHelp: model.canAdd ? MessagesPanelModel.addHelp : MessagesPanelModel.noStudioHelp,
                        addLabel: "New message", add: { ui.messageEditor = .new })
            if model.messages.isEmpty {
                EmptyMessage(text: model.hasStudio ? "No messages in this Studio" : "No Studio open")
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message, model: model, armed: $armed, edit: { ui.messageEditor = .edit(message.id) },
                                       send: send, delete: delete, isModalOpen: ui.isModalOpen)
                        }
                    }
                }
            }
            Text(MessagesPanelModel.footnote)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, 10)
    }
}

private struct MessageRow: View {
    let message: Message
    let model: MessagesPanelModel
    @Binding var armed: Message.ID?
    let edit: () -> Void
    let send: (Command) -> Void
    let delete: (Message.ID) -> Void
    let isModalOpen: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let isOn = model.isShowing(message)
        let canDelete = model.canDelete(message)
        HStack(spacing: ThemeTokens.spacingS) {
            VStack(alignment: .leading, spacing: 0) {
                Text(message.text).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                Text(MessagesPanelModel.destination).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(isOn ? "Hide" : "Show") { send(model.toggleCommand(message)) }
                .buttonStyle(PanelButtonStyle(kind: isOn ? .hide : .primary, width: nil, minWidth: 58, height: 28,
                                              font: .system(size: 12, weight: .bold)))
                .fixedSize()
                .accessibilityLabel("\(isOn ? "Hide" : "Show") message: \(message.text)")
            RowIconButton(symbol: "pencil", help: "Edit", label: "Edit message: \(message.text)", action: edit)
                .disabled(isModalOpen)
            DeleteButton(isArmed: armed == message.id, canDelete: canDelete, blockedHelp: MessagesPanelModel.deleteBlockedHelp,
                         label: "Delete message: \(message.text)") {
                if armed == message.id { armed = nil; delete(message.id) } else { armed = message.id }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
        .background(isOn ? theme.live.opacity(0.18) : theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? theme.live : theme.border, lineWidth: 1))
        .contextMenu {
            Button("Edit…", action: edit).disabled(isModalOpen)
            Button(isOn ? "Hide" : "Show") { send(model.toggleCommand(message)) }
            Divider()
            Button("Delete") { delete(message.id) }.disabled(!canDelete)
        }
        .onChange(of: canDelete) { _, can in if !can, armed == message.id { armed = nil } }
    }
}

/// The Timer tab (Main.dc.html L647, board MainTimers.dc.html): TIMERS, "n running", Stop all, + New; one row per timer
/// with its name, type line, time (a dash: nothing reports it yet), ✎, 🗑, then ▶ / ❚❚, Restart and Overrun. A running
/// timer's row is lit (the board's --sel with an accent border), from `StageState.runningTimers` only.
struct TimersPanel: View {
    let model: TimersPanelModel
    let ui: OperatorUIState
    let send: (Command) -> Void
    let delete: (StageTimer.ID) -> Void
    @Environment(\.theme) private var theme
    @State private var armed: StageTimer.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingS) {
            ListTabHeader(title: "TIMERS", note: model.runningNote, actionTitle: "Stop all", canAct: model.canStopAll,
                        actionLabel: "Stop all timers", act: { model.stopAllCommands.forEach(send) },
                        canAdd: model.canAdd && !ui.isModalOpen, addHelp: model.canAdd ? "New timer" : TimersPanelModel.noStudioHelp,
                        addLabel: "New timer", add: { ui.timerEditor = .new })
            if model.timers.isEmpty {
                EmptyMessage(text: model.hasStudio ? "No timers in this Studio" : "No Studio open")
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.timers) { timer in
                            TimerRow(timer: timer, model: model, armed: $armed, edit: { ui.timerEditor = .edit(timer.id) },
                                     send: send, delete: delete, isModalOpen: ui.isModalOpen)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, ThemeTokens.spacingM)
        .padding(.vertical, 10)
    }
}

private struct TimerRow: View {
    let timer: StageTimer
    let model: TimersPanelModel
    @Binding var armed: StageTimer.ID?
    let edit: () -> Void
    let send: (Command) -> Void
    let delete: (StageTimer.ID) -> Void
    let isModalOpen: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let isOn = model.isRunning(timer)
        let canDelete = model.canDelete(timer)
        VStack(alignment: .leading, spacing: ThemeTokens.spacingS) {
            HStack(spacing: ThemeTokens.spacingS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.name).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                    Text(TimersPanelModel.modeLine(timer)).font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimersPanelModel.timeText)
                    .font(ThemeTokens.mono(20, weight: .semibold))
                    .foregroundStyle(isOn ? theme.textPrimary : theme.textSecondary)
                    .help(TimersPanelModel.timeHelp)
                    .accessibilityLabel("Time not reported")
                RowIconButton(symbol: "pencil", help: "Edit", label: "Edit timer: \(timer.name)", action: edit)
                    .disabled(isModalOpen)
                DeleteButton(isArmed: armed == timer.id, canDelete: canDelete, blockedHelp: TimersPanelModel.deleteBlockedHelp,
                             label: "Delete timer: \(timer.name)") {
                    if armed == timer.id { armed = nil; delete(timer.id) } else { armed = timer.id }
                }
            }
            HStack(spacing: ThemeTokens.spacingS) {
                Button { send(model.toggleCommand(timer)) } label: {
                    Image(systemName: isOn ? "pause.fill" : "play.fill").font(.system(size: 12))
                }
                .buttonStyle(PanelButtonStyle(kind: isOn ? .hide : .primary, width: 34, height: 28))
                .help(isOn ? "Stop" : "Start")
                .accessibilityLabel("\(isOn ? "Stop" : "Start") timer: \(timer.name)")
                Button { send(model.resetCommand(timer)) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PanelButtonStyle(kind: .secondary, width: 34, height: 28))
                .help("Restart")
                .accessibilityLabel("Restart timer: \(timer.name)")
                Spacer(minLength: 0)
                if timer.mode == .countdown { OverrunChip() }
            }
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8))
        .background(isOn ? theme.selection : theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? theme.accent : theme.border, lineWidth: 1))
        .contextMenu {
            Button("Edit…", action: edit).disabled(isModalOpen)
            Button(isOn ? "Stop" : "Start") { send(model.toggleCommand(timer)) }
            Button("Restart") { send(model.resetCommand(timer)) }
            Divider()
            Button("Delete") { delete(timer.id) }.disabled(!canDelete)
        }
        .onChange(of: canDelete) { _, can in if !can, armed == timer.id { armed = nil } }
    }
}

/// The board's Overrun chip, off: a timer has no overrun setting.
private struct OverrunChip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(theme.border).frame(width: 26, height: 14)
                .overlay(alignment: .leading) { Circle().fill(theme.textSecondary).frame(width: 10, height: 10).padding(.leading, 2) }
            Text("Overrun").font(.system(size: 12, weight: .bold))
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 26)
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(theme.border, lineWidth: 1))
        .opacity(0.5)
        .help(TimersPanelModel.overrunHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overrun, off")
        .accessibilityHint(TimersPanelModel.overrunHelp)
    }
}

/// Section label, a dim note, a link-style action, "+ New" in the accent (Main.dc.html L627).
private struct ListTabHeader: View {
    let title: String
    let note: String
    let actionTitle: String
    let canAct: Bool
    let actionLabel: String
    let act: () -> Void
    let canAdd: Bool
    let addHelp: String
    let addLabel: String
    let add: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: ThemeTokens.spacingS) {
            SectionLabel(text: title)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: act)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(canAct ? theme.textPrimary : theme.textSecondary)
                .disabled(!canAct)
                .opacity(canAct ? 1 : 0.5)
                .accessibilityLabel(actionLabel)
            Button("+ New", action: add)
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(theme.accent)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.5)
                .help(addHelp)
                .accessibilityLabel(addLabel)
        }
    }
}

/// 28 pt square on --panel with a --line border and a dim icon (the board's ✎).
private struct RowIconButton: View {
    let symbol: String
    let help: String
    let label: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The board's 🗑: the first click arms it (red, ✓, "Click again to delete"), the second deletes. Off while the item is
/// on air.
private struct DeleteButton: View {
    let isArmed: Bool
    let canDelete: Bool
    let blockedHelp: String
    let label: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: isArmed ? "checkmark" : "trash")
                .font(.system(size: 12, weight: isArmed ? .bold : .medium))
                .foregroundStyle(isArmed ? theme.onLive : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(isArmed ? theme.live : theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(isArmed ? theme.live : theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canDelete)
        .opacity(canDelete ? 1 : 0.4)
        .help(canDelete ? (isArmed ? "Click again to delete" : "Delete") : blockedHelp)
        .accessibilityLabel(label)
        .accessibilityHint(isArmed ? "Click again to delete" : "")
    }
}
