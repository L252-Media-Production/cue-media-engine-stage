import SwiftUI
import StageKit

/// The message editor (MessageEditor.dc.html; Style menu MessageEditorStyle.dc.html): a 680 pt sheet. Title row with
/// Cancel and Save; MESSAGE, STYLE, SHOW FOR and Flash when shown on the left; SEND TO and PREVIEW on the right; a footer
/// with the summary and "Save and show". Only MESSAGE can be changed: a `Message` has no style, duration, flash or screen
/// list, so those are drawn as they behave in v0.1 (until hidden, every output screen) and cannot be changed.
///
/// Saving goes through `StudioController.saveMessage` (autosave, then `reloadStudio`). Saving a message that is showing
/// does not change the screens: they keep the shown text until it is shown again ("Save and show" does that).
struct MessageEditorSheet: View {
    let state: StageState
    let save: (Message) -> Void
    let send: (Command) -> Void
    @State var model: MessageEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var textFocused: Bool

    private var screens: [ScreenState] { state.outputScreens }
    private var isShowing: Bool { state.visibleMessages.contains(model.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: ThemeTokens.spacingL) {
                VStack(alignment: .leading, spacing: 14) {
                    messageField
                    styleField
                    durationField
                    flashRow
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    sendTo
                    preview
                }
                .frame(width: 280)
            }
            .padding(16)
            footer
        }
        .frame(width: 680)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { textFocused = true }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: ThemeTokens.spacingM) {
            Text(model.title).font(.system(size: 15, weight: .bold))
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 28))
                .keyboardShortcut(.cancelAction)
            Button("Save") { commit(show: false) }
                .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 28))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .help(model.invalidReason ?? "")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(theme.surface)
        .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "MESSAGE")
            TextField("", text: $model.text, prompt: Text("Please silence your phones"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(2...4)
                .focused($textFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 64, alignment: .topLeading)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.accent, lineWidth: 1))
                .accessibilityLabel("Message")
            if isShowing && !model.isNew {
                Text(MessageEditorModel.showingNote)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The board's style dropdown. It opens, so the styles can be seen, but none can be picked.
    private var styleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "STYLE")
            Menu {
                ForEach(MessageEditorModel.styles, id: \.self) { style in
                    Button(style) {}.disabled(true)
                }
                Divider()
                Button("Edit templates ↗") {}.disabled(true)
                Divider()
                Text(MessageEditorModel.styleHelp)
            } label: {
                HStack {
                    Text(MessageEditorModel.styleTitle).fontWeight(.semibold)
                    Spacer()
                    Text("▾").foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(MessageEditorModel.styleHelp)
            .accessibilityLabel("Style, not set")
            .accessibilityHint(MessageEditorModel.styleHelp)
        }
    }

    private var durationField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "SHOW FOR")
            HStack(spacing: 0) {
                ForEach(MessageEditorModel.durations, id: \.self) { duration in
                    let on = MessageEditorModel.isDurationAvailable(duration)
                    Text(duration)
                        .font(.system(size: 12, weight: on ? .bold : .regular))
                        .foregroundStyle(on ? theme.onAccent : theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(on ? theme.accent : theme.surfaceRaised)
                        .opacity(on ? 1 : 0.5)
                        .help(on ? "" : MessageEditorModel.durationHelp)
                        .accessibilityLabel(duration)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityHint(on ? "" : MessageEditorModel.durationHelp)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        }
    }

    private var flashRow: some View {
        HStack(spacing: 10) {
            Text("Flash when shown").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().disabled(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        .opacity(0.5)
        .help(MessageEditorModel.flashHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Flash when shown, off")
        .accessibilityHint(MessageEditorModel.flashHelp)
    }

    private var sendTo: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: "SEND TO")
                Spacer()
                Text("All").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent).opacity(0.5)
                Text("None").font(.system(size: 12)).foregroundStyle(theme.textSecondary).opacity(0.5).padding(.leading, 10)
            }
            .help(MessageEditorModel.sendToHelp)
            VStack(spacing: 0) {
                if screens.isEmpty {
                    Text("No output screens").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                }
                ForEach(screens) { screen in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: 16, height: 16)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 4))
                        Text(screen.name).fontWeight(.semibold).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(MessageEditorModel.typeLabel(state.screenSetups[screen.screenID]?.type))
                            .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
                }
            }
            .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            .opacity(0.6)
            .help(MessageEditorModel.sendToHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Send to: every output screen")
            .accessibilityHint(MessageEditorModel.sendToHelp)
        }
    }

    /// The text on the board's preview background. No banner: a message has no style to draw.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "PREVIEW")
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1C3A5E), Color(hex: 0x0D1B2E)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(model.trimmedText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.slideText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
            .accessibilityLabel("Preview: \(model.trimmedText)")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(MessageEditorModel.summary(screenCount: screens.count))
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            Button("Save and show") { commit(show: true) }
                .buttonStyle(PanelButtonStyle(kind: .accentOutline, minWidth: 0, height: 30))
                .disabled(!model.canSave)
                .help(model.invalidReason ?? "Save, then show it on every output screen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surface)
        .overlay(alignment: .top) { theme.border.frame(height: 1) }
    }

    private func commit(show: Bool) {
        guard model.canSave else { return }
        let message = model.message
        save(message)
        // The save sent reloadStudio first (one ordered queue), so the engine knows a new message by now.
        if show { send(.showMessage(message.id, screens: [])) }
        dismiss()
    }
}
