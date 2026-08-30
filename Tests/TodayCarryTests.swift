import XCTest
import StrapStore
@testable import whoopmaxx

/// The Today screen's anchor-day carry (#911 / the v8 rollover-blank fix): while today's row
/// is still forming (last night not yet synced/scored), Charge / Rest / the signal vitals carry the
/// freshest strictly-prior values instead of blanking the dashboard. The `< key` bound is the #547
/// future-day guard. All helpers are pure over explicit keys — no live clock.
final class TodayCarryTests: XCTestCase {

    // MARK: - Charge carry

    /// The regression: history through yesterday, today's row entirely absent — Charge must carry
    /// yesterday's score, not blank.
    func testChargeCarriesNewestPriorScoredDayWhenTodayMissing() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-14", recovery: 72)]
        let carried = TodayModel.carriedChargeRow(days: days, before: "2026-07-15")
        XCTAssertEqual(carried?.day, "2026-07-14")
        XCTAssertEqual(carried?.recovery, 72)
    }

    /// Today's row present but strain-only (the first scoring pass of the day): the caller carries
    /// exactly when `row.recovery == nil`, and the helper must still pick yesterday.
    func testChargeCarrySkipsUnscoredTodayRow() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", recovery: 72),
                    Fixtures.dailyMetric(day: "2026-07-15", strain: 12)]
        let carried = TodayModel.carriedChargeRow(days: days, before: "2026-07-15")
        XCTAssertEqual(carried?.day, "2026-07-14")
    }

    /// #547: a stray future-dated scored row must never resurface as today.
    func testChargeCarryIgnoresFutureDatedRows() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", recovery: 72),
                    Fixtures.dailyMetric(day: "2026-07-20", recovery: 99)]
        let carried = TodayModel.carriedChargeRow(days: days, before: "2026-07-15")
        XCTAssertEqual(carried?.day, "2026-07-14")
    }

    /// A prior day with data but no recovery is not a Charge source (unlike the vitals fallback).
    func testChargeCarryRequiresRecovery() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", avgHrv: 70, strain: 44)]
        XCTAssertNil(TodayModel.carriedChargeRow(days: days, before: "2026-07-15"))
    }

    /// The carry freshness cap now applies to Charge too (matches Rest #977): a recovery score older
    /// than `carryFreshnessDays` must NOT pin as today's — a wearer who stopped syncing sees "—".
    func testChargeCarryRefusesStaleScores() {
        let stale = [Fixtures.dailyMetric(day: "2026-07-08", recovery: 61)]
        XCTAssertNil(TodayModel.carriedChargeRow(days: stale, before: "2026-07-15"))
        // At exactly the two-day freshness bound the carry still shows.
        let fresh = [Fixtures.dailyMetric(day: "2026-07-13", recovery: 61)]
        XCTAssertEqual(TodayModel.carriedChargeRow(days: fresh, before: "2026-07-15")?.recovery, 61)
    }

    // MARK: - Rest carry

    func testRestCarriesNewestPriorScoreWithSourceDay() {
        let series = ["2026-07-13": 81.0, "2026-07-14": 76.0, "2026-07-20": 99.0]
        let carried = TodayModel.carriedRest(restSeries: series, before: "2026-07-15")
        XCTAssertEqual(carried?.day, "2026-07-14")
        XCTAssertEqual(carried?.value, 76.0)
    }

    func testRestCarryNilOnEmptyHistory() {
        XCTAssertNil(TodayModel.carriedRest(restSeries: [:], before: "2026-07-15"))
    }

    /// #977: a Rest score older than `restCarryFreshnessDays` must NOT pin as today's — a wearer
    /// who stopped syncing sees "—", not last week's number.
    func testRestCarryRefusesStaleScores() {
        let series = ["2026-07-08": 81.0]
        XCTAssertNil(TodayModel.carriedRest(restSeries: series, before: "2026-07-15"))
        // At exactly the freshness bound the carry still shows.
        let fresh = ["2026-07-13": 81.0]
        XCTAssertEqual(TodayModel.carriedRest(restSeries: fresh, before: "2026-07-15")?.value, 81.0)
    }

    // MARK: - Vitals fallback

    /// Recovery-independent: a night with real HRV but null recovery is a valid vitals source.
    func testVitalsFallbackAcceptsUnscoredNight() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", restingHr: 52, avgHrv: 68, recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-14", avgHrv: 71)]
        let fallback = TodayModel.vitalsFallbackRow(days: days, before: "2026-07-15")
        XCTAssertEqual(fallback?.day, "2026-07-14")
    }

    /// A strain-only row carries no vitals and is skipped; the future guard holds here too.
    func testVitalsFallbackSkipsVitallessAndFutureRows() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", avgHrv: 68),
                    Fixtures.dailyMetric(day: "2026-07-14", strain: 44),
                    Fixtures.dailyMetric(day: "2026-07-20", avgHrv: 90)]
        let fallback = TodayModel.vitalsFallbackRow(days: days, before: "2026-07-15")
        XCTAssertEqual(fallback?.day, "2026-07-13")
    }

    /// Skin temp never carries (parity with the original): a skin-only prior row is not a vitals source.
    func testVitalsFallbackIgnoresSkinTempOnlyRows() {
        let skinOnly = Fixtures.dailyMetric(day: "2026-07-14", skinTempDevC: 0.4)
        XCTAssertNil(TodayModel.vitalsFallbackRow(days: [skinOnly], before: "2026-07-15"))
    }

    // MARK: - The browsed-history gate (`allowCarry: false`)
    //
    // Carry exists so the ANCHOR day never reads as broken while last night is still syncing. Stepping
    // BACK to a past day must switch every carry off together: painting 2026-07-14 with 2026-07-13's
    // Charge/Rest/vitals would show a day numbers it never had. `WidgetDayResolver.fields` is the one
    // implementation of both halves, so the gate is pinned here rather than in the view.

    /// A browsed day with no scored row of its own blanks Charge — no carry, and no "carried · …"
    /// caption source (which is also what makes the column non-tappable).
    func testBrowsedDayDoesNotCarryCharge() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-14", strain: 12)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:],
                                         key: "2026-07-14", allowCarry: false)
        XCTAssertNil(f.charge)
        XCTAssertNil(f.chargeCarriedFrom)
        XCTAssertEqual(f.effort, 12)   // the day's OWN strain is not a carry — it still shows
    }

    /// Same for Rest: a browsed day without its own `sleep_performance` shows "—".
    func testBrowsedDayDoesNotCarryRest() {
        let series = ["2026-07-13": 81.0]
        let f = WidgetDayResolver.fields(days: [], restSeries: series,
                                         key: "2026-07-14", allowCarry: false)
        XCTAssertNil(f.rest)
        XCTAssertNil(f.restCarriedFrom)
    }

    /// And the vitals fallback: a browsed day's Signals read only that day's own row.
    func testBrowsedDayDoesNotFallBackToPriorVitals() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", restingHr: 52, avgHrv: 68),
                    Fixtures.dailyMetric(day: "2026-07-14", strain: 12)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:],
                                         key: "2026-07-14", allowCarry: false)
        XCTAssertNil(f.vitalsRow)
        XCTAssertNil(f.hrv)
        XCTAssertNil(f.restingHr)
    }

    /// The control: the SAME fixtures on the anchor day (`allowCarry: true`) carry all three, so the
    /// blanks above are the gate doing its job and not an empty-history artefact.
    func testAnchorDayCarriesAllThreeWithTheSameFixtures() {
        let days = [Fixtures.dailyMetric(day: "2026-07-13", restingHr: 52, avgHrv: 68, recovery: 61),
                    Fixtures.dailyMetric(day: "2026-07-14", strain: 12)]
        let f = WidgetDayResolver.fields(days: days, restSeries: ["2026-07-13": 81.0],
                                         key: "2026-07-14", allowCarry: true)
        XCTAssertEqual(f.charge, 61)
        XCTAssertEqual(f.chargeCarriedFrom, "2026-07-13")
        XCTAssertEqual(f.rest, 81)
        XCTAssertEqual(f.restCarriedFrom, "2026-07-13")
        XCTAssertEqual(f.vitalsRow?.day, "2026-07-13")
        XCTAssertEqual(f.hrv, 68)
        XCTAssertEqual(f.restingHr, 52)
    }

    // MARK: - Carry age

    func testDaysBetween() {
        XCTAssertEqual(TodayModel.daysBetween("2026-07-13", "2026-07-15"), 2)
        XCTAssertEqual(TodayModel.daysBetween("2026-07-15", "2026-07-15"), 0)
        XCTAssertNil(TodayModel.daysBetween("garbage", "2026-07-15"))
    }

    // MARK: - Low-coverage Effort (baseline pollution + the partial-capture flag)

    /// BASELINE POLLUTION. Effort is ACCUMULATED — `edwardsTRIMP` is a plain sum with no coverage term —
    /// so a half-captured day's strain is a FLOOR, not a measurement, and folding it into the prior mean
    /// drags every other day's "typical" tick down. Measured on the real 18 days: including 2026-07-15
    /// (66.8% coverage) and 07-26 moved the Effort baseline 45.97 → 43.87, a 2.10-point shift on EVERY
    /// day's column. The fixture below reproduces that shape: four honest ~60s plus one censored 27.
    func testEffortBaselineExcludesLowCoverageDays() {
        let days = (13...17).map { d -> DailyMetric in
            let day = String(format: "2026-07-%02d", d)
            return Fixtures.dailyMetric(day: day, strain: day == "2026-07-15" ? 27 : 60)
        } + [Fixtures.dailyMetric(day: "2026-07-18", strain: 44)]

        // Unfiltered, the censored day drags the mean down: (60+60+27+60+60)/5 = 53.4 → 53.
        let polluted = WidgetDayResolver.fields(days: days, restSeries: [:],
                                                key: "2026-07-18", allowCarry: false)
        XCTAssertEqual(polluted.effortBaseline, 53, "the pre-fix behaviour, pinned so the delta is visible")

        // With 07-15 graded low-coverage it drops out entirely: (60+60+60+60)/4 = 60.
        let clean = WidgetDayResolver.fields(days: days, restSeries: [:],
                                             effortCoverage: ["2026-07-15": 0.668],
                                             key: "2026-07-18", allowCarry: false)
        XCTAssertEqual(clean.effortBaseline, 60,
                       "a day whose Effort is only a floor must not sit in every other day's typical")
        XCTAssertFalse(clean.effortLowCoverage, "07-18 itself was fully captured")
    }

    /// A low-coverage day still SHOWS its Effort — the number is real, just a floor — but is flagged so
    /// the column renders provisional and captions "partial capture". Blanking it instead would delete a
    /// genuine 11.4 h of measured HR, and would blank TODAY every morning (today is partial by
    /// construction), which is exactly what the `windowNotStarted` guard upstream avoids.
    func testLowCoverageDayKeepsItsEffortAndIsFlagged() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", strain: 60),
                    Fixtures.dailyMetric(day: "2026-07-15", strain: 27)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:],
                                         effortCoverage: ["2026-07-15": 0.668],
                                         key: "2026-07-15", allowCarry: false)
        XCTAssertEqual(f.effort, 27, "the measured value is kept — it is a floor, not a fabrication")
        XCTAssertTrue(f.effortLowCoverage)
    }

    /// An UNGRADED day (no `effort_coverage` point — today before its waking window opens) is never
    /// treated as low coverage. Absent must read as "unknown", never as 0%: this is what stops the flag
    /// from firing on every morning's still-accumulating Effort.
    func testUngradedDayIsNotFlagged() {
        let days = [Fixtures.dailyMetric(day: "2026-07-15", strain: 27)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:], effortCoverage: [:],
                                         key: "2026-07-15", allowCarry: false)
        XCTAssertFalse(f.effortLowCoverage, "absent coverage means not graded, not 0%")
        XCTAssertEqual(f.effort, 27)
    }

    /// A day ABOVE the bar is untouched — 2026-07-25 grades 0.891 on the real data and must stay a
    /// full-confidence day, so the threshold is not simply flagging anything short of perfect.
    func testHighButImperfectCoverageIsNotFlagged() {
        let days = [Fixtures.dailyMetric(day: "2026-07-25", strain: 64)]
        let f = WidgetDayResolver.fields(days: days, restSeries: [:],
                                         effortCoverage: ["2026-07-25": 0.891],
                                         key: "2026-07-25", allowCarry: false)
        XCTAssertFalse(f.effortLowCoverage)
    }
}
