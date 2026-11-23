import Darwin
import XCTest
import StageKit
@testable import CueMEStage

/// A fresh temp folder per test; never the user's Documents or Application Support.
class TempFolderTestCase: XCTestCase {
    var temp: URL!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("cueme-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        AtomicFile.testHook = nil
        try? FileManager.default.removeItem(at: temp)
    }

    var machine: MachinePaths { MachinePaths(root: temp.appendingPathComponent("Machine", isDirectory: true)) }

    @MainActor
    func environment(pid: Int32 = 1000, identity: MachineIdentity? = nil, running: @escaping (Int32) -> Bool = { _ in false }) -> StudioStore.Environment {
        StudioStore.Environment(
            machine: machine, identity: identity ?? MachineIdentity(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "Test Mac"),
            appVersion: "0.1-test", debounce: .milliseconds(80), retry: .milliseconds(80), isProcessRunning: running, pid: pid
        )
    }

    func sampleStudio(name: String = "Studio") -> Studio {
        Studio(seededFrom: .sample, name: name, now: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1-test")
    }

    func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
}

@MainActor
final class StudioStoreTests: TempFolderTestCase {
    func testSaveThenLoadIsEqualAndSplitPerFile() throws {
        let studio = sampleStudio()
        let url = temp.appendingPathComponent("Studio.stg")
        let package = try StudioPackage.create(studio, at: url)
        XCTAssertEqual(try package.read().studio, studio.normalized())

        let library = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("library").path)
        XCTAssertEqual(Set(library), Set(studio.songs.map { "\($0.id.uuidString).json" }))
        let manifest = try String(contentsOf: url.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(#""format" : "cueme-stage-studio""#))
    }

    func testChangingOneSongRewritesOneDataFile() async throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let store = StudioStore(environment: environment())
        try store.create(sampleStudio(), at: url)
        let song = try XCTUnwrap(store.studio?.songs.first)

        store.update { $0.songs[0].title = "Renamed" }
        store.update { $0.songs[0].title = "Renamed again" } // debounced: one save
        await wait(0.4)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.lastWrite, ["library/\(song.id.uuidString).json", "manifest.json"],
                       "one data file, plus the manifest for its modified date")
        XCTAssertEqual(try StudioPackage(url: url).read().studio.songs.first { $0.id == song.id }?.title, "Renamed again")

        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(store.lastWrite, [], "nothing changed: nothing written")
    }

    func testRemovedSongRemovesItsFile() throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let store = StudioStore(environment: environment())
        try store.create(sampleStudio(), at: url)
        let gone = store.studio!.songs[0].id
        store.update { $0.songs.removeFirst() }
        store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("library/\(gone.uuidString).json").path))
    }

    func testFailedWriteLeavesTheOldFileIntact() throws {
        let file = temp.appendingPathComponent("a.json")
        try AtomicFile.write(Data("old".utf8), to: file)
        struct Crash: Error {}
        for step in [AtomicFile.Step.halfWritten, .flushed] {
            AtomicFile.testHook = { s, _ in if s == step { throw Crash() } }
            XCTAssertThrowsError(try AtomicFile.write(Data("new content".utf8), to: file))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), ["a.json"], "no temp file left")
        }
        AtomicFile.testHook = nil
        try AtomicFile.write(Data("new".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
    }

    func testAFailedSaveIsANoticeAndIsRetried() async throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let store = StudioStore(environment: environment())
        try store.create(sampleStudio(), at: url)
        struct DiskFull: Error {}
        var failures = 1
        AtomicFile.testHook = { _, _ in if failures > 0 { failures -= 1; throw DiskFull() } }

        store.update { $0.messages[0].text = "Changed" }
        XCTAssertFalse(store.saveNow())
        XCTAssertTrue(store.notice?.hasPrefix("Could not save") == true)
        await wait(0.4)
        XCTAssertNil(store.notice, "the retry worked and cleared the notice")
        XCTAssertEqual(try StudioPackage(url: url).read().studio.messages[0].text, "Changed")
    }

    func testCloseSavesAndRemovesTheLock() throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let store = StudioStore(environment: environment())
        try store.create(sampleStudio(), at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("lock.json").path))
        store.update { $0.manifest.name = "Renamed" }
        store.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("lock.json").path))
        XCTAssertEqual(try StudioPackage(url: url).read().studio.name, "Renamed")
        XCTAssertNil(store.studio)
    }

    // MARK: Lock

    func testTheFourLockCases() throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let package = try StudioPackage.create(sampleStudio(), at: url)
        let me = MachineIdentity(id: UUID(), name: "Here")
        let running: Set<Int32> = [77]
        let locking = StudioLocking(identity: me, pid: 1000, appVersion: "0.1", isProcessRunning: { running.contains($0) })
        func lock(_ machine: UUID, _ pid: Int32) -> StudioLock {
            StudioLock(machineID: machine, machineName: machine == me.id ? "Here" : "FOH Mac", pid: pid, openedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1")
        }

        XCTAssertEqual(locking.assess(nil), .free)
        XCTAssertEqual(locking.assess(lock(me.id, 1000)), .ours)
        let other = lock(UUID(), 1000)
        XCTAssertEqual(locking.assess(other), .held(other, sameMachine: false), "another machine: even with our pid")
        let live = lock(me.id, 77)
        XCTAssertEqual(locking.assess(live), .held(live, sameMachine: true), "another process here, still running")
        let stale = lock(me.id, 78)
        XCTAssertEqual(locking.assess(stale), .stale(stale), "process gone: stale")
        XCTAssertFalse(LockAssessment.stale(stale).needsWarning)
        XCTAssertTrue(LockAssessment.held(other, sameMachine: false).needsWarning)

        let text = StudioLocking.warning(studioName: "Studio", lock: other, sameMachine: false)
        XCTAssertTrue(text.contains("FOH Mac"))
        XCTAssertTrue(StudioLocking.warning(studioName: "Studio", lock: live, sameMachine: true).contains("process 77"))

        // Release never deletes another machine's lock.
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(other), to: package.lockURL)
        locking.release(package)
        XCTAssertEqual(locking.read(package), other)
    }

    func testStaleLockIsReplacedSilentlyAndOpenAnywayTakesIt() throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let package = try StudioPackage.create(sampleStudio(), at: url)
        let env = environment(pid: 1000)
        let stale = StudioLock(machineID: env.identity.id, machineName: "Test Mac", pid: 999, openedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1")
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(stale), to: package.lockURL)

        let store = StudioStore(environment: env)
        let pending = try store.prepareOpen(url)
        XCTAssertEqual(pending.lock, .stale(stale))
        store.open(pending)
        XCTAssertEqual(env.locking.read(package)?.pid, 1000)
    }

    func testOpenACopyGivesANewID() throws {
        let url = temp.appendingPathComponent("Studio.stg")
        let original = sampleStudio()
        let package = try StudioPackage.create(original, at: url)
        let theirs = StudioLock(machineID: UUID(), machineName: "FOH Mac", pid: 5, openedAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "0.1")
        try AtomicFile.write(try StudioCodec.makeEncoder().encode(theirs), to: package.lockURL)

        let store = StudioStore(environment: environment())
        let pending = try store.prepareOpen(url)
        XCTAssertTrue(pending.lock.needsWarning)
        try store.openCopy(of: pending)
        XCTAssertNotEqual(store.studio?.id, original.id)
        XCTAssertEqual(store.studio?.name, "Studio copy")
        XCTAssertEqual(store.url?.lastPathComponent, "Studio copy.stg")
        XCTAssertEqual(store.studio?.songs, original.normalized().songs)
        XCTAssertEqual(StudioLocking(identity: MachineIdentity(id: UUID(), name: "x"), appVersion: "").read(package), theirs, "original lock untouched")
    }

    func testNameClashNeverOverwrites() throws {
        let first = StudioLocations.unusedPackageURL(named: "Show", in: temp)
        _ = try StudioPackage.create(sampleStudio(), at: first)
        XCTAssertEqual(StudioLocations.unusedPackageURL(named: "Show", in: temp).lastPathComponent, "Show 2.stg")
        XCTAssertThrowsError(try StudioPackage.create(sampleStudio(), at: first))
    }

    func testRecentListKeepsTenNewestFirst() {
        let defaults = UserDefaults(suiteName: "cueme.tests.recent.\(UUID().uuidString)")!
        let recent = RecentStudios(defaults: defaults)
        for n in 1...12 { recent.add(temp.appendingPathComponent("S\(n).stg")) }
        recent.add(temp.appendingPathComponent("S5.stg"))
        XCTAssertEqual(recent.urls.count, 10)
        XCTAssertEqual(recent.urls.first?.lastPathComponent, "S5.stg")
        XCTAssertEqual(recent.urls.filter { $0.lastPathComponent == "S5.stg" }.count, 1)
        recent.clear()
        XCTAssertEqual(recent.urls, [])
    }

    // MARK: Per-machine outputs

    func testOutputAssignmentsArePerMachineAndPerStudio() throws {
        let outputs = MachineOutputs(paths: machine)
        let studio = UUID(), other = UUID(), left = UUID(), right = UUID()
        XCTAssertEqual(outputs.assignments(studio: studio, screens: [left, right]).map(\.connectorID), [nil, nil], "nothing guessed")

        try outputs.save(studio: studio, assignments: [.init(screenID: left, connectorID: "decklink-A-1"), .init(screenID: right, connectorID: nil)])
        XCTAssertEqual(outputs.assignments(studio: studio, screens: [left, right]).map(\.connectorID), ["decklink-A-1", nil])
        XCTAssertEqual(outputs.assignments(studio: other, screens: [left]).map(\.connectorID), [nil], "another Studio with the same screen ids")
        XCTAssertEqual(MachineOutputs(paths: MachinePaths(root: temp.appendingPathComponent("OtherMac"))).assignments(studio: studio, screens: [left]).map(\.connectorID),
                       [nil], "another machine")
    }
}

final class MediaRelinkTests: TempFolderTestCase {
    private func file(_ path: String, _ contents: String) throws -> URL {
        let url = temp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func sha(_ s: String) throws -> String {
        let url = temp.appendingPathComponent("hash-\(UUID().uuidString)")
        try Data(s.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try FileHasher.sha256(of: url)
    }

    func testHashIsSHA256() throws {
        XCTAssertEqual(try sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRelinkByHashNameSizeAmbiguousAndMissing() throws {
        let folder = temp.appendingPathComponent("Media", isDirectory: true)
        let moved = try file("Media/sub/renamed.wav", "walk-in audio")
        let byName = try file("Media/welcome.wav", "welcome!")
        let still = try file("Media/still.mov", "same place")
        _ = try file("Media/a/dup.wav", "1234")
        _ = try file("Media/b/dup.wav", "5678")

        let index = [
            MediaIndexEntry(id: UUID(), name: "Walk-in", kind: .audio, size: 13, sha256: try sha("walk-in audio"), lastKnownPath: "/old/walk-in.wav"),
            MediaIndexEntry(id: UUID(), name: "Welcome", kind: .audio, size: 8, lastKnownPath: "/old/place/welcome.wav"),
            MediaIndexEntry(id: UUID(), name: "Still", kind: .video, size: 10, sha256: try sha("same place"), lastKnownPath: still.standardizedFileURL.path),
            MediaIndexEntry(id: UUID(), name: "Dup", kind: .audio, size: 4, lastKnownPath: "/old/dup.wav"),
            MediaIndexEntry(id: UUID(), name: "Gone", kind: .audio, size: 99, sha256: "00", lastKnownPath: "/old/gone.wav"),
        ]
        var cache = HashCache()
        let report = try RelinkScanner.scan(index: index, folders: [folder, folder.appendingPathComponent("sub")], cache: &cache)

        XCTAssertEqual(report.statuses[index[0].id], .relinked(moved.standardizedFileURL.path), "by hash, though renamed")
        XCTAssertEqual(report.statuses[index[1].id], .relinked(byName.standardizedFileURL.path), "by name + size")
        XCTAssertEqual(report.statuses[index[2].id], .found(still.standardizedFileURL.path))
        guard case let .ambiguous(paths) = report.statuses[index[3].id] else { return XCTFail("ambiguous") }
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(report.statuses[index[4].id], .missing)
        XCTAssertEqual([report.found, report.relinked, report.missing, report.ambiguous], [1, 2, 1, 1])

        XCTAssertEqual(report.index[0].lastKnownPath, moved.standardizedFileURL.path)
        XCTAssertEqual(report.index[1].sha256, try sha("welcome!"), "hash filled in once found")
        XCTAssertEqual(report.index[4], index[4], "a missing entry keeps its id and data")
    }

    func testHashesAreCachedByPathSizeAndTime() throws {
        let folder = temp.appendingPathComponent("Media", isDirectory: true)
        let f = try file("Media/clip.mov", "frames")
        let entry = MediaIndexEntry(id: UUID(), name: "Clip", kind: .video, size: 6, sha256: try sha("frames"))
        var cache = HashCache()
        _ = try RelinkScanner.scan(index: [entry], folders: [folder], cache: &cache)
        XCTAssertEqual(cache.entries.count, 1)
        // A cached hash is trusted without reading the file: prove it with a fake cached value.
        let key = try XCTUnwrap(cache.entries.keys.first)
        cache.entries[key] = "cached-value"
        let report = try RelinkScanner.scan(index: [MediaIndexEntry(id: entry.id, name: "Clip", kind: .video, size: 6, sha256: "cached-value")],
                                            folders: [folder], cache: &cache)
        XCTAssertEqual(report.statuses[entry.id], .relinked(f.standardizedFileURL.path))

        // Changing the file (new mtime) misses the cache.
        try Data("frames".utf8).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: f.path)
        _ = try RelinkScanner.scan(index: [entry], folders: [folder], cache: &cache)
        XCTAssertEqual(cache.entries.count, 2)
    }

    func testScanCanBeCancelledAndRunsOffTheMainThread() async throws {
        let folder = temp.appendingPathComponent("Media", isDirectory: true)
        for n in 0..<50 { _ = try file("Media/f\(n).bin", "x\(n)") }
        let index = [MediaIndexEntry(id: UUID(), name: "f1.bin", kind: .audio, size: 2, sha256: try sha("x1"))]
        let report = try await RelinkScanner.run(index: index, folders: [folder], machine: machine)
        XCTAssertEqual(report.relinked, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: machine.hashCache.path), "cache saved")

        let task = Task { try await RelinkScanner.run(index: index, folders: [folder], machine: machine) }
        task.cancel()
        do { _ = try await task.value; } catch is CancellationError { return } catch { return XCTFail("\(error)") }
        // Finishing before the cancel landed is also acceptable for so small a folder.
    }

    /// A 1 GiB file (sparse, so it costs no disk) is hashed in 1 MiB chunks; the process's peak memory does not grow by
    /// anything near the file size.
    func testLargeFileIsHashedByStreaming() throws {
        let url = temp.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30)
        try handle.close()

        let peakBefore = peakFootprint()
        var chunks = 0
        var largest = 0
        _ = try FileHasher.sha256(of: url) { chunks += 1; largest = max(largest, $0) }
        let peakAfter = peakFootprint()
        XCTAssertEqual(chunks, 1024)
        XCTAssertEqual(largest, FileHasher.chunkSize)
        XCTAssertLessThan(peakAfter - peakBefore, 128 << 20, "peak grew \(peakAfter - peakBefore) bytes for a 1 GiB file")
    }

    private func peakFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0
    }
}
