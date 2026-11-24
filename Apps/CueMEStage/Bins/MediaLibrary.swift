import CoreGraphics
import Foundation
import Observation
import StageKit

/// The bins' file work, kept off the main thread: which index entries are missing, thumbnails, waveform peaks, file
/// formats, and adding files (hash + probe, in place). Results are cached by media id for as long as the app runs.
/// Nothing here writes to a media folder.
@MainActor
@Observable
final class MediaLibrary {
    /// Index entries whose file is not at its last known path (or that have none).
    private(set) var missing: Set<MediaItem.ID> = []
    private(set) var thumbnails: [MediaItem.ID: CGImage] = [:]
    private(set) var peaks: [MediaItem.ID: [Float]] = [:]
    private(set) var probes: [MediaItem.ID: MediaProbe] = [:]
    /// The add in progress (or the last one, until a new one starts).
    private(set) var job: AddJob?

    nonisolated static let bars = 40

    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var checkedSignature: [String] = []
    /// One waveform at a time, so many long files never read in parallel.
    @ObservationIgnored private let waveformQueue = SerialWork()

    // MARK: Missing files

    /// Checks, off the main thread, which entries have no file at their last known path. Cheap to call again: the
    /// same index is not checked twice in a row.
    func checkAvailability(_ index: [MediaIndexEntry]) {
        let signature = index.map { "\($0.id)|\($0.lastKnownPath ?? "")" }
        guard signature != checkedSignature else { return }
        checkedSignature = signature
        availabilityTask?.cancel()
        let list = index.map { ($0.id, $0.lastKnownPath) }
        availabilityTask = Task { [weak self] in
            let gone = await Task.detached(priority: .utility) { Self.missingIDs(list) }.value
            guard !Task.isCancelled else { return }
            self?.missing = gone
        }
    }

    nonisolated static func missingIDs(_ list: [(MediaItem.ID, String?)]) -> Set<MediaItem.ID> {
        Set(list.filter { _, path in
            guard let path, path.hasPrefix("/") else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }.map(\.0))
    }

    /// Missing here, or by the last relink scan.
    func isMissing(_ id: MediaItem.ID, relink: RelinkReport?) -> Bool {
        if case .missing? = relink?.statuses[id] { return true }
        return missing.contains(id)
    }

    // MARK: Thumbnails, waveforms, formats

    private func once(_ key: String) -> Bool { requested.insert(key).inserted }

    private func url(_ entry: MediaIndexEntry) -> URL? {
        guard let path = entry.lastKnownPath, path.hasPrefix("/"), !missing.contains(entry.id) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func requestThumbnail(_ entry: MediaIndexEntry) {
        guard entry.kind != .audio, let url = url(entry), once("t\(entry.id)\(url.path)") else { return }
        Task { [weak self] in
            if let image = await MediaThumbnails.make(url) { self?.thumbnails[entry.id] = image }
        }
    }

    func requestPeaks(_ entry: MediaIndexEntry) {
        guard entry.kind == .audio, let url = url(entry), once("w\(entry.id)\(url.path)") else { return }
        let queue = waveformQueue
        Task { [weak self] in
            let bars = await queue.run { try? WaveformPeaks.read(url, bars: Self.bars) }
            if let bars, !bars.isEmpty { self?.peaks[entry.id] = bars }
        }
    }

    func requestProbe(_ entry: MediaIndexEntry) {
        guard let url = url(entry), once("p\(entry.id)\(url.path)") else { return }
        let kind = entry.kind
        Task { [weak self] in
            let probe = await Task.detached(priority: .utility) { await MediaProbe.read(url, kind: kind) }.value
            self?.probes[entry.id] = probe
        }
    }

    // MARK: Adding files

    /// Starts adding `files` to the open Studio's index, one by one, in place. Each file is registered as soon as it is
    /// hashed, so closing the progress dialog ("Run in background") loses nothing.
    func startAdding(_ files: [AddFileRow], bin: StudioBinFolder.Bin, folder: StudioBinFolder.ID?, studios: StudioController) {
        let job = AddJob(rows: files, bin: bin, folder: folder, studioID: studios.studios.studio?.id)
        self.job = job
        let machine = studios.studios.environment.machine
        job.task = Task { [weak self, weak studios] in
            for index in job.rows.indices {
                guard !Task.isCancelled else { break }
                let row = job.rows[index]
                // Unsupported and already-known files stay as they are (the progress list shows them as Skipped / Already in library).
                guard row.status == .ready, let kind = row.kind else { continue }
                job.rows[index].status = .hashing(0)
                do {
                    let entry = try await MediaRegistrar.entry(for: row.url, kind: kind, machine: machine) { fraction in
                        Task { @MainActor in if case .hashing = job.rows[index].status { job.rows[index].status = .hashing(fraction) } }
                    }
                    guard let studios, studios.studios.studio?.id == job.studioID else {
                        job.rows[index].status = .failed("The Studio was closed")
                        break
                    }
                    let result = studios.registerMedia([entry], into: folder)
                    job.rows[index].status = result.added.isEmpty ? .alreadyInLibrary : .done
                    if let id = result.added.first { job.added.append(id) }
                } catch {
                    job.rows[index].status = Task.isCancelled ? .skipped : .failed(error.localizedDescription)
                }
            }
            job.isFinished = true
            if let index = studios?.studios.studio?.media { self?.checkAvailability(index) }
        }
    }
}

/// One file in the Add files dialog and its progress.
struct AddFileRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ready
        /// Not a kind this bin holds (or not media at all).
        case unsupported
        /// The same path is in the index already (a hash match is found while adding).
        case alreadyInLibrary
        case hashing(Double)
        case done
        case skipped
        case failed(String)
    }

    var url: URL
    var kind: MediaItem.Kind?
    var status: Status
    var probe: MediaProbe?
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    /// Ready when the bin holds its kind and its path is not in the index yet.
    static func make(_ url: URL, bin: StudioBinFolder.Bin, index: [MediaIndexEntry]) -> AddFileRow {
        let url = url.standardizedFileURL
        let kind = MediaFileKind.of(url)
        let status: Status
        if let kind, bin.holds(kind) {
            status = index.contains { $0.lastKnownPath == url.path } ? .alreadyInLibrary : .ready
        } else {
            status = .unsupported
        }
        return AddFileRow(url: url, kind: kind, status: status)
    }
}

/// An add in progress: its rows and whether it is over.
@MainActor
@Observable
final class AddJob {
    var rows: [AddFileRow]
    let bin: StudioBinFolder.Bin
    let folder: StudioBinFolder.ID?
    let studioID: UUID?
    var isFinished = false
    var added: [MediaItem.ID] = []
    @ObservationIgnored var task: Task<Void, Never>?

    init(rows: [AddFileRow], bin: StudioBinFolder.Bin, folder: StudioBinFolder.ID?, studioID: UUID?) {
        self.rows = rows
        self.bin = bin
        self.folder = folder
        self.studioID = studioID
    }
}

/// Runs async work one item at a time, off the main thread.
actor SerialWork {
    func run<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
}
