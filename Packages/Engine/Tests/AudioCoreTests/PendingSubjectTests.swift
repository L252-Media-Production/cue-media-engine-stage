import XCTest

/// The pending subject must skip, not pass and not fail.
final class PendingSubjectTests: XCTestCase {
    func testPendingSubjectThrowsSkip() {
        let subject = PendingSubject()
        XCTAssertThrowsError(try subject.fadeGain(.up, x: 0.5)) { error in
            XCTAssertTrue(error is XCTSkip, "expected XCTSkip, got \(error)")
        }
        XCTAssertThrowsError(try subject.duckLoop(DuckLoopRequest(
            settings: try! JSONDecoder().decode(DuckSettings.self, from: Data(
                #"{"duck_threshold_db":-30,"duck_ratio":6,"duck_attack_ms":10,"duck_release_ms":500,"duck_hold":true,"top_track_pct":100}"#.utf8)),
            voiceOver: try! JSONDecoder().decode(VoiceOver.self, from: Data(
                #"{"file":"v","starts_at_s":0.5,"length_s":2,"level_pct":100,"segments_s_and_sample_value":[[2,0]]}"#.utf8)),
            stepS: 0.01, lookAheadS: 0.02, backgroundLengthS: 30, backgroundAloneS: 0.5, tickEverySteps: 5, maxSteps: 620, sampleCount: 1))) { XCTAssertTrue($0 is XCTSkip) }
    }
}
