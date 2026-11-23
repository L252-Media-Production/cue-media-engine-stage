import XCTest
@testable import CueMEStage

/// The adjustable panel sizes: defaults, limits, reset, storage, and how they fit the 1100 and 1440 windows.
final class PanelSizesTests: XCTestCase {
    /// The operator view's main area (between the status bar and the title bar) for a window of 1100 × 720 and
    /// 1440 × 900: the full width, minus the 28 pt title bar, the 28 pt status bar and its divider.
    private let small = (width: CGFloat(1100), height: CGFloat(720 - 28 - 28 - 1), window: CGFloat(720 - 28))
    private let large = (width: CGFloat(1440), height: CGFloat(900 - 28 - 28 - 1), window: CGFloat(900 - 28))

    private func gridWidth(_ s: PanelSizes, _ width: CGFloat) -> CGFloat { width - s.service - s.right - 2 * PanelSizes.dividerThickness }

    func testDefaultsAreTheMockupSizes() {
        XCTAssertEqual(PanelSizes.defaults, PanelSizes(service: 280, right: 360, bottom: 330))
        XCTAssertEqual(PanelSizes.defaults.service, ServicePanelLayout.width)
        XCTAssertEqual(PanelSizes.defaults.right, OperatorLayout.rightColumnWidth)
        XCTAssertEqual(PanelSizes.defaults.bottom, OperatorLayout.bottomPanelHeight)
        for area in [small, large] {
            XCTAssertEqual(PanelSizes.defaults.fitted(width: area.width, height: area.height, windowHeight: area.window), .defaults,
                           "the defaults fit unchanged at \(area.width)")
        }
    }

    func testEachSizeIsClampedToItsRange() {
        let huge = (width: CGFloat(4000), height: CGFloat(3000))
        let d = PanelSizes.defaults
        XCTAssertEqual(d.setting(.service, to: 100, width: huge.width, height: huge.height).service, 220)
        XCTAssertEqual(d.setting(.service, to: 999, width: huge.width, height: huge.height).service, 420)
        XCTAssertEqual(d.setting(.right, to: 100, width: huge.width, height: huge.height).right, 300)
        XCTAssertEqual(d.setting(.right, to: 999, width: huge.width, height: huge.height).right, 520)
        XCTAssertEqual(d.setting(.bottom, to: 50, width: huge.width, height: huge.height).bottom, 200)
        XCTAssertEqual(d.setting(.bottom, to: 5000, width: huge.width, height: huge.height).bottom, 0.6 * huge.height, "60 % of the window")
        XCTAssertEqual(d.setting(.service, to: 333, width: huge.width, height: huge.height).service, 333, "inside the range: as dragged")
    }

    func testAt1100TheGridKeepsItsMinimumAndNothingOverlaps() {
        let d = PanelSizes.defaults
        let wide = d.setting(.service, to: 420, width: small.width, height: small.height, windowHeight: small.window)
        XCTAssertEqual(wide.service, 1100 - 2 - 360 - PanelSizes.gridMinWidth, "the divider stops where the grid would get too narrow")
        XCTAssertEqual(gridWidth(wide, small.width), PanelSizes.gridMinWidth)
        let both = wide.setting(.right, to: 520, width: small.width, height: small.height, windowHeight: small.window)
        XCTAssertEqual(both.right, 360, "no room left for the right column to grow")
        XCTAssertEqual(both.service, wide.service, "a drag never resizes the other panel")
        let narrowRight = d.setting(.right, to: 300, width: small.width, height: small.height, windowHeight: small.window)
            .setting(.service, to: 420, width: small.width, height: small.height, windowHeight: small.window)
        XCTAssertEqual(narrowRight.right, 300)
        XCTAssertEqual(narrowRight.service, 398, "with the right column at its minimum the service panel gets the room")
        XCTAssertGreaterThanOrEqual(gridWidth(both, small.width), PanelSizes.gridMinWidth)

        let tall = d.setting(.bottom, to: 1000, width: small.width, height: small.height, windowHeight: small.window)
        XCTAssertEqual(tall.bottom, 0.6 * small.window, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(small.height - tall.bottom - 1, PanelSizes.gridMinHeight, "the grid keeps a row")
    }

    func testAt1440EveryMaximumFits() {
        let all = PanelSizes(service: 420, right: 520, bottom: 2000).fitted(width: large.width, height: large.height, windowHeight: large.window)
        XCTAssertEqual(all.service, 420)
        XCTAssertEqual(all.right, 520, "both maximums fit at 1440")
        XCTAssertEqual(gridWidth(all, large.width), 498)
        XCTAssertGreaterThanOrEqual(gridWidth(all, large.width), PanelSizes.gridMinWidth)
        XCTAssertEqual(all.bottom, 0.6 * large.window, accuracy: 0.01)
        let mins = PanelSizes(service: 0, right: 0, bottom: 0).fitted(width: large.width, height: large.height, windowHeight: large.window)
        XCTAssertEqual(mins, PanelSizes(service: 220, right: 300, bottom: 200))
    }

    func testStoredSizesFitAgainWhenTheWindowShrinks() {
        let stored = PanelSizes(service: 420, right: 520, bottom: 500)
        let fitted = stored.fitted(width: small.width, height: small.height, windowHeight: small.window)
        XCTAssertGreaterThanOrEqual(gridWidth(fitted, small.width), PanelSizes.gridMinWidth)
        XCTAssertLessThanOrEqual(fitted.bottom, 0.6 * small.window + 0.01)
        XCTAssertEqual(stored.fitted(width: 4000, height: 3000), stored, "the stored values come back in a large window")
    }

    func testResetOneAndAll() throws {
        let custom = PanelSizes(service: 300, right: 400, bottom: 250)
        XCTAssertEqual(custom.resetting(.service), PanelSizes(service: 280, right: 400, bottom: 250), "double-click: only that one")
        XCTAssertEqual(custom.resetting(.right), PanelSizes(service: 300, right: 360, bottom: 250))
        XCTAssertEqual(custom.resetting(.bottom), PanelSizes(service: 300, right: 400, bottom: 330))

        let suite = "cueme.tests.panels.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        custom.save(to: defaults)
        PanelSizes.resetAll(in: defaults)
        XCTAssertEqual(PanelSizes.load(from: defaults), .defaults, "View > Reset Panel Sizes: all three")
        XCTAssertTrue(PanelSizes.storageKeys.allSatisfy { defaults.object(forKey: $0) == nil })
    }

    func testPersistenceRoundTrip() throws {
        let suite = "cueme.tests.panels.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PanelSizes.load(from: defaults), .defaults, "nothing stored: the defaults")
        let custom = PanelSizes(service: 312, right: 444, bottom: 256)
        custom.save(to: defaults)
        XCTAssertEqual(PanelSizes.load(from: defaults), custom)
        XCTAssertEqual(defaults.double(forKey: "cueme.layout.servicePanelWidth"), 312)
        XCTAssertEqual(defaults.double(forKey: "cueme.layout.rightColumnWidth"), 444)
        XCTAssertEqual(defaults.double(forKey: "cueme.layout.bottomPanelHeight"), 256)
    }
}
