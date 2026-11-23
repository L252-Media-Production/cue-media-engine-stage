import Darwin
import Foundation

/// Writes a file so that it is either the old version or the new one, never half of either: the bytes go to a temp
/// file in the same folder, are flushed to the disk (F_FULLFSYNC), then rename(2) replaces the target in one step.
/// On any failure the temp file is removed and the target is untouched.
enum AtomicFile {
    /// Points a test can fail at.
    enum Step { case halfWritten, flushed }
    /// Tests only: called at each step; a throw simulates a crash or a full disk there.
    static var testHook: ((Step, URL) throws -> Void)?

    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            let half = data.count / 2
            try handle.write(contentsOf: data.prefix(half))
            try testHook?(.halfWritten, temp)
            try handle.write(contentsOf: data.dropFirst(half))
            // F_FULLFSYNC reaches the platters / flash; fall back to fsync where it is not supported.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0, fsync(handle.fileDescriptor) != 0 { throw posixError() }
            try testHook?(.flushed, temp)
            guard rename(temp.path, url.path) == 0 else { throw posixError() }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
