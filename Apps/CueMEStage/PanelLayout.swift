import SwiftUI

/// Collects the global frames of named parts of the layout, for tests (the no-gap checks). Nil in the app: the
/// `layoutProbe(_:)` modifier then adds nothing.
@MainActor
final class LayoutProbe {
    private(set) var frames: [String: CGRect] = [:]
    func record(_ name: String, _ frame: CGRect) { frames[name] = frame }
    subscript(_ name: String) -> CGRect? { frames[name] }
}

private struct LayoutProbeKey: EnvironmentKey {
    static let defaultValue: LayoutProbe? = nil
}

extension EnvironmentValues {
    var layoutProbe: LayoutProbe? {
        get { self[LayoutProbeKey.self] }
        set { self[LayoutProbeKey.self] = newValue }
    }
}

private struct LayoutProbeModifier: ViewModifier {
    let name: String
    @Environment(\.layoutProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.record(name, $0) }
        } else {
            content
        }
    }
}

extension View {
    /// Reports this view's global frame to the environment's `LayoutProbe` under `name` (tests only).
    func layoutProbe(_ name: String) -> some View { modifier(LayoutProbeModifier(name: name)) }
}

/// A panel column whose content may be taller than the panel: it fills the height it is given, top-aligned, and scrolls
/// when its content needs more (instead of making the panel taller, which pushed the panel's content off centre). A
/// `Spacer` in the content still pushes what follows it to the bottom while everything fits.
struct ColumnScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { area in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: .top)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// A bin's three columns (Media and Audio): the leading column, a divider, the middle (fills), a divider, the trailing
/// column. The side widths are this machine's (`BinColumnSizes`, keys per bin), fitted to the bin's width when drawn:
/// a narrow window shrinks them, a wider one gives the stored widths back. Every column is top-aligned and fills the
/// height, so no column can sit lower than another.
struct BinColumns<Leading: View, Middle: View, Trailing: View>: View {
    let keys: BinColumnSizes.Keys
    let labels: (leading: String, trailing: String)
    /// Prefix of the layout-probe names ("audio" / "media").
    let probe: String
    @ViewBuilder let leading: Leading
    @ViewBuilder let middle: Middle
    @ViewBuilder let trailing: Trailing
    @AppStorage private var leadingWidth: Double
    @AppStorage private var trailingWidth: Double

    init(keys: BinColumnSizes.Keys, labels: (leading: String, trailing: String), probe: String,
         @ViewBuilder leading: () -> Leading, @ViewBuilder middle: () -> Middle, @ViewBuilder trailing: () -> Trailing) {
        self.keys = keys
        self.labels = labels
        self.probe = probe
        self.leading = leading()
        self.middle = middle()
        self.trailing = trailing()
        _leadingWidth = AppStorage(wrappedValue: Double(BinColumnSizes.defaults.leading), keys.leading)
        _trailingWidth = AppStorage(wrappedValue: Double(BinColumnSizes.defaults.trailing), keys.trailing)
    }

    private func keep(_ sizes: BinColumnSizes) {
        leadingWidth = sizes.leading
        trailingWidth = sizes.trailing
    }

    var body: some View {
        GeometryReader { area in
            let width = area.size.width
            let sizes = BinColumnSizes(leading: leadingWidth, trailing: trailingWidth).fitted(width: width)
            HStack(alignment: .top, spacing: 0) {
                leading
                    .frame(width: sizes.leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .layoutProbe("\(probe).leading")
                PanelDivider(axis: .vertical, value: sizes.leading, direction: 1, label: labels.leading) {
                    keep(sizes.setting(.leading, to: $0, width: width))
                } reset: { keep(sizes.resetting(.leading)) }
                middle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .layoutProbe("\(probe).middle")
                PanelDivider(axis: .vertical, value: sizes.trailing, direction: -1, label: labels.trailing) {
                    keep(sizes.setting(.trailing, to: $0, width: width))
                } reset: { keep(sizes.resetting(.trailing)) }
                trailing
                    .frame(width: sizes.trailing)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .layoutProbe("\(probe).trailing")
            }
            .frame(width: width, height: area.size.height, alignment: .top)
        }
    }
}
