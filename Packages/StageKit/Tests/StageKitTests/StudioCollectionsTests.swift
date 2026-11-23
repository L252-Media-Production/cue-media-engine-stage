import XCTest
@testable import StageKit

/// Collections (collections.json) and service sections (`sections` in a service file): additive and optional.
final class StudioCollectionsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)

    func sample() -> Studio { Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1") }

    func testAStudioWithoutCollectionsOrSectionsWritesBackByteForByte() throws {
        let files = try StudioCodec.encode(sample())
        XCTAssertNil(files["collections.json"], "no collections.json until there is a collection")
        for (path, data) in files where path.hasPrefix("services/") {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sections"), path)
        }
        let again = try StudioCodec.encode(try StudioCodec.decode(files))
        XCTAssertEqual(again, files)
    }

    func testAServiceFileWithoutSectionsIsExactlyTheService() throws {
        let studio = sample()
        let service = studio.services[0]
        let files = try StudioCodec.encode(studio)
        XCTAssertEqual(files["services/\(service.id.uuidString).json"], try StudioCodec.makeEncoder().encode(service))
    }

    func testCollectionsAndSectionsRoundTrip() throws {
        var studio = sample()
        let worship = StudioCollection(name: "Worship Songs")
        studio.collections = [worship, StudioCollection(name: "Kids Songs")]
        studio.songs[0].collectionID = worship.id
        let service = studio.services[0]
        studio.setSections([
            ServiceSection(name: "Pre-service", firstItemID: service.items[0].id),
            ServiceSection(name: "Worship", firstItemID: service.items[1].id),
            ServiceSection(name: "Offering"),
        ], of: service.id)

        let files = try StudioCodec.encode(studio)
        XCTAssertNotNil(files["collections.json"])
        XCTAssertTrue(StudioCodec.isShowDataPath("collections.json"))
        let serviceJSON = String(decoding: files["services/\(service.id.uuidString).json"]!, as: UTF8.self)
        XCTAssertTrue(serviceJSON.contains("\"sections\""), serviceJSON)
        XCTAssertTrue(serviceJSON.contains("\"items\""), "the service itself is still there")

        let back = try StudioCodec.decode(files)
        XCTAssertEqual(back, studio.normalized())
        XCTAssertEqual(back.collections.map(\.name), ["Worship Songs", "Kids Songs"], "collections keep their order")
        XCTAssertEqual(back.sections(of: service.id).map(\.name), ["Pre-service", "Worship", "Offering"])
        XCTAssertEqual(back.validationIssues(), [])
        // The engine-facing service has no sections: items and their order are untouched.
        XCTAssertEqual(back.library().service.items, service.items)
    }

    func testOldFilesWithoutTheNewKeysStillDecode() throws {
        // A song file and a service file as UI-3a wrote them.
        var files = try StudioCodec.encode(sample())
        let song = sample().songs[0]
        files["library/\(song.id.uuidString).json"] = Data("""
        { "kind" : "song", "song" : { "id" : "\(song.id.uuidString)", "slides" : [], "title" : "Old" } }
        """.utf8)
        let studio = try StudioCodec.decode(files)
        let old = try XCTUnwrap(studio.songs.first { $0.id == song.id })
        XCTAssertNil(old.collectionID)
        XCTAssertEqual(studio.collections, [])
        XCTAssertEqual(studio.sections, [:])
    }

    func testRemovingTheLastSectionOrCollectionRemovesTheKeyOrFile() throws {
        var studio = sample()
        let original = try StudioCodec.encode(studio)
        let service = studio.services[0]
        studio.collections = [StudioCollection(name: "Hymns")]
        studio.setSections([ServiceSection(name: "Closing")], of: service.id)
        XCTAssertNotEqual(try StudioCodec.encode(studio), original)
        studio.collections = []
        studio.setSections([], of: service.id)
        XCTAssertNil(studio.sections[service.id])
        XCTAssertEqual(try StudioCodec.encode(studio), original, "back to the bytes it started with")
    }

    func testValidationReportsAnUnknownCollectionAndSectionsOfAnUnknownService() {
        var studio = sample()
        studio.songs[0].collectionID = UUID()
        studio.sections[UUID()] = [ServiceSection(name: "Lost")]
        let issues = studio.validationIssues()
        XCTAssertTrue(issues.contains { $0.contains("unknown collection") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("sections for unknown service") }, "\(issues)")
    }
}
