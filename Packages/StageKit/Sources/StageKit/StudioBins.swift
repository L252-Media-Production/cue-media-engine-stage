import Foundation

// The Media bin (video and photos) and the Audio bin (music): their folders (bins.json) and what each folder lists.
// Media is never a collection: collections hold slide-bearing items only.

/// bins.json: one folder of the Media bin or the Audio bin. A folder only groups media index entries (an entry names
/// its folder with `MediaIndexEntry.folderID`); it is never a folder on disk, and nothing in the user's media folders is
/// created, moved or deleted for it.
public struct StudioBinFolder: Codable, Sendable, Hashable, Identifiable {
    public enum Bin: String, Codable, Sendable, CaseIterable {
        /// Video and photos.
        case media
        /// Music and other audio.
        case audio

        /// The bin a media kind belongs to.
        public static func of(_ kind: MediaItem.Kind) -> Bin { kind == .audio ? .audio : .media }
        public func holds(_ kind: MediaItem.Kind) -> Bool { Bin.of(kind) == self }
    }

    public var id: UUID
    public var name: String
    public var bin: Bin
    /// The folder this one is inside; nil = top level.
    public var parentID: UUID?
    /// A linked folder: where its files were on the Mac that linked it. A hint, like `lastKnownPath`, never a key.
    /// The folder is linked on a Mac when this path is one of that Mac's media folders.
    public var linkedPath: String?

    public init(id: UUID = UUID(), name: String, bin: Bin, parentID: UUID? = nil, linkedPath: String? = nil) {
        self.id = id
        self.name = name
        self.bin = bin
        self.parentID = parentID
        self.linkedPath = linkedPath
    }
}

/// The Media bin's type filter.
public enum MediaKindFilter: String, Sendable, CaseIterable {
    case all, video, photo

    public var title: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .photo: "Photos"
        }
    }

    public func accepts(_ kind: MediaItem.Kind) -> Bool {
        switch self {
        case .all: true
        case .video: kind == .video
        case .photo: kind == .image
        }
    }
}

/// What a bin's folder column has selected: every item of the bin, or one folder.
public enum BinSelection: Hashable, Sendable {
    case all
    case folder(StudioBinFolder.ID)
}

/// The folders and items of one bin, from a Studio. Pure: the operator view draws it, tests check it.
public struct BinListing: Sendable {
    public struct FolderRow: Equatable, Sendable, Identifiable {
        public var selection: BinSelection
        public var name: String
        /// 0 for the "All" row and top-level folders.
        public var depth: Int
        /// Items directly in it (the "All" row: every item of the bin).
        public var count: Int
        public var hasChildren: Bool
        public var linkedPath: String?
        public var id: BinSelection { selection }
    }

    public let bin: StudioBinFolder.Bin
    public let folders: [StudioBinFolder]
    /// The bin's entries only (video and photos, or audio).
    public let entries: [MediaIndexEntry]

    public init(studio: Studio?, bin: StudioBinFolder.Bin) {
        self.bin = bin
        folders = studio?.binFolders.filter { $0.bin == bin } ?? []
        entries = studio?.media.filter { bin.holds($0.kind) } ?? []
    }

    public static func allTitle(_ bin: StudioBinFolder.Bin) -> String { bin == .media ? "All media" : "All audio" }

    private func byName<T>(_ list: [T], _ name: (T) -> String) -> [T] {
        list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The folder's own entries; a folder of the other bin, or an unknown one, holds none.
    private func isIn(_ entry: MediaIndexEntry, _ folder: StudioBinFolder.ID) -> Bool { entry.folderID == folder }

    /// "All", then the folders depth first, children under their parent, each level by name. A folder whose parent
    /// is unknown (or in the other bin) is shown at the top level; a cycle is broken where it is found.
    public var rows: [FolderRow] {
        let ids = Set(folders.map(\.id))
        func parent(_ f: StudioBinFolder) -> StudioBinFolder.ID? { f.parentID.flatMap { ids.contains($0) && $0 != f.id ? $0 : nil } }
        var rows = [FolderRow(selection: .all, name: Self.allTitle(bin), depth: 0, count: entries.count, hasChildren: false)]
        var placed: Set<StudioBinFolder.ID> = []
        func place(_ folder: StudioBinFolder, depth: Int) {
            guard placed.insert(folder.id).inserted else { return }
            let children = byName(folders.filter { parent($0) == folder.id && !placed.contains($0.id) }, \.name)
            rows.append(FolderRow(selection: .folder(folder.id), name: folder.name, depth: depth,
                                  count: entries.filter { isIn($0, folder.id) }.count, hasChildren: !children.isEmpty,
                                  linkedPath: folder.linkedPath))
            for child in children { place(child, depth: depth + 1) }
        }
        for top in byName(folders.filter { parent($0) == nil }, \.name) { place(top, depth: 0) }
        // Folders only reachable through a cycle.
        for rest in byName(folders.filter { !placed.contains($0.id) }, \.name) { place(rest, depth: 0) }
        return rows
    }

    public func folder(_ id: StudioBinFolder.ID) -> StudioBinFolder? { folders.first { $0.id == id } }

    /// The selection when it still exists, else "All".
    public func resolve(_ selection: BinSelection) -> BinSelection {
        if case let .folder(id) = selection, folder(id) == nil { return .all }
        return selection
    }

    /// The items to show, by name. A search looks through the whole bin, whatever folder is selected; without one,
    /// the selected folder's own items. The filter keeps one kind (video or photos); it does nothing in the Audio bin.
    public func items(in selection: BinSelection, query: String = "", filter: MediaKindFilter = .all) -> [MediaIndexEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: [MediaIndexEntry]
        if !q.isEmpty {
            list = entries.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.fileName.localizedCaseInsensitiveContains(q) }
        } else {
            switch resolve(selection) {
            case .all: list = entries
            case let .folder(id): list = entries.filter { isIn($0, id) }
            }
        }
        if bin == .media { list = list.filter { filter.accepts($0.kind) } }
        return byName(list, \.name)
    }
}

/// What registering files did: which entries are new, and which were already in the index.
public struct MediaRegistration: Equatable, Sendable {
    public var added: [MediaItem.ID] = []
    /// Files already in the index (same SHA-256, or the same path when either has no hash): the existing entry's id.
    public var existing: [MediaItem.ID] = []

    public init(added: [MediaItem.ID] = [], existing: [MediaItem.ID] = []) {
        self.added = added
        self.existing = existing
    }
}

extension Studio {
    /// A new folder in a bin (a library folder only: nothing is created on disk). The parent must be a folder of the
    /// same bin, else the folder goes to the top level.
    @discardableResult
    public mutating func addBinFolder(named name: String, in bin: StudioBinFolder.Bin, parent: StudioBinFolder.ID? = nil,
                                      linkedPath: String? = nil) -> StudioBinFolder {
        let parentOK = parent.map { p in binFolders.contains { $0.id == p && $0.bin == bin } } ?? false
        let folder = StudioBinFolder(name: name, bin: bin, parentID: parentOK ? parent : nil, linkedPath: linkedPath)
        binFolders.append(folder)
        return folder
    }

    /// The index entry that is the same file as `entry`: the same SHA-256, or, when either has no hash, the same path.
    public func existingMedia(matching entry: MediaIndexEntry) -> MediaIndexEntry? {
        if let sha = entry.sha256, let hit = media.first(where: { $0.sha256 == sha }) { return hit }
        guard let path = entry.lastKnownPath else { return nil }
        return media.first { ($0.sha256 == nil || entry.sha256 == nil) && $0.lastKnownPath == path }
    }

    /// Adds files to the media index, in place: an entry is only a reference (name, kind, size, hash, path). A file that
    /// is already in the index is not added again; its entry is left where it is. `folder` must belong to the
    /// entry's bin, else the entry goes in no folder.
    @discardableResult
    public mutating func registerMedia(_ entries: [MediaIndexEntry], into folder: StudioBinFolder.ID?) -> MediaRegistration {
        var result = MediaRegistration()
        for var entry in entries {
            if let hit = existingMedia(matching: entry) {
                result.existing.append(hit.id)
                continue
            }
            let target = folder.flatMap { id in binFolders.first { $0.id == id && $0.bin.holds(entry.kind) } }
            entry.folderID = target?.id
            media.append(entry)
            result.added.append(entry.id)
        }
        return result
    }

    /// A media row at the end of the active service. Refused (nil) for an id not in the index or without a service.
    @discardableResult
    public mutating func appendMediaRow(_ id: MediaItem.ID) -> Item? {
        guard let entry = media.first(where: { $0.id == id }), let service = activeService,
              let s = services.firstIndex(where: { $0.id == service.id }) else { return nil }
        let item = Item(title: entry.name, content: .media(id))
        services[s].items.append(item)
        return item
    }

    /// The stored audio settings of a track, or the defaults when it has none.
    public func audioSettings(for id: MediaItem.ID) -> AudioSettings {
        audioSettings[id] ?? AudioSettings(mediaID: id)
    }
}
