import XCTest
@testable import StageKit

/// The Song editor's model: optional song fields, groups, lyrics as text, lines per slide, capitalization.
final class SongLyricsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)
    var amazing: Song { Library.sample.songs[0] }

    // MARK: Fields

    func testASongWithoutTheNewFieldsWritesBackByteForByte() throws {
        let studio = Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1")
        let files = try StudioCodec.encode(studio)
        let song = String(decoding: files["library/\(amazing.id.uuidString).json"]!, as: UTF8.self)
        for key in ["copyright", "ccliNumber", "key", "tempo", "collectionID", "groups", "linesPerSlide", "capitalization",
                    "audioTrackID", "backgroundID"] {
            XCTAssertFalse(song.contains("\"\(key)\""), "\(key) is left out while nil")
        }
        XCTAssertEqual(try StudioCodec.encode(try StudioCodec.decode(files)), files)
    }

    func testEveryNewFieldRoundTrips() throws {
        var studio = Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1")
        let collection = StudioCollection(name: "Worship Songs")
        studio.collections = [collection]
        var song = SongLyrics.materialized(studio.songs[0])
        song.copyright = "Public domain"
        song.ccliNumber = "22025"
        song.key = "G"
        song.tempo = 72
        song.collectionID = collection.id
        song.linesPerSlide = 2
        song.capitalization = .allCaps
        song.audioTrackID = studio.media[0].id
        song.backgroundID = studio.media[1].id
        studio.songs[0] = song

        let back = try StudioCodec.decode(try StudioCodec.encode(studio))
        XCTAssertEqual(back.songs.first { $0.id == song.id }, song)
        XCTAssertEqual(back.validationIssues(), [])
    }

    func testValidationCatchesBadSongReferences() {
        var studio = Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1")
        studio.songs[0].audioTrackID = UUID()
        studio.songs[0].groups = [SongGroup(name: "Lost", color: "#000000", slideIDs: [UUID()])]
        let issues = studio.validationIssues()
        XCTAssertTrue(issues.contains { $0.contains("unknown media as its audio track") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("group Lost has an unknown slide") }, "\(issues)")
    }

    func testASongsMediaTravelsWithItInAnItemFile() throws {
        var song = amazing
        let media = Library.sample.media
        song.audioTrackID = media[0].id
        XCTAssertEqual(StudioItemPayload.song(song).mediaIDs, [media[0].id])
        XCTAssertEqual(StudioItemPayload.song(amazing).mediaIDs, [])
    }

    // MARK: Groups

    func testGroupsAreDerivedFromLabelsUntilStored() {
        let groups = SongLyrics.groups(of: amazing)
        XCTAssertEqual(groups.map(\.name), ["Verse 1", "Verse 2", "Verse 3"])
        XCTAssertEqual(groups.map(\.id), amazing.slides.map(\.id), "stable: a derived group is named after its first slide")
        XCTAssertEqual(groups.map(\.color), Array(SongLyrics.palette.prefix(3)))
        XCTAssertNil(amazing.groups)
        XCTAssertEqual(SongLyrics.materialized(amazing).groups, groups)

        var repeated = amazing
        repeated.slides[2].label = "Verse 1"
        XCTAssertEqual(SongLyrics.groups(of: repeated).first?.slideIDs, [amazing.slides[0].id, amazing.slides[2].id], "one group per name")
    }

    // MARK: Text ↔ slides

    func testLyricsToTextAndBack() {
        let text = SongLyrics.text(of: amazing)
        XCTAssertEqual(text, """
        [Verse 1]
        Amazing grace, how sweet the sound
        That saved a wretch like me

        [Verse 2]
        'Twas grace that taught my heart to fear
        And grace my fears relieved

        [Verse 3]
        Through many dangers, toils and snares
        I have already come
        """)
        let back = SongLyrics.applying(text: text, to: amazing)
        XCTAssertEqual(back.slides, amazing.slides, "same text: same slides, ids and labels")
        XCTAssertEqual(back.groups, SongLyrics.groups(of: amazing), "the derived groups become real ones, unchanged")
        XCTAssertEqual(SongLyrics.text(of: back), text)
    }

    func testTypingUpdatesTheSlides() {
        let text = """
        [Verse 1]
        Amazing grace, how sweet the sound
        That saved a wretch like me

        I once was lost, but now am found
        Was blind, but now I see

        [chorus]
          My chains are gone
        [Verse 1]
        Again
        """
        let song = SongLyrics.applying(text: text, to: amazing)
        XCTAssertEqual(song.slides.map(\.lines), [
            ["Amazing grace, how sweet the sound", "That saved a wretch like me"],
            ["I once was lost, but now am found", "Was blind, but now I see"],
            ["My chains are gone"],
            ["Again"],
        ], "a blank line or a heading ends a slide; lines are trimmed")
        XCTAssertEqual(song.slides.map(\.label), ["Verse 1", "Verse 1", "chorus", "Verse 1"])
        XCTAssertEqual(Array(song.slides.prefix(3).map(\.id)), amazing.slides.map(\.id), "ids kept by position")
        let groups = song.groups ?? []
        XCTAssertEqual(groups.map(\.name), ["Verse 1", "chorus"], "a heading used again is the same group")
        XCTAssertEqual(groups[0].id, amazing.slides[0].id, "the existing group keeps its id ...")
        XCTAssertEqual(groups[0].color, SongLyrics.palette[0], "... and colour")
        XCTAssertEqual(groups[0].slideIDs, [song.slides[0].id, song.slides[1].id, song.slides[3].id])
        XCTAssertEqual(groups[1].color, SongLyrics.palette[3], "a new group takes the next free colour (Verse 2 and 3 had 1 and 2)")
    }

    func testAHeadingWithoutLinesMakesNoGroupAndLinesBeforeAnyHeadingAreUngrouped() {
        let song = SongLyrics.applying(text: "Intro line\n\n[Bridge]\n", to: Song(title: "New", slides: []))
        XCTAssertEqual(song.slides.map(\.lines), [["Intro line"]])
        XCTAssertEqual(song.slides.map(\.label), [""])
        XCTAssertEqual(song.groups, [])
        XCTAssertEqual(SongLyrics.text(of: song), "Intro line")
    }

    func testAnOwnSlideLabelIsKeptWhileTheSlideStaysInItsGroup() {
        var song = SongLyrics.materialized(amazing)
        song.slides[0].label = "Opening"
        let edited = SongLyrics.applying(text: SongLyrics.text(of: song).replacingOccurrences(of: "sweet", with: "SWEET"), to: song)
        XCTAssertEqual(edited.slides[0].label, "Opening")
        XCTAssertEqual(edited.slides[0].lines[0], "Amazing grace, how SWEET the sound")
    }

    // MARK: Lines per slide

    func testLinesPerSlideSplitsTypedParagraphs() {
        var song = Song(title: "New", slides: [])
        song.linesPerSlide = 2
        let typed = SongLyrics.applying(text: "[Verse]\none\ntwo\nthree\nfour\nfive", to: song)
        XCTAssertEqual(typed.slides.map(\.lines), [["one", "two"], ["three", "four"], ["five"]])
        XCTAssertEqual(typed.groups?.first?.slideIDs.count, 3)
    }

    func testSettingLinesPerSlideResplitsEachGroup() {
        let one = SongLyrics.settingLinesPerSlide(1, of: amazing)
        XCTAssertEqual(one.linesPerSlide, 1)
        XCTAssertEqual(one.slides.count, 6)
        XCTAssertEqual(one.slides.map(\.label), ["Verse 1", "Verse 1", "Verse 2", "Verse 2", "Verse 3", "Verse 3"])
        let four = SongLyrics.settingLinesPerSlide(4, of: one)
        XCTAssertEqual(four.slides.map(\.lines.count), [2, 2, 2], "runs are joined again per group, never across groups")
        XCTAssertEqual(four.slides.map(\.lines), amazing.slides.map(\.lines))
        let off = SongLyrics.settingLinesPerSlide(nil, of: one)
        XCTAssertNil(off.linesPerSlide)
        XCTAssertEqual(off.slides, one.slides, "off: stored only, slides unchanged")
        XCTAssertEqual(SongLyrics.settingLinesPerSlide(0, of: amazing).linesPerSlide, 1, "at least one line")
    }

    // MARK: Capitalization

    func testCapitalization() {
        XCTAssertEqual(SongLyrics.capitalize("'Twas grace that taught", .allCaps), "'TWAS GRACE THAT TAUGHT")
        XCTAssertEqual(SongLyrics.capitalize("'TWAS Grace that TAUGHT", .sentenceCase), "'Twas grace that taught")
        XCTAssertEqual(SongLyrics.capitalize("Leave As Is", .none), "Leave As Is")
        XCTAssertEqual(SongLyrics.capitalize("", .sentenceCase), "")
    }

    func testCapitalizationIsAppliedForTheOutputsAndTheTextIsKept() {
        var studio = Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1")
        studio.songs[0].capitalization = .allCaps
        XCTAssertEqual(studio.songs[0].slides[0].lines[0], "Amazing grace, how sweet the sound", "the typed text is kept")
        let shown = studio.library().songs.first { $0.id == studio.songs[0].id }
        XCTAssertEqual(shown?.slides[0].lines[0], "AMAZING GRACE, HOW SWEET THE SOUND")
        studio.songs[0].capitalization = SongCapitalization.none
        XCTAssertEqual(studio.library().songs.first { $0.id == studio.songs[0].id }?.slides, studio.songs[0].slides)
    }
}
