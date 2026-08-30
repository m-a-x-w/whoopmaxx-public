import XCTest
@testable import whoopmaxx

/// Regression pins for `BackfillPolicy.shouldRun` — the empty-streak exponential-backoff sync limiter.
/// These lock the CURRENT rate-limiter behaviour so a refactor can't silently loosen (battery drain) or
/// tighten (missed syncs) the floors. Constants at time of writing: periodicFloor 900s, eventFloor 90s,
/// emptyBackoffThreshold 3, maxEmptyBackoff 4×.
final class BackfillPolicyTests: XCTestCase {

    // MARK: - lastBackfillAt == nil → always run (no prior sync to floor against)

    func testNilLastAlwaysRuns() {
        for trig in [BackfillTrigger.periodic, .strap, .connect, .foreground] {
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: trig, now: 0, lastBackfillAt: nil, emptyStreak: 9))
        }
    }

    // MARK: - .manual / .autoContinue are un-floored regardless of streak / elapsed

    func testManualAndAutoContinueAlwaysRun() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 0, lastBackfillAt: 0, emptyStreak: 10))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 0, lastBackfillAt: 0, emptyStreak: 10))
    }

    // MARK: - Below threshold → backoff 1.0 (baseline floors)

    func testPeriodicBelowThresholdUses900sFloor() {
        // streak 2 < threshold 3 → backoff 1.0 → 900s floor.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 899, lastBackfillAt: 0, emptyStreak: 2))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 900, lastBackfillAt: 0, emptyStreak: 2))
    }

    func testStrapBelowThresholdUses90sFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 89, lastBackfillAt: 0, emptyStreak: 2))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 90, lastBackfillAt: 0, emptyStreak: 2))
    }

    // MARK: - streak == threshold → backoff 2.0

    func testPeriodicAtThresholdDoublesTo1800s() {
        // streak 3 → min(2^1, 4) = 2.0 → 1800s floor.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1799, lastBackfillAt: 0, emptyStreak: 3))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1800, lastBackfillAt: 0, emptyStreak: 3))
        // What WOULD have run at streak 0 (elapsed 900) is now stretched out.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 900, lastBackfillAt: 0, emptyStreak: 3))
    }

    func testStrapAtThresholdDoublesTo180s() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 179, lastBackfillAt: 0, emptyStreak: 3))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 180, lastBackfillAt: 0, emptyStreak: 3))
        // The baseline 90s floor no longer suffices.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 90, lastBackfillAt: 0, emptyStreak: 3))
    }

    // MARK: - Huge streak caps at maxEmptyBackoff (4×)

    func testPeriodicHugeStreakCapsAt4x() {
        // streak 10 → min(2^8, 4) = 4.0 → 3600s floor (not 900·256).
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 3599, lastBackfillAt: 0, emptyStreak: 10))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 3600, lastBackfillAt: 0, emptyStreak: 10))
    }

    func testStrapHugeStreakCapsAt4x() {
        // streak 10 → 4.0 → 360s floor.
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 359, lastBackfillAt: 0, emptyStreak: 10))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 360, lastBackfillAt: 0, emptyStreak: 10))
    }

    // MARK: - .connect / .foreground use eventFloor with NO backoff, even at streak 10

    func testConnectAndForegroundNeverBackOff() {
        for trig in [BackfillTrigger.connect, .foreground] {
            // 90s eventFloor holds regardless of streak (would be 360s if backoff applied).
            XCTAssertFalse(BackfillPolicy.shouldRun(trigger: trig, now: 89, lastBackfillAt: 0, emptyStreak: 10))
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: trig, now: 90, lastBackfillAt: 0, emptyStreak: 10))
        }
    }
}
