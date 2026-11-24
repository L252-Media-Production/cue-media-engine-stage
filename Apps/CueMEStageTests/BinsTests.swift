import AVFoundation
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The Media and Audio bins: listing, search and the type filter, registering files in place (nothing in a media
/// folder is ever written, moved or deleted), linking a folder, missing files, audio settings, the play command, and
/// the controls that are drawn but disabled.
@MainActor
final class BinsTests: StudioEditTestCase {
    // MARK: Helpers

    /// A folder of media files on "this Mac", outside the Studio.
    var mediaFolder: URL { temp.appendingPathComponent("Movies/Easter", isDirectory: true) }

    @discardableResult
    func makeFile(_ name: String, in folder: URL? = nil, bytes: Int = 3000) throws -> URL {
        let folder = folder ?? mediaFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        // Different bytes per name: the same bytes are the same file (found by hash).
        try (Data(name.utf8) + Data((0..<bytes).map { UInt8($0 % 251) })).write(to: url)
        return url
    }

    /// A real 48 kHz stereo WAV: a sine at `amplitude` for `seconds`.
    @discardableResult
    func makeWAV(_ name: String, seconds: Double = 1, amplitude: Float = 0.5, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? mediaFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        try file.write(from: buffer)
        return url
    }

    /// Every file under a folder with its size, modification date and bytes: what "nothing touched" is checked against.
    func snapshot(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
            let sha = values.isDirectory == true ? "dir" : try FileHasher.sha256(of: url)
            result[url.path] = "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(sha)"
        }
        return result
    }

    func waitForJob() async {
        await until("the add finishes", timeout: 10) { [self] in controller.media.job?.isFinished == true }
    }

    /// The Studio as it is on disk now.
    func onDisk() throws -> Studio { try StudioPackage(url: controller.studios.url!).read().studio }

    // MARK: Listing, search and filter

    func testMediaBinListsVideoAndPhotosWithKindAndLengthAndNeverMusic() async {
        await launch()
        let loops = controller.addBinFolder(named: "Sunday Loops", in: .media, parent: nil)!
        let clip = MediaIndexEntry(id: UUID(), name: "loop_a.mov", kind: .video, duration: 30, lastKnownPath: "/nowhere/loop_a.mov")
        let photo = MediaIndexEntry(id: UUID(), name: "welcome.png", kind: .image, lastKnownPath: "/nowhere/welcome.png")
        controller.registerMedia([clip, photo], into: loops)

        let model = MediaBinModel(studio: studio, selection: .all)
        XCTAssertEqual(model.rows.map(\.name), ["All media", "Sunday Loops"])
        XCTAssertEqual(model.rows.map(\.count), [2, 2])
        XCTAssertEqual(model.tiles.map(\.entry.name), ["loop_a.mov", "welcome.png"], "the sample's audio is not here")
        XCTAssertEqual(model.tiles.map(\.kindLabel), ["VIDEO", "PHOTO"])
        XCTAssertEqual(model.tiles.map(\.duration), ["0:30", "—"], "a photo has no length")
        XCTAssertEqual(model.selected?.id, clip.id, "the first item is selected, as on the board")
        XCTAssertEqual(model.meta(studio.media.first { $0.id == clip.id }!), "Video · 0:30 · Sunday Loops")
        XCTAssertEqual(model.meta(clip), "Video · 0:30 · No folder", "an entry in no folder")
        XCTAssertEqual(MediaBinModel(studio: studio, selection: .folder(loops)).title, "Sunday Loops")
        XCTAssertEqual(MediaBinModel(studio: studio, selection: .folder(UUID())).title, "All media", "a folder that is gone")
    }

    func testSearchAndTypeFilter() async {
        await launch()
        let advent = controller.addBinFolder(named: "Advent", in: .media, parent: nil)!
        controller.registerMedia([
            MediaIndexEntry(id: UUID(), name: "advent_candles.mov", kind: .video, lastKnownPath: "/x/advent_candles.mov"),
            MediaIndexEntry(id: UUID(), name: "advent_wreath.png", kind: .image, lastKnownPath: "/x/advent_wreath.png"),
            MediaIndexEntry(id: UUID(), name: "countdown.mov", kind: .video, lastKnownPath: "/x/countdown.mov"),
        ], into: nil)
        var model = MediaBinModel(studio: studio, selection: .folder(advent), query: "advent")
        XCTAssertEqual(model.tiles.map(\.entry.name), ["advent_candles.mov", "advent_wreath.png"], "search looks through the whole bin")
        XCTAssertEqual(model.title, "Results for “advent”")
        model.filter = .photo
        XCTAssertEqual(model.tiles.map(\.entry.name), ["advent_wreath.png"])
        model.filter = .video
        model.query = ""
        model.selection = .all
        XCTAssertEqual(model.tiles.map(\.entry.name), ["advent_candles.mov", "countdown.mov"])
        model.query = "zzz"
        XCTAssertEqual(model.emptyText, "Nothing found")

        let audio = AudioBinModel(studio: studio, audio: AudioState(), selection: .all, query: "walk")
        XCTAssertEqual(audio.tracks.map(\.entry.name), ["Walk-in loop"])
        XCTAssertEqual(audio.title, "Results for “walk”")
    }

    func testAudioBinListsTracksWithLengthAndTheSongsThatUseThem() async {
        await launch()
        let walkIn = studio.media.first { $0.name == "Walk-in loop" }!
        let song = studio.songs[0]
        var edited = song
        edited.audioTrackID = walkIn.id
        controller.updateSong(edited)
        let tracks = controller.addBinFolder(named: "Worship Tracks", in: .audio, parent: nil)!

        let model = AudioBinModel(studio: studio, audio: stage.state.audio, selection: .all)
        XCTAssertEqual(model.rows.map(\.name), ["All audio", "Worship Tracks"])
        XCTAssertEqual(model.rows.map(\.count), [3, 0])
        XCTAssertEqual(model.tracks.map(\.entry.name), ["Phones VO", "Walk-in loop", "Welcome VO"])
        XCTAssertEqual(model.tracks.map(\.duration), ["0:04", "3:00", "0:06"])
        XCTAssertEqual(model.tracks.first { $0.id == walkIn.id }?.usedLabel, "♪ \(song.title)")
        XCTAssertNil(model.tracks.first { $0.entry.name == "Welcome VO" }?.usedLabel)
        XCTAssertEqual(AudioBinModel(studio: studio, audio: AudioState(), selection: .folder(tracks)).emptyText, "This folder is empty")
        XCTAssertEqual(AudioBinModel.formatLine(walkIn, probe: nil, missing: true), "3:00 · file missing")
        XCTAssertEqual(AudioBinModel.formatLine(walkIn, probe: MediaProbe(sampleRate: 48_000, channels: 2), missing: false), "3:00 · 48 kHz stereo")
        XCTAssertEqual(AudioBinModel.formatLine(walkIn, probe: nil, missing: false), "3:00 · —", "a dash for what is not known")
    }

    // MARK: Folders

    func testNewFolderIsALibraryFolderOnly() async {
        await launch()
        let count = controller.studios.saveCount
        let before = try? snapshot(temp.appendingPathComponent("Documents"))
        let loops = controller.addBinFolder(named: "  Sunday Loops ", in: .media, parent: nil)
        XCTAssertNotNil(loops)
        XCTAssertNil(controller.addBinFolder(named: "  ", in: .media, parent: nil), "a name is needed")
        let advent = controller.addBinFolder(named: "Advent", in: .media, parent: loops)
        XCTAssertEqual(studio.binFolders.map(\.name), ["Sunday Loops", "Advent"])
        XCTAssertEqual(studio.binFolders.last?.parentID, loops)
        _ = advent
        let written = await saved(after: count)
        XCTAssertEqual(Set(written), ["bins.json", "manifest.json"], "only bins.json (and the manifest)")
        let after = try? snapshot(temp.appendingPathComponent("Documents"))
        XCTAssertEqual(Set(after?.keys.filter { !$0.contains(".stg/") } ?? []), Set(before?.keys.filter { !$0.contains(".stg/") } ?? []),
                       "no folder is made on disk")
    }

    // MARK: Add files: in place

    func testRegisteringAFileHashesItInPlaceAndTouchesNothing() async throws {
        await launch()
        let clip = try makeFile("easter_loop_a.mov", bytes: 3 * 1024 * 1024 + 17)
        let before = try snapshot(mediaFolder)
        var reported: [Double] = []
        let lock = NSLock()
        let entry = try await MediaRegistrar.entry(for: clip, kind: .video, machine: machine) { f in lock.withLock { reported.append(f) } }
        XCTAssertEqual(entry.sha256, try FileHasher.sha256(of: clip))
        XCTAssertEqual(entry.size, Int64(try XCTUnwrap(clip.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
        XCTAssertEqual(entry.lastKnownPath, clip.standardizedFileURL.path, "in place: the file's own path")
        XCTAssertEqual(entry.name, "easter_loop_a.mov")
        XCTAssertEqual(lock.withLock { reported.last }, 1, "hashing reports progress up to 100 %")
        XCTAssertEqual(try snapshot(mediaFolder), before, "nothing in the media folder changed")
        XCTAssertNotNil(HashCache.load(machine).entries.values.first { $0 == entry.sha256 }, "the hash is cached on this Mac")
    }

    func testAddFilesRegistersReadyFilesAndSkipsTheRest() async throws {
        await launch()
        let loops = controller.addBinFolder(named: "Sunday Loops", in: .media, parent: nil)!
        let clip = try makeFile("easter_intro.mp4")
        let photo = try makeFile("he_is_risen.png")
        let song = try makeFile("hymn.wav")
        let notes = try makeFile("notes.txt")
        let before = try snapshot(mediaFolder)

        let rows = [clip, photo, song, notes].map { AddFileRow.make($0, bin: .media, index: studio.media) }
        XCTAssertEqual(rows.map(\.statusText), ["Ready", "Ready", "Unsupported", "Unsupported"], "music never goes in the Media bin")
        XCTAssertEqual(AddFilesModel(rows: rows).footer.hasPrefix("2 files · "), true)
        XCTAssertTrue(AddFilesModel(rows: rows).canAdd)

        let count = controller.studios.saveCount
        controller.media.startAdding(rows, bin: .media, folder: loops, studios: controller)
        await waitForJob()
        let job = try XCTUnwrap(controller.media.job)
        XCTAssertEqual(job.rows.map(\.statusText), ["Done", "Done", "Unsupported", "Unsupported"])
        XCTAssertEqual(job.rows.map(\.progressText), ["Done", "Done", "Skipped", "Skipped"], "the board's progress wording")
        XCTAssertEqual(AddProgressModel(rows: job.rows, isFinished: true).footer, "2 added · 2 skipped")
        XCTAssertEqual(AddProgressModel(rows: job.rows, isFinished: true).title, "Adding 2 files")
        let added = studio.media.filter { job.added.contains($0.id) }
        XCTAssertEqual(added.map(\.name).sorted(), ["easter_intro.mp4", "he_is_risen.png"])
        XCTAssertTrue(added.allSatisfy { $0.folderID == loops && $0.sha256 != nil && $0.lastKnownPath?.hasPrefix(mediaFolder.path) == true })
        XCTAssertEqual(added.first { $0.name == "he_is_risen.png" }?.kind, .image)
        XCTAssertEqual(try snapshot(mediaFolder), before, "no file copied, moved, written or deleted")

        _ = await saved(after: count)
        XCTAssertEqual(Set(try onDisk().media.map(\.id)).isSuperset(of: added.map(\.id)), true, "autosaved to media.json")
        await until("the engine reloads with them") { [self] in
            controller.catalog.get(studio.id)?.library.media.contains { $0.id == added[0].id } == true
        }

        // The same files again: already in the library, nothing added twice.
        let again = [clip, photo].map { AddFileRow.make($0, bin: .media, index: studio.media) }
        XCTAssertEqual(again.map(\.statusText), ["Already in library", "Already in library"])
        XCTAssertFalse(AddFilesModel(rows: again).canAdd)
        let copy = try makeFile("intro_copy.mp4", in: temp.appendingPathComponent("Elsewhere"))
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: clip, to: copy)
        controller.media.startAdding([AddFileRow.make(copy, bin: .media, index: studio.media)], bin: .media, folder: nil, studios: controller)
        await waitForJob()
        XCTAssertEqual(controller.media.job?.rows.map(\.statusText), ["Already in library"], "the same bytes elsewhere: found by hash")
        XCTAssertEqual(studio.media.filter { $0.name.hasSuffix(".mp4") }.count, 1)
    }

    func testAudioFilesGoToTheAudioBinWithTheirLength() async throws {
        await launch()
        let wav = try makeWAV("track_01_opening.wav", seconds: 1.5)
        let tracks = controller.addBinFolder(named: "Worship Tracks", in: .audio, parent: nil)!
        let rows = [AddFileRow.make(wav, bin: .audio, index: studio.media), AddFileRow.make(try makeFile("loop.mov"), bin: .audio, index: studio.media)]
        XCTAssertEqual(rows.map(\.statusText), ["Ready", "Unsupported"], "video never goes in the Audio bin")
        controller.media.startAdding(rows, bin: .audio, folder: tracks, studios: controller)
        await waitForJob()
        let entry = try XCTUnwrap(studio.media.first { $0.name == "track_01_opening.wav" })
        XCTAssertEqual(entry.kind, .audio)
        XCTAssertEqual(entry.folderID, tracks)
        XCTAssertEqual(try XCTUnwrap(entry.duration), 1.5, accuracy: 0.01)
        XCTAssertEqual(AudioBinModel(studio: studio, audio: AudioState(), selection: .folder(tracks)).tracks.map(\.duration), ["0:02"])
    }

    // MARK: Link a folder

    func testLinkAFolderAddsItToThisMacAndRegistersItsVideoAndPhotosInPlace() async throws {
        await launch()
        try makeFile("loop_blue_01.mov")
        try makeFile("welcome.png")
        try makeFile("hymn.wav")
        try makeFile("deep.mov", in: mediaFolder.appendingPathComponent("Sub"))
        let before = try snapshot(mediaFolder)

        let shallow = try MediaFolderListing.files(in: mediaFolder, includeSubfolders: false, kinds: [.video, .image])
        let deep = try MediaFolderListing.files(in: mediaFolder, includeSubfolders: true, kinds: [.video, .image])
        XCTAssertEqual(shallow.map(\.url.lastPathComponent), ["loop_blue_01.mov", "welcome.png"])
        XCTAssertEqual(deep.map(\.url.lastPathComponent), ["loop_blue_01.mov", "deep.mov", "welcome.png"])
        XCTAssertTrue(MediaFolderListing.summary(deep).hasPrefix("2 videos · 1 photo · "), MediaFolderListing.summary(deep))

        var link = LinkFolderModel()
        XCTAssertFalse(link.canLink)
        link.choose(mediaFolder)
        XCTAssertEqual(link.name, "Easter", "named after the folder")
        XCTAssertTrue(link.canLink)

        let id = try XCTUnwrap(controller.linkFolder(mediaFolder, name: link.trimmedName))
        XCTAssertEqual(MediaFolders(paths: machine).load().map(\.standardizedFileURL.path), [mediaFolder.standardizedFileURL.path],
                       "the folder joins this Mac's media folders")
        let folder = try XCTUnwrap(studio.binFolders.first { $0.id == id })
        XCTAssertEqual(folder.bin, .media)
        XCTAssertEqual(folder.linkedPath, mediaFolder.standardizedFileURL.path)
        XCTAssertTrue(controller.isLinkedHere(folder.linkedPath))
        let model = MediaBinModel(studio: studio, selection: .folder(id), isLinkedHere: { [controller] in controller!.isLinkedHere($0) })
        XCTAssertEqual(model.linkedPath, folder.linkedPath)
        XCTAssertTrue(model.linkedHere)

        controller.media.startAdding(deep.map { AddFileRow.make($0.url, bin: .media, index: studio.media) }, bin: .media, folder: id, studios: controller)
        await waitForJob()
        XCTAssertEqual(BinListing(studio: studio, bin: .media).items(in: .folder(id)).map(\.name), ["deep.mov", "loop_blue_01.mov", "welcome.png"])
        XCTAssertEqual(try snapshot(mediaFolder), before, "linking reads the folder only")

        controller.unlinkFolder(id)
        XCTAssertNil(studio.binFolders.first { $0.id == id }?.linkedPath)
        XCTAssertEqual(BinListing(studio: studio, bin: .media).items(in: .folder(id)).count, 3, "unlinking keeps the items")
        XCTAssertEqual(MediaFolders(paths: machine).load().count, 1, "and this Mac's media folder list (other Studios may use it)")
        XCTAssertEqual(try snapshot(mediaFolder), before)
    }

    // MARK: Missing files

    func testMissingFilesAreFoundOffTheMainThreadAndShown() async throws {
        await launch()
        let here = try makeFile("here.mov")
        let present = MediaIndexEntry(id: UUID(), name: "here.mov", kind: .video, lastKnownPath: here.path)
        let gone = MediaIndexEntry(id: UUID(), name: "gone.mov", kind: .video, lastKnownPath: mediaFolder.appendingPathComponent("gone.mov").path)
        let relative = MediaIndexEntry(id: UUID(), name: "rel.mov", kind: .video, lastKnownPath: "Video/rel.mov")
        XCTAssertEqual(MediaLibrary.missingIDs([(present.id, present.lastKnownPath), (gone.id, gone.lastKnownPath), (relative.id, relative.lastKnownPath),
                                                (UUID(), nil)]).count, 3, "gone, relative and pathless are missing")

        controller.registerMedia([present, gone], into: nil)
        await until("the check runs") { [self] in controller.media.missing.contains(gone.id) }
        XCTAssertFalse(controller.media.missing.contains(present.id))
        let model = MediaBinModel(studio: studio, selection: .all,
                                  isMissing: { [controller] in controller!.media.isMissing($0, relink: controller!.relinkReport) })
        XCTAssertEqual(model.tiles.map(\.isMissing), [true, false], "gone.mov, here.mov")
        XCTAssertEqual(model.meta(gone), "Video · — · No folder · file missing")
        XCTAssertEqual(MediaBinModel.missingLabel, "⚠ Missing", "the service list's warning")

        var report = RelinkReport()
        report.statuses[present.id] = .missing
        XCTAssertTrue(controller.media.isMissing(present.id, relink: report), "a relink scan's missing counts too")
    }

    // MARK: Audio settings

    func testInspectorValuesRoundTripThroughTheStudioAndReachTheEngine() async throws {
        await launch()
        let welcome = studio.media.first { $0.name == "Welcome VO" }!
        XCTAssertNil(studio.audioSettings[welcome.id], "no settings stored yet")
        let count = controller.studios.saveCount
        let next = AudioInspector.setting(studio.audioSettings(for: welcome.id), volume: -6, fadeIn: 0.5, fadeOut: 3)
        controller.setAudioSettings(next)
        XCTAssertEqual(studio.audioSettings[welcome.id]?.levelDB, -6)
        let written = await saved(after: count)
        XCTAssertEqual(Set(written), ["audio.json", "manifest.json"], "only audio.json (and the manifest)")
        XCTAssertEqual(try onDisk().audioSettings[welcome.id], next)
        await until("the engine reloads") { [self] in controller.catalog.get(studio.id)?.library.audioSettings[welcome.id] == next }

        let walkIn = studio.media.first { $0.name == "Walk-in loop" }!
        let kept = studio.audioSettings[walkIn.id]!
        controller.setAudioSettings(AudioInspector.setting(kept, fadeOut: 5))
        XCTAssertEqual(studio.audioSettings[walkIn.id]?.triggers, kept.triggers, "triggers and trims are kept")
        XCTAssertEqual(studio.audioSettings[walkIn.id]?.trimIn, kept.trimIn)
        XCTAssertEqual(studio.audioSettings[walkIn.id]?.fadeOut, 5)

        controller.setAudioSettings(AudioSettings(mediaID: UUID(), levelDB: -1))
        XCTAssertEqual(studio.audioSettings.count, 2, "no settings for media that is not in the index")
    }

    func testInspectorKeepsValuesToTheAudioSpec() {
        XCTAssertEqual(AudioInspector.clampVolume(-80), -60)
        XCTAssertEqual(AudioInspector.clampVolume(6), 0, "the level only turns down")
        XCTAssertEqual(AudioInspector.clampVolume(-6.04), -6)
        XCTAssertEqual(AudioInspector.volumeText(-6), "-6 dB")
        XCTAssertEqual(AudioInspector.volumeText(-4.5), "-4.5 dB")
        XCTAssertEqual(AudioInspector.clampFade(0), 0, "a cut")
        XCTAssertEqual(AudioInspector.clampFade(-1), 0)
        XCTAssertEqual(AudioInspector.clampFade(0.02), 0.1, "stored fades are 100 ms at least")
        XCTAssertEqual(AudioInspector.clampFade(25), 10)
        XCTAssertEqual(AudioInspector.fadeText(0.5), "0.5 s")
        XCTAssertEqual(AudioInspector.fadeText(3), "3 s")
        XCTAssertEqual(AudioInspector.parseSeconds("2,5 s"), 2.5)
        XCTAssertNil(AudioInspector.parseSeconds("soon"))
    }

    // MARK: Waveform and format: real data

    func testWaveformPeaksAndFormatComeFromTheFile() async throws {
        let wav = try makeWAV("tone.wav", seconds: 2, amplitude: 0.5)
        let peaks = try WaveformPeaks.read(wav, bars: 40)
        XCTAssertEqual(peaks.count, 40)
        XCTAssertTrue(peaks.allSatisfy { abs($0 - 0.5) < 0.02 }, "\(peaks)")
        let silent = try WaveformPeaks.read(try makeWAV("silence.wav", seconds: 1, amplitude: 0), bars: 10)
        XCTAssertEqual(silent, Array(repeating: 0, count: 10))
        let probe = await MediaProbe.read(wav, kind: .audio)
        XCTAssertEqual(probe.sampleRate, 48_000)
        XCTAssertEqual(probe.channels, 2)
        XCTAssertEqual(try XCTUnwrap(probe.duration), 2, accuracy: 0.001)
        XCTAssertEqual(probe.metaLine(kind: .audio), "0:02 · 48 kHz stereo")
        XCTAssertEqual(MediaProbe(pixelWidth: 1920, pixelHeight: 1080, frameRate: 29.97).metaLine(kind: .video), "1920x1080 · 29.97 fps")
        XCTAssertEqual(MediaProbe().metaLine(kind: .video), "—")
    }

    // MARK: Play

    func testPlayButtonSendsPlayAudioThenPauseAndResume() async {
        await launch()
        let welcome = studio.media.first { $0.name == "Welcome VO" }!
        let other = studio.media.first { $0.name == "Phones VO" }!
        XCTAssertEqual(AudioBinModel.playCommand(welcome.id, stage.state.audio), .playAudio(mediaID: welcome.id, options: AudioPlayOptions()))
        stage.send(AudioBinModel.playCommand(welcome.id, stage.state.audio))
        await until("it plays") { [self] in stage.state.audio.liveTrack == welcome.id && stage.state.audio.transport == .playing }
        XCTAssertEqual(AudioBinModel(studio: studio, audio: stage.state.audio, selection: .all).tracks.first { $0.id == welcome.id }?.play, .playing)
        XCTAssertEqual(AudioBinModel.playCommand(welcome.id, stage.state.audio), .pauseAudio)
        XCTAssertEqual(AudioBinModel.playCommand(other.id, stage.state.audio), .playAudio(mediaID: other.id, options: AudioPlayOptions()),
                       "another track starts with its own stored settings")
        stage.send(.pauseAudio)
        await until("paused") { [self] in stage.state.audio.transport == .paused }
        XCTAssertEqual(AudioBinModel.playCommand(welcome.id, stage.state.audio), .resumeAudio)
        stage.send(.stopAudio)
    }

    // MARK: Into the service

    func testDoubleClickOrDragAddsAMediaRowToTheService() async throws {
        await launch()
        let clip = MediaIndexEntry(id: UUID(), name: "countdown_5min.mov", kind: .video, duration: 300, lastKnownPath: "/x/countdown_5min.mov")
        controller.registerMedia([clip], into: nil)
        let count = controller.studios.saveCount
        let rows = service.items.count
        let id = try XCTUnwrap(controller.addMediaToService(clip.id))
        XCTAssertEqual(service.items.count, rows + 1)
        XCTAssertEqual(service.items.last?.id, id)
        XCTAssertEqual(service.items.last?.content, .media(clip.id))
        XCTAssertEqual(service.items.last?.title, "countdown_5min.mov")
        XCTAssertTrue(studio.collections.allSatisfy { $0.name != "countdown_5min.mov" }, "media is never a collection")
        let written = await saved(after: count)
        XCTAssertTrue(written.contains("services/\(service.id.uuidString).json"))
        await until("the engine has the row") { [self] in stage.state.service?.items.contains { $0.id == id } == true }
        let list = ServiceListModel(state: stage.state, studio: studio, relink: nil)
        XCTAssertEqual(list.rows.last?.title, "countdown_5min.mov")
        XCTAssertEqual(list.rows.last?.meta, "5:00")

        XCTAssertEqual(MediaDrag.id(from: MediaDrag.payload(clip.id)), clip.id, "the drag payload")
        XCTAssertNil(MediaDrag.id(from: "Amazing Grace"), "other text is not a bin item")
        XCTAssertNil(controller.addMediaToService(UUID()))
    }

    // MARK: Disabled controls, dialogs and keys

    func testControlsWithNothingBehindThemAreDisabledWithAReason() {
        let reasons = [BinHelp.mediaType, BinHelp.composition, BinHelp.layer, BinHelp.mediaEnd, BinHelp.goLive, BinHelp.audioEnd,
                       BinHelp.addToSlide, BinHelp.addToTimeline, BinHelp.playlists, BinHelp.copyIntoLibrary, BinHelp.optimize, BinHelp.watch,
                       BinHelp.preview]
        XCTAssertTrue(reasons.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(reasons).count, reasons.count)
        // The board's wording.
        XCTAssertEqual(MediaBinModel.addItems, ["New folder", "Add files…", "Link a folder…"])
        XCTAssertEqual(AddFilesModel.storageOptions, ["Copy into library", "Keep in place"])
        XCTAssertEqual(AddFilesModel.formatOptions, ["Optimize", "Keep original"])
        XCTAssertEqual(LinkFolderModel.options, ["Watch for changes", "Include subfolders", "Optimize new files automatically"])
        XCTAssertEqual(AudioBinModel.endOptions, ["↻ Loop", "■ Stop", "⏭ Next"])
        XCTAssertEqual(AddProgressModel.backgroundTitle, "Run in background")
        XCTAssertEqual(NewBinFolderModel.parentChoices(BinListing(studio: nil, bin: .media)).map(\.title), ["Top level"])
        var folder = NewBinFolderModel()
        XCTAssertFalse(folder.canCreate)
        folder.name = " Easter "
        XCTAssertEqual(folder.trimmedName, "Easter")
        XCTAssertTrue(folder.canCreate)
        // AudioSettings has no end action: all three choices stay off, not just Next.
        let fields = Mirror(reflecting: AudioSettings(mediaID: UUID())).children.compactMap(\.label)
        XCTAssertFalse(fields.contains { $0.lowercased().contains("end") }, "\(fields)")
    }

    func testBinDialogsCountAsModalAndAddNoUnmodifiedShortcut() {
        let ui = OperatorUIState()
        XCTAssertFalse(ui.isModalOpen)
        for dialog: BinDialog in [.newFolder(.media), .addFiles(.audio, [], folder: nil), .progress, .linkFolder(nil)] {
            ui.binDialog = dialog
            XCTAssertTrue(ui.isModalOpen, "\(dialog): Return and the arrows stay away from the show")
        }
        XCTAssertEqual(Shortcuts.unmodified.count, 3, "Return, Left and Right only")
        XCTAssertEqual(Shortcuts.tab(.media), KeyboardShortcut("2", modifiers: .command))
        XCTAssertEqual(Shortcuts.tab(.audio), KeyboardShortcut("4", modifiers: .command))
        XCTAssertTrue(BottomTab.media.isEnabled && BottomTab.audio.isEnabled)
    }
}
