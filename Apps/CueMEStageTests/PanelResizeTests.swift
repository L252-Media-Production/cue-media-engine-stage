import AppKit
import Observation
import SwiftUI
import XCTest
import StageKit
@testable import CueMEStage

/// The bins' side columns, the collections list height, and the divider itself: defaults, clamps, reset, storage,
/// shrink and restore.
final class PanelResizeModelTests: XCTestCase {
    func testBinDefaultsAreTheBoardWidths() {
        XCTAssertEqual(BinColumnSizes.defaults, BinColumnSizes(leading: 250, trailing: 250), "Main.dc.html L263, L314, L417, L453")
        // The bottom panel at 1440 with the default service panel and right column: 1440 - 280 - 360 - 2.
        XCTAssertEqual(BinColumnSizes.defaults.fitted(width: 798), .defaults)
    }

    func testBinColumnsAreClamped() {
        let d = BinColumnSizes.defaults, wide: CGFloat = 2000
        XCTAssertEqual(d.setting(.leading, to: 50, width: wide).leading, 180)
        XCTAssertEqual(d.setting(.leading, to: 900, width: wide).leading, 420)
        XCTAssertEqual(d.setting(.trailing, to: 50, width: wide).trailing, 180)
        XCTAssertEqual(d.setting(.trailing, to: 900, width: wide).trailing, 420)
        XCTAssertEqual(d.setting(.leading, to: 301, width: wide).leading, 301, "inside the range: as dragged")
        XCTAssertEqual(d.setting(.leading, to: 301, width: wide).trailing, 250, "the other column keeps its width")
    }

    func testTheMiddleKeepsItsMinimum() {
        let width: CGFloat = 798
        let grown = BinColumnSizes.defaults.setting(.trailing, to: 420, width: width)
        XCTAssertEqual(width - 2 - grown.leading - grown.trailing, BinColumnSizes.middleMin, "the divider stops at the track list's minimum")
        let both = BinColumnSizes(leading: 420, trailing: 420).fitted(width: width)
        XCTAssertGreaterThanOrEqual(width - 2 - both.leading - both.trailing, BinColumnSizes.middleMin)
    }

    func testBinShrinkAndRestore() {
        let stored = BinColumnSizes(leading: 380, trailing: 330)
        let narrow = stored.fitted(width: 700)
        XCTAssertLessThan(narrow.leading + narrow.trailing, stored.leading + stored.trailing, "shrunk to fit")
        XCTAssertGreaterThanOrEqual(700 - 2 - narrow.leading - narrow.trailing, BinColumnSizes.middleMin)
        XCTAssertEqual(stored.fitted(width: 1400), stored, "a wider bin gives the stored widths back")
        let tiny = stored.fitted(width: 300)
        XCTAssertEqual(tiny, BinColumnSizes(leading: 180, trailing: 180), "the minimums win in a bin too narrow for all")
    }

    func testBinReset() {
        let s = BinColumnSizes(leading: 300, trailing: 400)
        XCTAssertEqual(s.resetting(.leading), BinColumnSizes(leading: 250, trailing: 400))
        XCTAssertEqual(s.resetting(.trailing), BinColumnSizes(leading: 300, trailing: 250))
    }

    func testCollectionsHeight() {
        XCTAssertNil(CollectionsHeight.fitted(nil, shared: 500), "until dragged it fits its rows")
        XCTAssertEqual(ServicePanelLayout.collectionsHeight(rows: 1), 27)
        XCTAssertEqual(ServicePanelLayout.collectionsHeight(rows: 40), 150, "as before")
        XCTAssertEqual(CollectionsHeight.clamp(20, shared: 500), 80)
        XCTAssertEqual(CollectionsHeight.clamp(450, shared: 500), 380, "the service list keeps 120")
        XCTAssertEqual(CollectionsHeight.clamp(200, shared: 500), 200)
        XCTAssertEqual(CollectionsHeight.fitted(300, shared: 350), 230, "a shorter window shrinks it")
        XCTAssertEqual(CollectionsHeight.fitted(300, shared: 800), 300, "and a taller one gives it back")
        XCTAssertEqual(CollectionsHeight.fitted(300, shared: 150), 80, "the collections minimum wins in a tiny window")
    }

    func testTheDivider() {
        XCTAssertGreaterThanOrEqual(PanelDivider.hitThickness, 8)
        XCTAssertEqual(PanelDivider.dragged(start: 330, delta: -40, direction: -1), 370, "dragging the bottom divider up grows it")
        XCTAssertEqual(PanelDivider.dragged(start: 250, delta: 30, direction: 1), 280)
    }

    func testKeysAndResetAll() throws {
        let keys = [StorageKeys.collectionsHeight, StorageKeys.audioLibraryWidth, StorageKeys.audioInspectorWidth,
                    StorageKeys.mediaFolderWidth, StorageKeys.mediaInspectorWidth]
        XCTAssertEqual(keys, ["cueme.layout.collectionsHeight", "cueme.layout.audioLibraryWidth", "cueme.layout.audioInspectorWidth",
                              "cueme.layout.mediaFolderWidth", "cueme.layout.mediaInspectorWidth"])
        XCTAssertEqual(Set(PanelSizes.storageKeys).count, PanelSizes.storageKeys.count)
        for key in keys { XCTAssertTrue(PanelSizes.storageKeys.contains(key), key) }
        let store = try XCTUnwrap(UserDefaults(suiteName: "cueme.tests.resize.\(UUID().uuidString)"))
        for key in PanelSizes.storageKeys { store.set(123.0, forKey: key) }
        PanelSizes.resetAll(in: store)
        for key in PanelSizes.storageKeys { XCTAssertNil(store.object(forKey: key), "View > Reset Panel Sizes forgets \(key)") }
    }
}

/// The real bottom panel, hosted at several heights (as a drag sets them), with its frames read back: the tab bar and
/// the content always meet, every bin column starts at the content's top, and no tab changes the height.
@MainActor
final class BottomPanelLayoutTests: StudioEditTestCase {
    @Observable final class Height { var value: CGFloat = 330 }

    private var windows: [NSWindow] = []
    private var layout: UserDefaults!
    private let probe = LayoutProbe()
    private let height = Height()

    override func setUp() async throws {
        try await super.setUp()
        layout = UserDefaults(suiteName: "cueme.tests.layout.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        try await super.tearDown()
    }

    private struct Host: View {
        let panel: BottomPanel
        let height: Height
        var body: some View {
            VStack(spacing: 0) {
                Color.clear // the slide grid's place
                panel.frame(height: height.value, alignment: .top)
            }
        }
    }

    /// The bottom panel with a video selected in the Media bin and a track in the Audio bin (the inspectors are the
    /// tallest content), 798 pt wide as at 1440 with the default columns.
    private func host() async -> (video: MediaItem.ID, track: MediaItem.ID) {
        await launch()
        let video = MediaIndexEntry(id: UUID(), name: "loop_a.mov", kind: .video, duration: 30, lastKnownPath: "/nowhere/loop_a.mov")
        controller.edit { $0.media.append(video) }
        let track = try! XCTUnwrap(studio.media.first { $0.kind == .audio }).id
        let panel = BottomPanel(state: stage.state, send: stage.send, studios: controller, ui: OperatorUIState(),
                                mediaSelection: video.id, audioSelection: track)
        let root = Host(panel: panel, height: height)
            .modifier(Themed())
            .environment(\.layoutProbe, probe)
            .defaultAppStorage(layout)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 798, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        windows.append(window)
        await settle()
        return (video.id, track)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    private func select(_ tab: BottomTab) async {
        layout.set(tab.rawValue, forKey: StorageKeys.bottomTab)
        await settle()
    }

    private func frame(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        guard let frame = probe[name] else { XCTFail("no frame for \(name)", file: file, line: line); return .zero }
        return frame
    }

    /// The tab bar at the panel's top, the content right under it to the panel's bottom, the bin's columns from the
    /// content's top, none taller than the content.
    private func assertRigid(_ bin: String?, at h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let panel = frame("bottom.panel"), header = frame("bottom.header"), content = frame("bottom.content")
        let what = "at \(h) pt"
        XCTAssertEqual(panel.height, h, accuracy: 0.5, "the panel is the height it was given, \(what)", file: file, line: line)
        XCTAssertEqual(header.minY, panel.minY, accuracy: 0.5, "the tab bar is at the panel's top, \(what)", file: file, line: line)
        XCTAssertEqual(content.minY, header.maxY, accuracy: 0.5, "no gap under the tab bar, \(what)", file: file, line: line)
        XCTAssertEqual(content.maxY, panel.maxY, accuracy: 0.5, "the content ends at the panel's bottom, \(what)", file: file, line: line)
        guard let bin else { return }
        for column in ["leading", "middle", "trailing"] {
            let f = frame("\(bin).\(column)", file: file, line: line)
            XCTAssertEqual(f.minY, content.minY, accuracy: 0.5, "\(bin) \(column) starts at the content's top, \(what)", file: file, line: line)
            XCTAssertEqual(f.height, content.height, accuracy: 0.5, "\(bin) \(column) fills the content, \(what)", file: file, line: line)
        }
    }

    /// Heights a drag passes through, from the minimum (where the inspectors are far taller than the room) to tall,
    /// including fractional mid-drag values.
    private let heights: [CGFloat] = [200, 213.5, 247, 268.25, 301, 330, 377.75, 450, 512]

    func testTheTabBarAndTheContentMoveTogetherAtEveryHeight() async {
        _ = await host()
        for (tab, bin) in [(BottomTab.media, "media"), (.audio, "audio")] {
            await select(tab)
            XCTAssertNotNil(probe["\(bin).inspector"], "the \(bin) inspector is open (the tallest content)")
            for h in heights {
                height.value = h
                await settle()
                assertRigid(bin, at: h)
            }
            // Back down, as a drag the other way.
            for h in heights.reversed() {
                height.value = h
                await settle()
                assertRigid(bin, at: h)
            }
        }
    }

    func testSwitchingTabsNeverChangesTheHeight() async {
        _ = await host()
        for h: CGFloat in [214, 330, 470] {
            height.value = h
            await settle()
            var tops: [CGFloat] = []
            for tab in BottomTab.allCases + BottomTab.allCases.reversed() {
                await select(tab)
                assertRigid(nil, at: h)
                tops.append(frame("bottom.content").minY)
            }
            XCTAssertEqual(Set(tops.map { Int(($0 * 2).rounded()) }).count, 1, "the content starts at the same place on every tab, at \(h)")
        }
    }

    func testTheCollectionsListKeepsItsDraggedHeight() async throws {
        await launch()
        let panelHeight = Height()
        panelHeight.value = 700
        struct ServiceHost: View {
            let panel: ServicePanel
            let height: Height
            var body: some View { panel.frame(width: 280, height: height.value, alignment: .top) }
        }
        let panel = ServicePanel(state: stage.state, studio: studio, relink: nil, ui: OperatorUIState(), go: { _ in }, addSection: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 280, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ServiceHost(panel: panel, height: panelHeight)
            .modifier(Themed()).environment(\.layoutProbe, probe).defaultAppStorage(layout))
        window.orderFront(nil)
        windows.append(window)
        await settle()
        let rows = CollectionsModel(studio: studio, query: "", expanded: []).rows.count
        XCTAssertEqual(frame("service.collections").height, ServicePanelLayout.collectionsHeight(rows: rows), accuracy: 0.5, "fits its rows until dragged")
        let shared = frame("service.collections").height + frame("service.list").height

        layout.set(260.0, forKey: StorageKeys.collectionsHeight)
        await settle()
        XCTAssertEqual(frame("service.collections").height, 260, accuracy: 0.5, "the dragged height, kept on this machine")
        XCTAssertEqual(frame("service.collections").height + frame("service.list").height, shared, accuracy: 1, "the list gives up the room")
        layout.set(10.0, forKey: StorageKeys.collectionsHeight)
        await settle()
        XCTAssertEqual(frame("service.collections").height, CollectionsHeight.min, accuracy: 0.5)

        layout.set(400.0, forKey: StorageKeys.collectionsHeight)
        panelHeight.value = 450
        await settle()
        await settle()
        XCTAssertGreaterThanOrEqual(frame("service.list").height, CollectionsHeight.listMin - 1, "a shorter window shrinks the collections")
        panelHeight.value = 700
        await settle()
        await settle()
        XCTAssertEqual(frame("service.collections").height, 400, accuracy: 0.5, "and a taller one gives the height back")

        PanelSizes.resetAll(in: layout)
        await settle()
        XCTAssertEqual(frame("service.collections").height, ServicePanelLayout.collectionsHeight(rows: rows), accuracy: 0.5, "reset: fits its rows")
    }

    func testBinColumnsFollowTheStoredWidths() async {
        _ = await host()
        await select(.audio)
        XCTAssertEqual(frame("audio.leading").width, 250, accuracy: 0.5, "board default")
        XCTAssertEqual(frame("audio.trailing").width, 250, accuracy: 0.5)
        layout.set(300.0, forKey: StorageKeys.audioLibraryWidth)
        layout.set(222.0, forKey: StorageKeys.audioInspectorWidth)
        await settle()
        XCTAssertEqual(frame("audio.leading").width, 300, accuracy: 0.5, "kept on this machine")
        XCTAssertEqual(frame("audio.trailing").width, 222, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frame("audio.middle").width, BinColumnSizes.middleMin)
        await select(.media)
        XCTAssertEqual(frame("media.leading").width, 250, accuracy: 0.5, "the Media bin has its own widths")
        layout.set(9999.0, forKey: StorageKeys.mediaFolderWidth)
        await settle()
        XCTAssertGreaterThanOrEqual(frame("media.middle").width, BinColumnSizes.middleMin - 0.5, "an oversized stored width is fitted")
        PanelSizes.resetAll(in: layout)
        await settle()
        XCTAssertEqual(frame("media.leading").width, 250, accuracy: 0.5, "View > Reset Panel Sizes")
        await select(.audio)
        XCTAssertEqual(frame("audio.leading").width, 250, accuracy: 0.5)
    }
}
