import Foundation

/// An in-memory engine for the UI and tests. Applies commands to a `StageState` and fakes telemetry
/// (playhead, voice-overs, ducking) when `tick(seconds:)` is called or the telemetry loop runs.
///
/// The audio behaviour is a rough stand-in, not the contract in docs/audio-spec-1.md: triggers fire when the
/// playhead crosses them, a trigger reached while a voice is on top is skipped, the background is ducked by a
/// fixed amount while a voice plays, and the track ends at its trim Out (or the end of the file). The end action of
/// `playAudio` decides the passes: `.loop` wraps to trim In for ever, `.once` plays two passes, `.default` and
/// `.stop` one (the mock has no playlist, so both then stop). Volume and fade-in are checked but not simulated.
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

    public init(library: Library = .sample) {
        self.library = library
        self.state = StageState(
            service: library.service,
            screens: library.screens.map { ScreenState(screenID: $0.id, name: $0.name) },
            outputs: library.outputs.map { OutputStatus(outputID: $0.id, name: $0.name) }
        )
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
                for i in state.screens.indices { state.screens[i].live = nil }
            }
            if target == .messages || target == .all {
                state.visibleMessages = []
                for i in state.screens.indices { state.screens[i].messages = [] }
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
            let known = Set(state.screens.map(\.screenID))
            guard screens.allSatisfy(known.contains) else { return reject(command, "unknown screen") }
            let targets = screens.isEmpty ? known : Set(screens)
            for i in state.screens.indices {
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
        }
    }

    private func reject(_ command: Command, _ reason: String) {
        emit(.commandRejected(command, reason: reason))
    }

    // MARK: Slides

    private func slides(ofItemAt index: Int) -> [Slide] {
        guard case let .song(songID) = library.service.items[index].content else { return [] }
        return library.song(songID)?.slides ?? []
    }

    private func takeLive(itemIndex: Int, slideIndex: Int) -> Bool {
        let slides = slides(ofItemAt: itemIndex)
        guard slides.indices.contains(slideIndex) else { return false }
        let slide = slides[slideIndex]
        let live = LiveSlide(
            itemID: library.service.items[itemIndex].id, slideIndex: slideIndex, slideID: slide.id,
            label: slide.label, lines: slide.lines
        )
        for i in state.screens.indices { state.screens[i].live = live }
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
