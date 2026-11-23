import XCTest
@testable import CueMEStage

/// The single-instance decision. The real second launch (activating the first copy and quitting) cannot run inside the
/// test host; see the task report for the manual check.
final class SingleInstanceTests: XCTestCase {
    private let me: pid_t = 500
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func copy(_ pid: pid_t, _ seconds: Double? = nil, terminated: Bool = false) -> SingleInstance.Copy {
        .init(pid: pid, launchDate: seconds.map { t0.addingTimeInterval($0) }, isTerminated: terminated)
    }

    func testAloneItLaunches() {
        XCTAssertEqual(SingleInstance.decide(running: [], current: me, environment: [:]), .proceed)
        XCTAssertEqual(SingleInstance.decide(running: [copy(me, 5)], current: me, environment: [:]), .proceed, "only itself")
    }

    func testAnotherCopyTakesOver() {
        XCTAssertEqual(SingleInstance.decide(running: [copy(me, 5), copy(321, 1)], current: me, environment: [:]), .handOff(to: 321))
    }

    func testTheOldestOfSeveralWins() {
        let running = [copy(me, 9), copy(600, 4), copy(321, 1), copy(700, 3)]
        XCTAssertEqual(SingleInstance.decide(running: running, current: me, environment: [:]), .handOff(to: 321))
    }

    func testATerminatingCopyDoesNotCount() {
        XCTAssertEqual(SingleInstance.decide(running: [copy(me, 5), copy(321, 1, terminated: true)], current: me, environment: [:]), .proceed)
    }

    func testTheTestHostIsExempt() {
        let env = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        XCTAssertEqual(SingleInstance.decide(running: [copy(me), copy(321)], current: me, environment: env), .proceed)
    }

    func testTheEnvironmentFlagAllowsMore() {
        XCTAssertEqual(SingleInstance.decide(running: [copy(me), copy(321)], current: me, environment: ["CUEME_ALLOW_MULTIPLE": "1"]), .proceed)
        XCTAssertEqual(SingleInstance.decide(running: [copy(me), copy(321)], current: me, environment: ["CUEME_ALLOW_MULTIPLE": "0"]),
                       .handOff(to: 321), "only 1 allows it")
        XCTAssertEqual(SingleInstance.decide(running: [copy(me), copy(321)], current: me, environment: ["CUEME_ALLOW_MULTIPLE": ""]),
                       .handOff(to: 321))
    }

    func testThisTestHostIsNotStopped() {
        // The test host itself got past the check, and it reports the exemption.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        XCTAssertEqual(SingleInstance.decide(running: [copy(me), copy(321)], current: me, environment: ProcessInfo.processInfo.environment), .proceed)
    }
}
