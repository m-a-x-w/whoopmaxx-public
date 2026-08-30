import XCTest
import StrapStore
@testable import whoopmaxx

/// `MetricDef.delta(series:)` — the Data-tab "vs 30-day typical" delta. Two invariants covered:
/// C3 uses a ROW-COUNT window (the last 30 prior points), the SAME population Today / the widget use,
/// so the Data tab can't disagree with them; and C2 hides a delta whose FORMATTED magnitude prints
/// zero (an exact-±0.5 integer diff renders "%.0f" → "0" — no colored zero-magnitude arrow).
final class MetricDeltaTests: XCTestCase {

    /// The RHR metric (integer format, lower-is-better) — a representative integer metric to exercise
    /// the delta rounding boundary against.
    private let rhr = MetricCatalog.all.first { $0.key == "rhr" }!

    private let base = MetricCatalog.date(fromDayKey: "2026-01-01")!
    private func day(_ n: Int) -> Date { base.addingTimeInterval(TimeInterval(n) * 86_400) }

    // MARK: - C3: row-count window, not calendar-30-days

    /// The baseline is the LAST 30 PRIOR ROWS regardless of how many calendar days they span. Here the
    /// 30 prior points are 5 days apart (spanning ~145 days), and the older ones carry a different value
    /// than the recent handful — so a calendar-30-day cutoff would see only the recent value (Δ≈0, no
    /// delta) while the row-count window averages all 30. The delta must reflect the row-count mean.
    func testDeltaUsesRowCountWindowNotCalendarDays() {
        var series: [(date: Date, value: Double)] = []
        for i in 0..<24 { series.append((day(i * 5), 40)) }          // oldest 24 priors → 40
        for i in 0..<6  { series.append((day(120 + i * 5), 10)) }    // 6 recent priors  → 10
        series.append((day(150), 10))                                // latest → 10
        // Row-count mean over the 30 priors = (24·40 + 6·10)/30 = 34, so Δ = 10 − 34 = −24.
        // A calendar-30-day window (only the recent 10s) would give mean 10 → Δ 0 → nil.
        let delta = rhr.delta(series: series)
        XCTAssertNotNil(delta, "row-count window must include the older priors a calendar window drops")
        XCTAssertEqual(delta?.text, "24")
        XCTAssertEqual(delta?.up, false)
        XCTAssertEqual(delta?.sentiment, .good)   // RHR down is good
    }

    // MARK: - C2: exact-0.5 boundary prints "0" → no delta

    /// diff exactly ±0.5 passes `minimumVisible` (0.5 for an integer) but `%.0f` renders it "0" — a
    /// colored ▲0 for no real change. The delta must be suppressed.
    func testExactHalfIntegerDeltaIsHidden() {
        let series: [(date: Date, value: Double)] = [
            (day(0), 10), (day(1), 10), (day(2), 10), (day(3), 10.5)   // Δ = 0.5 → "%.0f" → "0"
        ]
        XCTAssertNil(rhr.delta(series: series))
    }

    /// A genuinely-nonzero integer delta is unchanged — the C2 gate must not over-suppress.
    func testWholeIntegerDeltaSurvives() {
        let series: [(date: Date, value: Double)] = [
            (day(0), 10), (day(1), 10), (day(2), 10), (day(3), 11)     // Δ = 1.0
        ]
        let delta = rhr.delta(series: series)
        XCTAssertEqual(delta?.text, "1")
        XCTAssertEqual(delta?.up, true)
    }

    /// A sub-visible diff (below `minimumVisible`) still yields no delta — the fast-path guard survives.
    func testSubVisibleDeltaIsHidden() {
        let series: [(date: Date, value: Double)] = [
            (day(0), 10), (day(1), 10), (day(2), 10), (day(3), 10.2)   // Δ = 0.2 < 0.5
        ]
        XCTAssertNil(rhr.delta(series: series))
    }

    /// Too little history (< 3 prior points) yields no delta, unchanged by C3.
    func testTooLittleHistoryYieldsNoDelta() {
        let series: [(date: Date, value: Double)] = [(day(0), 10), (day(1), 20)]
        XCTAssertNil(rhr.delta(series: series))
    }
}
