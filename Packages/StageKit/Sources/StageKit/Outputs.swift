import Foundation

// Output setup: the connectors the engine reports, which screen goes out of which connector, and how each screen
// sits on the canvas. The app never invents connectors; it only reads `StageState.connectors` and sends commands.

/// What a screen is for. Decides where it is listed in Output Setup and which connectors it may use.
public enum ScreenType: String, Codable, Sendable, Hashable, CaseIterable {
    case audience, stage, announcements, speaker, input

    /// Input screens take a signal in (IMAG); every other type sends one out.
    public var isInput: Bool { self == .input }
}

/// A physical or network connector as the engine reports it: a DeckLink SDI port, an NDI sender or receiver, or a
/// display. The list is the engine's; the app never edits it.
public struct Connector: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case sdiOut, sdiIn, ndiOut, ndiIn, display

        public var isInput: Bool { self == .sdiIn || self == .ndiIn }
        public var isSDI: Bool { self == .sdiOut || self == .sdiIn }
    }

    /// Stable engine id (for DeckLink, derived from the card's persistent id and the connector index).
    public var id: String
    public var kind: Kind
    /// Operator label, e.g. "SDI 1" or "NDI CueME Main".
    public var label: String
    /// The card the connector is on; nil for NDI and displays.
    public var cardID: String?
    public var cardName: String?
    /// Position on the card, from 1; nil off a card.
    public var index: Int?
    /// False while the engine cannot use the connector (card missing, set the other way round, in use elsewhere).
    public var available: Bool

    public init(id: String, kind: Kind, label: String, cardID: String? = nil, cardName: String? = nil, index: Int? = nil, available: Bool = true) {
        self.id = id
        self.kind = kind
        self.label = label
        self.cardID = cardID
        self.cardName = cardName
        self.index = index
        self.available = available
    }

    /// True when a screen of `type` may be sent to (or fed from) this connector.
    public func accepts(_ type: ScreenType) -> Bool { kind.isInput == type.isInput }
}

/// Which connector a screen goes out of (or, for an input screen, comes in from). nil = not assigned.
public struct OutputAssignment: Codable, Sendable, Hashable {
    public var screenID: Screen.ID
    public var connectorID: Connector.ID?

    public init(screenID: Screen.ID, connectorID: Connector.ID?) {
        self.screenID = screenID
        self.connectorID = connectorID
    }
}

/// A rectangle on the canvas, in canvas pixels.
public struct CanvasRect: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int = 0, y: Int = 0, width: Int = 1920, height: Int = 1080) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ScreenRotation: Int, Codable, Sendable, Hashable, CaseIterable {
    case none = 0, right = 90, upsideDown = 180, left = 270
}

/// How a screen is set up: its type, its look, and (for audience screens) whether and where it sits on the canvas.
public struct ScreenSetup: Codable, Sendable, Hashable {
    public var type: ScreenType
    public var lookID: Look.ID?
    /// Part of the shared canvas. Every on-canvas screen must go out of SDI connectors on one card.
    public var onCanvas: Bool
    public var canvas: CanvasRect
    public var rotation: ScreenRotation

    public init(type: ScreenType, lookID: Look.ID? = nil, onCanvas: Bool = false, canvas: CanvasRect = CanvasRect(), rotation: ScreenRotation = .none) {
        self.type = type
        self.lookID = lookID
        self.onCanvas = onCanvas
        self.canvas = canvas
        self.rotation = rotation
    }

    /// The reason this setup is refused, or nil when it is valid.
    public var invalidReason: String? {
        if canvas.width <= 0 || canvas.height <= 0 { return "canvas size must be above 0" }
        if onCanvas && type != .audience { return "only audience screens can be on the canvas" }
        return nil
    }
}

public enum TestPattern: String, Codable, Sendable, Hashable, CaseIterable {
    case bars, grid
}

public enum TestPatternTarget: Codable, Sendable, Hashable {
    case all
    case screen(Screen.ID)
}

/// A test pattern being sent. While one runs it replaces what the targeted outputs show; the live slide is not
/// changed, so taking it off brings the live content straight back.
public struct ActiveTestPattern: Codable, Sendable, Hashable {
    public var target: TestPatternTarget
    public var pattern: TestPattern

    public init(target: TestPatternTarget, pattern: TestPattern) {
        self.target = target
        self.pattern = pattern
    }

    public func covers(_ screenID: Screen.ID) -> Bool {
        switch target {
        case .all: true
        case let .screen(id): id == screenID
        }
    }
}

/// Something wrong with the output setup that the operator must see. Not a refusal: the engine still runs it.
public enum OutputWarning: Codable, Sendable, Hashable {
    /// The on-canvas screens go out of SDI connectors on more than one card, so they are not frame-locked.
    case canvasSpansCards([Screen.ID])
    /// An on-canvas screen goes out of an NDI output or a display, which is not synchronised to the SDI clock.
    case canvasOnNonSDI(Screen.ID)
    /// The screen's connector is missing from the engine's list or not available.
    case connectorUnavailable(Screen.ID)
}

/// The warnings for an output setup. Pure: the UI runs it on its working copy, the engine on its own state.
/// Screens are reported in `assignments` order; unassigned screens raise nothing.
public func outputWarnings(
    connectors: [Connector], assignments: [OutputAssignment], screenSetups: [Screen.ID: ScreenSetup]
) -> [OutputWarning] {
    let byID = Dictionary(connectors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var warnings: [OutputWarning] = []
    var sdiCanvas: [(screen: Screen.ID, card: String?)] = []

    for assignment in assignments {
        guard let connectorID = assignment.connectorID else { continue }
        guard let connector = byID[connectorID], connector.available else {
            warnings.append(.connectorUnavailable(assignment.screenID))
            continue
        }
        guard screenSetups[assignment.screenID]?.onCanvas == true else { continue }
        if connector.kind == .sdiOut {
            sdiCanvas.append((assignment.screenID, connector.cardID))
        } else {
            warnings.append(.canvasOnNonSDI(assignment.screenID))
        }
    }

    if Set(sdiCanvas.map(\.card)).count > 1 {
        warnings.insert(.canvasSpansCards(sdiCanvas.map(\.screen)), at: 0)
    }
    return warnings
}
