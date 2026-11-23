import Foundation
import StageKit

/// Runs a system tool (only /usr/bin tools; no third-party code) and collects its output.
enum Tool {
    struct Result { var status: Int32; var output: Data; var error: String }

    static func run(_ path: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting so a large listing cannot fill the pipe and stall the tool.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: output, error: String(decoding: error, as: UTF8.self))
    }
}

enum StudioBundleError: Error, Equatable, LocalizedError {
    case tooLarge(bytes: Int64, limit: Int64)
    case notAZip(String)
    case unsafeEntry(String)
    case noStudioInside
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes, limit):
            "This Studio bundle is too large (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)))."
        case let .notAZip(reason): "This file is not a readable Studio bundle (\(reason))."
        case let .unsafeEntry(name): "This Studio bundle was refused: the entry “\(name)” would be written outside the Studio."
        case .noStudioInside: "This bundle does not contain exactly one Studio (.stg) folder."
        case let .toolFailed(reason): "The bundle could not be processed: \(reason)"
        }
    }
}

/// .stgbundle: a Studio as ONE file, for sending and archiving. A zip (made with /usr/bin/ditto) of the package
/// folder, without media, cache/ or lock.json.
enum StudioBundle {
    /// A Studio holds no media, so even a large library is far below this.
    static let maxBundleBytes: Int64 = 256 * 1024 * 1024
    /// Guards against a zip bomb: the total size once unzipped.
    static let maxUnzippedBytes: Int64 = 1024 * 1024 * 1024

    struct Limits { var bundle = maxBundleBytes; var unzipped = maxUnzippedBytes }

    static func export(_ package: StudioPackage, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("cueme-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(package.url.lastPathComponent, isDirectory: true)
        // Show data only: readFiles leaves out lock.json and cache/, and media is never in a Studio.
        let files = try package.readFiles()
        try StudioPackage(url: folder).write(files, previous: [:])
        let zip = staging.appendingPathComponent("out.zip")
        let result = try Tool.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path])
        guard result.status == 0 else { throw StudioBundleError.toolFailed("ditto: \(result.error)") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: zip)
        } else {
            try FileManager.default.moveItem(at: zip, to: destination)
        }
    }

    /// Checks a bundle without unpacking it: size, entry names (no absolute paths, no "..", one top-level .stg
    /// folder), unzipped size, and the manifest's format and version. Returns the name of the top-level folder.
    static func inspect(_ bundle: URL, limits: Limits = Limits()) throws -> String {
        let size = Int64((try? bundle.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= limits.bundle else { throw StudioBundleError.tooLarge(bytes: size, limit: limits.bundle) }

        let list = try Tool.run("/usr/bin/zipinfo", ["-1", bundle.path])
        guard list.status == 0 else { throw StudioBundleError.notAZip("the zip directory could not be read") }
        let entries = String(decoding: list.output, as: UTF8.self).split(separator: "\n").map(String.init)
        guard !entries.isEmpty else { throw StudioBundleError.notAZip("empty") }
        var tops: Set<String> = []
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            if entry.hasPrefix("/") || entry.hasPrefix("~") || entry.contains("\\") || parts.contains("..") {
                throw StudioBundleError.unsafeEntry(entry)
            }
            tops.insert(String(parts[0]))
        }
        guard tops.count == 1, let top = tops.first, top.hasSuffix(".\(StudioFormat.packageExtension)") else {
            throw StudioBundleError.noStudioInside
        }

        let totals = try Tool.run("/usr/bin/zipinfo", ["-t", bundle.path])
        let words = String(decoding: totals.output, as: UTF8.self).split(separator: " ")
        guard totals.status == 0, let i = words.firstIndex(where: { $0.hasPrefix("bytes") }), i > 0, let unzipped = Int64(words[i - 1]) else {
            throw StudioBundleError.notAZip("the zip totals could not be read")
        }
        guard unzipped <= limits.unzipped else { throw StudioBundleError.tooLarge(bytes: unzipped, limit: limits.unzipped) }

        let manifest = try Tool.run("/usr/bin/unzip", ["-p", bundle.path, "\(top)/\(StudioCodec.manifestPath)"])
        try StudioCodec.checkManifest(manifest.status == 0 ? manifest.output : nil)
        return top
    }

    /// Inspects, then unpacks into a new temp folder and reads the Studio from there. Nothing outside the temp folder
    /// is touched. The caller moves or copies the result into place.
    static func extract(_ bundle: URL, limits: Limits = Limits()) throws -> (package: StudioPackage, studio: Studio, tempFolder: URL) {
        let top = try inspect(bundle, limits: limits)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cueme-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let result = try Tool.run("/usr/bin/ditto", ["-x", "-k", bundle.path, folder.path])
            guard result.status == 0 else { throw StudioBundleError.notAZip("ditto could not unpack it: \(result.error)") }
            // No symbolic links: one could point outside the Studio.
            if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw StudioBundleError.unsafeEntry(url.lastPathComponent)
                }
            }
            let package = StudioPackage(url: folder.appendingPathComponent(top, isDirectory: true))
            return (package, try package.read().studio, folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Import Studio > Open as a new Studio: a new package in `folder`. A name in use gets " 2", " 3" ... (never an
    /// overwrite), and an id in use (the open Studio's, say) gets a new id. Returns the new package's URL.
    static func importAsNew(_ bundle: URL, into folder: URL, idsInUse: Set<UUID>, now: Date, limits: Limits = Limits()) throws -> URL {
        let (_, imported, temp) = try extract(bundle, limits: limits)
        defer { try? FileManager.default.removeItem(at: temp) }
        var studio = imported
        let target = StudioLocations.unusedPackageURL(named: studio.name, in: folder)
        studio.manifest.name = target.deletingPathExtension().lastPathComponent
        if idsInUse.contains(studio.id) { studio.manifest.id = UUID() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try StudioPackage.create(studio, at: target)
        return target
    }
}

extension StudioStore {
    /// Import Studio > Replace the current one: the bundle's show data replaces the open Studio's. The open Studio
    /// keeps its id, name, place and creation date (so this machine's output assignments still apply).
    func replaceContents(withBundle bundle: URL, limits: StudioBundle.Limits = StudioBundle.Limits()) throws {
        let (_, imported, temp) = try StudioBundle.extract(bundle, limits: limits)
        defer { try? FileManager.default.removeItem(at: temp) }
        update { studio in
            var replacement = imported
            replacement.manifest = studio.manifest
            if let active = imported.manifest.activeServiceID { replacement.manifest.activeServiceID = active }
            studio = replacement
        }
        saveNow()
    }
}
