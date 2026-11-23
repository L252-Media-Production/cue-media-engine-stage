import Foundation
import StageKit

/// Fixed sizes of the service panel (Main.dc.html L49–L86).
enum ServicePanelLayout {
    /// L49.
    static let width: CGFloat = 280
    /// L56: the collections block scrolls past this.
    static let collectionsMaxHeight: CGFloat = 150
    /// One collection row: padding 6 + 13 pt text + 6, plus the 1 pt gap.
    static let collectionRowHeight: CGFloat = 27
}

/// What colour a row's right-hand meta is drawn in (Main.dc.html L920 `metaColor`).
enum RowMetaTone: Equatable {
    case dim
    /// "→ Lobby TV" (a screen target). Nothing in the data gives one yet.
    case accent
    /// "⚠ Missing".
    case warning
}

/// One row of the service list: only what the data holds. Songs have no look, track or length in the model, so they
/// have no sub-line or meta; media rows show their file, length and a missing file.
struct ServiceRowInfo: Equatable, Identifiable {
    var id: Item.ID
    var title: String
    /// SF Symbol for the item type.
    var icon: String
    var sub: String?
    var meta: String?
    var metaTone: RowMetaTone = .dim
    var isLive: Bool
}

/// The service list: rows under section headings. The Studio model has no sections (a service is a flat list of
/// items), so every row sits under the board's ITEMS label and no heading is invented.
struct ServiceListModel {
    let state: StageState
    /// The open Studio, for media names and lengths; nil in the mock.
    let studio: Studio?
    /// The last relink scan, for "⚠ Missing"; nil until one ran.
    let relink: RelinkReport?

    static let itemsLabel = "ITEMS"

    var sections: [(title: String, rows: [ServiceRowInfo])] {
        let rows = (state.service?.items ?? []).map(row)
        return rows.isEmpty ? [] : [(Self.itemsLabel, rows)]
    }

    var rows: [ServiceRowInfo] { sections.flatMap(\.rows) }

    func row(_ item: Item) -> ServiceRowInfo {
        var row = ServiceRowInfo(id: item.id, title: item.title, icon: "rectangle", isLive: isLive(item))
        switch item.content {
        case .song:
            row.icon = "music.note"
        case let .media(id):
            let entry = studio?.media.first { $0.id == id }
            row.icon = Self.icon(entry?.kind ?? .audio)
            row.sub = entry?.fileName
            if case .missing = relink?.statuses[id] {
                row.meta = "⚠ Missing"
                row.metaTone = .warning
            } else {
                row.meta = entry?.duration.map(Self.duration)
            }
        case .blank:
            break
        }
        return row
    }

    /// Live: the item on the first output screen, or the media item whose track plays.
    func isLive(_ item: Item) -> Bool {
        if state.primaryLive?.itemID == item.id { return true }
        guard case let .media(id) = item.content else { return false }
        return state.audio.liveTrack == id
    }

    static func icon(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .audio: "waveform"
        case .video: "film"
        case .image: "photo"
        }
    }

    /// "4:12", or "1:02:03" past an hour.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The selection moved by `step` rows (arrow keys), clamped to the list; the first row when nothing is selected.
    func moving(_ selection: Item.ID?, by step: Int) -> Item.ID? {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let selection, let index = ids.firstIndex(of: selection) else { return ids.first }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }
}

/// The COLLECTIONS block (Main.dc.html L55–L57, L870–L889). The Studio has no collections of its own, so the two
/// libraries it does have are shown as collections: its songs and its media. Search filters both.
struct CollectionsModel {
    struct Collection: Equatable {
        var id: String
        var title: String
        var entries: [Entry]
    }

    struct Entry: Equatable {
        var title: String
        /// SF Symbol.
        var icon: String
        var meta: String?
    }

    enum Row: Equatable {
        case collection(id: String, title: String, count: Int, isExpanded: Bool)
        case entry(Entry)
    }

    let studio: Studio?
    var query = ""
    var expanded: Set<String> = []

    var collections: [Collection] {
        guard let studio else { return [] }
        return [
            Collection(id: "songs", title: "Songs", entries: studio.songs.map { Entry(title: $0.title, icon: "music.note") }),
            Collection(id: "media", title: "Media", entries: studio.media.map {
                Entry(title: $0.name, icon: ServiceListModel.icon($0.kind), meta: $0.duration.map(ServiceListModel.duration))
            }),
        ]
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Without a search: each collection with its count, its entries under it when expanded. With one: only the
    /// collections with a match, opened, with the matching entries (all of them when the collection's name matches).
    var rows: [Row] {
        let q = trimmedQuery
        return collections.flatMap { collection -> [Row] in
            if q.isEmpty {
                let open = expanded.contains(collection.id)
                return [.collection(id: collection.id, title: collection.title, count: collection.entries.count, isExpanded: open)]
                    + (open ? collection.entries.map(Row.entry) : [])
            }
            let entries = collection.title.localizedCaseInsensitiveContains(q)
                ? collection.entries
                : collection.entries.filter { $0.title.localizedCaseInsensitiveContains(q) }
            guard !entries.isEmpty else { return [] }
            return [.collection(id: collection.id, title: collection.title, count: entries.count, isExpanded: true)]
                + entries.map(Row.entry)
        }
    }

    func toggling(_ id: String) -> Set<String> { expanded.symmetricDifference([id]) }
}

/// The service picker (Main.dc.html L62, L890–L897): the Studio's services, the one on air checked. Switching needs a
/// service operation the app does not have yet, so only the current one can be picked.
struct ServicePickerModel {
    let state: StageState
    let studio: Studio?

    static let switchHelp = "Switching services is not available in v0.1"
    static let newServiceHelp = "New services are not available in v0.1"
    static let sectionHelp = "Sections are not available in v0.1"
    static let activityHelp = "Activities are not available in v0.1"

    var title: String { state.service?.name ?? "No service" }
    var services: [(id: Service.ID, name: String, count: Int)] {
        studio?.services.map { ($0.id, $0.name, $0.items.count) } ?? state.service.map { [($0.id, $0.name, $0.items.count)] } ?? []
    }

    func isCurrent(_ id: Service.ID) -> Bool { id == state.service?.id }
    func canPick(_ id: Service.ID) -> Bool { isCurrent(id) }
}
