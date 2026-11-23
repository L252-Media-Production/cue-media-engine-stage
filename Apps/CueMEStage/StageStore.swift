import Foundation
import Observation
import StageKit

/// The UI's single bridge to an engine. Views read `state` and call `send(_:)`; they never see the client.
///
/// Commands go through one serial pump so they reach the client in the order they were sent
/// (separate `Task`s per command could reorder Go and Next).
@MainActor
@Observable
final class StageStore {
    private(set) var state = StageState()
    private(set) var lastEvent: StageEvent?

    @ObservationIgnored private let client: any StageClient
    @ObservationIgnored private let outbox: AsyncStream<Command>.Continuation
    /// Called with every new snapshot (the Studio controller keeps the Studio and the machine in step with it).
    @ObservationIgnored var onState: ((StageState) -> Void)?

    init(client: any StageClient) {
        self.client = client
        let (commands, outbox) = AsyncStream.makeStream(of: Command.self)
        self.outbox = outbox

        Task {
            for await command in commands { await client.send(command) }
        }
        Task { [weak self] in
            for await snapshot in await client.states() {
                self?.state = snapshot
                self?.onState?(snapshot)
            }
        }
        Task { [weak self] in
            for await event in await client.events() { self?.lastEvent = event }
        }
    }

    func send(_ command: Command) {
        outbox.yield(command)
    }

    /// A store on the mock engine with its fake telemetry running.
    static func mock(library: Library = .sample, studios: StudioCatalog? = nil) -> StageStore {
        let client = MockStageClient(library: library, studioSource: studios?.source)
        Task { await client.startTelemetry() }
        return StageStore(client: client)
    }
}

extension StageState {
    func item(_ id: Item.ID?) -> Item? {
        guard let id else { return nil }
        return service?.items.first { $0.id == id }
    }

    /// Display name of a media item, from the service entry that plays it.
    func mediaTitle(_ id: MediaItem.ID?) -> String? {
        guard let id else { return nil }
        return service?.items.first { $0.content == .media(id) }?.title
    }
}
