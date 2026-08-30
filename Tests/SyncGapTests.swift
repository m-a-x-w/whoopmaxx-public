import XCTest
@testable import whoopmaxx

/// Pins for `SyncGap` — the Live tab sync-progress row's gap clamps + compact-duration formatting.
/// These lock the CURRENT edge behaviour: nil frontier reads "first sync", anything under the
/// 5-minute floor (including a frontier AHEAD of now — strap clock drift) reads "caught up", and the
/// duration is always the two largest non-zero units ("2d 4h" / "4h 12m" / "12m"), never a percent.
final class SyncGapTests: XCTestCase {

    /// A fixed "now" so every gap below is exact — no wall clock in these tests.
    private let now: TimeInterval = 1_700_000_000

    // MARK: - Word states (no numeral)

    func testNilFrontierReadsFirstSync() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: nil, now: now), .firstSync)
    }

    func testGapUnderFiveMinutesReadsCaughtUp() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: now, now: now), .caughtUp)
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 1, now: now), .caughtUp)
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 299, now: now), .caughtUp)
    }

    func testFrontierInFutureReadsCaughtUpNotNegative() {
        // Strap clock drifted ahead of the phone — must clamp to "caught up", never a negative gap.
        XCTAssertEqual(SyncGap.reading(frontierUnix: now + 3_600, now: now), .caughtUp)
    }

    // MARK: - The 5-minute boundary flips to a numeral

    func testExactlyFiveMinutesReadsBehind() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 300, now: now), .behind("5m"))
    }

    // MARK: - Compact duration tiers

    func testMinutesOnly() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 12 * 60, now: now), .behind("12m"))
        // Sub-minute remainder truncates — 12m59s is still an honest "12m".
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - (12 * 60 + 59), now: now), .behind("12m"))
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - (4 * 3_600 + 12 * 60), now: now),
                       .behind("4h 12m"))
        // Exactly on the hour drops the zero remainder — "4h", never "4h 0m".
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 4 * 3_600, now: now), .behind("4h"))
        // The hour boundary itself: 59m is minutes-only, 60m tips into hours.
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 59 * 60, now: now), .behind("59m"))
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 60 * 60, now: now), .behind("1h"))
    }

    func testDaysAndHours() {
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - (2 * 86_400 + 4 * 3_600), now: now),
                       .behind("2d 4h"))
        // Exactly on the day drops the zero remainder — "2d", never "2d 0h".
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 2 * 86_400, now: now), .behind("2d"))
        // The day boundary itself: 23h 59m stays hours+minutes, 24h tips into days — and the
        // minutes remainder is dropped at the day tier (two largest units only).
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - (23 * 3_600 + 59 * 60), now: now),
                       .behind("23h 59m"))
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - 86_400, now: now), .behind("1d"))
        XCTAssertEqual(SyncGap.reading(frontierUnix: now - (86_400 + 30 * 60), now: now),
                       .behind("1d"))
    }
}
