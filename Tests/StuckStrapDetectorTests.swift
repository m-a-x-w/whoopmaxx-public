import XCTest
@testable import whoopmaxx

/// Regression pins for `StuckStrapDetector.observe` — the behind-AND-frozen state machine that decides a
/// strap is "stuck" (reporting records newer than ours, while our persisted-HR frontier hasn't advanced).
/// Config under test: stuckAfterSeconds 60, behindGapSeconds 300.
final class StuckStrapDetectorTests: XCTestCase {

    private func detector() -> StuckStrapDetector {
        StuckStrapDetector(stuckAfterSeconds: 60, behindGapSeconds: 300)
    }

    /// The first observation only seeds the frontier/clock — never stuck, even when already far behind.
    func testFirstObservationSeedsAndIsNotStuck() {
        var d = detector()
        XCTAssertFalse(d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 0))
    }

    /// An advancing frontier resets the clock and reports healthy, even when the strap is way ahead and a
    /// long time has passed since the seed.
    func testAdvancingFrontierResetsEvenWhenBehind() {
        var d = detector()
        _ = d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 0)     // seed
        XCTAssertFalse(d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_100, now: 10_000))
    }

    /// Strap within behindGapSeconds (300s) of our frontier → caught up / off-wrist, never stuck, even
    /// long after the frozen window would otherwise trip.
    func testNotBehindIsNeverStuck() {
        var d = detector()
        _ = d.observe(strapNewestTs: 5_200, ourFrontierTs: 5_000, now: 0)      // seed (gap 200 ≤ 300)
        XCTAssertFalse(d.observe(strapNewestTs: 5_200, ourFrontierTs: 5_000, now: 10_000))
    }

    /// Behind by > 300s AND frontier frozen for ≥ 60s → stuck.
    func testBehindAndFrozenAtThresholdIsStuck() {
        var d = detector()
        _ = d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 0)     // seed
        XCTAssertTrue(d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 60))
    }

    /// Behind but frozen only 59s (one below the threshold) → not yet stuck.
    func testBehindButFrozenBelowThresholdIsNotStuck() {
        var d = detector()
        _ = d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 0)     // seed
        XCTAssertFalse(d.observe(strapNewestTs: 10_000, ourFrontierTs: 5_000, now: 59))
    }

    /// A nil strap-newest OR nil frontier short-circuits to false (nothing to compare).
    func testNilInputsAreNeverStuck() {
        var d = detector()
        XCTAssertFalse(d.observe(strapNewestTs: nil, ourFrontierTs: 5_000, now: 100))
        XCTAssertFalse(d.observe(strapNewestTs: 10_000, ourFrontierTs: nil, now: 100))
    }
}
