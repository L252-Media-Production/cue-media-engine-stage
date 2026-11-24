import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import StageKit
import UniformTypeIdentifiers

// Reading media files for the bins: kind, size, length and format, thumbnails and waveform peaks. Every function here
// only READS a file; nothing in the user's media folders is ever written, moved or deleted. Callers run them off the
// main thread (`MediaLibrary`).

enum MediaFileKind {
    /// The media kind of a file by its type (extension), or nil when it is not audio, video or a picture.
    static func of(_ url: URL) -> MediaItem.Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    /// The panel types for a bin's Add files.
    static func panelTypes(_ bin: StudioBinFolder.Bin) -> [UTType] { bin == .media ? [.movie, .image] : [.audio] }
}

/// What a file is, as far as it can be read cheaply. Every field is optional: nil is shown as a dash.
struct MediaProbe: Equatable, Sendable {
    var size: Int64?
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: Double?
    var sampleRate: Double?
    var channels: Int?

    /// The Add files row's meta (MediaDialog.dc.html): "1920x1080 · 29.97 fps · 0:45", "1920x1080" for a picture,
    /// "4:12 · 48 kHz stereo" for audio. Parts that are not known are left out; nothing known is a dash.
    func metaLine(kind: MediaItem.Kind?) -> String {
        var parts: [String] = []
        if let w = pixelWidth, let h = pixelHeight { parts.append("\(w)x\(h)") }
        if kind == .video, let fps = frameRate, fps > 0 { parts.append("\(Self.fps(fps)) fps") }
        if kind != .image, let d = duration { parts.append(ServiceListModel.duration(d)) }
        if kind == .audio, let format = audioFormat { parts.append(format) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// "48 kHz stereo", "44.1 kHz mono", "96 kHz 6 ch"; nil when not known.
    var audioFormat: String? {
        guard let rate = sampleRate, rate > 0 else { return nil }
        let khz = rate / 1000
        let rateText = khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
        guard let ch = channels else { return rateText }
        return "\(rateText) \(ch == 1 ? "mono" : ch == 2 ? "stereo" : "\(ch) ch")"
    }

    /// "29.97", "60", "25".
    static func fps(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.rounded() == rounded ? "\(Int(rounded))" : String(format: "%.2f", rounded)
    }

    /// "412 MB", "3.4 GB", "2.1 MB" (decimal units, as the Finder).
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Reads size, length and format. Pictures through ImageIO, audio through AVAudioFile, video through AVAsset.
    static func read(_ url: URL, kind: MediaItem.Kind?) async -> MediaProbe {
        var probe = MediaProbe()
        probe.size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        switch kind {
        case .image?:
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                probe.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                probe.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
            }
        case .audio?:
            if let file = try? AVAudioFile(forReading: url) {
                let format = file.fileFormat
                probe.sampleRate = format.sampleRate
                probe.channels = Int(format.channelCount)
                if format.sampleRate > 0 { probe.duration = Double(file.length) / format.sampleRate }
            }
        case .video?:
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isNumeric { probe.duration = d.seconds }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, transform, fps) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate) {
                let shown = size.applying(transform)
                probe.pixelWidth = Int(abs(shown.width).rounded())
                probe.pixelHeight = Int(abs(shown.height).rounded())
                probe.frameRate = Double(fps)
            }
        case nil:
            break
        }
        return probe
    }
}

/// Thumbnails from Quick Look (it decodes off the main thread and caches on its own).
enum MediaThumbnails {
    static func make(_ url: URL, size: CGSize = CGSize(width: 320, height: 180), scale: CGFloat = 2) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}

/// Waveform bars: the peak level of each of `bars` equal parts of the file, 0...1. Real data, read cheaply: a long file
/// is sampled (a window of `window` frames read at evenly spaced points in each part) so the read stays bounded
/// (`maxFrames`); a short file is read whole.
enum WaveformPeaks {
    static let window: AVAudioFrameCount = 4096
    static let maxFrames: AVAudioFramePosition = 2_000_000

    static func read(_ url: URL, bars: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let length = file.length
        guard bars > 0, length > 0 else { return [] }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return [] }
        let perBar = Double(length) / Double(bars)
        let windowsPerBar = max(1, min(Int((perBar / Double(window)).rounded(.up)), Int(maxFrames) / (bars * Int(window))))
        var peaks = [Float](repeating: 0, count: bars)
        for bar in 0..<bars {
            if Task.isCancelled { throw CancellationError() }
            let start = Double(bar) * perBar
            for w in 0..<windowsPerBar {
                let position = AVAudioFramePosition(start + perBar * Double(w) / Double(windowsPerBar))
                guard position < length else { break }
                file.framePosition = position
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(window), length - position)))
                guard let channels = buffer.floatChannelData else { continue }
                for c in 0..<Int(format.channelCount) {
                    let samples = channels[c]
                    for i in 0..<Int(buffer.frameLength) { peaks[bar] = max(peaks[bar], abs(samples[i])) }
                }
            }
        }
        return peaks.map { min(1, $0) }
    }
}

/// Lists the files of a folder (and its subfolders when asked), skipping hidden files and packages. Reads only.
enum MediaFolderListing {
    struct File: Equatable, Sendable {
        var url: URL
        var kind: MediaItem.Kind
        var size: Int64
    }

    static func files(in folder: URL, includeSubfolders: Bool, kinds: Set<MediaItem.Kind>) throws -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var urls: [URL] = []
        if includeSubfolders {
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL {
                if Task.isCancelled { throw CancellationError() }
                urls.append(url)
            }
        } else {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let kind = MediaFileKind.of(url), kinds.contains(kind) else { return nil }
            return File(url: url.standardizedFileURL, kind: kind, size: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// "12 videos · 4 photos · 5.8 GB" (MediaDialog.dc.html, Link a folder).
    static func summary(_ files: [File]) -> String {
        let videos = files.filter { $0.kind == .video }.count
        let photos = files.filter { $0.kind == .image }.count
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        return [n(videos, "video", "videos"), n(photos, "photo", "photos"), MediaProbe.size(files.reduce(0) { $0 + $1.size })]
            .joined(separator: " · ")
    }
}

/// One file registered in place: hashed (with the machine's hash cache) and probed, never copied or changed.
enum MediaRegistrar {
    /// The index entry for `url`. `progress` gets 0...1 while it hashes. Reads the file only.
    static func entry(for url: URL, kind: MediaItem.Kind, machine: MachinePaths, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaIndexEntry {
        let path = url.standardizedFileURL.path
        let hashed = try await Task.detached(priority: .utility) { () throws -> (String, Int64) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values.fileSize ?? 0)
            var cache = HashCache.load(machine)
            let key = HashCache.key(path: path, size: size, modified: values.contentModificationDate ?? .distantPast)
            if let known = cache.entries[key] { return (known, size) }
            var read: Int64 = 0
            var reported = -1
            let sha = try FileHasher.sha256(of: url) { chunk in
                read += Int64(chunk)
                let percent = size > 0 ? Int(read * 100 / size) : 100
                if percent != reported { reported = percent; progress(Double(percent) / 100) }
            }
            cache = HashCache.load(machine) // another scan may have saved meanwhile
            cache.entries[key] = sha
            try? cache.save(machine)
            return (sha, size)
        }.value
        let probe = await MediaProbe.read(url, kind: kind)
        return MediaIndexEntry(id: UUID(), name: url.lastPathComponent, kind: kind, duration: kind == .image ? nil : probe.duration,
                               size: hashed.1, sha256: hashed.0, lastKnownPath: path)
    }
}
