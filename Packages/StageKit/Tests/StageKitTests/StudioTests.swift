import XCTest
@testable import StageKit

final class StudioCodecTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)

    func sample() -> Studio { Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1") }

    func testRoundTrip() throws {
        let studio = sample()
        let files = try StudioCodec.encode(studio)
        XCTAssertEqual(try StudioCodec.decode(files), studio.normalized())
        XCTAssertEqual(studio.validationIssues(), [])
    }

    func testFileLayout() throws {
        let studio = sample()
        let paths = Set(try StudioCodec.encode(studio).keys)
        var expected: Set<String> = ["manifest.json", "audio.json", "media.json", "looks.json", "screens.json", "timers.json", "messages.json"]
        for song in studio.songs { expected.insert("library/\(song.id.uuidString).json") }
        for service in studio.services { expected.insert("services/\(service.id.uuidString).json") }
        XCTAssertEqual(paths, expected)
        XCTAssertTrue(paths.allSatisfy(StudioCodec.isShowDataPath))
        XCTAssertFalse(StudioCodec.isShowDataPath("lock.json"))
        XCTAssertFalse(StudioCodec.isShowDataPath("cache/peaks.bin"))
    }

    func testJSONIsPrettySortedAndISO8601() throws {
        let files = try StudioCodec.encode(sample())
        let manifest = String(decoding: files["manifest.json"]!, as: UTF8.self)
        XCTAssertTrue(manifest.contains("\n  \""), "pretty-printed")
        let keys = manifest.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let end = t.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(t[t.index(after: t.startIndex)..<end])
        }
        XCTAssertEqual(keys, keys.sorted(), "sorted keys")
        XCTAssertTrue(manifest.contains(#""created" : "2026-09-21T"#), manifest)
        XCTAssertTrue(manifest.contains(#""format" : "cueme-stage-studio""#))
        XCTAssertTrue(manifest.contains(#""formatVersion" : 1"#))
    }

    func testChangingOneSongChangesOneLibraryFile() throws {
        var studio = sample()
        let before = try StudioCodec.encode(studio)
        studio.songs[0].slides[0].lines[0] = "Changed"
        let after = try StudioCodec.encode(studio)
        let changed = after.keys.filter { after[$0] != before[$0] }
        XCTAssertEqual(changed, ["library/\(studio.songs[0].id.uuidString).json"])
    }

    func testScreensCarryLayoutsButNoConnectors() throws {
        let studio = sample()
        let json = String(decoding: try StudioCodec.encode(studio)["screens.json"]!, as: UTF8.self)
        XCTAssertFalse(json.contains("connector"))
        XCTAssertFalse(json.contains("outputID"))
        XCTAssertEqual(studio.screens.map(\.name), ["Left", "Stage", "Right", "IMAG"])
        let lib = studio.library()
        XCTAssertEqual(lib.screens.map(\.id), studio.screens.map(\.id))
        XCTAssertEqual(lib.screenSetups[studio.screens[2].id]?.canvas.x, 1920)
        XCTAssertEqual(lib.outputs, [])
    }

    func testMissingListFilesAreEmpty() throws {
        var files = try StudioCodec.encode(sample())
        files["messages.json"] = nil
        files["timers.json"] = nil
        let studio = try StudioCodec.decode(files)
        XCTAssertEqual(studio.messages, [])
        XCTAssertEqual(studio.timers, [])
    }

    func testTooNewIsRefusedWithTheMessage() throws {
        var files = try StudioCodec.encode(sample())
        files["manifest.json"] = Data(#"{"format":"cueme-stage-studio","formatVersion":2}"#.utf8)
        XCTAssertThrowsError(try StudioCodec.decode(files)) { error in
            XCTAssertEqual(error as? StudioError, .tooNew(found: 2, supported: 1))
            XCTAssertTrue(error.localizedDescription.hasPrefix("This Studio was made by a newer CueME Stage"))
        }
    }

    func testNotAStudio() {
        XCTAssertThrowsError(try StudioCodec.decode([:])) { XCTAssertEqual($0 as? StudioError, .notAStudio("no manifest.json")) }
        XCTAssertThrowsError(try StudioCodec.checkManifest(Data(#"{"format":"other","formatVersion":1}"#.utf8)))
        XCTAssertThrowsError(try StudioCodec.checkManifest(Data("garbage".utf8)))
    }

    /// A fake format 0: songs were bare in songs/<id>.json. The hook moves them to library/ before decoding.
    func testMigrationHookRunsForAnOlderVersion() throws {
        let studio = sample()
        var v0 = try StudioCodec.encode(studio)
        for song in studio.songs {
            v0["library/\(song.id.uuidString).json"] = nil
            v0["songs/\(song.id.uuidString).json"] = try StudioCodec.makeEncoder().encode(song)
        }
        var manifest = studio.manifest
        manifest.formatVersion = 0
        v0["manifest.json"] = try StudioCodec.makeEncoder().encode(manifest)

        XCTAssertThrowsError(try StudioCodec.decode(v0)) { XCTAssertEqual($0 as? StudioError, .noMigration(from: 0)) }

        let ran = Flag()
        let migrations: [Int: StudioCodec.Migration] = [0: { files in
            ran.set()
            for path in files.keys where path.hasPrefix("songs/") {
                let song = try StudioCodec.makeDecoder().decode(Song.self, from: files[path]!)
                files["library/\(song.id.uuidString).json"] = try StudioCodec.makeEncoder().encode(LibraryItemFile(song: song))
                files[path] = nil
            }
        }]
        let migrated = try StudioCodec.decode(v0, migrations: migrations)
        XCTAssertTrue(ran.value)
        XCTAssertEqual(migrated.manifest.formatVersion, 1)
        XCTAssertEqual(migrated, studio.normalized())
    }

    func testValidationFindsBrokenReferences() {
        var studio = sample()
        studio.songs.removeAll()
        studio.looks.append(Look(name: "Bad", backgroundMediaID: UUID()))
        let issues = studio.validationIssues()
        XCTAssertTrue(issues.contains { $0.contains("missing song") })
        XCTAssertTrue(issues.contains { $0.contains("look Bad") })
    }

    func testLockRoundTrip() throws {
        let lock = StudioLock(machineID: UUID(), machineName: "Mac Studio", pid: 4242, openedAt: now, appVersion: "0.1")
        let data = try StudioCodec.makeEncoder().encode(lock)
        XCTAssertEqual(try StudioCodec.makeDecoder().decode(StudioLock.self, from: data), lock)
    }
}

final class StudioItemCodecTests: XCTestCase {
    let lib = Library.sample

    func testSongsRoundTripWithHeader() throws {
        let data = try StudioItemCodec.encode(lib.songs.map(StudioItemPayload.song), media: [], appVersion: "0.1", exported: Date())
        let header = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(header["format"] as? String, "cueme-stage-item")
        XCTAssertEqual(header["formatVersion"] as? Int, 1)
        XCTAssertEqual(header["kind"] as? String, "song")
        let result = try StudioItemCodec().decode(data)
        XCTAssertEqual(result.items, lib.songs.map(StudioItemPayload.song))
        XCTAssertEqual(result.skipped, [])
    }

    func testCollectionAndMediaRefs() throws {
        let media = MediaIndexEntry(id: UUID(), name: "Loop", kind: .video, size: 10, sha256: "ab")
        let look = Look(name: "Loop look", backgroundMediaID: media.id)
        let items: [StudioItemPayload] = [.look(look), .message(lib.messages[0]), .timer(lib.timers[0])]
        let data = try StudioItemCodec.encode(items, media: [media, MediaIndexEntry(id: UUID(), name: "Other", kind: .audio)], appVersion: "0.1", exported: Date())
        let result = try StudioItemCodec().decode(data)
        XCTAssertEqual(result.items, items)
        XCTAssertEqual(result.mediaRefs, [.init(id: media.id, name: "Loop", size: 10, sha256: "ab", kind: .video)])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""kind" : "collection""#))
    }

    func testHeaderChecks() {
        let codec = StudioItemCodec()
        XCTAssertThrowsError(try codec.decode(Data("nope".utf8)))
        XCTAssertThrowsError(try codec.decode(Data(#"{"format":"cueme-stage-studio","formatVersion":1,"kind":"song"}"#.utf8)))
        XCTAssertThrowsError(try codec.decode(Data(#"{"format":"cueme-stage-item","formatVersion":9,"kind":"song"}"#.utf8))) {
            XCTAssertEqual($0 as? StudioItemError, .tooNew(found: 9, supported: 1))
            XCTAssertTrue($0.localizedDescription.hasPrefix("This item file was made by a newer CueME Stage"))
        }
        XCTAssertThrowsError(try codec.decode(Data(#"{"format":"cueme-stage-item","formatVersion":1,"kind":"spaceship"}"#.utf8)))
    }

    func testUnknownKindIsSkippedAndReported() throws {
        let song = lib.songs[0]
        var file = try JSONSerialization.jsonObject(with: StudioItemCodec.encode([.song(song)], media: [], appVersion: "0.1", exported: Date())) as! [String: Any]
        var items = file["items"] as! [[String: Any]]
        let alien = UUID()
        items.append(["kind": "presentation", "id": alien.uuidString, "name": "Deck", "data": ["slides": []]])
        items.append(["kind": "song", "id": UUID().uuidString, "name": "Broken", "data": ["nonsense": true]])
        file["items"] = items
        file["kind"] = "collection"
        let result = try StudioItemCodec().decode(JSONSerialization.data(withJSONObject: file))
        XCTAssertEqual(result.items, [.song(song)])
        XCTAssertEqual(result.skipped.map(\.name), ["Deck", "Broken"])
        XCTAssertEqual(result.skipped[0].reason, "unknown kind presentation")
        XCTAssertTrue(result.skipped[1].reason.hasPrefix("bad data"))
    }

    func testKeepBothGivesANewID() {
        let payload = StudioItemPayload.song(lib.songs[0])
        let copy = payload.withID(UUID())
        XCTAssertNotEqual(copy.id, payload.id)
        XCTAssertEqual(copy.name, payload.name)
    }
}

final class MockStudioTests: XCTestCase {
    func testOpenCloseAndReloadAStudio() async throws {
        var studio = Studio(seededFrom: .sample, name: "Sunday", now: Date(), appVersion: "0.1")
        let info = StudioInfo(id: studio.id, name: studio.name)
        let box = Box(MockStageClient.LoadedStudio(info: info, library: studio.library(), assignments: []))
        let client = MockStageClient(library: .sample, studioSource: { id in id == info.id ? box.value : nil })
        let song = Library.sample.service.items[1]
        await client.send(.go(itemID: song.id, slideIndex: 0))
        await client.send(.playAudio(mediaID: Library.sample.media[0].id))
        let events = await client.events()

        await client.send(.openStudio(info.id))
        var state = await client.currentState
        XCTAssertEqual(state.studio, info)
        XCTAssertNil(state.primaryLive, "switching stops what was live")
        XCTAssertNil(state.audio.liveTrack)
        XCTAssertEqual(state.screens.map(\.screenID), studio.screens.map(\.id))
        XCTAssertTrue(state.assignments.allSatisfy { $0.connectorID == nil }, "no assignments here: Unassigned, nothing guessed")
        XCTAssertEqual(state.connectors, MockStageClient.sampleConnectors, "connectors are the machine's, unchanged")
        XCTAssertEqual(state.service?.id, studio.services[0].id)

        // Reload keeps what is live.
        await client.send(.go(itemID: studio.services[0].items[1].id, slideIndex: 1))
        studio.messages.append(Message(text: "New"))
        box.value = MockStageClient.LoadedStudio(info: info, library: studio.library(), assignments: [])
        await client.send(.reloadStudio(info.id))
        state = await client.currentState
        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.primaryLive?.slideIndex, 1)

        await client.send(.openStudio(UUID()))
        await client.send(.closeStudio)
        state = await client.currentState
        XCTAssertNil(state.studio)
        XCTAssertEqual(state.screens, [])
        await client.send(.closeStudio)

        var seen: [StageEvent] = []
        var iterator = events.makeAsyncIterator()
        while seen.count < 6, let e = await iterator.next() { seen.append(e) }
        XCTAssertTrue(seen.contains(.studioOpened(info)))
        XCTAssertTrue(seen.contains(.studioClosed(info)))
        XCTAssertTrue(seen.contains(.commandRejected(.closeStudio, reason: "no Studio open")))
        XCTAssertTrue(seen.contains { if case .commandRejected(.openStudio, "unknown Studio") = $0 { true } else { false } })
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A Sendable flag for @Sendable closures in tests.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}
