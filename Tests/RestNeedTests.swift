import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// The personalized sleep need (`ScoreEngine.personalNeedHours`) the hero Rest score is scored
/// against — and, since the Rest screen's need-line + 7-night debt read the SAME function, the one
/// derivation all three surfaces share. Pure over `repo.days`: trailing mean of nightly asleep hours
/// (nights with `totalSleepMin > 0` only), floored at 7.5 h; under 7 nights fall back to
/// `Rest.defaultNeedHours` (8 h). Asserted in MINUTES (× 60) — the unit the Rest
/// screen renders.
final class RestNeedTests: XCTestCase {

    /// Under the 7-night floor the personal mean is not trusted — fall back to the 8 h default.
    func testFallsBackToDefaultUnderMinNights() {
        // 6 nights, would-be 9 h mean.
        let days = (0..<6).map { Fixtures.dailyMetric(day: "2026-06-0\($0)", totalSleepMin: 540) }
        XCTAssertEqual(ScoreEngine.personalNeedHours(days: days) * 60,
                       Rest.defaultNeedHours * 60, accuracy: 1e-9)
    }

    /// At/above the floor the trailing mean drives the need. 7 nights of 9 h → 540 min.
    func testTrailingMeanAboveFloor() {
        let days = (0..<7).map { Fixtures.dailyMetric(day: "2026-06-1\($0)", totalSleepMin: 540) }
        XCTAssertEqual(ScoreEngine.personalNeedHours(days: days) * 60, 540, accuracy: 1e-9)
    }

    /// A short sleeper's mean is floored at 7.5 h so the need never drops below a healthy minimum.
    /// 7 nights of 6 h (mean 6 h) → floored to 7.5 h = 450 min.
    func testFlooredAtSevenAndAHalfHours() {
        let days = (0..<7).map { Fixtures.dailyMetric(day: "2026-06-2\($0)", totalSleepMin: 360) }
        XCTAssertEqual(ScoreEngine.personalNeedHours(days: days) * 60, 450, accuracy: 1e-9)
    }

    /// Nil and zero-minute nights are excluded from BOTH the count and the mean (only `tst > 0`
    /// counts). Here seven 8 h nights → 8 h = 480, with the 0/nil rows ignored (they neither drag the
    /// mean down nor pad the count).
    func testIgnoresZeroAndNilNights() {
        var days = (0..<7).map { Fixtures.dailyMetric(day: "2026-06-3\($0)", totalSleepMin: 480) }
        days.append(Fixtures.dailyMetric(day: "2026-07-01", totalSleepMin: 0))
        days.append(Fixtures.dailyMetric(day: "2026-07-02", totalSleepMin: nil))
        XCTAssertEqual(ScoreEngine.personalNeedHours(days: days) * 60, 480, accuracy: 1e-9)
    }

    /// The empty-history case is the cold-start default (8 h).
    func testEmptyHistoryIsDefault() {
        XCTAssertEqual(ScoreEngine.personalNeedHours(days: []) * 60,
                       Rest.defaultNeedHours * 60, accuracy: 1e-9)
    }
}
