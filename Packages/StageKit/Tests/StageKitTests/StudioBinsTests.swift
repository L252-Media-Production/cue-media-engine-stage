import XCTest
@testable import StageKit

/// The Media and Audio bins: folders (bins.json, additive and optional), what each folder lists, search and the type
/// filter, registering files in place, media rows in a service and audio settings.
final class StudioBinsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)

    func sample() -> Studio { Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1") }

    func entry(_ name: String, _ kind: MediaItem.Kind, sha: String? = nil, path: String? = nil, folder: UUID? = nil) -> MediaIndexEntry {
        MediaIndexEntry(id: UUID(), name: name, kind: kind, size: 10, sha256: sha, lastKnownPath: path ?? "/Media/\(name)", folderID: folder)
    }

    /// A Studio with two media folders (Loops > Advent) and one audio folder, and items in each.
    func binStudio() -> (Studio, loops: StudioBinFolder, advent: StudioBinFolder, tracks: StudioBinFolder) {
        var studio = sample()
        let loops = studio.addBinFolder(named: "Sunday Loops", in: .media)
        let advent = studio.addBinFolder(named: "Advent", in: .media, parent: loops.id)
        let tracks = studio.addBinFolder(named: "Worship Tracks", in: .audio)
        studio.media += [
            entry("loop_b.mov", .video, folder: loops.id),
            entry("loop_a.mov", .video, folder: loops.id),
            entry("wreath.png", .image, folder: advent.id),
            entry("logo.png", .image),
            entry("track_01.wav", .audio, folder: tracks.id),
        ]
        return (studio, loops, advent, tracks)
    }

    // MARK: File format

    func testAStudioWithoutBinsWritesBackByteForByte() throws {
        let files = try StudioCodec.encode(sample())
        XCTAssertNil(files["bins.json"], "no bins.json until there is a folder")
        XCTAssertFalse(String(decoding: files["media.json"]!, as: UTF8.self).contains("folderID"), "no folderID while nil")
        XCTAssertEqual(try StudioCodec.encode(try StudioCodec.decode(files)), files)
    }

    func testBinFoldersAndFolderIDsRoundTrip() throws {
        let (studio, loops, advent, _) = binStudio()
        let files = try StudioCodec.encode(studio)
        XCTAssertNotNil(files["bins.json"])
        XCTAssertTrue(StudioCodec.isShowDataPath("bins.json"))
        XCTAssertTrue(String(decoding: files["media.json"]!, as: UTF8.self).contains("\"folderID\""))
        let back = try StudioCodec.decode(files)
        XCTAssertEqual(back, studio.normalized())
        XCTAssertEqual(back.binFolders.first { $0.id == advent.id }?.parentID, loops.id)
        XCTAssertEqual(back.validationIssues(), [])
        XCTAssertEqual(StudioManifest(name: "x", created: now, appVersion: "0.1").formatVersion, 1, "no formatVersion bump")
    }

    func testAnOldMediaIndexWithoutFolderIDsStillDecodes() throws {
        var files = try StudioCodec.encode(sample())
        files["media.json"] = Data("""
        [ { "id" : "\(UUID().uuidString)", "kind" : "video", "name" : "old.mov" } ]
        """.utf8)
        let studio = try StudioCodec.decode(files)
        XCTAssertNil(studio.media.first?.folderID)
        XCTAssertEqual(studio.binFolders, [])
    }

    func testValidationFindsBadFolderReferences() {
        var (studio, _, _, tracks) = binStudio()
        studio.media.append(entry("clip.mov", .video, folder: tracks.id))
        studio.media.append(entry("lost.mov", .video, folder: UUID()))
        studio.binFolders.append(StudioBinFolder(name: "Orphan", bin: .media, parentID: UUID()))
        let issues = studio.validationIssues()
        XCTAssertTrue(issues.contains("media clip.mov is in a folder of the audio bin"), "\(issues)")
        XCTAssertTrue(issues.contains("media lost.mov is in an unknown bin folder"), "\(issues)")
        XCTAssertTrue(issues.contains("bin folder Orphan is inside an unknown folder"), "\(issues)")
    }

    // MARK: Listing

    func testFolderRowsAreAllThenTheTreeWithCounts() {
        let (studio, loops, advent, tracks) = binStudio()
        let media = BinListing(studio: studio, bin: .media)
        XCTAssertEqual(media.rows.map(\.name), ["All media", "Sunday Loops", "Advent"])
        XCTAssertEqual(media.rows.map(\.selection), [.all, .folder(loops.id), .folder(advent.id)])
        XCTAssertEqual(media.rows.map(\.depth), [0, 0, 1])
        XCTAssertEqual(media.rows.map(\.count), [4, 2, 1], "All counts every video and photo; a folder its own items")
        XCTAssertEqual(media.rows.map(\.hasChildren), [false, true, false])

        let audio = BinListing(studio: studio, bin: .audio)
        XCTAssertEqual(audio.rows.map(\.name), ["All audio", "Worship Tracks"])
        XCTAssertEqual(audio.rows.map(\.count), [Library.sample.media.count + 1, 1], "the sample's audio is in All audio")
        XCTAssertEqual(audio.rows[1].selection, .folder(tracks.id))
    }

    func testMediaBinNeverListsMusicAndAudioBinNeverListsVideo() {
        let (studio, _, _, _) = binStudio()
        XCTAssertTrue(BinListing(studio: studio, bin: .media).items(in: .all).allSatisfy { $0.kind != .audio })
        XCTAssertTrue(BinListing(studio: studio, bin: .audio).items(in: .all).allSatisfy { $0.kind == .audio })
    }

    func testItemsOfAFolderAreItsOwnByName() {
        let (studio, loops, advent, _) = binStudio()
        let media = BinListing(studio: studio, bin: .media)
        XCTAssertEqual(media.items(in: .folder(loops.id)).map(\.name), ["loop_a.mov", "loop_b.mov"])
        XCTAssertEqual(media.items(in: .folder(advent.id)).map(\.name), ["wreath.png"])
        XCTAssertEqual(media.items(in: .all).map(\.name), ["logo.png", "loop_a.mov", "loop_b.mov", "wreath.png"])
        XCTAssertEqual(media.items(in: .folder(UUID())).count, 4, "a folder that is gone falls back to All")
    }

    func testSearchLooksThroughTheWholeBin() {
        let (studio, _, advent, _) = binStudio()
        let media = BinListing(studio: studio, bin: .media)
        XCTAssertEqual(media.items(in: .folder(advent.id), query: " LOOP ").map(\.name), ["loop_a.mov", "loop_b.mov"])
        XCTAssertEqual(media.items(in: .all, query: "track").count, 0, "music is never found in the Media bin")
        XCTAssertEqual(BinListing(studio: studio, bin: .audio).items(in: .all, query: "track_01").map(\.name), ["track_01.wav"])
    }

    func testTypeFilterKeepsVideoOrPhotos() {
        let (studio, loops, _, _) = binStudio()
        let media = BinListing(studio: studio, bin: .media)
        XCTAssertEqual(media.items(in: .all, filter: .video).map(\.name), ["loop_a.mov", "loop_b.mov"])
        XCTAssertEqual(media.items(in: .all, filter: .photo).map(\.name), ["logo.png", "wreath.png"])
        XCTAssertEqual(media.items(in: .folder(loops.id), filter: .photo), [])
        XCTAssertEqual(media.items(in: .all, query: "png", filter: .video), [], "search and filter combine")
        XCTAssertEqual(BinListing(studio: studio, bin: .audio).items(in: .all, filter: .video).count, Library.sample.media.count + 1,
                       "the filter does nothing in the Audio bin")
        XCTAssertEqual(MediaKindFilter.allCases.map(\.title), ["All", "Video", "Photos"])
    }

    // MARK: Changes

    func testNewFolderGoesInsideAParentOfTheSameBinOnly() {
        var (studio, loops, _, tracks) = binStudio()
        let easter = studio.addBinFolder(named: "Easter", in: .media, parent: loops.id)
        XCTAssertEqual(easter.parentID, loops.id)
        let wrong = studio.addBinFolder(named: "Stingers", in: .media, parent: tracks.id)
        XCTAssertNil(wrong.parentID, "an audio folder cannot hold a media folder")
        XCTAssertEqual(studio.validationIssues(), [])
    }

    func testRegisterAddsReferencesAndSkipsFilesAlreadyInTheIndex() {
        var (studio, loops, _, tracks) = binStudio()
        let known = studio.media.first { $0.name == "loop_a.mov" }!
        studio.media[studio.media.firstIndex(of: known)!].sha256 = "aaa"
        let before = studio.media.count
        let fresh = entry("new.mov", .video, sha: "bbb")
        let sameHash = entry("renamed.mov", .video, sha: "aaa", path: "/Elsewhere/renamed.mov")
        let samePath = entry("loop_b.mov", .video, sha: "ccc", path: "/Media/loop_b.mov") // the indexed one has no hash
        let song = entry("song.wav", .audio, sha: "ddd")
        let result = studio.registerMedia([fresh, sameHash, samePath, song], into: loops.id)
        XCTAssertEqual(result.added, [fresh.id, song.id])
        XCTAssertEqual(result.existing.count, 2)
        XCTAssertEqual(studio.media.count, before + 2)
        XCTAssertEqual(studio.media.first { $0.id == fresh.id }?.folderID, loops.id)
        XCTAssertNil(studio.media.first { $0.id == song.id }?.folderID, "a media folder does not take audio")
        XCTAssertEqual(studio.media.first { $0.id == fresh.id }?.lastKnownPath, fresh.lastKnownPath, "in place: the path is kept")
        _ = tracks
        XCTAssertEqual(studio.validationIssues(), [])
    }

    func testAppendMediaRowAddsToTheActiveService() {
        var (studio, _, _, _) = binStudio()
        let clip = studio.media.first { $0.name == "loop_a.mov" }!
        let count = studio.activeService!.items.count
        let item = studio.appendMediaRow(clip.id)
        XCTAssertEqual(item?.content, .media(clip.id))
        XCTAssertEqual(item?.title, "loop_a.mov")
        XCTAssertEqual(item?.slideCount, 0)
        XCTAssertEqual(studio.activeService!.items.count, count + 1)
        XCTAssertEqual(studio.activeService!.items.last, item)
        XCTAssertNil(studio.appendMediaRow(UUID()), "unknown media")
        XCTAssertTrue(studio.collections.isEmpty, "media is never a collection")
        XCTAssertEqual(studio.validationIssues(), [])
    }

    func testAudioSettingsDefaultsAndRoundTrip() throws {
        var studio = sample()
        let walkIn = studio.media.first { $0.name == "Walk-in loop" }!
        let welcome = studio.media.first { $0.name == "Welcome VO" }!
        XCTAssertEqual(studio.audioSettings(for: walkIn.id).levelDB, -3)
        XCTAssertEqual(studio.audioSettings(for: welcome.id), AudioSettings(mediaID: welcome.id), "defaults when none stored")
        var settings = studio.audioSettings(for: welcome.id)
        settings.levelDB = -6
        settings.fadeIn = 0.5
        settings.fadeOut = 3
        studio.audioSettings[welcome.id] = settings
        let back = try StudioCodec.decode(try StudioCodec.encode(studio))
        XCTAssertEqual(back.audioSettings[welcome.id], settings)
        XCTAssertEqual(back.library().audioSettings[welcome.id], settings, "the engine gets them")
    }
}
