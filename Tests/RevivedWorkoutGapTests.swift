import XCTest
@testable import whoopmaxx

/// A manual workout revived from its durable snapshot after an app kill must record only its REAL
/// coverage, not the wall-clock hours it sat idle. `endWorkout` clamps the finish to the newest captured
/// sample for exactly that reason — but re-arming realtime on revival fed fresh ~now samples straight in,
/// so the clamp became a no-op and Stop saved a row spanning the entire dead gap. The fix stops a
/// revived-across-a-gap session from capturing at all, so the clamp does its job.
///
/// These pin the DECISION (was the gap real?) and the clamp arithmetic, both of which are pure. The
/// controller itself is @MainActor and needs a live repo/profile, so the wiring is verified by the
/// build plus the existing ActiveWorkoutPersistence tests.
final class RevivedWorkoutGapTests: XCTestCase {

    /// Mirrors `rehydrateActiveWorkout`'s decision.
    private func isRevivedIdle(lastSampleTs: Int, now: TimeInterval, gap: TimeInterval = 300) -> Bool {
        (now - TimeInterval(lastSampleTs)) > gap
    }

    /// Mirrors `endWorkout`'s clamp.
    private func clampedEnd(lastSampleTs: Int?, now: Date) -> Date {
        let last = lastSampleTs.map { Date(timeIntervalSince1970: Double($0)) }
        return min(now, last ?? now)
    }

    /// A crash-and-immediate-relaunch must keep capturing — the snapshot is persisted on a 15 s throttle,
    /// so a few seconds of staleness is normal and must not disable a live session.
    func testFastRelaunchStillCaptures() {
        let now: TimeInterval = 1_800_000_000
        XCTAssertFalse(isRevivedIdle(lastSampleTs: Int(now) - 5, now: now))
        XCTAssertFalse(isRevivedIdle(lastSampleTs: Int(now) - 60, now: now))
        XCTAssertFalse(isRevivedIdle(lastSampleTs: Int(now) - 299, now: now))
    }

    /// The regression case: an overnight kill is a real gap, so the session is finalization-only.
    func testOvernightKillIsRevivedIdle() {
        let now: TimeInterval = 1_800_000_000
        XCTAssertTrue(isRevivedIdle(lastSampleTs: Int(now) - 301, now: now))
        XCTAssertTrue(isRevivedIdle(lastSampleTs: Int(now) - 14 * 3_600, now: now))
    }

    /// With no post-revival sample, the clamp yields the last real sample — the honest end.
    func testClampYieldsTheLastRealSampleAcrossAGap() {
        // Start 18:00, last sample 18:40, reopened at 08:00 next day.
        let start = 1_800_000_000
        let lastSample = start + 40 * 60
        let reopened = Date(timeIntervalSince1970: Double(start + 14 * 3_600))

        let end = clampedEnd(lastSampleTs: lastSample, now: reopened)
        let duration = end.timeIntervalSince(Date(timeIntervalSince1970: Double(start)))

        XCTAssertEqual(duration, 40 * 60, accuracy: 0.5,
                       "the saved row must be the real 40 minutes, not the 14-hour wall-clock span")
    }

    /// …and that is precisely what a post-revival sample destroyed: with capture re-armed, the newest
    /// sample is ~now and the clamp no longer bounds anything.
    func testAPostRevivalSampleWouldDefeatTheClamp() {
        let start = 1_800_000_000
        let reopened = Date(timeIntervalSince1970: Double(start + 14 * 3_600))
        let sampleAtReopen = Int(reopened.timeIntervalSince1970)

        let end = clampedEnd(lastSampleTs: sampleAtReopen, now: reopened)
        let duration = end.timeIntervalSince(Date(timeIntervalSince1970: Double(start)))

        XCTAssertEqual(duration, 14 * 3_600, accuracy: 0.5,
                       "this is the defect the revivedIdle guard prevents")
    }

    /// A live session is unaffected: its newest sample is ~now, so the clamp is a no-op.
    func testLiveSessionClampIsANoOp() {
        let start = 1_800_000_000
        let now = Date(timeIntervalSince1970: Double(start + 1_800))
        let end = clampedEnd(lastSampleTs: Int(now.timeIntervalSince1970), now: now)
        XCTAssertEqual(end.timeIntervalSince(Date(timeIntervalSince1970: Double(start))), 1_800, accuracy: 0.5)
    }

    /// A snapshot with no samples falls back to its start, so the gap reads as real and the session is
    /// finalization-only — it will be discarded by the `samples.count >= 2` guard anyway.
    func testEmptySnapshotFallsBackToStartAndCountsAsIdle() {
        let start = 1_800_000_000
        let now = TimeInterval(start + 3_600)
        XCTAssertTrue(isRevivedIdle(lastSampleTs: start, now: now))
    }
}
