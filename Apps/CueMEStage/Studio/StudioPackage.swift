import Foundation
import StageKit

/// Where Studios live by default: ~/Documents/CueME Stage/.
enum StudioLocations {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CueME Stage", isDirectory: true)
    }

    /// `<folder>/<name>.stg`, or "<name> 2.stg", "<name> 3.stg" ... when that exists. Never an existing path.
    static func unusedPackageURL(named name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent("\(name).\(StudioFormat.packageExtension)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n).\(StudioFormat.packageExtension)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}

/// A `<Name>.stg` folder on disk: reads its files into `StudioCodec.Files` and writes changed files back atomically.
struct StudioPackage {
    let url: URL

    var lockURL: URL { url.appendingPathComponent(StudioCodec.lockPath) }

    /// Every .json in the package except lock.json and cache/ (migrations may need files the current codec does not
    /// know, so this is wider than `StudioCodec.isShowDataPath`).
    func readFiles() throws -> StudioCodec.Files {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw StudioError.notAStudio("\(url.lastPathComponent) is not a folder")
        }
        var files: StudioCodec.Files = [:]
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let file as URL in walker {
            let full = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(root + "/") else { continue }
            let path = String(full.dropFirst(root.count + 1))
            if path == StudioCodec.lockPath || path.hasPrefix(StudioCodec.cacheFolder + "/") { continue }
            guard path.hasSuffix(".json"), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files[path] = try Data(contentsOf: file)
        }
        return files
    }

    func read() throws -> (studio: Studio, files: StudioCodec.Files) {
        let files = try readFiles()
        return (try StudioCodec.decode(files), files)
    }

    /// Writes the files whose bytes differ from `previous` and removes the show-data files that are no longer there.
    /// The manifest goes last. Returns the paths written or removed.
    @discardableResult
    func write(_ files: StudioCodec.Files, previous: StudioCodec.Files) throws -> [String] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let changed = files.keys.filter { files[$0] != previous[$0] }
            .sorted { ($0 == StudioCodec.manifestPath ? 1 : 0, $0) < ($1 == StudioCodec.manifestPath ? 1 : 0, $1) }
        for path in changed {
            try AtomicFile.write(files[path]!, to: url.appendingPathComponent(path))
        }
        let removed = previous.keys.filter { files[$0] == nil && StudioCodec.isShowDataPath($0) }.sorted()
        for path in removed {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(path))
        }
        return changed + removed
    }

    /// A new package with `studio` in it. Fails if anything is at `url` already.
    static func create(_ studio: Studio, at url: URL) throws -> StudioPackage {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        let package = StudioPackage(url: url)
        try package.write(try StudioCodec.encode(studio), previous: [:])
        return package
    }

    /// "Open a Copy": the show data (no lock, no cache) in a new package next to this one, with a new id and
    /// "<name> copy" as its name.
    func makeCopy(now: Date, appVersion: String) throws -> URL {
        var studio = try read().studio
        studio.manifest.id = UUID()
        studio.manifest.name = "\(studio.name) copy"
        studio.manifest.created = now
        studio.manifest.modified = now
        studio.manifest.appVersion = appVersion
        let target = StudioLocations.unusedPackageURL(named: studio.name, in: url.deletingLastPathComponent())
        _ = try StudioPackage.create(studio, at: target)
        return target
    }
}
