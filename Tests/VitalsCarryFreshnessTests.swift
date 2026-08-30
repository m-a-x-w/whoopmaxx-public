import XCTest
import StrapStore
@testable import whoopmaxx

/// Charge and Rest both refuse a carry older than `carryFreshnessDays`, because — per the doc on that
/// constant — "a wearer who stopped syncing must see '—', not last week's value pinned as today's".
/// The vitals carry is the third one and had no such cap: it returned the freshest vitals-bearing row
/// anywhere in the 120-day refresh window. After a sync gap Today therefore showed an all-em-dash score
/// trio directly above three precise present-tense vitals with coloured "vs typical" deltas and no
/// source-day caption, and wrote the same values into the widget snapshot.
final class VitalsCarryFreshnessTests: XCTestCase {

    private func row(_ day: String, hrv: Double? = nil, rhr: Int? = nil, resp: Double? = nil) -> DailyMetric {
        Fixtures.dailyMetric(day: day, restingHr: rhr, avgHrv: hrv, respRateBpm: resp)
    }

    /// Inside the cap: still carried, exactly as before.
    func testFreshVitalsAreStillCarried() {
        let days = [row("2026-08-01", hrv: 64), row("2026-08-02")]
        let carried = TodayModel.vitalsFallbackRow(days: days, before: "2026-08-02")
        XCTAssertEqual(carried?.day, "2026-08-01")
        XCTAssertEqual(carried?.avgHrv, 64)
    }

    /// Exactly at the bound is accepted — the same inclusive rule the score carries use.
    func testVitalsAtTheFreshnessBoundAreCarried() {
        let days = [row("2026-08-01", rhr: 52)]
        XCTAssertEqual(TodayModel.vitalsFallbackRow(days: days, before: "2026-08-03")?.day, "2026-08-01")
    }

    /// The regression: past the bound the honest answer is nil, not a months-old reading.
    func testStaleVitalsAreRefused() {
        let days = [row("2026-08-01", hrv: 64, rhr: 52, resp: 14.3)]
        XCTAssertNil(TodayModel.vitalsFallbackRow(days: days, before: "2026-08-04"),
                     "a 3-day-old night must not be presented as today's vitals")
        XCTAssertNil(TodayModel.vitalsFallbackRow(days: days, before: "2026-11-01"),
                     "…and certainly not a 3-month-old one")
    }

    /// The cap must match the score carries exactly, or Today contradicts itself again.
    func testVitalsCarryUsesTheSameCapAsChargeAndRest() {
        let days = [row("2026-08-01", hrv: 64)]
        for offset in 1...5 {
            let key = String(format: "2026-08-%02d", 1 + offset)
            let vitals = TodayModel.vitalsFallbackRow(days: days, before: key)
            XCTAssertEqual(vitals != nil, offset <= TodayModel.carryFreshnessDays,
                           "vitals carry at age \(offset) must follow carryFreshnessDays")
        }
    }

    /// A vitals-less row must never satisfy the carry, however fresh.
    func testRowsWithNoVitalsAreSkipped() {
        let days = [row("2026-08-01"), row("2026-08-02")]
        XCTAssertNil(TodayModel.vitalsFallbackRow(days: days, before: "2026-08-03"))
    }

    /// It reaches PAST a vitals-less day to a fresh-enough one behind it.
    func testCarryReachesPastAVitallessDayWithinTheCap() {
        let days = [row("2026-08-01", hrv: 64), row("2026-08-02")]
        XCTAssertEqual(TodayModel.vitalsFallbackRow(days: days, before: "2026-08-03")?.day, "2026-08-01")
    }

    /// Future rows are never a source (the #547 guard on `< key`).
    func testFutureRowsAreNeverCarried() {
        let days = [row("2026-08-05", hrv: 64)]
        XCTAssertNil(TodayModel.vitalsFallbackRow(days: days, before: "2026-08-03"))
    }
}
