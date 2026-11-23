import Foundation

/// An in-memory engine for the UI and tests. Applies commands to a `StageState` and fakes telemetry
/// (playhead, voice-overs, ducking) when `tick(seconds:)` is called or the telemetry loop runs.
///
/// The audio behaviour is a rough stand-in, not the contract in docs/audio-spec-1.md: triggers fire when the
/// playhead crosses them, a trigger reached while a voice is on top is skipped, the background is ducked by a
/// fixed amount while a voice plays, and the track ends at its trim Out (or the end of the file). The end action of
/// `playAudio` decides the passes: `.loop` wraps to trim In for ever, `.once` plays two passes, `.default` and
/// `.stop` one (the mock has no playlist, so both then stop). Volume and fade-in are checked but not simulated.
///
/// Outputs: the mock plays the engine's part and reports `sampleConnectors` (or the list it is given). Slides and
/// messages go to output screens only, never to input screens. A test pattern is state only: the mock has no
/// pixels, and the live slide is left as it was.
public actor MockStageClient: StageClient {
    /// Reduction shown while a voice-over plays.
    public static let fakeDuckingDB = 8.0
    /// Voice length used when the voice media has no duration.
    public static let defaultVoiceSeconds = 5.0

    public private(set) var library: Library
    private var state: StageState
    private var stateSubscribers: [UUID: AsyncStream<StageState>.Continuation] = [:]
    private var eventSubscribers: [UUID: AsyncStream<StageEvent>.Continuation] = [:]

    /// Item and slide index of the last slide taken live (kept through a clear so Next continues from it).
    private var cursor: (item: Int, slide: Int)?
    private var spentOnce: Set<TriggerPoint.ID> = []
    private var skipped: Set<TriggerPoint.ID> = []
    private var voiceRemaining = 0.0
    private var fadeRemaining: Double?
    /// Passes still to play after the running one; nil = loop for ever.
    private var passesLeft: Int? = 0
    private var telemetryTask: Task<Void, Never>?

    /// The connectors of the v0.1 rig: two DeckLink Duo 2 cards with 4 SDI connectors each (card B's 4th set to
    /// input, for IMAG), two NDI senders and one display.
    public static let sampleConnectors: [Connector] = {
        func sdi(_ card: String, _ n: Int, _ kind: Connector.Kind = .sdiOut) -> Connector {
            Connector(id: "decklink-\(card)-\(n)", kind: kind, label: kind == .sdiIn ? "SDI \(n) In" : "SDI \(n)",
                      cardID: "decklink-\(card)", cardName: "DeckLink Duo 2 (\(card))", index: n)
        }
        return (1...4).map { sdi("A", $0) } + (1...3).map { sdi("B", $0) } + [sdi("B", 4, .sdiIn)] + [
            Connector(id: "ndi-out-1", kind: .ndiOut, label: "NDI CueME Main"),
            Connector(id: "ndi-out-2", kind: .ndiOut, label: "NDI CueME Stage"),
            Connector(id: "display-1", kind: .display, label: "Display 1 (HDMI)"),
        ]
    }()

    /// Each screen, in library order, on the first free connector that accepts it (with the sample: Left, Stage and
    /// Right on card A, IMAG on card B's input).
    public static func defaultAssignments(screens: [Screen], connectors: [Connector]) -> [OutputAssignment] {
        var used: Set<Connector.ID> = []
        return screens.map { screen in
            let connector = connectors.first { $0.available && $0.accepts(screen.type) && !used.contains($0.id) }
            if let connector { used.insert(connector.id) }
            return OutputAssignment(screenID: screen.id, connectorID: connector?.id)
        }
    }

    /// A Studio as the mock loads it. The app reads the package and this machine's output assignments; the mock
    /// does no file IO (StageKit is Foundation only).
    public struct LoadedStudio: Sendable {
        public var info: StudioInfo
        public var library: Library
        public var assignments: [OutputAssignment]

        public init(info: StudioInfo, library: Library, assignments: [OutputAssignment]) {
            self.info = info
            self.library = library
            self.assignments = assignments
        }
    }

    /// Where `openStudio` and `reloadStudio` find a Studio by id; nil = unknown.
    public typealias StudioSource = @Sendable (UUID) -> LoadedStudio?

    private let connectors: [Connector]
    private let studioSource: StudioSource?

    /// `assignments` nil = `defaultAssignments`.
    public init(library: Library = .sample, connectors: [Connector] = MockStageClient.sampleConnectors, assignments: [OutputAssignment]? = nil,
                studioSource: StudioSource? = nil) {
        self.library = library
        self.connectors = connectors
        self.studioSource = studioSource
        self.state = Self.makeState(library: library, connectors: connectors,
                                    assignments: assignments ?? Self.defaultAssignments(screens: library.screens, connectors: connectors))
    }

    /// A fresh snapshot for a library: nothing live, nothing playing.
    private static func makeState(library: Library, connectors: [Connector], assignments: [OutputAssignment], studio: StudioInfo? = nil) -> StageState {
        var state = StageState(
            service: library.service,
            slides: slides(of: library),
            screens: library.screens.map { ScreenState(screenID: $0.id, name: $0.name) },
            messages: library.messages,
            outputs: library.outputs.map { OutputStatus(outputID: $0.id, name: $0.name) },
            looks: library.looks,
            connectors: connectors,
            assignments: library.screens.map { screen in
                OutputAssignment(screenID: screen.id, connectorID: assignments.first { $0.screenID == screen.id }?.connectorID)
            },
            screenSetups: Dictionary(uniqueKeysWithValues: library.screens.map { screen in
                (screen.id, library.screenSetups[screen.id] ?? ScreenSetup(
                    type: screen.type, onCanvas: screen.type == .audience,
                    canvas: CanvasRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height)
                ))
            })
        )
        state.studio = studio
        // Nothing taken yet: Next starts at the first slide of the service (as `step(forward:)` says).
        if let item = library.service.items.first(where: { state.slides[$0.id] != nil }), let slide = state.slides[item.id]?.first {
            state.nextSlide = LiveSlide(itemID: item.id, slideIndex: 0, slideID: slide.id, label: slide.label, lines: slide.lines)
        }
        return state
    }

    private static func slides(of library: Library) -> [Item.ID: [Slide]] {
        var slides: [Item.ID: [Slide]] = [:]
        for item in library.service.items {
            if case let .song(songID) = item.content, let song = library.song(songID), !song.slides.isEmpty {
                slides[item.id] = song.slides
            }
        }
        return slides
    }

    /// Switches to another library: everything live stops (slides, messages, audio, test pattern, blackout).
    private func load(_ library: Library, assignments: [OutputAssignment], studio: StudioInfo?) {
        if let track = state.audio.liveTrack { emit(.audioEnded(mediaID: track)) }
        let counters = state.audio.counters
        let outputs = state.outputs
        self.library = library
        state = Self.makeState(library: library, connectors: state.connectors, assignments: assignments, studio: studio)
        state.audio.counters = counters
        if state.outputs.isEmpty { state.outputs = outputs }
        cursor = nil
        spentOnce = []
        skipped = []
        voiceRemaining = 0
        fadeRemaining = nil
        passesLeft = 0
    }

    // MARK: StageClient

    public var currentState: StageState { state }

    public func states() -> AsyncStream<StageState> {
        let (stream, continuation) = AsyncStream.makeStream(of: StageState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        continuation.yield(state)
        return stream
    }

    public func events() -> AsyncStream<StageEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: StageEvent.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        eventSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSubscriber(id) }
        }
        return stream
    }

    public func send(_ command: Command) {
        apply(command)
        refreshNextSlide()
        publish()
    }

    // MARK: Fake telemetry

    /// Advances the fake audio clock by `seconds`.
    public func tick(seconds dt: Double) {
        advance(dt)
        publish()
    }

    /// Ticks on its own every `interval` until `stopTelemetry()`.
    public func startTelemetry(interval: Duration = .milliseconds(100)) {
        telemetryTask?.cancel()
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick(seconds: seconds)
            }
        }
    }

    public func stopTelemetry() {
        telemetryTask?.cancel()
        telemetryTask = nil
    }

    public func simulateCounters(_ counters: AudioCounters) {
        guard counters != state.audio.counters else { return }
        state.audio.counters = counters
        emit(.countersChanged(counters))
        publish()
    }

    public func simulateOutput(_ outputID: Output.ID, health: OutputStatus.Health, droppedFrames: Int? = nil) {
        guard let i = state.outputs.firstIndex(where: { $0.outputID == outputID }) else { return }
        state.outputs[i].health = health
        if let droppedFrames { state.outputs[i].droppedFrames = droppedFrames }
        emit(.outputHealthChanged(state.outputs[i]))
        publish()
    }

    /// Plays the engine reporting a connector as (un)available, e.g. a card that went missing.
    public func simulateConnector(_ id: Connector.ID, available: Bool) {
        guard let i = state.connectors.firstIndex(where: { $0.id == id }) else { return }
        state.connectors[i].available = available
        publish()
    }

    // MARK: Commands

    private func apply(_ command: Command) {
        switch command {
        case let .go(itemID, slideIndex):
            guard let itemIndex = library.service.items.firstIndex(where: { $0.id == itemID }) else {
                return reject(command, "unknown item")
            }
            let item = library.service.items[itemIndex]
            if case let .media(mediaID) = item.content {
                return apply(.playAudio(mediaID: mediaID, options: AudioPlayOptions()))
            }
            guard takeLive(itemIndex: itemIndex, slideIndex: slideIndex) else {
                return reject(command, "no slide \(slideIndex) in \(item.title)")
            }

        case .next:
            guard let target = step(forward: true) else { return reject(command, "end of service") }
            _ = takeLive(itemIndex: target.item, slideIndex: target.slide)

        case .previous:
            guard let target = step(forward: false) else { return reject(command, "start of service") }
            _ = takeLive(itemIndex: target.item, slideIndex: target.slide)

        case let .clear(target):
            if target == .slide || target == .all {
                for i in outputIndices { state.screens[i].live = nil }
            }
            if target == .messages || target == .all {
                state.visibleMessages = []
                for i in outputIndices { state.screens[i].messages = [] }
            }
            if target == .audio { endTrack() }
            emit(.cleared(target))

        case let .blackout(on):
            guard state.blackout != on else { return }
            state.blackout = on
            emit(.blackoutChanged(on))

        case let .applyLook(id):
            guard library.looks.contains(where: { $0.id == id }) else { return reject(command, "unknown look") }
            state.activeLook = id

        case let .showMessage(id, screens):
            guard library.messages.contains(where: { $0.id == id }) else { return reject(command, "unknown message") }
            let known = Set(state.outputScreens.map(\.screenID))
            guard screens.allSatisfy(known.contains) else { return reject(command, "unknown screen") }
            let targets = screens.isEmpty ? known : Set(screens)
            for i in outputIndices {
                state.screens[i].messages.removeAll { $0 == id }
                if targets.contains(state.screens[i].screenID) { state.screens[i].messages.append(id) }
            }
            if !state.visibleMessages.contains(id) { state.visibleMessages.append(id) }

        case let .hideMessage(id):
            state.visibleMessages.removeAll { $0 == id }
            for i in state.screens.indices { state.screens[i].messages.removeAll { $0 == id } }

        case let .startTimer(id):
            guard library.timers.contains(where: { $0.id == id }) else { return reject(command, "unknown timer") }
            if !state.runningTimers.contains(id) { state.runningTimers.append(id) }

        case let .stopTimer(id), let .resetTimer(id):
            state.runningTimers.removeAll { $0 == id }

        case let .playAudio(mediaID, options):
            guard let media = library.mediaItem(mediaID), media.kind == .audio else {
                return reject(command, "not an audio item")
            }
            if let reason = options.invalidReason { return reject(command, reason) }
            if let old = state.audio.liveTrack { emit(.audioEnded(mediaID: old)) }
            // A new track cuts everything, the voice-over and the ducking included.
            let settings = library.audioSettings[mediaID]
            state.audio = AudioState(
                liveTrack: mediaID, transport: .playing, position: settings?.trimIn ?? 0, counters: state.audio.counters
            )
            spentOnce = []
            skipped = []
            voiceRemaining = 0
            fadeRemaining = nil
            switch options.endAction ?? .default {
            case .default, .stop: passesLeft = 0
            case .once: passesLeft = 1
            case .loop: passesLeft = nil
            }
            refreshNextTrigger()
            emit(.audioStarted(mediaID: mediaID))

        case .pauseAudio:
            guard state.audio.transport == .playing else { return reject(command, "nothing playing") }
            state.audio.transport = .paused

        case .resumeAudio:
            guard state.audio.transport == .paused else { return reject(command, "not paused") }
            state.audio.transport = .playing

        case .stopAudio:
            endTrack()

        case let .fadeAudio(seconds):
            guard state.audio.liveTrack != nil else { return reject(command, "nothing playing") }
            if seconds <= 0 { return endTrack() }
            state.audio.transport = .fading
            fadeRemaining = seconds

        case let .seekAudio(seconds):
            guard let track = state.audio.liveTrack else { return reject(command, "nothing playing") }
            let (lo, hi) = window(of: track)
            let to = min(max(seconds, lo), hi)
            // A seek back re-arms the points after the new position.
            if to < state.audio.position {
                let rearm = Set(triggers(of: track).filter { $0.at >= to }.map(\.id))
                spentOnce.subtract(rearm)
                skipped.subtract(rearm)
            }
            state.audio.position = to
            refreshNextTrigger()

        case .skipNextTrigger:
            guard let next = state.audio.nextTrigger else { return reject(command, "no trigger ahead") }
            skipped.insert(next.triggerID)
            emit(.triggerSkipped(triggerID: next.triggerID))
            refreshNextTrigger()

        case let .assignScreen(screenID, connectorID):
            guard let a = state.assignments.firstIndex(where: { $0.screenID == screenID }),
                  let setup = state.screenSetups[screenID] else { return reject(command, "unknown screen") }
            if let connectorID {
                guard let connector = state.connector(connectorID) else { return reject(command, "unknown connector") }
                guard connector.available else { return reject(command, "\(connector.label) is not available") }
                guard connector.accepts(setup.type) else {
                    return reject(command, setup.type.isInput ? "\(connector.label) is not an input" : "\(connector.label) is not an output")
                }
                if let other = state.assignments.first(where: { $0.connectorID == connectorID && $0.screenID != screenID }) {
                    let name = state.screens.first { $0.screenID == other.screenID }?.name ?? "another screen"
                    return reject(command, "\(connector.label) is already used by \(name)")
                }
            }
            state.assignments[a].connectorID = connectorID

        case let .setScreenSetup(screenID, setup):
            guard state.screenSetups[screenID] != nil else { return reject(command, "unknown screen") }
            if let reason = setup.invalidReason { return reject(command, reason) }
            if let look = setup.lookID, !library.looks.contains(where: { $0.id == look }) { return reject(command, "unknown look") }
            if let connector = state.connector(state.connectorID(for: screenID)), !connector.accepts(setup.type) {
                return reject(command, "unassign \(connector.label) before changing the screen's direction")
            }
            state.screenSetups[screenID] = setup

        case let .showTestPattern(target, pattern):
            if case let .screen(id) = target, !state.outputScreens.contains(where: { $0.screenID == id }) {
                return reject(command, "not an output screen")
            }
            let active = ActiveTestPattern(target: target, pattern: pattern)
            guard state.testPattern != active else { return }
            state.testPattern = active
            emit(.testPatternChanged(active))

        case .hideTestPattern:
            guard state.testPattern != nil else { return reject(command, "no test pattern running") }
            state.testPattern = nil
            emit(.testPatternChanged(nil))

        case let .openStudio(id):
            guard let loaded = studioSource?(id) else { return reject(command, "unknown Studio") }
            load(loaded.library, assignments: loaded.assignments, studio: loaded.info)
            emit(.studioOpened(loaded.info))

        case .closeStudio:
            guard let info = state.studio else { return reject(command, "no Studio open") }
            load(.empty, assignments: [], studio: nil)
            emit(.studioClosed(info))

        case let .reloadStudio(id):
            guard state.studio?.id == id, let loaded = studioSource?(id) else { return reject(command, "not the open Studio") }
            // Show data changed (items imported, media relinked): new content, nothing live is stopped.
            library = loaded.library
            state.service = loaded.library.service
            state.slides = Self.slides(of: loaded.library)
            state.messages = loaded.library.messages
            state.looks = loaded.library.looks
            state.studio = loaded.info
        }
    }

    /// Indices in `state.screens` of the screens that take slides and messages.
    private var outputIndices: [Int] {
        state.screens.indices.filter { state.screenSetups[state.screens[$0].screenID]?.type.isInput != true }
    }

    private func reject(_ command: Command, _ reason: String) {
        emit(.commandRejected(command, reason: reason))
    }

    // MARK: Slides

    private func slides(ofItemAt index: Int) -> [Slide] {
        guard case let .song(songID) = library.service.items[index].content else { return [] }
        return library.song(songID)?.slides ?? []
    }

    private func liveSlide(itemIndex: Int, slideIndex: Int) -> LiveSlide? {
        let slides = slides(ofItemAt: itemIndex)
        guard slides.indices.contains(slideIndex) else { return nil }
        let slide = slides[slideIndex]
        return LiveSlide(
            itemID: library.service.items[itemIndex].id, slideIndex: slideIndex, slideID: slide.id,
            label: slide.label, lines: slide.lines
        )
    }

    private func refreshNextSlide() {
        state.nextSlide = step(forward: true).flatMap { liveSlide(itemIndex: $0.item, slideIndex: $0.slide) }
    }

    private func takeLive(itemIndex: Int, slideIndex: Int) -> Bool {
        guard let live = liveSlide(itemIndex: itemIndex, slideIndex: slideIndex) else { return false }
        for i in outputIndices { state.screens[i].live = live }
        cursor = (itemIndex, slideIndex)
        emit(.slideLive(live))
        return true
    }

    private func step(forward: Bool) -> (item: Int, slide: Int)? {
        let items = library.service.items
        guard let cursor else {
            // Nothing taken yet: Next starts at the first slide of the service.
            guard forward, let first = items.indices.first(where: { !slides(ofItemAt: $0).isEmpty }) else { return nil }
            return (first, 0)
        }
        let slideCount = slides(ofItemAt: cursor.item).count
        if forward, cursor.slide + 1 < slideCount { return (cursor.item, cursor.slide + 1) }
        if !forward, cursor.slide > 0 { return (cursor.item, cursor.slide - 1) }
        let others = forward
            ? Array(items.indices.filter { $0 > cursor.item })
            : Array(items.indices.filter { $0 < cursor.item }.reversed())
        guard let item = others.first(where: { !slides(ofItemAt: $0).isEmpty }) else { return nil }
        return (item, forward ? 0 : slides(ofItemAt: item).count - 1)
    }

    // MARK: Audio

    private func window(of track: MediaItem.ID) -> (Double, Double) {
        let settings = library.audioSettings[track]
        let end = settings?.trimOut ?? library.mediaItem(track)?.duration ?? .infinity
        return (settings?.trimIn ?? 0, end)
    }

    private func triggers(of track: MediaItem.ID) -> [TriggerPoint] {
        (library.audioSettings[track]?.triggers ?? []).sorted { $0.at < $1.at }
    }

    private func isArmed(_ point: TriggerPoint) -> Bool {
        point.enabled && !skipped.contains(point.id) && !(point.once && spentOnce.contains(point.id))
    }

    private func refreshNextTrigger() {
        guard let track = state.audio.liveTrack else { state.audio.nextTrigger = nil; return }
        let (_, end) = window(of: track)
        let next = triggers(of: track).first { $0.at >= state.audio.position && $0.at < end && isArmed($0) }
        state.audio.nextTrigger = next.map { NextTrigger(triggerID: $0.id, at: $0.at, voiceMediaID: $0.voiceMediaID) }
    }

    private func advance(_ dt: Double) {
        guard dt > 0, let track = state.audio.liveTrack,
              state.audio.transport == .playing || state.audio.transport == .fading else { return }

        let from = state.audio.position
        let to = from + dt
        let (_, end) = window(of: track)

        // Voice-over on top.
        if state.audio.voicePlaying {
            voiceRemaining -= dt
            if voiceRemaining <= 0 {
                state.audio.voicePlaying = false
                state.audio.duckingReductionDB = 0
            }
        }

        // Points crossed in [from, to).
        for point in triggers(of: track) where point.at >= from && point.at < min(to, end) && isArmed(point) {
            if point.once { spentOnce.insert(point.id) }
            if state.audio.voicePlaying { continue } // a second point while a voice is on top is skipped, never queued
            state.audio.voicePlaying = true
            state.audio.duckingReductionDB = Self.fakeDuckingDB
            voiceRemaining = library.mediaItem(point.voiceMediaID)?.duration ?? Self.defaultVoiceSeconds
            emit(.triggerFired(triggerID: point.id, voiceMediaID: point.voiceMediaID))
        }

        state.audio.position = min(to, end)

        if let remaining = fadeRemaining {
            fadeRemaining = remaining - dt
            if remaining - dt <= 0 { return endTrack() }
        }
        if to >= end {
            // Another pass (a loop or the second pass of `once`) starts again at trim In; a fade still ends it.
            guard passesLeft != 0, end.isFinite else { return endTrack() }
            if let left = passesLeft { passesLeft = left - 1 }
            state.audio.position = window(of: track).0
            skipped = []
        }
        refreshNextTrigger()
    }

    private func endTrack() {
        if let track = state.audio.liveTrack { emit(.audioEnded(mediaID: track)) }
        state.audio = AudioState(counters: state.audio.counters)
        voiceRemaining = 0
        fadeRemaining = nil
    }

    // MARK: Publishing

    private func publish() {
        for continuation in stateSubscribers.values { continuation.yield(state) }
    }

    private func emit(_ event: StageEvent) {
        for continuation in eventSubscribers.values { continuation.yield(event) }
    }

    private func removeStateSubscriber(_ id: UUID) { stateSubscribers[id] = nil }
    private func removeEventSubscriber(_ id: UUID) { eventSubscribers[id] = nil }
}
