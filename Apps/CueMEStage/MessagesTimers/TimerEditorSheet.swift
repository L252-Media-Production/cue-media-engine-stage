import SwiftUI
import StageKit

/// The timer editor (TimerEditor.dc.html, "Count down from"; TimerEditorTo.dc.html, "Count down to time"): a 580 pt
/// sheet. Title row with Cancel and Save; NAME, TYPE, the minutes and seconds with ▴ / ▾, Overrun, PREVIEW. The fields
/// are what `StageTimer` has. "Count down to time" (a time of day) and Overrun have no field and cannot be chosen.
/// Saving goes through `StudioController.saveTimer` (autosave, then `reloadStudio`).
struct TimerEditorSheet: View {
    let save: (StageTimer) -> Void
    @State var model: TimerEditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                nameField
                typeField
                timeFields
                if model.showsOverrun { overrunRow }
                preview
            }
            .padding(16)
        }
        .frame(width: 580)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { nameFocused = true }
    }

    private var header: some View {
        HStack(spacing: ThemeTokens.spacingM) {
            Text(model.title).font(.system(size: 15, weight: .bold))
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 28))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: commit)
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

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "NAME")
            TextField("", text: $model.name, prompt: Text("Announcements"))
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.accent, lineWidth: 1))
                .onSubmit(commit)
                .accessibilityLabel("Timer name")
        }
    }

    private var typeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "TYPE")
            HStack(spacing: 0) {
                ForEach(TimerKind.allCases) { kind in
                    let on = model.kind == kind
                    Button { model.choose(kind) } label: {
                        Text(kind.rawValue)
                            .font(.system(size: 12, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? theme.onAccent : theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? theme.accent : theme.surfaceRaised)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!kind.isAvailable)
                    .opacity(kind.isAvailable ? 1 : 0.5)
                    .help(kind.help)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ThemeTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        }
    }

    private var timeFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: model.fieldLabel)
            HStack(alignment: .center, spacing: 6) {
                StepperBox(value: model.shownMinutes, label: "Minutes", isEnabled: model.fieldsEditable,
                           up: { model.stepMinutes(true) }, down: { model.stepMinutes(false) })
                Text(":").font(.system(size: 24, weight: .semibold)).foregroundStyle(theme.textSecondary)
                StepperBox(value: model.shownSeconds, label: "Seconds", isEnabled: model.fieldsEditable,
                           up: { model.stepSeconds(true) }, down: { model.stepSeconds(false) })
            }
        }
        .help(model.fieldsEditable ? "" : "A count-up timer starts at 00:00")
    }

    private var overrunRow: some View {
        HStack(spacing: 10) {
            Text("Overrun").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().disabled(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
        .opacity(0.5)
        .help(TimersPanelModel.overrunHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overrun, off")
        .accessibilityHint(TimersPanelModel.overrunHelp)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "PREVIEW")
            Text(model.previewText)
                .font(ThemeTokens.mono(56, weight: .semibold))
                .foregroundStyle(Color(hex: 0x47C86E))
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                .accessibilityLabel("Preview \(model.previewText)")
        }
    }

    private func commit() {
        guard model.canSave else { return }
        save(model.timer)
        dismiss()
    }
}

/// A 56 × 44 mono box with ▴ above and ▾ below (TimerEditor.dc.html).
private struct StepperBox: View {
    let value: Int
    let label: String
    let isEnabled: Bool
    let up: () -> Void
    let down: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 3) {
            arrow("▴", "Increase \(label.lowercased())", up)
            Text(String(format: "%02d", value))
                .font(ThemeTokens.mono(24, weight: .semibold))
                .frame(width: 56, height: 44)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                .accessibilityLabel(label)
                .accessibilityValue("\(value)")
                .accessibilityAdjustableAction { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .increment: up()
                    case .decrement: down()
                    @unknown default: break
                    }
                }
            arrow("▾", "Decrease \(label.lowercased())", down)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func arrow(_ glyph: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 56, height: 20)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(name)
    }
}
