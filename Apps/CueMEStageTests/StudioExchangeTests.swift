import XCTest
import StageKit
@testable import CueMEStage

/// A minimal zip writer (stored entries) so a test can build a zip with any entry name, "../" included.
enum TestZip {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    static func make(_ entries: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for (name, data) in entries {
            let offset = UInt32(out.count), crc = crc32(data), nameData = Data(name.utf8)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(nameData.count, &out); u16(0, &out)
            out.append(nameData); out.append(data)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central); u16(nameData.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central)
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        return out
    }
}

@MainActor
final class StudioBundleTests: TempFolderTestCase {
    private func makeStudioPackage() throws -> (StudioPackage, Studio) {
        let studio = sampleStudio(name: "Sunday")
        let url = temp.appendingPathComponent("Sunday.stg")
        let package = try StudioPackage.create(studio, at: url)
        // Things that must not travel: the lock and the cache.
        try Data("{}".utf8).write(to: package.lockURL)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data("peaks".utf8).write(to: url.appendingPathComponent("cache/peaks.json"))
        return (package, studio)
    }

    func testExportThenImportEqualsTheOriginalMinusCacheAndLock() throws {
        let (package, studio) = try makeStudioPackage()
        let bundle = temp.appendingPathComponent("Sunday.stgbundle")
        try StudioBundle.export(package, to: bundle)

        let entries = String(decoding: try Tool.run("/usr/bin/zipinfo", ["-1", bundle.path]).output, as: UTF8.self)
        XCTAssertFalse(entries.contains("lock.json"))
        XCTAssertFalse(entries.contains("cache/"))
        XCTAssertTrue(entries.contains("Sunday.stg/manifest.json"))

        let into = temp.appendingPathComponent("Imported", isDirectory: true)
        let url = try StudioBundle.importAsNew(bundle, into: into, idsInUse: [], now: Date())
        XCTAssertEqual(url.lastPathComponent, "Sunday.stg")
        XCTAssertEqual(try StudioPackage(url: url).read().studio, studio.normalized())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0 == "lock.json" || $0 == "cache" }, [])

        // Again: the name is taken (never overwritten) and, being in use, the id is new.
        let second = try StudioBundle.importAsNew(bundle, into: into, idsInUse: [studio.id], now: Date())
        XCTAssertEqual(second.lastPathComponent, "Sunday 2.stg")
        let copy = try StudioPackage(url: second).read().studio
        XCTAssertEqual(copy.name, "Sunday 2")
        XCTAssertNotEqual(copy.id, studio.id)
        XCTAssertEqual(copy.songs, studio.normalized().songs)
    }

    func testReplaceCurrentKeepsIdentity() throws {
        let (package, _) = try makeStudioPackage()
        let bundle = temp.appendingPathComponent("Sunday.stgbundle")
        try StudioBundle.export(package, to: bundle)

        let store = StudioStore(environment: environment())
        var other = sampleStudio(name: "Other")
        other.songs.removeAll()
        try store.create(other, at: temp.appendingPathComponent("Other.stg"))
        try store.replaceContents(withBundle: bundle)
        XCTAssertEqual(store.studio?.id, other.id)
        XCTAssertEqual(store.studio?.name, "Other")
        XCTAssertEqual(store.studio?.songs.count, 2)
        XCTAssertEqual(try StudioPackage(url: store.url!).read().studio.songs.count, 2, "saved")
    }

    func testPathTraversalIsRefused() throws {
        let manifest = try StudioCodec.makeEncoder().encode(sampleStudio().manifest)
        let evil = temp.appendingPathComponent("evil.stgbundle")
        try TestZip.make([("Evil.stg/manifest.json", manifest), ("Evil.stg/../../escaped.txt", Data("x".utf8))]).write(to: evil)
        XCTAssertThrowsError(try StudioBundle.extract(evil)) {
            XCTAssertEqual($0 as? StudioBundleError, .unsafeEntry("Evil.stg/../../escaped.txt"))
        }
        let absolute = temp.appendingPathComponent("abs.stgbundle")
        try TestZip.make([("/tmp/escaped.txt", Data("x".utf8))]).write(to: absolute)
        XCTAssertThrowsError(try StudioBundle.extract(absolute)) { XCTAssertEqual($0 as? StudioBundleError, .unsafeEntry("/tmp/escaped.txt")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    func testOversizeIsRefused() throws {
        let (package, _) = try makeStudioPackage()
        let bundle = temp.appendingPathComponent("Sunday.stgbundle")
        try StudioBundle.export(package, to: bundle)
        XCTAssertThrowsError(try StudioBundle.extract(bundle, limits: .init(bundle: 100, unzipped: .max))) {
            guard case .tooLarge = $0 as? StudioBundleError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try StudioBundle.extract(bundle, limits: .init(bundle: .max, unzipped: 100))) {
            guard case .tooLarge = $0 as? StudioBundleError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(StudioBundle.maxBundleBytes, 256 * 1024 * 1024)
    }

    func testCorruptZipIsRefusedClearly() throws {
        let bad = temp.appendingPathComponent("bad.stgbundle")
        try Data("this is not a zip".utf8).write(to: bad)
        XCTAssertThrowsError(try StudioBundle.extract(bad)) { error in
            XCTAssertEqual(error as? StudioBundleError, .notAZip("the zip directory could not be read"))
            XCTAssertTrue(error.localizedDescription.hasPrefix("This file is not a readable Studio bundle"))
        }
    }

    func testTooNewManifestIsRefusedBeforeUnpacking() throws {
        let newer = Data(#"{"format":"cueme-stage-studio","formatVersion":7}"#.utf8)
        let bundle = temp.appendingPathComponent("new.stgbundle")
        try TestZip.make([("Future.stg/manifest.json", newer)]).write(to: bundle)
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("cueme-import-") }
        XCTAssertThrowsError(try StudioBundle.extract(bundle)) {
            XCTAssertEqual($0 as? StudioError, .tooNew(found: 7, supported: 1))
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("cueme-import-") }
        XCTAssertEqual(Set(after), Set(before), "nothing unpacked")
    }

    func testABundleWithTwoStudiosIsRefused() throws {
        let manifest = try StudioCodec.makeEncoder().encode(sampleStudio().manifest)
        let bundle = temp.appendingPathComponent("two.stgbundle")
        try TestZip.make([("A.stg/manifest.json", manifest), ("B.stg/manifest.json", manifest)]).write(to: bundle)
        XCTAssertThrowsError(try StudioBundle.extract(bundle)) { XCTAssertEqual($0 as? StudioBundleError, .noStudioInside) }
    }
}

final class StudioItemImportTests: TempFolderTestCase {
    func testClashChoicesAndMediaRefs() throws {
        var studio = sampleStudio()
        let song = studio.songs[0]
        let background = MediaIndexEntry(id: UUID(), name: "loop.mov", kind: .video, size: 42, sha256: "ff")
        var source = studio
        source.media.append(background)
        let look = Look(name: "New look", backgroundMediaID: background.id)
        var edited = song
        edited.title = "Edited"
        let message = studio.messages[0]

        let data = try StudioItemImporter.export([.song(edited), .message(message), .look(look)], from: source, appVersion: "0.1", now: Date())
        let url = temp.appendingPathComponent("items.stgitem")
        try data.write(to: url)
        let imported = try StudioItemImporter.read(url)
        XCTAssertEqual(StudioItemImporter.clashes(imported, in: studio).map(\.id), [song.id, message.id])

        // Replace the song, keep both messages.
        var asked: [String] = []
        let result = StudioItemImporter.apply(imported, to: &studio) { item in
            asked.append(item.name)
            return item.kind == "song" ? .replace : .keepBoth
        }
        XCTAssertEqual(asked, ["Edited", message.text], "asked once per clash")
        XCTAssertEqual(result.replaced, ["Edited"])
        XCTAssertEqual(result.keptBoth, [message.text])
        XCTAssertEqual(result.added, ["New look"])
        XCTAssertEqual(result.mediaAdded, ["loop.mov"])
        XCTAssertEqual(studio.songs.first { $0.id == song.id }?.title, "Edited")
        XCTAssertEqual(studio.messages.filter { $0.text == message.text }.count, 2)
        XCTAssertEqual(Set(studio.messages.map(\.id)).count, studio.messages.count, "Keep both made a new id")
        XCTAssertEqual(studio.media.last, MediaIndexEntry(id: background.id, name: "loop.mov", kind: .video, size: 42, sha256: "ff"))

        // Skip leaves the Studio as it is; the media ref is not added twice.
        let before = studio
        let skipped = StudioItemImporter.apply(imported, to: &studio) { _ in .skip }
        XCTAssertEqual(skipped.skipped.count, 3)
        XCTAssertEqual(skipped.mediaAdded, [])
        XCTAssertEqual(studio, before)
    }

    func testUnknownKindsAreReportedNotFatal() throws {
        var json = try JSONSerialization.jsonObject(with: StudioItemImporter.export([.timer(sampleStudio().timers[0])], from: sampleStudio(), appVersion: "0.1", now: Date())) as! [String: Any]
        json["items"] = (json["items"] as! [[String: Any]]) + [["kind": "presentation", "id": UUID().uuidString, "name": "Announcements deck", "data": [:]]]
        let url = temp.appendingPathComponent("mixed.stgitem")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var studio = sampleStudio()
        studio.timers.removeAll()
        let result = StudioItemImporter.apply(try StudioItemImporter.read(url), to: &studio) { _ in .skip }
        XCTAssertEqual(result.added, ["Service start"])
        XCTAssertEqual(result.notRead, ["Announcements deck (unknown kind presentation)"])
    }

    func testTooNewItemFileIsRefused() throws {
        let url = temp.appendingPathComponent("new.stgitem")
        try Data(#"{"format":"cueme-stage-item","formatVersion":3,"kind":"song","items":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try StudioItemImporter.read(url)) { XCTAssertEqual($0 as? StudioItemError, .tooNew(found: 3, supported: 1)) }
    }
}
