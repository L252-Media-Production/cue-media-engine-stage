import Foundation
import StageKit

/// Fixed sizes of the slide grid (Main.dc.html L94–L125).
enum SlideGridLayout {
    /// L116: `repeat(4, minmax(0, 1fr))`.
    static let columns = 4
    /// L116: gap 10.
    static let spacing: CGFloat = 10
    /// L113: padding 14 × 18, groups 14 apart.
    static let verticalPadding: CGFloat = 14
    static let horizontalPadding: CGFloat = 18
    static let groupSpacing: CGFloat = 14
}

/// A titled block of slides (Main.dc.html L117–L119).
struct SlideGroup: Equatable, Identifiable {
    var id: Int { firstIndex }
    /// Upper-case, in the label style: "VERSE", "CHORUS".
    var title: String
    /// Index of the first slide in the item.
    var firstIndex: Int
    var slides: [Slide]
    var count: Int { slides.count }
}

/// The slides of an item in groups. Songs carry no groups, only a label per slide ("Verse 1", "Chorus"), so a group
/// is a run of neighbouring slides whose label has the same name once a trailing number is dropped: "Verse 1",
/// "Verse 2", "Verse 3" make VERSE (3); a chorus in between starts a new group.
enum SlideGrouping {
    static func groups(_ slides: [Slide]) -> [SlideGroup] {
        var groups: [SlideGroup] = []
        for (index, slide) in slides.enumerated() {
            let title = baseName(slide.label).uppercased()
            if let last = groups.last, last.title == title {
                groups[groups.count - 1].slides.append(slide)
            } else {
                groups.append(SlideGroup(title: title.isEmpty ? "SLIDES" : title, firstIndex: index, slides: [slide]))
            }
        }
        return groups
    }

    /// "Verse 2" → "Verse"; "Chorus" → "Chorus"; "Pre-Chorus 1b" stays as is.
    static func baseName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.lastIndex(of: " "),
              trimmed[trimmed.index(after: space)...].allSatisfy(\.isNumber),
              trimmed.index(after: space) < trimmed.endIndex else { return trimmed }
        return String(trimmed[..<space])
    }
}

/// The grid header (Main.dc.html L95–L104): title, file chips, "Send to ▾", "Edit ✎". Only data the model has: a media
/// item's own file; a song's audio track and background (library items by id), when it has them.
struct SlideGridHeaderModel {
    let item: Item?
    let studio: Studio?

    static let sendToTitle = "Default"
    static let sendToHelp = "Send to is not available in v0.1"

    var title: String { item?.title ?? "Slides" }

    var chips: [String] {
        func chip(_ id: MediaItem.ID?) -> String? {
            guard let id, let entry = studio?.media.first(where: { $0.id == id }) else { return nil }
            return entry.kind == .audio ? "♪ \(entry.fileName)" : entry.fileName
        }
        switch item?.content {
        case let .media(id)?: return [chip(id)].compactMap { $0 }
        case .song?: return [chip(song?.audioTrackID), chip(song?.backgroundID)].compactMap { $0 }
        default: return []
        }
    }

    /// The song the item plays, when it is a song of the Studio.
    var song: Song? {
        guard case let .song(id)? = item?.content else { return nil }
        return studio?.songs.first { $0.id == id }
    }

    var songID: Song.ID? { song?.id }

    /// Edit is shown for items with an editor on the board (songs); it opens the Song editor.
    var showsEdit: Bool {
        if case .song? = item?.content { true } else { false }
    }
}
