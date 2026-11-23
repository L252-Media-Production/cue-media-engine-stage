import Foundation
import StageKit

/// What to do with an imported item whose id is already in the Studio.
enum ItemClashChoice: Equatable { case skip, replace, keepBoth }

struct ItemImportResult: Equatable {
    var added: [String] = []
    var replaced: [String] = []
    var keptBoth: [String] = []
    var skipped: [String] = []
    /// Items the file had but this version cannot read (unknown kind, bad data), with the reason.
    var notRead: [String] = []
    var mediaAdded: [String] = []
}

/// .stgitem import and export against a Studio. The reading and the kind registry are StageKit's
/// (`StudioItemCodec`); this decides clashes and adds the media the items need to the Studio's index.
enum StudioItemImporter {
    static let maxFileBytes = 64 * 1024 * 1024

    static func read(_ url: URL, codec: StudioItemCodec = StudioItemCodec()) throws -> StudioItemImport {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw StudioItemError.notAnItemFile("larger than \(maxFileBytes / 1024 / 1024) MB") }
        return try codec.decode(try Data(contentsOf: url))
    }

    static func export(_ items: [StudioItemPayload], from studio: Studio, appVersion: String, now: Date) throws -> Data {
        try StudioItemCodec.encode(items, media: studio.media, appVersion: appVersion, exported: now)
    }

    /// The imported items whose id is already in the Studio (same kind). Ask about each.
    static func clashes(_ imported: StudioItemImport, in studio: Studio) -> [StudioItemPayload] {
        imported.items.filter { studio.contains($0) }
    }

    /// Adds the items. `choice` is asked for every clash (Skip, Replace or Keep both).
    static func apply(_ imported: StudioItemImport, to studio: inout Studio, choice: (StudioItemPayload) -> ItemClashChoice) -> ItemImportResult {
        var result = ItemImportResult()
        result.notRead = imported.skipped.map { "\($0.name) (\($0.reason))" }
        for item in imported.items {
            guard studio.contains(item) else {
                studio.insert(item)
                result.added.append(item.name)
                continue
            }
            switch choice(item) {
            case .skip: result.skipped.append(item.name)
            case .replace:
                studio.replace(item)
                result.replaced.append(item.name)
            case .keepBoth:
                studio.insert(item.withID(UUID()))
                result.keptBoth.append(item.name)
            }
        }
        let known = Set(studio.media.map(\.id))
        for ref in imported.mediaRefs where !known.contains(ref.id) {
            studio.media.append(MediaIndexEntry(id: ref.id, name: ref.name, kind: ref.kind ?? guessKind(ref.name), size: ref.size, sha256: ref.sha256))
            result.mediaAdded.append(ref.name)
        }
        return result
    }

    /// For a media ref written without its kind: by file extension, video when unknown.
    static func guessKind(_ name: String) -> MediaItem.Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf": .audio
        case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp": .image
        default: .video
        }
    }
}

extension Studio {
    func contains(_ item: StudioItemPayload) -> Bool {
        switch item {
        case let .song(v): songs.contains { $0.id == v.id }
        case let .message(v): messages.contains { $0.id == v.id }
        case let .timer(v): timers.contains { $0.id == v.id }
        case let .look(v): looks.contains { $0.id == v.id }
        }
    }

    mutating func insert(_ item: StudioItemPayload) {
        switch item {
        case let .song(v): songs.append(v)
        case let .message(v): messages.append(v)
        case let .timer(v): timers.append(v)
        case let .look(v): looks.append(v)
        }
    }

    mutating func replace(_ item: StudioItemPayload) {
        switch item {
        case let .song(v): if let i = songs.firstIndex(where: { $0.id == v.id }) { songs[i] = v }
        case let .message(v): if let i = messages.firstIndex(where: { $0.id == v.id }) { messages[i] = v }
        case let .timer(v): if let i = timers.firstIndex(where: { $0.id == v.id }) { timers[i] = v }
        case let .look(v): if let i = looks.firstIndex(where: { $0.id == v.id }) { looks[i] = v }
        }
    }
}
