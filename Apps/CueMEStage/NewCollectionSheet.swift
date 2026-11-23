import SwiftUI
import StageKit

/// The New collection dialog (ServiceDialog.dc.html, kind "collection"; board "New collection",
/// ServiceNewCollection.dc.html): 460 pt on --chrome, a title row, NAME (focused, accent border), LOOK (drawn, off until
/// collections can have a look), then Cancel and "Create collection".
struct NewCollectionSheet: View {
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var model = NewCollectionModel()
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NewCollectionModel.title)
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { theme.border.frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "NAME")
                    TextField("", text: $model.name, prompt: Text("Kids Songs"))
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.accent, lineWidth: 1))
                        .onSubmit(submit)
                        .accessibilityLabel("Collection name")
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "LOOK")
                    HStack {
                        Text(NewCollectionModel.lookTitle)
                        Spacer()
                        Text("▾").foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: ThemeTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: ThemeTokens.radius).stroke(theme.border, lineWidth: 1))
                    .opacity(0.5)
                    .help(NewCollectionModel.lookHelp)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Look, \(NewCollectionModel.lookTitle)")
                    .accessibilityHint(NewCollectionModel.lookHelp)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PanelButtonStyle(kind: .secondary, minWidth: 0, height: 30))
                    .keyboardShortcut(.cancelAction)
                Button(NewCollectionModel.createTitle, action: submit)
                    .buttonStyle(PanelButtonStyle(kind: .primary, minWidth: 0, height: 30))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCreate)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { theme.border.frame(height: 1) }
        }
        .frame(width: 460)
        .background(theme.surface)
        .foregroundStyle(theme.textPrimary)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard model.canCreate else { return }
        create(model.trimmedName)
        dismiss()
    }
}
