import CryptoKit
import Foundation
import StageKit

/// SHA-256 of a file, read in fixed-size chunks: memory stays at about one chunk whatever the file size.
enum FileHasher {
    static let chunkSize = 1 << 20

    /// `onChunk` gets the size of each chunk read (tests use it to see the streaming).
    static func sha256(of url: URL, chunkSize: Int = chunkSize, onChunk: ((Int) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            onChunk?(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a relink scan found for each media index entry.
struct RelinkReport: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// At its last known path.
        case found(String)
        /// Somewhere else; the index now points there.
        case relinked(String)
        /// Not in any media folder. Its trims, triggers and end actions stay attached (they hang off the id).
        case missing
        /// More than one candidate; nothing changed.
        case ambiguous([String])
    }

    var statuses: [MediaItem.ID: Status] = [:]
    /// The index with found and relinked entries updated (path, size, hash).
    var index: [MediaIndexEntry] = []

    private func count(_ match: (Status) -> Bool) -> Int { statuses.values.filter(match).count }
    var found: Int { count { if case .found = $0 { true } else { false } } }
    var relinked: Int { count { if case .relinked = $0 { true } else { false } } }
    var missing: Int { count { $0 == .missing } }
    var ambiguous: Int { count { if case .ambiguous = $0 { true } else { false } } }
}

/// Finds the files of a media index in the machine's media folders: by SHA-256 first, then by file name + size.
/// Synchronous and cancellable (checks `Task.isCancelled`); run it with `RelinkScanner.run` off the main thread.
enum RelinkScanner {
    struct FileInfo {
        let path: String
        let size: Int64
        let modified: Date
        var name: String { (path as NSString).lastPathComponent }
    }

    static func listFiles(in folders: [URL]) throws -> [FileInfo] {
        var seen: Set<String> = []
        var result: [FileInfo] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if Task.isCancelled { throw CancellationError() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue } // two folders may overlap
                result.append(FileInfo(path: path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
        }
        return result
    }

    static func scan(index: [MediaIndexEntry], folders: [URL], cache: inout HashCache) throws -> RelinkReport {
        let files = try listFiles(in: folders)
        // Hash only files whose size some hashed entry has (all files if a hashed entry has no size).
        let hashedEntries = index.filter { $0.sha256 != nil }
        let wantedSizes = Set(hashedEntries.compactMap(\.size))
        let hashAll = hashedEntries.contains { $0.size == nil }
        var hashes: [String: String] = [:] // path -> sha
        func hash(_ file: FileInfo) throws -> String {
            if let h = hashes[file.path] { return h }
            let key = HashCache.key(path: file.path, size: file.size, modified: file.modified)
            let h = try cache.entries[key] ?? FileHasher.sha256(of: URL(fileURLWithPath: file.path))
            cache.entries[key] = h
            hashes[file.path] = h
            return h
        }
        if !hashedEntries.isEmpty {
            for file in files where hashAll || wantedSizes.contains(file.size) {
                if Task.isCancelled { throw CancellationError() }
                _ = try hash(file)
            }
        }

        var report = RelinkReport()
        for var entry in index {
            if Task.isCancelled { throw CancellationError() }
            var matches: [FileInfo] = []
            if let sha = entry.sha256 {
                matches = files.filter { hashes[$0.path] == sha }
            }
            if matches.isEmpty {
                matches = files.filter { $0.name == entry.fileName && (entry.size == nil || $0.size == entry.size) }
            }
            let status: RelinkReport.Status
            let chosen: FileInfo?
            if let last = matches.first(where: { $0.path == entry.lastKnownPath }) {
                status = .found(last.path)
                chosen = last
            } else if matches.count == 1 {
                status = .relinked(matches[0].path)
                chosen = matches[0]
            } else if matches.isEmpty {
                status = .missing
                chosen = nil
            } else {
                status = .ambiguous(matches.map(\.path).sorted())
                chosen = nil
            }
            if let chosen {
                entry.lastKnownPath = chosen.path
                entry.size = chosen.size
                if entry.sha256 == nil { entry.sha256 = hashes[chosen.path] ?? (try? hash(chosen)) }
            }
            report.statuses[entry.id] = status
            report.index.append(entry)
        }
        return report
    }

    /// Runs `scan` on a background thread with the machine's hash cache, and saves the cache afterwards.
    /// Cancelling the calling task cancels the scan.
    static func run(index: [MediaIndexEntry], folders: [URL], machine: MachinePaths) async throws -> RelinkReport {
        let task = Task.detached(priority: .utility) { () throws -> RelinkReport in
            var cache = HashCache.load(machine)
            let report = try scan(index: index, folders: folders, cache: &cache)
            try? cache.save(machine)
            return report
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
