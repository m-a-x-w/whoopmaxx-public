import XCTest
import Foundation
import StrapAnalytics
import StrapStore
@testable import whoopmaxx

/// The metric detail's "vs previous period" cell (011 W1.3). Three things are pinned.
///
/// (1) The two slopes that both call themselves "per day" are NOT the same number on a series with a
/// wear gap: `SeriesStat.slopePerDay` is least-squares against the ARRAY INDEX, `MetricMath.slopePerDay`
/// is against the REAL day. The strip's Slope cell must keep the per-day one — this pins the divergence
/// so a later "cleanup" cannot quietly swap them under one label.
/// (2) With no comparable previous window the cell renders an em dash, never `ComparisonEngine`'s raw
/// `current.mean − 0` and never a "0%".
/// (3) A flat window prints no percent arrow, and a real sub-percent move prints "<1%" rather than a
/// rounded "0%".
final class PeriodComparisonTests: XCTestCase {

    /// RHR — integer format, LOWER is better, so the sentiment of a move is not the direction of it.
    private let rhr = MetricCatalog.all.first { $0.key == "rhr" }!
    /// Charge — integer format, higher is better: the same move must read the other way.
    private let charge = MetricCatalog.all.first { $0.key == "recovery" }!
    /// Resp rate — one decimal place, for the sub-percent formatting case.
    private let resp = MetricCatalog.all.first { $0.key == "resp" }!

    /// Day n of the fixture, by CALENDAR arithmetic — the same arithmetic `previousValues` slices with,
    /// so the window boundaries land exactly on fixture points in every zone, DST year or not.
    private let base = MetricCatalog.date(fromDayKey: "2026-01-01")!
    private func day(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: base)! }

    /// The slope fixture instead needs EXACT 24 h steps: `MetricMath.slopePerDay` divides elapsed
    /// seconds by 86_400, so a DST hour inside the fixture would move the very number being pinned.
    private let tickBase = Date(timeIntervalSince1970: 1_000_000)
    private func tick(_ n: Int) -> Date { tickBase.addingTimeInterval(Double(n) * 86_400) }

    // MARK: - The two slopes are different numbers

    /// Four points on days 0, 1, 2, 6 — a deliberate 3-day gap before the last one, the shape a sparse
    /// series takes when a day goes unwritten (`ScoreEngine` needs enough samples behind a day before it
    /// writes one). Rising 10 → 11 → 12 → 16.
    ///
    /// Per ARRAY INDEX the last point is one step after the third, so the fit is steep: 1.9/step.
    /// Per REAL day it is four days after, so the same points fit exactly 1.0/day. Same series, same
    /// label, ~2× apart — which is why only `MetricMath.slopePerDay` may feed the Slope cell.
    func testIndexSlopeAndRealDaySlopeDivergeAcrossAGap() throws {
        let points: [(date: Date, value: Double)] = [
            (tick(0), 10.0), (tick(1), 11.0), (tick(2), 12.0), (tick(6), 16.0)
        ].map { (date: $0.0, value: $0.1) }
        let values = points.map(\.value)

        let indexSlope = ComparisonEngine.stat(values).slopePerDay
        let perDaySlope = try XCTUnwrap(MetricMath.slopePerDay(points))

        XCTAssertEqual(indexSlope, 1.9, accuracy: 1e-9, "engine slope is per array index")
        XCTAssertEqual(perDaySlope, 1.0, accuracy: 1e-9, "MetricMath slope is per real day")
        XCTAssertNotEqual(indexSlope, perDaySlope, accuracy: 0.5,
                          "the two 'per day' slopes must stay distinct — swapping them changes the sign "
                          + "and the magnitude the Slope cell calls the finding")
    }

    /// Without a gap the two agree — so the divergence above is the GAP's doing, not a units bug in one
    /// of them. (Also stops the test above from passing for the wrong reason.)
    func testTheTwoSlopesAgreeOnAnUnbrokenSeries() throws {
        let points: [(date: Date, value: Double)] = [
            (tick(0), 10.0), (tick(1), 12.0), (tick(2), 14.0), (tick(3), 16.0)
        ].map { (date: $0.0, value: $0.1) }
        let indexSlope = ComparisonEngine.stat(points.map(\.value)).slopePerDay
        let perDaySlope = try XCTUnwrap(MetricMath.slopePerDay(points))
        XCTAssertEqual(indexSlope, perDaySlope, accuracy: 1e-9)
        XCTAssertEqual(perDaySlope, 2.0, accuracy: 1e-9)
    }

    // MARK: - No previous window → an em dash, not a number

    /// The engine, asked to compare against an empty period, answers `current.mean − 0` — the current
    /// mean wearing a plus sign. The readout must refuse it: "—", no percent, no direction.
    func testEmptyPreviousWindowRendersEmDashNeverAZero() {
        let current = [52.0, 54.0, 53.0]                       // mean 53
        XCTAssertEqual(ComparisonEngine.compare(current: current, previous: []).delta, 53.0,
                       accuracy: 1e-9, "the raw engine delta against an empty period IS the current mean")

        let readout = PeriodDeltaReadout.make(current: current, previous: [], windowDays: 30)
        XCTAssertNil(readout.delta)
        XCTAssertNil(readout.pct)
        XCTAssertNil(readout.percentText)
        XCTAssertNil(readout.percentDelta(for: rhr))
        XCTAssertEqual(readout.direction, 0)
        XCTAssertEqual(readout.valueText(rhr), "—")
        XCTAssertEqual(readout.caption, "No comparable 30-day window before this one.")
    }

    /// An unreachable previous window (nil, not empty) refuses identically — the screen cannot tell
    /// "no older data" from "older data not loaded", so both land on the em dash.
    func testUnreachablePreviousWindowRendersEmDash() {
        let readout = PeriodDeltaReadout.make(current: [52, 54], previous: nil, windowDays: 90)
        XCTAssertNil(readout.delta)
        XCTAssertEqual(readout.valueText(charge), "—")
        XCTAssertEqual(readout.caption, "No comparable 90-day window before this one.")
    }

    // MARK: - Slicing the previous window

    /// 60 daily points, value = day index. The charted 30-day window is days 30…59, so the previous one
    /// is days 0…29: 30 values, none of them shared with the charted window.
    func testPreviousWindowIsTheSameLengthAndExcludesTheChartedOne() throws {
        let series = (0..<60).map { (date: day($0), value: Double($0)) }
        let previous = try XCTUnwrap(PeriodDeltaReadout.previousValues(series: series, windowDays: 30))
        XCTAssertEqual(previous.count, 30)
        XCTAssertEqual(try XCTUnwrap(previous.min()), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(previous.max()), 29, accuracy: 1e-9,
                       "day 30 belongs to the CHARTED window, not the previous one")
    }

    /// One day short of covering the previous window (days 1…59) → nil. The loaded history has to reach
    /// the previous window's first day; a fragment of it compared as if it were the whole thing is the
    /// plausible-looking number this refuses to print.
    func testPreviousWindowIsNilWhenHistoryDoesNotReachItsFirstDay() {
        let series = (1..<60).map { (date: day($0), value: Double($0)) }
        XCTAssertNil(PeriodDeltaReadout.previousValues(series: series, windowDays: 30))
        // …and one more day of history is enough to turn it on, so the gate is a boundary and not a wall.
        let reaching = (0..<60).map { (date: day($0), value: Double($0)) }
        XCTAssertNotNil(PeriodDeltaReadout.previousValues(series: reaching, windowDays: 30))
    }

    /// Wear gaps INSIDE the previous window are fine — the window is a date range, not a row count, and
    /// the caption says how many days each side actually carried.
    func testPreviousWindowKeepsItsGapsAndReportsTheCount() throws {
        // Days 0…59 with 3, 4, 5 missing (the same gap shape as the slope fixture).
        let series = (0..<60).filter { !(3...5).contains($0) }.map { (date: day($0), value: Double($0)) }
        let previous = try XCTUnwrap(PeriodDeltaReadout.previousValues(series: series, windowDays: 30))
        XCTAssertEqual(previous.count, 27)
        let readout = PeriodDeltaReadout.make(current: series.suffix(30).map(\.value),
                                              previous: previous, windowDays: 30)
        XCTAssertEqual(readout.previousDays, 27)
        XCTAssertEqual(readout.currentDays, 30)
        XCTAssertEqual(readout.caption, "Mean vs the preceding 30 days · 30 days measured vs 27.")
    }

    // MARK: - What the cell prints when there IS a comparison

    /// RHR 55 → 50 across the two windows: a −5 change, −9%, and DOWN on RHR means better.
    func testMeasuredDropCarriesPercentAndMetricSentiment() throws {
        let readout = PeriodDeltaReadout.make(current: [50, 50, 50], previous: [55, 55, 55],
                                              windowDays: 30)
        XCTAssertEqual(try XCTUnwrap(readout.delta), -5, accuracy: 1e-9)
        XCTAssertEqual(readout.direction, -1)
        XCTAssertEqual(readout.percentText, "9%")
        XCTAssertEqual(readout.valueText(rhr), "\u{2212}5")   // U+2212, the minus MetricDef prints
        XCTAssertEqual(readout.caption, "Mean vs the preceding 30 days · 3 days measured vs 3.")

        let arrow = try XCTUnwrap(readout.percentDelta(for: rhr))
        XCTAssertFalse(arrow.up)
        XCTAssertEqual(arrow.text, "9%")
        XCTAssertEqual(arrow.sentiment, .good, "RHR down is better")
        // The SAME readout on a higher-is-better metric must read the other way.
        XCTAssertEqual(try XCTUnwrap(readout.percentDelta(for: charge)).sentiment, .bad)
    }

    /// Two identical windows: the change is a measured zero, so the numeral is "+0" (the Slope cell's
    /// convention right beside it) — but there is NO arrow, because "▲ 0%" reads as a move.
    func testFlatChangePrintsNoPercentArrow() throws {
        let readout = PeriodDeltaReadout.make(current: [50, 50], previous: [50, 50], windowDays: 7)
        XCTAssertEqual(try XCTUnwrap(readout.delta), 0, accuracy: 1e-12)
        XCTAssertEqual(readout.direction, 0)
        XCTAssertNil(readout.pct)
        XCTAssertNil(readout.percentText)
        XCTAssertNil(readout.percentDelta(for: rhr))
        XCTAssertEqual(readout.valueText(rhr), "+0")
    }

    /// A real but sub-percent move (14.40 → 14.46 rpm, +0.42%) says "<1%". Rounding it to "0%" would
    /// print a zero beside an arrow claiming a direction.
    func testSubPercentChangeSaysLessThanOnePercent() {
        let readout = PeriodDeltaReadout.make(current: [14.46, 14.46], previous: [14.4, 14.4],
                                              windowDays: 30)
        XCTAssertEqual(readout.direction, 1)
        XCTAssertEqual(readout.percentText, "<1%")
        XCTAssertEqual(readout.valueText(resp), "+0.1")
    }

    /// A previous mean of 0 leaves the ratio undefined: the signed change still prints, the percent does
    /// not (and does not become a "0%" or an infinity).
    func testZeroPreviousMeanPrintsTheChangeWithoutAPercent() throws {
        let readout = PeriodDeltaReadout.make(current: [4, 6], previous: [0, 0], windowDays: 7)
        XCTAssertEqual(try XCTUnwrap(readout.delta), 5, accuracy: 1e-9)
        XCTAssertEqual(readout.direction, 1)
        XCTAssertNil(readout.pct)
        XCTAssertNil(readout.percentDelta(for: charge))
        XCTAssertEqual(readout.valueText(charge), "+5")
    }

    // MARK: - A percent change needs a ratio scale

    /// Skin temp is a signed DEVIATION from the user's own baseline, so its multi-week mean sits near
    /// zero by construction and `(cur − prev) / |prev|` has an arbitrary denominator and no bound. The
    /// engine still computes a percent; the screen must refuse to draw it. Ungated, the arrow reads
    /// "▼ 650%" for a 0.13 °C move, so this pins the refusal AND the signed value that replaces it.
    func testDeviationScaledMetricPrintsNoPercentArrow() throws {
        let skinTemp = MetricCatalog.all.first { $0.key == "skin_temp" }!
        let readout = PeriodDeltaReadout.make(current: [-0.11, -0.11], previous: [0.02, 0.02],
                                              windowDays: 90)
        // The engine's raw percent IS the unbounded number we refuse to render.
        XCTAssertEqual(try XCTUnwrap(readout.pct), -650, accuracy: 1)
        XCTAssertNil(readout.percentDelta(for: skinTemp))
        XCTAssertEqual(readout.valueText(skinTemp), "\u{2212}0.13")   // a true minus, not a hyphen
        // The gate is the FORMAT, not the metric key: a ratio-scaled metric on the same readout still
        // draws its arrow, so this cannot pass by suppressing percents everywhere.
        XCTAssertNotNil(readout.percentDelta(for: charge))
    }

    // MARK: - The deep read must not detach the screen from the repository

    /// `deep` is a one-shot snapshot; `repo.days` keeps refreshing under it. The overlay must let the
    /// LIVE row win on every day it carries, or one 90D tap freezes the hero, the chart and the stats
    /// strip against the store as of that tap — for every range, until the screen is popped.
    func testLiveCacheWinsOverTheDeepSnapshotPerDay() {
        let snapshot = [daily("2026-01-01", recovery: 40), daily("2026-01-02", recovery: 41),
                        daily("2026-01-03", recovery: 42)]
        // The live cache reaches only the last two days, and the newest has since been rescored.
        let live = [daily("2026-01-02", recovery: 41), daily("2026-01-03", recovery: 88)]

        let merged = MetricDetailScreen.overlay(live: live, onto: snapshot)

        XCTAssertEqual(merged.map(\.day), ["2026-01-01", "2026-01-02", "2026-01-03"])
        XCTAssertEqual(merged.last?.recovery, 88, "the rescored day must win over the snapshot")
        XCTAssertEqual(merged.first?.recovery, 40, "history the live cache cannot reach must survive")
    }

    /// The overlay replaces the live day WHOLESALE rather than filling its nils from the snapshot: the
    /// loser here is merely older, so a field that has since become nil must stay nil rather than be
    /// resurrected. That is the one behaviour distinguishing it from `Repository.mergeDaily`.
    func testOverlayDoesNotResurrectAFieldTheLiveRowHasCleared() {
        let snapshot = [daily("2026-01-01", recovery: 40, rhr: 55)]
        let live = [daily("2026-01-01", recovery: 40, rhr: nil)]
        XCTAssertNil(MetricDetailScreen.overlay(live: live, onto: snapshot).first?.restingHr)
    }

    private func daily(_ day: String, recovery: Double?, rhr: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: nil, recovery: recovery,
                    strain: nil, exerciseCount: nil)
    }
}
