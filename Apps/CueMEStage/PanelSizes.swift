import AppKit
import SwiftUI

/// The three adjustable panel sizes of the operator view: service panel width, right column width, bottom panel
/// height. The mockup's sizes are the defaults. Stored on this machine (UserDefaults), never in a Studio. Pure, so the
/// limits are tested without the UI.
struct PanelSizes: Equatable {
    enum Panel: CaseIterable { case service, right, bottom }

    var service: CGFloat
    var right: CGFloat
    var bottom: CGFloat

    /// Main.dc.html L49, L512, L1327.
    static let defaults = PanelSizes(service: 280, right: 360, bottom: 330)

    static let serviceRange: ClosedRange<CGFloat> = 220...420
    static let rightRange: ClosedRange<CGFloat> = 300...520
    static let bottomMin: CGFloat = 200
    /// The bottom panel may take at most this share of the window height.
    static let bottomMaxFraction: CGFloat = 0.6
    /// The slide grid keeps at least this much: four columns of about 80 pt with their gaps and padding, and one row.
    static let gridMinWidth: CGFloat = 400
    static let gridMinHeight: CGFloat = 160
    /// The visible divider line between panels.
    static let dividerThickness: CGFloat = 1

    /// The sizes as they fit an area of `width` × `height` (the operator view between the notice and status bars):
    /// each within its own range, and none so large that the grid drops below its minimum. The service panel is
    /// fitted first, then the right column next to it. In a window too small for every minimum the minimums win.
    func fitted(width: CGFloat, height: CGFloat, windowHeight: CGFloat? = nil) -> PanelSizes {
        let dividers = 2 * Self.dividerThickness
        let service = Self.clamp(self.service, Self.serviceRange.lowerBound,
                                 min(Self.serviceRange.upperBound, width - dividers - Self.rightRange.lowerBound - Self.gridMinWidth))
        let right = Self.clamp(self.right, Self.rightRange.lowerBound,
                               min(Self.rightRange.upperBound, width - dividers - service - Self.gridMinWidth))
        let bottom = Self.clamp(self.bottom, Self.bottomMin,
                                min(Self.bottomMaxFraction * (windowHeight ?? height), height - Self.dividerThickness - Self.gridMinHeight))
        return PanelSizes(service: service, right: right, bottom: bottom)
    }

    /// A drag: these sizes (fitted) with one panel set to `value`. The other panels keep their size, so the dragged
    /// divider stops where the grid would drop below its minimum (or at the panel's own limit).
    func setting(_ panel: Panel, to value: CGFloat, width: CGFloat, height: CGFloat, windowHeight: CGFloat? = nil) -> PanelSizes {
        var copy = fitted(width: width, height: height, windowHeight: windowHeight)
        let free = width - 2 * Self.dividerThickness - Self.gridMinWidth
        switch panel {
        case .service:
            copy.service = Self.clamp(value, Self.serviceRange.lowerBound, min(Self.serviceRange.upperBound, free - copy.right))
        case .right:
            copy.right = Self.clamp(value, Self.rightRange.lowerBound, min(Self.rightRange.upperBound, free - copy.service))
        case .bottom:
            copy.bottom = value
            copy = copy.fitted(width: width, height: height, windowHeight: windowHeight)
        }
        return copy
    }

    /// These sizes with one panel back at its default (fitted when drawn, like any stored size).
    func resetting(_ panel: Panel) -> PanelSizes {
        var copy = self
        switch panel {
        case .service: copy.service = Self.defaults.service
        case .right: copy.right = Self.defaults.right
        case .bottom: copy.bottom = Self.defaults.bottom
        }
        return copy
    }

    /// `low` wins over `high` when the area is too small for both.
    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }

    // MARK: Storage

    /// Read from this machine's defaults; a missing key is the default size.
    static func load(from store: UserDefaults) -> PanelSizes {
        func read(_ key: String, _ fallback: CGFloat) -> CGFloat {
            store.object(forKey: key) == nil ? fallback : CGFloat(store.double(forKey: key))
        }
        return PanelSizes(service: read(StorageKeys.servicePanelWidth, defaults.service),
                          right: read(StorageKeys.rightColumnWidth, defaults.right),
                          bottom: read(StorageKeys.bottomPanelHeight, defaults.bottom))
    }

    func save(to store: UserDefaults) {
        store.set(Double(service), forKey: StorageKeys.servicePanelWidth)
        store.set(Double(right), forKey: StorageKeys.rightColumnWidth)
        store.set(Double(bottom), forKey: StorageKeys.bottomPanelHeight)
    }

    static let storageKeys = [StorageKeys.servicePanelWidth, StorageKeys.rightColumnWidth, StorageKeys.bottomPanelHeight,
                              StorageKeys.collectionsHeight] + BinColumnSizes.Keys.audio.all + BinColumnSizes.Keys.media.all

    /// View > Reset Panel Sizes: forget every panel size (the three above, the collections list, the bins' columns), so
    /// the defaults apply.
    static func resetAll(in store: UserDefaults) {
        storageKeys.forEach(store.removeObject(forKey:))
    }
}

/// A divider between two panels: the 1 pt line in the border colour, and a 6 pt invisible hit area over it with the
/// resize cursor. Hover and drag show a subtle line in an overlay, so nothing moves while idle. Drag to resize,
/// double-click to reset. The hit area sits above the panels next to it (`zIndex`), so a drag on it never reaches a
/// slide card or a service row.
struct PanelDivider: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    /// The size this divider controls, as drawn now.
    let value: CGFloat
    /// +1 when dragging right / down grows the panel, -1 when dragging left / up does.
    let direction: CGFloat
    let label: String
    let set: (CGFloat) -> Void
    let reset: () -> Void
    @Environment(\.theme) private var theme
    @State private var start: CGFloat?
    @State private var hovering = false

    /// At least 8 pt to grab, centred on the 1 pt line.
    static let hitThickness: CGFloat = 8

    var body: some View {
        let vertical = axis == .vertical
        theme.border
            .frame(width: vertical ? PanelSizes.dividerThickness : nil, height: vertical ? nil : PanelSizes.dividerThickness)
            .overlay {
                ZStack {
                    if hovering || start != nil {
                        theme.textSecondary.opacity(0.7)
                            .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                    }
                    Color.clear
                        .frame(width: vertical ? Self.hitThickness : nil, height: vertical ? nil : Self.hitThickness)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                hovering = true
                                cursor.set()
                            case .ended:
                                hovering = false
                                if start == nil { NSCursor.arrow.set() }
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    if start == nil { start = value }
                                    cursor.set()
                                    // The start is taken once; the size follows the translation in global space (which
                                    // does not move with the panels), with no animation, so every frame is exact.
                                    let delta = vertical ? drag.translation.width : drag.translation.height
                                    var still = Transaction()
                                    still.disablesAnimations = true
                                    withTransaction(still) { set(PanelDivider.dragged(start: start ?? value, delta: delta, direction: direction)) }
                                }
                                .onEnded { _ in
                                    start = nil
                                    if !hovering { NSCursor.arrow.set() }
                                }
                        )
                        .onTapGesture(count: 2) { reset() }
                }
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value)) points")
            .accessibilityHint("Drag to resize, double-click to reset")
            .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private var cursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }

    /// The size a drag asks for: the size at drag start plus the translation (signed by `direction`). Never the size as
    /// drawn during the drag, which would feed the panel's own movement back into the drag.
    static func dragged(start: CGFloat, delta: CGFloat, direction: CGFloat) -> CGFloat { start + direction * delta }
}

/// The two side columns of a bin: the folder or library column (leading) and the inspector (trailing). The middle (grid
/// or track list) takes the rest and keeps at least `middleMin`. The board's widths are the defaults. Stored on this
/// machine; pure, so the limits are tested without the UI.
struct BinColumnSizes: Equatable {
    enum Column: CaseIterable { case leading, trailing }

    struct Keys: Equatable {
        let leading: String
        let trailing: String
        var all: [String] { [leading, trailing] }

        static let audio = Keys(leading: StorageKeys.audioLibraryWidth, trailing: StorageKeys.audioInspectorWidth)
        static let media = Keys(leading: StorageKeys.mediaFolderWidth, trailing: StorageKeys.mediaInspectorWidth)
    }

    var leading: CGFloat
    var trailing: CGFloat

    /// Main.dc.html L263 / L314 (Media bin) and L417 / L453 (Audio bin): 250 and 250.
    static let defaults = BinColumnSizes(leading: 250, trailing: 250)
    static let sideRange: ClosedRange<CGFloat> = 180...420
    static let middleMin: CGFloat = 200

    /// The widths as they fit a bin `width` wide: leading first, then trailing, each in its range, the middle never
    /// below its minimum (in a bin too narrow for every minimum the minimums win).
    func fitted(width: CGFloat) -> BinColumnSizes {
        let free = width - 2 * PanelSizes.dividerThickness - Self.middleMin
        let leading = PanelSizes.clamp(self.leading, Self.sideRange.lowerBound,
                                       min(Self.sideRange.upperBound, free - Self.sideRange.lowerBound))
        let trailing = PanelSizes.clamp(self.trailing, Self.sideRange.lowerBound, min(Self.sideRange.upperBound, free - leading))
        return BinColumnSizes(leading: leading, trailing: trailing)
    }

    /// A drag: these widths (fitted) with one column set to `value`; the other keeps its width.
    func setting(_ column: Column, to value: CGFloat, width: CGFloat) -> BinColumnSizes {
        var copy = fitted(width: width)
        let free = width - 2 * PanelSizes.dividerThickness - Self.middleMin
        switch column {
        case .leading: copy.leading = PanelSizes.clamp(value, Self.sideRange.lowerBound, min(Self.sideRange.upperBound, free - copy.trailing))
        case .trailing: copy.trailing = PanelSizes.clamp(value, Self.sideRange.lowerBound, min(Self.sideRange.upperBound, free - copy.leading))
        }
        return copy
    }

    func resetting(_ column: Column) -> BinColumnSizes {
        var copy = self
        switch column {
        case .leading: copy.leading = Self.defaults.leading
        case .trailing: copy.trailing = Self.defaults.trailing
        }
        return copy
    }
}

/// The height of the service panel's COLLECTIONS list. Until it is dragged it fits its rows (up to
/// `ServicePanelLayout.collectionsMaxHeight`, as before); once dragged it keeps the stored height, at least `min`, and
/// the service list under it keeps at least `listMin`.
enum CollectionsHeight {
    static let min: CGFloat = 80
    static let listMin: CGFloat = 120

    /// The height to draw: nil (fit the rows) while nothing is stored. `shared` is the collections list and the service
    /// list together, as drawn: the room the divider splits.
    static func fitted(_ stored: CGFloat?, shared: CGFloat) -> CGFloat? {
        stored.map { clamp($0, shared: shared) }
    }

    /// A drag to `value`.
    static func clamp(_ value: CGFloat, shared: CGFloat) -> CGFloat {
        PanelSizes.clamp(value, min, shared - listMin)
    }
}
