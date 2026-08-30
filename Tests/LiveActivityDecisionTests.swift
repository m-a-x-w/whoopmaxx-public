import XCTest
@testable import whoopmaxx

/// The Live-Activity start/stop truth table, pure so it's tested away from ActivityKit (which can't run
/// under XCTest). Covers the continuous auto path and the manual pin path (which passes autoStart=true).
final class LiveActivityDecisionTests: XCTestCase {

    func testSystemDisabledDoesNothing() {
        // Even connected + streaming + an activity showing: the master switch off means hands-off (the
        // request would throw, and an existing activity is the system's to dismiss).
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: false, connected: true, hasBpm: true,
                                                   activityExists: true, autoStartEnabled: true), .none)
    }

    func testDisconnectEndsExistingActivity() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: false, hasBpm: false,
                                                   activityExists: true, autoStartEnabled: false), .end)
    }

    func testDisconnectWithNoActivityDoesNothing() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: false, hasBpm: false,
                                                   activityExists: false, autoStartEnabled: true), .none)
    }

    func testConnectedWithActivityAndBpmUpdates() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: true, hasBpm: true,
                                                   activityExists: true, autoStartEnabled: false), .update)
    }

    /// Connected, an activity is up, but no bpm this tick → hold (don't push a nil, don't tear down).
    func testConnectedWithActivityButNoBpmHolds() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: true, hasBpm: false,
                                                   activityExists: true, autoStartEnabled: false), .none)
    }

    /// Auto path: connected + bpm but the auto-start toggle is OFF → never auto-start.
    func testAutoStartOffDoesNotStart() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: true, hasBpm: true,
                                                   activityExists: false, autoStartEnabled: false), .none)
    }

    /// Auto path: connected + bpm + toggle ON → start.
    func testAutoStartOnStarts() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: true, hasBpm: true,
                                                   activityExists: false, autoStartEnabled: true), .start)
    }

    /// Manual pin (autoStartEnabled forced true) still needs a bpm to show.
    func testManualStartNeedsBpm() {
        XCTAssertEqual(LiveActivityDecision.decide(systemEnabled: true, connected: true, hasBpm: false,
                                                   activityExists: false, autoStartEnabled: true), .none)
    }
}
