import XCTest
@testable import whoopmaxx

/// Pins the central live-HR smoother (lifted out of `AppRoot.ingestHR`): the 30–220 plausibility clamp
/// with its 60000/R-R fallback, both window bounds (~10 s / 40 samples), and the #39 rule — a dropped
/// link blanks the median instead of freezing the last value, while a transient garbage sample with the
/// link still up keeps it.
final class HRSmootherTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Clamp

    func testRejectsImplausibleReportedHR() {
        var s = HRSmoother()
        XCTAssertNil(s.ingest(heartRate: 0, rr: [], now: t0))      // garbage zero
        XCTAssertNil(s.ingest(heartRate: 29, rr: [], now: t0))     // below the floor
        XCTAssertNil(s.ingest(heartRate: 221, rr: [], now: t0))    // above the ceiling
        XCTAssertEqual(s.sampleCount, 0)

        XCTAssertEqual(s.ingest(heartRate: 30, rr: [], now: t0), 30)     // inclusive floor
        XCTAssertEqual(s.ingest(heartRate: 220, rr: [], now: t0), 220)   // inclusive ceiling
        XCTAssertEqual(s.sampleCount, 2)
    }

    func testFallsBackToRRWhenNoReportedHR() {
        var s = HRSmoother()
        XCTAssertEqual(s.ingest(heartRate: nil, rr: [500], now: t0), 120)   // 60000/500
        // An R-R that decodes outside the clamp is rejected, and a zero R-R is not divided by — both
        // leave the window (and so the median) untouched.
        XCTAssertEqual(s.ingest(heartRate: nil, rr: [100], now: t0), 120)   // 600 bpm → rejected
        XCTAssertEqual(s.ingest(heartRate: nil, rr: [0], now: t0), 120)
        XCTAssertEqual(s.sampleCount, 1)
    }

    // MARK: - Window bounds

    func testDropsSamplesOlderThanTheTimeWindow() {
        var s = HRSmoother()
        XCTAssertEqual(s.ingest(heartRate: 60, rr: [], now: t0), 60)
        // Still inside ~10 s: both samples count (median of two takes the upper).
        XCTAssertEqual(s.ingest(heartRate: 180, rr: [], now: t0.addingTimeInterval(5)), 180)
        XCTAssertEqual(s.sampleCount, 2)
        // 11 s past the first sample — it falls out of the window on this ingest.
        XCTAssertEqual(s.ingest(heartRate: 200, rr: [], now: t0.addingTimeInterval(11)), 200)
        XCTAssertEqual(s.sampleCount, 2)
    }

    func testCapsTheWindowAtFortySamples() {
        var s = HRSmoother()
        // All at the same instant, so only the sample cap can bound the window.
        for i in 0..<50 { _ = s.ingest(heartRate: 100 + (i % 5), rr: [], now: t0) }
        XCTAssertEqual(s.sampleCount, 40)
    }

    func testShortSmoothReadsOnlyTheTrailingSeconds() {
        var s = HRSmoother()
        _ = s.ingest(heartRate: 60, rr: [], now: t0)
        _ = s.ingest(heartRate: 120, rr: [], now: t0.addingTimeInterval(8))
        _ = s.ingest(heartRate: 180, rr: [], now: t0.addingTimeInterval(9))
        let now = t0.addingTimeInterval(9)
        XCTAssertEqual(s.smoothedBpm(over: 5, now: now), 180)    // [120, 180]
        XCTAssertEqual(s.smoothedBpm(over: 30, now: now), 120)   // [60, 120, 180]
    }

    // MARK: - #39 blank-on-disconnect

    func testBlanksWhenBothLiveSourcesGoAway() {
        var s = HRSmoother()
        XCTAssertEqual(s.ingest(heartRate: 70, rr: [], now: t0), 70)
        // Disconnect blanks heartRate AND rr — drop the stale median rather than freeze it.
        XCTAssertNil(s.ingest(heartRate: nil, rr: [], now: t0.addingTimeInterval(1)))
        XCTAssertEqual(s.sampleCount, 0)
        XCTAssertNil(s.smoothedBpm(over: 5, now: t0.addingTimeInterval(1)))
    }

    func testTransientGarbageKeepsTheLastMedianWhileTheLinkIsUp() {
        var s = HRSmoother()
        XCTAssertEqual(s.ingest(heartRate: 70, rr: [], now: t0), 70)
        // Out of range on BOTH lanes, but the strap is still reporting — hold the median.
        XCTAssertEqual(s.ingest(heartRate: 500, rr: [100], now: t0.addingTimeInterval(1)), 70)
        XCTAssertEqual(s.sampleCount, 1)
    }

    func testResetDropsTheWholeWindow() {
        var s = HRSmoother()
        _ = s.ingest(heartRate: 70, rr: [], now: t0)
        s.reset()
        XCTAssertEqual(s.sampleCount, 0)
        XCTAssertNil(s.smoothedBpm(over: 10, now: t0))
    }
}
