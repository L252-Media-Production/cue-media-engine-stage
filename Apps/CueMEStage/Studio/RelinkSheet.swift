import SwiftUI
import StageKit

/// File > Relink Media…: this Mac's media folders, a scan, and what it found. Nothing is imported or copied.
struct RelinkSheet: View {
    let studios: StudioController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeTokens.spacingM) {
            Text("RELINK MEDIA").font(ThemeTokens.mono(12, weight: .bold))
            Text("Media folders on this Mac (shared by every Studio)").font(.caption).foregroundStyle(theme.textSecondary)
            List {
                ForEach(studios.mediaFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { studios.removeMediaFolder(folder) }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: 110)
            HStack {
                Button("Add Folder…") { studios.addMediaFolder() }
                Spacer()
                if studios.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Cancel Scan") { studios.cancelRelink() }
                } else {
                    Button("Scan") { studios.relink() }.disabled(studios.mediaFolders.isEmpty)
                }
            }
            if let report = studios.relinkReport {
                Text("Found \(report.found) · Relinked \(report.relinked) · Missing \(report.missing) · Ambiguous \(report.ambiguous)")
                    .font(ThemeTokens.mono(12, weight: .semibold))
                List(report.index) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Text(label(report.statuses[entry.id]))
                            .font(ThemeTokens.mono(11))
                            .foregroundStyle(color(report.statuses[entry.id]))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(ThemeTokens.spacingL)
        .frame(width: 620, height: 520)
        .background(theme.background)
    }

    private func label(_ status: RelinkReport.Status?) -> String {
        switch status {
        case .found: "Found"
        case .relinked: "Relinked"
        case .missing, nil: "Missing"
        case let .ambiguous(paths): "Ambiguous (\(paths.count))"
        }
    }

    private func color(_ status: RelinkReport.Status?) -> Color {
        switch status {
        case .found, .relinked: theme.ok
        case .ambiguous: theme.warning
        case .missing, nil: theme.danger
        }
    }
}
