import Foundation
import StageKit

/// The sheet's working copy: only the edits, laid over the live `StageState`. A screen nobody edited keeps
/// following the engine; Apply turns the edits into Commands, Revert drops them. Pure, so it is tested without UI.
struct OutputSetupDraft: Equatable {
    private(set) var setups: [Screen.ID: ScreenSetup] = [:]
    /// The inner nil is "unassign".
    private(set) var assignments: [Screen.ID: Connector.ID?] = [:]

    func setup(_ id: Screen.ID, in state: StageState) -> ScreenSetup? { setups[id] ?? state.screenSetups[id] }

    func connectorID(_ id: Screen.ID, in state: StageState) -> Connector.ID? {
        if let edited = assignments[id] { return edited }
        return state.connectorID(for: id)
    }

    /// An edit that matches the engine again is dropped, so it does not count as unapplied.
    mutating func set(_ setup: ScreenSetup, for id: Screen.ID, in state: StageState) {
        setups[id] = state.screenSetups[id] == setup ? nil : setup
    }

    mutating func assign(_ connector: Connector.ID?, to id: Screen.ID, in state: StageState) {
        if state.connectorID(for: id) == connector { assignments[id] = nil } else { assignments[id] = .some(connector) }
    }

    func hasEdits(in state: StageState) -> Bool { !commands(in: state).isEmpty }

    func effectiveAssignments(in state: StageState) -> [OutputAssignment] {
        state.assignments.map { OutputAssignment(screenID: $0.screenID, connectorID: connectorID($0.screenID, in: state)) }
    }

    func effectiveSetups(in state: StageState) -> [Screen.ID: ScreenSetup] { state.screenSetups.merging(setups) { $1 } }

    func warnings(in state: StageState) -> [OutputWarning] {
        outputWarnings(connectors: state.connectors, assignments: effectiveAssignments(in: state), screenSetups: effectiveSetups(in: state))
    }

    /// The Commands that make the engine match the draft, in an order the engine accepts: first every moved screen
    /// lets go of its connector (so two screens can swap), then the setups (a type change needs the screen
    /// unassigned), then the new assignments.
    func commands(in state: StageState) -> [Command] {
        let order = state.assignments.map(\.screenID)
        var release: [Command] = [], take: [Command] = []
        for id in order {
            guard let edited = assignments[id] else { continue }
            let old = state.connectorID(for: id)
            guard edited != old else { continue }
            if old != nil { release.append(.assignScreen(id, connector: nil)) }
            if let edited { take.append(.assignScreen(id, connector: edited)) }
        }
        let setupCommands: [Command] = order.compactMap { id in
            guard let setup = setups[id], setup != state.screenSetups[id] else { return nil }
            return .setScreenSetup(id, setup)
        }
        return release + setupCommands + take
    }

    /// The connectors the picker offers `screen`: available, of the right direction, and not used by another
    /// screen in the draft. Only ever taken from the engine's list.
    func connectorChoices(for screen: Screen.ID, in state: StageState) -> [Connector] {
        guard let type = setup(screen, in: state)?.type else { return [] }
        let taken = Set(effectiveAssignments(in: state).filter { $0.screenID != screen }.compactMap(\.connectorID))
        return state.connectors.filter { $0.available && $0.accepts(type) && !taken.contains($0.id) }
    }

    /// The screen the draft puts on `connector`, if any.
    func screen(on connector: Connector.ID, in state: StageState) -> ScreenState? {
        guard let id = effectiveAssignments(in: state).first(where: { $0.connectorID == connector })?.screenID else { return nil }
        return state.screens.first { $0.screenID == id }
    }

    /// One line per warning, naming the screens, connectors and cards.
    func warningTexts(in state: StageState) -> [String] {
        warnings(in: state).map { warning in
            switch warning {
            case let .canvasSpansCards(ids):
                let parts = ids.map { id -> String in
                    let c = state.connector(connectorID(id, in: state))
                    return "\(state.screenName(id)) on \(c?.cardName ?? "?") \(c?.label ?? "")"
                }
                var cards: [String] = []
                for id in ids { if let name = state.connector(connectorID(id, in: state))?.cardName, !cards.contains(name) { cards.append(name) } }
                return "The canvas spans \(cards.count) cards (\(cards.joined(separator: ", "))): \(parts.joined(separator: "; ")). "
                    + "All on-canvas screens must go out of one card, or they are not frame-locked."
            case let .canvasOnNonSDI(id):
                let label = state.connector(connectorID(id, in: state))?.label ?? "?"
                return "\(state.screenName(id)) is on the canvas but goes out of \(label), which is not synchronised to the SDI clock."
            case let .connectorUnavailable(id):
                let label = state.connector(connectorID(id, in: state))?.label ?? connectorID(id, in: state) ?? "?"
                return "\(state.screenName(id)): \(label) is not available."
            }
        }
    }
}

extension StageState {
    func screenName(_ id: Screen.ID) -> String { screens.first { $0.screenID == id }?.name ?? "Unknown screen" }
}

extension ScreenType {
    /// Section title in the screen list.
    var groupTitle: String {
        switch self {
        case .audience: "Audience"
        case .stage: "Stage"
        case .announcements: "Announcements"
        case .speaker: "Speaker displays"
        case .input: "Inputs"
        }
    }
}

extension Connector {
    /// "DeckLink Duo 2 (A) · SDI 1", or the label alone off a card.
    var pickerTitle: String { cardName.map { "\($0) · \(label)" } ?? label }
}

/// Tabs of the Output Setup sheet. Slices is shown but not available in v0.1.
enum OutputSetupTab: String, CaseIterable, Identifiable {
    case screens = "Screens"
    case slices = "Slices"

    var id: Self { self }
    var isEnabled: Bool { self == .screens }

    static func resolve(_ raw: String) -> OutputSetupTab {
        guard let tab = OutputSetupTab(rawValue: raw), tab.isEnabled else { return .screens }
        return tab
    }
}

/// Output > Test Pattern and the status-bar chip. Pure.
struct TestPatternMenuModel {
    let state: StageState

    /// "All Screens" then every output screen.
    var targets: [(title: String, target: TestPatternTarget)] {
        [("All Screens", .all)] + state.outputScreens.map { ($0.name, .screen($0.screenID)) }
    }

    func isActive(_ target: TestPatternTarget, _ pattern: TestPattern) -> Bool {
        state.testPattern == ActiveTestPattern(target: target, pattern: pattern)
    }

    /// Choosing the active entry again turns it off.
    func command(_ target: TestPatternTarget, _ pattern: TestPattern) -> Command {
        isActive(target, pattern) ? .hideTestPattern : .showTestPattern(target, pattern)
    }

    var canTurnOff: Bool { state.testPattern != nil }

    /// Tooltip of the status-bar chip, e.g. "Bars on all screens"; nil when no pattern runs.
    var description: String? {
        guard let active = state.testPattern else { return nil }
        let where_: String = switch active.target {
        case .all: "all screens"
        case let .screen(id): state.screenName(id)
        }
        return "\(active.pattern.title) on \(where_)"
    }

    /// The pattern a monitor of `screen` shows instead of live content, if any.
    func pattern(on screen: Screen.ID) -> TestPattern? {
        guard let active = state.testPattern, active.covers(screen) else { return nil }
        return active.pattern
    }
}

extension TestPattern {
    var title: String { self == .bars ? "Bars" : "Grid" }
}
