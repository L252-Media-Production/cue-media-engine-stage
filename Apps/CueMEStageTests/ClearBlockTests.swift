import AppKit
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The Clear block: icons, lit state from StageState, Black in amber, the two-row layout and its sizes.
@MainActor
final class ClearBlockTests: XCTestCase {
    let lib = Library.sample
    var amazing: Item { lib.service.items[1] }
    var walkIn: MediaItem.ID { lib.media[0].id }

    private func state(_ commands: [Command]) async -> StageState {
        let client = MockStageClient(library: lib)
        for command in commands { await client.send(command) }
        return await client.currentState
    }

    private func until(_ what: String, timeout: Double = 2, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        let met = condition()
        XCTAssertTrue(met, "timed out waiting for \(what)")
    }

    // MARK: Icons and labels

    func testSymbolsExistAreNotSlashedAndAreAllDifferent() {
        let names = ClearButton.allCases.map(\.symbol)
        XCTAssertEqual(names, ["square.stack.3d.up", "text.rectangle", "photo", "music.note", "bubble.left", "rectangle.fill"])
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) exists on this macOS")
            XCTAssertFalse(name.contains("slash"), name)
        }
        XCTAssertEqual(Set(names).count, names.count, "no symbol used twice")
    }

    func testEveryButtonHasALabelATooltipAndAValue() async {
        let idle = ClearRowModel(state: await state([]))
        XCTAssertEqual(ClearButton.allCases.map(idle.accessibilityLabel),
                       ["Clear all", "Clear slide", "Clear media", "Clear audio", "Clear message", "Black out all screens"])
        for button in ClearButton.allCases {
            XCTAssertFalse(idle.help(button).isEmpty, "\(button) has a tooltip")
        }
        XCTAssertEqual(ClearButton.allCases.map(idle.accessibilityValue), ["empty", "empty", "empty", "empty", "empty", "off"])
        XCTAssertEqual(idle.help(.media), "Media clear is not available in v0.1")
        XCTAssertFalse(idle.isEnabled(.media))

        let busy = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0), .blackout(true)]))
        XCTAssertEqual(busy.accessibilityValue(.slide), "active")
        XCTAssertEqual(busy.accessibilityValue(.all), "active")
        XCTAssertEqual(busy.accessibilityValue(.black), "on")
        XCTAssertEqual(busy.accessibilityValue(.media), "empty", "Media is never lit")
    }

    // MARK: Lit rules

    func testLitRules() async {
        func lit(_ commands: [Command]) async -> [ClearButton] {
            let model = ClearRowModel(state: await state(commands))
            return ClearButton.allCases.filter(model.isLit)
        }
        let nothing = await lit([])
        XCTAssertEqual(nothing, [], "nothing on air: nothing lit")
        let slide = await lit([.go(itemID: amazing.id, slideIndex: 0)])
        XCTAssertEqual(slide, [.slide])
        let playing = await lit([.playAudio(mediaID: walkIn)])
        XCTAssertEqual(playing, [.audio], "playing")
        let paused = await lit([.playAudio(mediaID: walkIn), .pauseAudio])
        XCTAssertEqual(paused, [.audio], "paused")
        let fading = await lit([.playAudio(mediaID: walkIn), .fadeAudio(seconds: 3)])
        XCTAssertEqual(fading, [.audio], "fading")
        let stopped = await lit([.playAudio(mediaID: walkIn), .stopAudio])
        XCTAssertEqual(stopped, [], "stopped")
        let message = await lit([.showMessage(lib.messages[0].id, screens: [])])
        XCTAssertEqual(message, [.message])
        let blackout = await lit([.blackout(true)])
        XCTAssertEqual(blackout, [], "Black is not a lit layer")
    }

    // MARK: Clicking

    func testAnUnlitButtonSendsNothing() async {
        let idle = ClearRowModel(state: await state([]))
        for button in [ClearButton.all, .slide, .media, .audio, .message] {
            XCTAssertEqual(idle.commands(button), [], "\(button)")
        }
        XCTAssertEqual(idle.commands(.black), [.blackout(true)], "Black toggles")
    }

    func testClickingALitButtonClearsItAndTheLightGoesOutWithTheState() async {
        let cases: [(ClearButton, [Command], [Command])] = [
            (.slide, [.go(itemID: amazing.id, slideIndex: 0)], [.clear(.slide)]),
            (.audio, [.playAudio(mediaID: walkIn)], [.fadeAudio(seconds: 2)]),
            (.message, [.showMessage(lib.messages[0].id, screens: [])], [.clear(.messages)]),
            (.all, [.go(itemID: amazing.id, slideIndex: 0), .playAudio(mediaID: walkIn), .showMessage(lib.messages[0].id, screens: [])],
             [.clear(.all), .fadeAudio(seconds: 2)]),
        ]
        for (button, setup, expected) in cases {
            let store = StageStore.mock(library: lib)
            setup.forEach(store.send)
            await until("\(button) can be pressed") {
                let m = ClearRowModel(state: store.state)
                return button == .all ? m.isEnabled(.all) : m.isLit(button)
            }
            let commands = ClearRowModel(state: store.state).commands(button)
            XCTAssertEqual(commands, expected, "\(button)")
            commands.forEach(store.send)
            // The mock's own clock runs here, so a fade ends about 2 s later.
            await until("\(button) goes out", timeout: 4) {
                let m = ClearRowModel(state: store.state)
                return button == .all ? !m.isEnabled(.all) : !m.isLit(button)
            }
            if button == .all {
                let model = ClearRowModel(state: store.state)
                XCTAssertFalse(model.isLit(.slide) || model.isLit(.audio) || model.isLit(.message), "All cleared all three")
            }
        }
    }

    // MARK: All

    func testAllIsNeverLitAndUsableOnlyWhileSomethingIsOnAir() async {
        let idle = ClearRowModel(state: await state([]))
        XCTAssertFalse(idle.isEnabled(.all), "nothing on air: dim")
        XCTAssertEqual(idle.commands(.all), [])
        XCTAssertEqual(idle.look(.all), ClearButtonLook(fill: .surfaceRaised, border: .border, icon: .textSecondary))
        let onAir: [[Command]] = [
            [.go(itemID: amazing.id, slideIndex: 0)], [.playAudio(mediaID: walkIn)], [.showMessage(lib.messages[0].id, screens: [])],
            [.playAudio(mediaID: walkIn), .pauseAudio],
        ]
        for setup in onAir {
            let model = ClearRowModel(state: await state(setup))
            XCTAssertTrue(model.isEnabled(.all), "\(setup)")
            XCTAssertFalse(model.isLit(.all), "never lit")
            XCTAssertEqual(model.look(.all), idle.look(.all), "never the red style")
            XCTAssertEqual(model.commands(.all).first, .clear(.all))
        }
        let slideOnly = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0)]))
        XCTAssertEqual(slideOnly.commands(.all), [.clear(.all)], "no fade without a track (it would be refused)")
    }

    // MARK: Audio fade

    func testClearAudioFadesOverTwoSecondsThenStops() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: walkIn))
        var s = await client.currentState
        let commands = ClearRowModel(state: s).commands(.audio)
        XCTAssertEqual(commands, [.fadeAudio(seconds: 2)])
        for c in commands { await client.send(c) }
        s = await client.currentState
        XCTAssertEqual(s.audio.transport, .fading)
        XCTAssertTrue(ClearRowModel(state: s).isLit(.audio), "lit during the fade")
        await client.tick(seconds: 1)
        s = await client.currentState
        XCTAssertEqual(s.audio.transport, .fading, "still fading at 1 s")
        XCTAssertTrue(ClearRowModel(state: s).isLit(.audio))
        await client.tick(seconds: 1)
        s = await client.currentState
        XCTAssertNil(s.audio.liveTrack, "stopped at 2 s")
        XCTAssertEqual(s.audio.transport, .stopped)
        XCTAssertFalse(ClearRowModel(state: s).isLit(.audio), "dim after")
    }

    func testAPausedTrackFadesToo() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: walkIn))
        await client.send(.pauseAudio)
        for c in ClearRowModel(state: await client.currentState).commands(.audio) { await client.send(c) }
        await client.tick(seconds: 2)
        let s = await client.currentState
        XCTAssertNil(s.audio.liveTrack)
    }

    func testStopPlaybackIsStillInstantAndFadeOutUnchanged() async {
        let client = MockStageClient(library: lib)
        await client.send(.playAudio(mediaID: walkIn))
        await client.send(.stopAudio) // Service > Audio > Stop Playback, Option-Cmd-.
        let s = await client.currentState
        XCTAssertNil(s.audio.liveTrack, "stopped at once, no clock needed")
        XCTAssertEqual(Shortcuts.audioStop, KeyboardShortcut(".", modifiers: [.command, .option]))
        XCTAssertEqual(ClearAudio.fadeSeconds, 2)
        XCTAssertEqual(ClearAudio.commands(StageState()), [], "no track: nothing to fade (Service > Clear > Audio is off)")
    }

    // MARK: Hover label

    func testHoverLabelTimer() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var timer = HoverLabelTimer()
        XCTAssertFalse(timer.isVisible(at: t0))
        timer.enter(at: t0)
        XCTAssertFalse(timer.isVisible(at: t0.addingTimeInterval(0.299)), "not before 300 ms")
        XCTAssertTrue(timer.isVisible(at: t0.addingTimeInterval(0.3)), "at 300 ms")
        timer.leave()
        XCTAssertFalse(timer.isVisible(at: t0.addingTimeInterval(1)), "gone when the pointer leaves")
        timer.enter(at: t0.addingTimeInterval(2))
        XCTAssertTrue(timer.isVisible(at: t0.addingTimeInterval(2.5)))
        timer.press()
        XCTAssertFalse(timer.isVisible(at: t0.addingTimeInterval(2.6)), "gone when pressed")
        XCTAssertFalse(timer.isVisible(at: t0.addingTimeInterval(9)), "and stays gone while the pointer stays")
        timer.enter(at: t0.addingTimeInterval(10))
        XCTAssertTrue(timer.isVisible(at: t0.addingTimeInterval(10.3)), "back after the pointer comes back")
    }

    func testHoverLabelStaysInsideTheColumnAndFlips() {
        // The block at column 300 (276 inner): six buttons of 42.7 pt with 4 pt gaps, on the second row (y 21).
        let inner: CGFloat = 276, each = (inner - 20) / 6
        let column = CGRect(x: 0, y: 0, width: inner, height: 53)
        let label = CGSize(width: 220, height: 22)
        for i in 0..<6 {
            let button = CGRect(x: CGFloat(i) * (each + 4), y: 21, width: each, height: 32)
            let c = HoverLabelPlacement.center(button: button, label: label, column: column, roomAbove: 400)
            XCTAssertGreaterThanOrEqual(c.x - label.width / 2, 0, "button \(i): not past the left edge")
            XCTAssertLessThanOrEqual(c.x + label.width / 2, inner, "button \(i): not past the right edge")
            XCTAssertEqual(c.y + label.height / 2, button.minY - HoverLabelPlacement.gap, accuracy: 0.01, "above the button")
            let flipped = HoverLabelPlacement.center(button: button, label: label, column: column, roomAbove: 10)
            XCTAssertEqual(flipped.y - label.height / 2, button.maxY + HoverLabelPlacement.gap, accuracy: 0.01, "below when no room above")
        }
        let small = CGSize(width: 60, height: 22)
        let middle = CGRect(x: 100, y: 21, width: each, height: 32)
        XCTAssertEqual(HoverLabelPlacement.center(button: middle, label: small, column: column, roomAbove: 400).x, middle.midX,
                       "centred on its button when it fits")
    }

    /// In the real view: the label shows after 300 ms of hover, over the layout (the block keeps its size) and inside
    /// the column.
    func testHoverLabelInTheRealBlockDoesNotMoveLayout() async throws {
        let model = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0)]))
        let before = NSHostingView(rootView: ClearBlock(model: model) { _ in }.frame(width: 276).modifier(Themed())).fittingSize
        let label = NSHostingView(rootView: HoverLabel(text: model.help(.all)).modifier(Themed())).fittingSize
        XCTAssertLessThanOrEqual(label.width, 276, "the longest label fits the narrowest column")
        XCTAssertEqual(before.height, 53, "the label is an overlay: the block is as tall as ever")
        for button in ClearButton.allCases {
            let w = NSHostingView(rootView: HoverLabel(text: model.help(button)).modifier(Themed())).fittingSize.width
            XCTAssertLessThanOrEqual(w, 276, "\(button)")
        }
    }

    // MARK: Black

    func testBlackIsAmberNeverRedAndHasTheSameBorderAsTheOthersWhileOff() async {
        let off = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0)]))
        XCTAssertEqual(off.look(.black), ClearButtonLook(fill: .surfaceRaised, border: .border, icon: .warning))
        XCTAssertEqual(off.look(.black).border, off.look(.media).border)
        XCTAssertEqual(off.look(.black).border, off.look(.slide).border, "also a lit one's")
        XCTAssertEqual(off.look(.black).fill, off.look(.media).fill, "the same neutral fill")
        XCTAssertEqual(off.look(.slide), ClearButtonLook(fill: .liveTint, border: .border, icon: .live), "lit: red tint, red icon")
        XCTAssertEqual(off.look(.audio), ClearButtonLook(fill: .surfaceRaised, border: .border, icon: .textSecondary), "unlit: dim")

        let on = ClearRowModel(state: await state([.blackout(true)]))
        XCTAssertEqual(on.look(.black), ClearButtonLook(fill: .warning, border: .warning, icon: .onWarning), "filled amber, dark icon")
        for model in [off, on] {
            let look = model.look(.black)
            XCTAssertFalse([look.fill, look.border, look.icon].contains { $0 == .live || $0 == .liveTint }, "never red")
        }
        for theme in [ThemeTokens.dark, .light] {
            XCTAssertEqual(theme.color(off.look(.black).border), theme.color(off.look(.slide).border))
            XCTAssertNotEqual(theme.color(on.look(.black).fill), theme.color(ClearButtonLook.Role.live))
        }
    }

    // MARK: Layout

    func testLayoutOrderAndTwoRows() async {
        XCTAssertEqual(RightColumnPart.order, [.outputPicker, .monitor, .clear, .previousNext, .tabs])
        let model = ClearRowModel(state: await state([]))
        let block = NSHostingView(rootView: ClearBlock(model: model) { _ in }.frame(width: 336).modifier(Themed()))
        let height = block.fittingSize.height
        XCTAssertGreaterThanOrEqual(height, ClearBlockLayout.buttonHeight + 14, "a header row above the buttons")
        XCTAssertLessThanOrEqual(height, 53, "no taller than the old Clear row, so the tabs keep their height")
    }

    func testTheScopeSaysAllAndALongScreenNameIsCut() async throws {
        let s = await state([])
        let model = ClearRowModel(state: s)
        XCTAssertEqual(model.chipTitle(.allScreens), "All")
        XCTAssertEqual(model.scopes.first?.title, "All screens", "the menu entry is unchanged")
        XCTAssertEqual(model.scopeAccessibilityValue(.allScreens), "All screens", "spoken: Clear scope, all screens")

        var long = s
        let id = try XCTUnwrap(long.screens.first?.screenID)
        long.screens[0].name = "Overflow Room Projector Left Very Long Name"
        let longModel = ClearRowModel(state: long)
        XCTAssertEqual(longModel.chipTitle(.screen(id)), long.screens[0].name)
        let short = NSHostingController(rootView: ScopeChip(model: longModel).modifier(Themed()))
            .sizeThatFits(in: CGSize(width: 1000, height: 100))
        let cut = NSHostingController(rootView: ScopeChip(model: longModel, scope: .screen(id)).modifier(Themed()))
            .sizeThatFits(in: CGSize(width: 1000, height: 100))
        XCTAssertLessThanOrEqual(cut.width, ClearBlockLayout.scopeMaxWidth, "capped: the name is cut with an ellipsis")
        XCTAssertEqual(cut.height, short.height, accuracy: 0.5, "still one line")
    }

    func testTheSixButtonsFitAt300And360InBothThemes() async {
        let model = ClearRowModel(state: await state([.go(itemID: amazing.id, slideIndex: 0), .blackout(true)]))
        for column in [CGFloat(300), 360] {
            let inner = column - 2 * OperatorLayout.columnPadding
            let each = (inner - 5 * ClearBlockLayout.buttonSpacing) / 6
            XCTAssertGreaterThanOrEqual(each, ClearBlockLayout.minButtonWidth, "column \(column): \(each) pt each")
            for dark in [true, false] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: inner, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = NSHostingView(rootView: ClearBlock(model: model) { _ in }.frame(width: inner).modifier(Themed()))
                window.contentView = view
                XCTAssertLessThanOrEqual(view.fittingSize.width, inner + 0.5, "column \(column), \(dark ? "dark" : "light"): fits")
                let natural = NSHostingController(rootView: ClearBlock(model: model) { _ in }.modifier(Themed()))
                    .sizeThatFits(in: CGSize(width: 0, height: 200))
                XCTAssertLessThanOrEqual(natural.width, 6 * ClearBlockLayout.minButtonWidth + 5 * ClearBlockLayout.buttonSpacing + 80,
                                         "the block can shrink to its minimum")
            }
        }
    }

    /// The figures for the report: the Clear block's and the tabs area's heights.
    func testHeights() async {
        let model = ClearRowModel(state: await state([]))
        for (w, h) in [(CGFloat(1440), CGFloat(900)), (1100, 720)] {
            let sizes = PanelSizes.defaults.fitted(width: w, height: h - 29)
            let inner = sizes.right - 2 * OperatorLayout.columnPadding
            let block = NSHostingView(rootView: ClearBlock(model: model) { _ in }.frame(width: inner).modifier(Themed())).fittingSize.height
            let column = h - OperatorLayout.statusBarHeight - 1
            let monitor = inner * 9 / 16
            let tabsNew = column - 2 * OperatorLayout.columnPadding - 4 * OperatorLayout.columnSpacing - 30 - monitor - block - 32
            let tabsOld = column - 2 * OperatorLayout.columnPadding - 4 * OperatorLayout.columnSpacing - 30 - monitor - 53 - 32
            print("HEIGHTS window \(w)x\(h): right column \(sizes.right), clear block \(block), tabs \(tabsNew) (before: \(tabsOld))")
            XCTAssertGreaterThanOrEqual(tabsNew, tabsOld, "the tabs keep their height")
        }
    }
}
