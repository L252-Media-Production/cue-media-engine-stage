import Foundation

/// The only way the UI talks to an engine. A real client (local IPC to StageEngine) and the mock both conform.
///
/// Each call to `states()` / `events()` returns a new stream for one subscriber. `states()` yields the current
/// snapshot first, then every change.
public protocol StageClient: Sendable {
    func send(_ command: Command) async
    func states() async -> AsyncStream<StageState>
    func events() async -> AsyncStream<StageEvent>
    var currentState: StageState { get async }
}
