import XCTest
@testable import whoopmaxx

/// SignalQuality (007 F4): worst-of grading over the session counters, with a plain-English
/// reason per finding and no reasons on a clean pass.
final class SignalQualityTests: XCTestCase {

    func testCleanSessionIsGoodWithNoReasons() {
        let a = SignalQuality.grade(rejectedFrames: 0, consoleOnly: false, reconnects: 0)
        XCTAssertEqual(a.grade, .good)
        XCTAssertTrue(a.reasons.isEmpty)
    }

    func testOrdinaryBleWeatherStaysGood() {
        // A couple of link drops per session is normal — below the fair threshold.
        let a = SignalQuality.grade(rejectedFrames: 0, consoleOnly: false,
                                    reconnects: SignalQuality.reconnectsFairThreshold - 1)
        XCTAssertEqual(a.grade, .good)
        XCTAssertTrue(a.reasons.isEmpty)
    }

    func testRejectedFramesAreFairThenPoor() {
        let fair = SignalQuality.grade(rejectedFrames: 3, consoleOnly: false, reconnects: 0)
        XCTAssertEqual(fair.grade, .fair)
        XCTAssertEqual(fair.reasons.count, 1)
        XCTAssertTrue(fair.reasons[0].contains("3"))

        let poor = SignalQuality.grade(rejectedFrames: SignalQuality.rejectedPoorThreshold,
                                       consoleOnly: false, reconnects: 0)
        XCTAssertEqual(poor.grade, .poor)
    }

    func testConsoleOnlySessionIsPoorAndNamesTheClock() {
        let a = SignalQuality.grade(rejectedFrames: 0, consoleOnly: true, reconnects: 0)
        XCTAssertEqual(a.grade, .poor)
        XCTAssertTrue(a.reasons.contains { $0.localizedCaseInsensitiveContains("clock") })
    }

    func testReconnectThresholds() {
        let fair = SignalQuality.grade(rejectedFrames: 0, consoleOnly: false,
                                       reconnects: SignalQuality.reconnectsFairThreshold)
        XCTAssertEqual(fair.grade, .fair)
        let poor = SignalQuality.grade(rejectedFrames: 0, consoleOnly: false,
                                       reconnects: SignalQuality.reconnectsPoorThreshold)
        XCTAssertEqual(poor.grade, .poor)
    }

    func testWorstOfWinsAndEveryFindingKeepsItsReason() {
        // Fair-grade rejections + poor-grade console-only ⇒ poor overall, BOTH reasons kept.
        let a = SignalQuality.grade(rejectedFrames: 2, consoleOnly: true,
                                    reconnects: SignalQuality.reconnectsFairThreshold)
        XCTAssertEqual(a.grade, .poor)
        XCTAssertEqual(a.reasons.count, 3)
    }

    func testDurationAndSpanFormatting() {
        XCTAssertEqual(StrapHealthFormat.duration(seconds: 2 * 3_600 + 35 * 60), "2h 35m")
        XCTAssertEqual(StrapHealthFormat.duration(seconds: 45 * 60), "45m")
        // 9,300 s = the demo gap shape: 2h 35m.
        XCTAssertEqual(StrapHealthFormat.duration(seconds: 9_300), "2h 35m")
    }
}
