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
    /// The song the row plays (for "Edit…"); nil for other items.
    var songID: Song.ID?
}

/// One block of the service list: a section header (nil for the items above the first section) and its rows.
struct ServiceListSection: Equatable, Identifiable {
    /// The section's id; nil for the block above the first header.
    var sectionID: ServiceSection.ID?
    /// As stored ("Pre-service"); drawn upper-case in the label style, as the board's PRE-SERVICE.
    var title: String?
    var rows: [ServiceRowInfo]
    var id: String { sectionID?.uuidString ?? "top" }
}

/// The service list under the board's ITEMS label: the rows in service order, grouped under the service's section
/// headers (Main.dc.html L72–L74, `head` rows). A header sits above the item it names (`firstItemID`); the items above
/// the first header have none; a header whose item is gone, or that names none, goes to the end with no rows. A
/// service without sections is one block with no header, as before.
struct ServiceListModel {
    let state: StageState
    /// The open Studio, for media names and lengths and the sections; nil in the mock.
    let studio: Studio?
    /// The last relink scan, for "⚠ Missing"; nil until one ran.
    let relink: RelinkReport?

    static let itemsLabel = "ITEMS"

    var sections: [ServiceListSection] {
        guard let service = state.service else { return [] }
        let headers = studio?.sections(of: service.id) ?? []
        let itemIDs = Set(service.items.map(\.id))
        var blocks: [ServiceListSection] = []
        var top = ServiceListSection(sectionID: nil, title: nil, rows: [])
        for item in service.items {
            let starting = headers.filter { $0.firstItemID == item.id }
            for header in starting { blocks.append(ServiceListSection(sectionID: header.id, title: header.name, rows: [])) }
            if blocks.isEmpty { top.rows.append(row(item)) } else { blocks[blocks.count - 1].rows.append(row(item)) }
        }
        for header in headers where header.firstItemID.map({ !itemIDs.contains($0) }) ?? true {
            blocks.append(ServiceListSection(sectionID: header.id, title: header.name, rows: []))
        }
        return (top.rows.isEmpty ? [] : [top]) + blocks
    }

    var rows: [ServiceRowInfo] { sections.flatMap(\.rows) }

    func row(_ item: Item) -> ServiceRowInfo {
        var row = ServiceRowInfo(id: item.id, title: item.title, icon: "rectangle", isLive: isLive(item))
        switch item.content {
        case let .song(id):
            row.icon = "music.note"
            row.songID = id
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

/// The COLLECTIONS block (Main.dc.html L55–L57, L870–L889). Collections hold only items with slides (songs now;
/// presentations and announcements later); media files are never a collection (video and photos go to the Media bin,
/// music to the Audio bin), though a media item can still be a row in a service.
///
/// The Studio's own collections come first, in their order, each with its count (an empty one shows 0). Songs in no
/// collection are listed after them as "Songs", only when there are any: a Studio without collections shows its
/// songs as before. Search filters these items only.
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
        /// The song, for "Edit…".
        var songID: Song.ID?
    }

    enum Row: Equatable {
        case collection(id: String, title: String, count: Int, isExpanded: Bool)
        case entry(Entry)
    }

    /// The id of the row holding songs that are in no collection.
    static let looseSongsID = "songs"
    static let looseSongsTitle = "Songs"

    let studio: Studio?
    var query = ""
    var expanded: Set<String> = []

    var collections: [Collection] {
        guard let studio else { return [] }
        let known = Set(studio.collections.map(\.id))
        func entries(_ songs: [Song]) -> [Entry] {
            songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { Entry(title: $0.title, icon: "music.note", songID: $0.id) }
        }
        let own = studio.collections.map { collection in
            Collection(id: collection.id.uuidString, title: collection.name,
                       entries: entries(studio.songs.filter { $0.collectionID == collection.id }))
        }
        let loose = studio.songs.filter { $0.collectionID.map { !known.contains($0) } ?? true }
        return own + (loose.isEmpty ? [] : [Collection(id: Self.looseSongsID, title: Self.looseSongsTitle, entries: entries(loose))])
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

/// The New collection dialog (ServiceDialog.dc.html, kind "collection"): a name; the Look is drawn but off.
struct NewCollectionModel {
    static let title = "New collection"
    static let createTitle = "Create collection"
    static let lookTitle = "Default look"
    static let lookHelp = "Choosing a look for a collection is not available yet"

    var name = ""
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool { !trimmedName.isEmpty }
}

/// The Section popover (Main.dc.html L68): a name, Cancel and Add. The header goes above the selected item, or to
/// the end of the service when nothing in it is selected.
struct NewSectionModel {
    static let label = "SECTION NAME"

    var name = ""
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !trimmedName.isEmpty }

    /// The item the new header sits above.
    static func anchor(selection: Item.ID?, in service: Service?) -> Item.ID? {
        guard let selection, service?.items.contains(where: { $0.id == selection }) == true else { return nil }
        return selection
    }
}

/// The service picker (Main.dc.html L62, L890–L897): the Studio's services, the one on air checked. Switching needs a
/// service operation the app does not have yet, so only the current one can be picked.
struct ServicePickerModel {
    let state: StageState
    let studio: Studio?

    static let switchHelp = "Switching services is not available in v0.1"
    static let newServiceHelp = "New services are not available in v0.1"
    static let activityHelp = "Activities are not available in v0.1"

    var title: String { state.service?.name ?? "No service" }
    var services: [(id: Service.ID, name: String, count: Int)] {
        studio?.services.map { ($0.id, $0.name, $0.items.count) } ?? state.service.map { [($0.id, $0.name, $0.items.count)] } ?? []
    }

    func isCurrent(_ id: Service.ID) -> Bool { id == state.service?.id }
    func canPick(_ id: Service.ID) -> Bool { isCurrent(id) }
}
