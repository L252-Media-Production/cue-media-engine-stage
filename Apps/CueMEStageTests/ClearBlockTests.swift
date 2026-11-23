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

    private func until(_ what: String, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(2)
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

    func testTooltipsShowAtOnce() {
        XCTAssertEqual(UserDefaults.standard.integer(forKey: CueMEStageApp.toolTipDelayKey), CueMEStageApp.toolTipDelay,
                       "registered at launch")
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
        XCTAssertEqual(slide, [.all, .slide])
        let playing = await lit([.playAudio(mediaID: walkIn)])
        XCTAssertEqual(playing, [.all, .audio], "playing")
        let paused = await lit([.playAudio(mediaID: walkIn), .pauseAudio])
        XCTAssertEqual(paused, [.all, .audio], "paused")
        let fading = await lit([.playAudio(mediaID: walkIn), .fadeAudio(seconds: 3)])
        XCTAssertEqual(fading, [.all, .audio], "fading")
        let stopped = await lit([.playAudio(mediaID: walkIn), .stopAudio])
        XCTAssertEqual(stopped, [], "stopped")
        let message = await lit([.showMessage(lib.messages[0].id, screens: [])])
        XCTAssertEqual(message, [.all, .message])
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
            (.audio, [.playAudio(mediaID: walkIn)], [.clear(.audio)]),
            (.message, [.showMessage(lib.messages[0].id, screens: [])], [.clear(.messages)]),
            (.all, [.go(itemID: amazing.id, slideIndex: 0), .playAudio(mediaID: walkIn), .showMessage(lib.messages[0].id, screens: [])],
             [.clear(.all), .clear(.audio)]),
        ]
        for (button, setup, expected) in cases {
            let store = StageStore.mock(library: lib)
            setup.forEach(store.send)
            await until("\(button) lit") { ClearRowModel(state: store.state).isLit(button) }
            let commands = ClearRowModel(state: store.state).commands(button)
            XCTAssertEqual(commands, expected, "\(button)")
            commands.forEach(store.send)
            await until("\(button) goes out") { !ClearRowModel(state: store.state).isLit(button) }
            if button == .all {
                let model = ClearRowModel(state: store.state)
                XCTAssertFalse(model.isLit(.slide) || model.isLit(.audio) || model.isLit(.message), "All cleared all three")
            }
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
