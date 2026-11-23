import Foundation

// Song lyrics as the Song editor edits them: groups, the lyrics as text, lines per slide and capitalization. Pure
// functions over `Song`, so the editor and the tests share them.

extension Song {
    /// The song as the outputs show it: `capitalization` applied to every line. The stored text is never changed.
    public var capitalizationApplied: Song {
        guard let mode = capitalization, mode != .none else { return self }
        var copy = self
        for i in copy.slides.indices {
            copy.slides[i].lines = copy.slides[i].lines.map { SongLyrics.capitalize($0, mode) }
        }
        return copy
    }
}

public enum SongLyrics {
    /// Group colours, in the order new groups take them (SongEditor.dc.html `G`, then more of the same weight).
    public static let palette = ["#9A8A1F", "#1F5F9E", "#2F8F4A", "#A05A1F", "#7A3FA0", "#A03F5F", "#2F8A8A", "#5F6B7A"]

    // MARK: Groups

    /// The song's groups. A song never edited in the Song editor has none stored; its groups are then derived from the
    /// slide labels: one group per distinct label (in order of first use), holding every slide with that label.
    /// Slides with an empty label are in no group. A derived group's id is its first slide's id, so it is stable.
    public static func groups(of song: Song) -> [SongGroup] {
        if let groups = song.groups { return groups }
        var groups: [SongGroup] = []
        for slide in song.slides {
            let name = slide.label.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let i = groups.firstIndex(where: { $0.name == name }) {
                groups[i].slideIDs.append(slide.id)
            } else {
                groups.append(SongGroup(id: slide.id, name: name, color: palette[groups.count % palette.count], slideIDs: [slide.id]))
            }
        }
        return groups
    }

    /// The group a slide is in, if any.
    public static func group(of slide: Slide.ID, in song: Song) -> SongGroup? {
        groups(of: song).first { $0.slideIDs.contains(slide) }
    }

    /// The song with its groups stored (derived ones made real). Done before any edit of groups or lyrics.
    public static func materialized(_ song: Song) -> Song {
        var copy = song
        copy.groups = groups(of: song)
        return copy
    }

    /// The first palette colour no group in `used` has; the palette again from the start when all are taken.
    public static func nextColor(notIn used: [String]) -> String {
        let taken = Set(used.map { $0.uppercased() })
        return palette.first { !taken.contains($0) } ?? palette[used.count % palette.count]
    }

    // MARK: Lyrics as text

    /// The Text edit tab's text: a `[Group]` heading where the group changes, the slide's lines, and a blank line
    /// between slides. Empty slides have no text.
    public static func text(of song: Song) -> String {
        var out: [String] = []
        var previous: SongGroup.ID??
        for slide in song.slides {
            let group = group(of: slide.id, in: song)
            if previous == nil || previous! != group?.id {
                if let group {
                    if !out.isEmpty { out.append("") }
                    out.append("[\(group.name)]")
                } else if !out.isEmpty {
                    out.append("")
                }
            } else {
                out.append("")
            }
            out.append(contentsOf: slide.lines)
            previous = .some(group?.id)
        }
        return out.joined(separator: "\n")
    }

    /// A `[Name]` line's name, or nil.
    static func heading(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 else { return nil }
        let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    struct Chunk: Equatable {
        var group: String?
        var lines: [String]
    }

    /// Text to chunks: a heading starts a group, a blank line ends a slide. Lines are trimmed.
    static func chunks(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var group: String?
        var buffer: [String] = []
        func flush() {
            if !buffer.isEmpty { chunks.append(Chunk(group: group, lines: buffer)) }
            buffer = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let name = heading(line) {
                flush()
                group = name
            } else if line.isEmpty {
                flush()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return chunks
    }

    /// Splits each chunk into slides of at most `n` lines.
    static func split(_ chunks: [Chunk], linesPerSlide n: Int?) -> [Chunk] {
        guard let n, n > 0 else { return chunks }
        return chunks.flatMap { chunk -> [Chunk] in
            guard chunk.lines.count > n else { return [chunk] }
            return stride(from: 0, to: chunk.lines.count, by: n).map {
                Chunk(group: chunk.group, lines: Array(chunk.lines[$0..<min($0 + n, chunk.lines.count)]))
            }
        }
    }

    /// The song with its slides and groups rebuilt from the Text edit tab. Paragraphs longer than `linesPerSlide`
    /// (when set) are split. Slide ids are kept by position, so unchanged slides keep their identity; a group keeps its
    /// id and colour when its heading names it again (any case), and a new heading gets the next free colour. A slide
    /// keeps a label of its own while it stays in a group of the same name; otherwise its label is its group's name.
    public static func applying(text: String, to song: Song) -> Song {
        build(split(chunks(text), linesPerSlide: song.linesPerSlide), from: song)
    }

    /// Lines per slide set in the Text tab: stored, and the song's slides re-split now. Each run of slides in one
    /// group is joined and cut into slides of `n` lines (nil: only stored, slides unchanged).
    public static func settingLinesPerSlide(_ n: Int?, of song: Song) -> Song {
        var song = song
        song.linesPerSlide = n.map { max(1, $0) }
        guard let n = song.linesPerSlide else { return song }
        var runs: [Chunk] = []
        var previous: SongGroup.ID??
        for slide in song.slides {
            let group = group(of: slide.id, in: song)
            if let p = previous, p == group?.id, !runs.isEmpty {
                runs[runs.count - 1].lines += slide.lines
            } else {
                runs.append(Chunk(group: group?.name, lines: slide.lines))
            }
            previous = .some(group?.id)
        }
        return build(split(runs.filter { !$0.lines.isEmpty }, linesPerSlide: n), from: song)
    }

    static func build(_ chunks: [Chunk], from song: Song) -> Song {
        let old = materialized(song)
        let oldGroups = old.groups ?? []
        var groups: [SongGroup] = []
        var slides: [Slide] = []
        for (i, chunk) in chunks.enumerated() {
            let previous = old.slides.indices.contains(i) ? old.slides[i] : nil
            let id = previous?.id ?? UUID()
            var label = ""
            if let name = chunk.group {
                let index: Int
                if let found = groups.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    index = found
                } else {
                    let existing = oldGroups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    let color = existing?.color ?? nextColor(notIn: groups.map(\.color) + oldGroups.map(\.color))
                    groups.append(SongGroup(id: existing?.id ?? UUID(), name: name, color: color))
                    index = groups.count - 1
                }
                groups[index].slideIDs.append(id)
                label = groups[index].name
                if let previous, let was = oldGroups.first(where: { $0.slideIDs.contains(previous.id) }),
                   was.name.caseInsensitiveCompare(name) == .orderedSame, !previous.label.isEmpty,
                   previous.label.caseInsensitiveCompare(was.name) != .orderedSame {
                    label = previous.label
                }
            }
            slides.append(Slide(id: id, label: label, lines: chunk.lines))
        }
        var result = song
        result.slides = slides
        result.groups = groups
        return result
    }

    // MARK: Capitalization

    public static func capitalize(_ line: String, _ mode: SongCapitalization) -> String {
        switch mode {
        case .none: return line
        case .allCaps: return line.uppercased()
        case .sentenceCase:
            let lower = line.lowercased()
            guard let first = lower.firstIndex(where: \.isLetter) else { return lower }
            return lower.replacingCharacters(in: first...first, with: lower[first...first].uppercased())
        }
    }
}
