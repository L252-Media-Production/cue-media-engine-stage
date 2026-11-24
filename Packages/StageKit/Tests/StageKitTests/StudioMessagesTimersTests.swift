import XCTest
@testable import StageKit

/// Messages and timers in a Studio (`messages.json`, `timers.json`, part of format 1 since the Studio was introduced),
/// and how the mock treats a message edited while it is visible.
final class StudioMessagesTimersTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000.123)

    func sample() -> Studio { Studio(seededFrom: .sample, name: "Studio", now: now, appVersion: "0.1") }

    func testMessagesAndTimersRoundTrip() throws {
        var studio = sample()
        studio.messages = [Message(text: "Please be seated"), Message(text: "Nursery pick-up: Room 3")]
        studio.timers = [
            StageTimer(name: "Countdown", mode: .countdown, duration: 300),
            StageTimer(name: "Service clock", mode: .countUp),
        ]
        let decoded = try StudioCodec.decode(try StudioCodec.encode(studio))
        XCTAssertEqual(decoded.messages, studio.messages)
        XCTAssertEqual(decoded.timers, studio.timers)
        XCTAssertEqual(decoded, studio.normalized())
    }

    /// A Studio saved before the message and timer editors existed reads and saves back to the same bytes.
    func testAnOlderStudioSavesBackByteForByte() throws {
        let original = try StudioCodec.encode(sample())
        let studio = try StudioCodec.decode(original)
        XCTAssertEqual(try StudioCodec.encode(studio), original)
    }

    func testEmptyListsStillReadAndSaveTheSame() throws {
        var studio = sample()
        studio.messages = []
        studio.timers = []
        let files = try StudioCodec.encode(studio)
        XCTAssertEqual(String(decoding: files["messages.json"]!, as: UTF8.self), "[\n\n]")
        XCTAssertEqual(try StudioCodec.encode(try StudioCodec.decode(files)), files)
    }

    func testEditingAMessageChangesOnlyMessagesJSON() throws {
        var studio = sample()
        let before = try StudioCodec.encode(studio)
        studio.messages[0].text = "Changed"
        let after = try StudioCodec.encode(studio)
        XCTAssertEqual(after.keys.filter { after[$0] != before[$0] }, ["messages.json"])
        studio.timers[0].duration = 600
        let third = try StudioCodec.encode(studio)
        XCTAssertEqual(third.keys.filter { third[$0] != after[$0] }, ["timers.json"])
    }

    // MARK: The mock and a message edited while visible

    func testEditingAVisibleMessageKeepsTheShownTextUntilShownAgain() async throws {
        var studio = sample()
        let id = studio.messages[0].id
        let info = StudioInfo(id: studio.id, name: studio.name)
        final class Box: @unchecked Sendable { var library: Library; init(_ l: Library) { library = l } }
        let box = Box(studio.library())
        let client = MockStageClient(library: .empty, studioSource: { requested in
            requested == info.id ? .init(info: info, library: box.library, assignments: []) : nil
        })
        await client.send(.openStudio(info.id))
        await client.send(.showMessage(id, screens: []))
        let shown = studio.messages[0].text

        studio.messages[0].text = "Edited while showing"
        studio.messages.append(Message(text: "Brand new"))
        box.library = studio.library()
        await client.send(.reloadStudio(info.id))
        var state = await client.currentState
        XCTAssertEqual(state.visibleMessages, [id])
        XCTAssertEqual(state.messages.first { $0.id == id }?.text, shown, "the audience still sees the shown text")
        XCTAssertTrue(state.messages.contains { $0.text == "Brand new" }, "a hidden message takes the new content at once")

        await client.send(.showMessage(id, screens: []))
        state = await client.currentState
        XCTAssertEqual(state.messages.first { $0.id == id }?.text, "Edited while showing", "showing it again takes the edit")

        studio.messages[0].text = "Edited again"
        box.library = studio.library()
        await client.send(.reloadStudio(info.id))
        await client.send(.hideMessage(id))
        state = await client.currentState
        XCTAssertEqual(state.messages.first { $0.id == id }?.text, "Edited again", "hiding it takes the saved version")
    }

    func testClearMessagesAlsoDropsTheShownVersions() async throws {
        var studio = sample()
        let id = studio.messages[0].id
        let info = StudioInfo(id: studio.id, name: studio.name)
        final class Box: @unchecked Sendable { var library: Library; init(_ l: Library) { library = l } }
        let box = Box(studio.library())
        let client = MockStageClient(library: .empty, studioSource: { requested in
            requested == info.id ? .init(info: info, library: box.library, assignments: []) : nil
        })
        await client.send(.openStudio(info.id))
        await client.send(.showMessage(id, screens: []))
        studio.messages[0].text = "Edited"
        box.library = studio.library()
        await client.send(.reloadStudio(info.id))
        await client.send(.clear(.messages))
        let state = await client.currentState
        XCTAssertEqual(state.visibleMessages, [])
        XCTAssertEqual(state.messages.map(\.text), ["Edited"])
    }

    func testAVisibleMessageDeletedFromTheStudioStaysUntilHidden() async throws {
        var studio = sample()
        let id = studio.messages[0].id
        let info = StudioInfo(id: studio.id, name: studio.name)
        final class Box: @unchecked Sendable { var library: Library; init(_ l: Library) { library = l } }
        let box = Box(studio.library())
        let client = MockStageClient(library: .empty, studioSource: { requested in
            requested == info.id ? .init(info: info, library: box.library, assignments: []) : nil
        })
        await client.send(.openStudio(info.id))
        await client.send(.showMessage(id, screens: []))
        studio.messages = []
        box.library = studio.library()
        await client.send(.reloadStudio(info.id))
        var state = await client.currentState
        XCTAssertEqual(state.messages.map(\.id), [id], "still on air")
        await client.send(.hideMessage(id))
        state = await client.currentState
        XCTAssertEqual(state.messages, [])
    }
}
