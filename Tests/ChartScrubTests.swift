import XCTest
import Foundation
@testable import whoopmaxx

/// The metric detail's chart scrub (017 P1) and its period columns (017 P2). Four rules are pinned, and
/// all four exist because these series are SPARSE: `ScoreEngine` writes a day only once it has seen 200+
/// HR samples, so a multi-day gap is the normal shape of a metric history, not an edge case.
///
/// (1) `BandChart.nearestPointDate` — `chartXSelection` hands over a CONTINUOUS x, a date anywhere along
/// the axis. It must resolve to the NEAREST plotted point, not to "the last point at or before x" and
/// certainly not to the raw touch: the raw touch is usually a day with no row, and "the point before" is
/// a different answer on every gap.
/// (2) `ScrubReadout.make` — the hero reads a column by EXACT date match and refuses everything else,
/// so the 64pt numeral and its caption can only ever describe something that was really measured.
/// (3) `PlottedSeries.make` — past the density threshold the chart plots weekly means, and an unmeasured
/// week gets NO column: a zero-height one would read as a measured zero.
/// (4) A weekly column is LABELLED as a mean, with the count of days behind it (017 decision 5). The
/// 64pt numeral is the same slot in both geometries, so the label is the only thing that separates an
/// aggregate from a measurement.
///
/// `@MainActor` because `BandChart` conforms to `View`, whose main-actor conformance its statics inherit
/// (the `AdvertisingNameDecodeTests` precedent).
@MainActor
final class ChartScrubTests: XCTestCase {

    /// Exact 24-hour ticks: nearest-point resolution is pure time arithmetic, and a DST hour inside a
    /// fixture would move the very midpoint these tests pin.
    private let base = Date(timeIntervalSince1970: 1_600_000_000)
    private func day(_ n: Double) -> Date { base.addingTimeInterval(n * 86_400) }

    /// A fortnight-wide gap — days 0 and 14 with nothing between, the shape a series takes when the
    /// strap is off the wrist for two weeks.
    private var gapped: [(Date, Double)] { [(day(0), 50), (day(14), 70)] }

    // MARK: - Nearest point

    /// A touch in the gap resolves to whichever side is closer — pinned on BOTH sides of the midpoint,
    /// so neither answer can be right by accident. Red if resolution is pinned to an END of the series
    /// (returning `points.first` fails the second assertion, `points.last` the first) instead of
    /// measuring distance.
    func testTouchBetweenTwoSparsePointsResolvesToTheCloserOne() {
        XCTAssertEqual(BandChart.nearestPointDate(to: day(6), in: gapped), day(0))
        XCTAssertEqual(BandChart.nearestPointDate(to: day(8), in: gapped), day(14))
    }

    /// THE distinction this whole packet turns on. A touch at day 12 is two days from the day-14 point
    /// and twelve from the day-0 one, so NEAREST says day 14 — while "the last point at or before the
    /// touch" says day 0, a fortnight from the finger. Red the moment resolution becomes
    /// `points.last { $0.0 <= x }`.
    func testNearestIsNotTheLastPointBeforeTheTouch() {
        let resolved = BandChart.nearestPointDate(to: day(12), in: gapped)
        XCTAssertEqual(resolved, day(14))
        XCTAssertNotEqual(resolved, day(0), "resolution must be by distance, not by 'the point before'")
    }

    /// Exactly halfway is a tie, and a tie goes to the EARLIER point (`points` runs oldest → newest, and
    /// the scan keeps its first best). Red if `gap < smallestGap` is relaxed to `gap <= smallestGap`.
    func testAnExactTieResolvesToTheEarlierPoint() {
        XCTAssertEqual(BandChart.nearestPointDate(to: day(7), in: gapped), day(0))
    }

    /// Past either end of the series, the nearest point is the end one — never nil, and never a date
    /// beyond the data. Red if the scan is bounded to the series' own span.
    func testTouchOutsideTheSeriesResolvesToTheNearestEnd() {
        let points: [(Date, Double)] = [(day(0), 50), (day(10), 60), (day(20), 55)]
        XCTAssertEqual(BandChart.nearestPointDate(to: day(40), in: points), day(20))
        XCTAssertEqual(BandChart.nearestPointDate(to: day(-9), in: points), day(0))
    }

    /// An empty chart has nothing to select: no crash, no selection. Red if the scan is rewritten to
    /// seed itself with `points[0]` (which would also trap on an empty series).
    func testEmptySeriesResolvesToNil() {
        XCTAssertNil(BandChart.nearestPointDate(to: day(3), in: []))
    }

    /// No touch is no selection — `chartXSelection` writes nil when the gesture ends, and that nil must
    /// pass straight through rather than resolve to the nearest point of nowhere. Red if the `guard let
    /// x` is dropped.
    func testNilSelectionResolvesToNil() {
        XCTAssertNil(BandChart.nearestPointDate(to: nil, in: gapped))
    }

    /// The resolved date is always one the series actually carries — the property the hero depends on.
    /// Red if resolution ever returns the raw x (e.g. `return x` as a fast path).
    func testResolvedDateIsAlwaysAPlottedPoint() {
        let points: [(Date, Double)] = [(day(0), 50), (day(3), 60), (day(19), 55)]
        for touch in stride(from: -2.0, through: 22.0, by: 0.5) {
            let resolved = BandChart.nearestPointDate(to: day(touch), in: points)
            XCTAssertNotNil(resolved)
            XCTAssertTrue(points.contains { $0.0 == resolved },
                          "x at day \(touch) resolved to a date the series has no row for")
        }
    }

    // MARK: - The hero's readout

    /// The DAILY plotted shape — one column per measured day, which is what every window under the
    /// density threshold plots and what the readout tests below read.
    private func columns(_ keys: [String], _ values: [Double]) -> [PlottedSeries.Column] {
        zip(keys, values).map {
            PlottedSeries.Column(date: MetricCatalog.date(fromDayKey: $0.0)!, value: $0.1,
                                 days: 1, period: .day)
        }
    }

    /// The readout reports the SCRUBBED column's own value, not the newest one. Red if `make` reads
    /// `columns.last` for the value.
    func testReadoutCarriesTheScrubbedPointsOwnValue() throws {
        let w = columns(["2026-08-01", "2026-08-05", "2026-08-07"], [61, 44, 78])
        let readout = try XCTUnwrap(ScrubReadout.make(selection: w[1].date, columns: w))
        XCTAssertEqual(readout.value, 44, accuracy: 1e-9)
    }

    /// The match is EXACT. `BandChart` already resolved the gesture to a plotted point, so anything that
    /// is not one of those dates — here one second off — is not a reading, and the hero falls back to
    /// the newest value rather than captioning an unmeasured day. Red if `make` is "improved" to snap to
    /// the nearest point itself.
    func testAnInexactSelectionIsNoReadout() {
        let w = columns(["2026-08-01", "2026-08-05", "2026-08-07"], [61, 44, 78])
        XCTAssertNil(ScrubReadout.make(selection: w[1].date.addingTimeInterval(1), columns: w))
        XCTAssertNotNil(ScrubReadout.make(selection: w[1].date, columns: w),
                        "the exact date must still read — both sides of the equality")
    }

    /// A selection left standing from a wider range names a day this window does not plot: no readout,
    /// so the hero returns to the newest value. Red if the lookup falls back to the nearest point.
    func testASelectionOutsideTheWindowIsNoReadout() {
        let w = columns(["2026-08-01", "2026-08-05", "2026-08-07"], [61, 44, 78])
        XCTAssertNil(ScrubReadout.make(selection: MetricCatalog.date(fromDayKey: "2025-11-02"), columns: w))
    }

    /// Nothing touched, and nothing to touch. Red if either guard is dropped.
    func testNoSelectionAndNoWindowAreNoReadout() {
        let w = columns(["2026-08-07"], [78])
        XCTAssertNil(ScrubReadout.make(selection: nil, columns: w))
        XCTAssertNil(ScrubReadout.make(selection: w[0].date, columns: []))
    }

    /// The caption carries the YEAR only when the scrubbed day falls in a different one from the newest
    /// charted point — on the 1Y range a bare "Sep 3" would otherwise be read as this year's. Both sides
    /// pinned: the same-year caption must NOT carry it. Red if the ternary in `make` collapses to either
    /// branch alone.
    func testTheDateTextCarriesTheYearOnlyAcrossAYearBoundary() throws {
        let w = columns(["2025-09-03", "2026-01-05", "2026-08-07"], [61, 44, 78])
        let calendar = Calendar.current
        let lastYear = String(calendar.component(.year, from: w[0].date))
        let thisYear = String(calendar.component(.year, from: w[2].date))

        let across = try XCTUnwrap(ScrubReadout.make(selection: w[0].date, columns: w))
        XCTAssertTrue(across.dateText.contains(lastYear),
                      "a day in another year must say which: \(across.dateText)")

        let within = try XCTUnwrap(ScrubReadout.make(selection: w[1].date, columns: w))
        XCTAssertFalse(within.dateText.contains(thisYear),
                       "the current year is noise on every caption: \(within.dateText)")
        XCTAssertFalse(within.dateText.isEmpty)
    }

    // MARK: - Period columns (P2)

    /// CALENDAR-day arithmetic from a fixed day key, unlike the exact-24 h `day(_:)` ticks above:
    /// week bucketing is a calendar operation, so a fixture that drifts by a DST hour could slide a day
    /// across a week boundary and move the very counts these tests pin. (The nearest-point fixtures keep
    /// their ticks because that resolution is pure time arithmetic.)
    private let dayZero = MetricCatalog.date(fromDayKey: "2025-01-01")!
    private func cal(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: dayZero)! }

    /// `count` consecutive measured days starting at `from`, values wandering inside a plausible range.
    private func dense(_ count: Int, from start: Int = 0) -> [(date: Date, value: Double)] {
        (0..<count).map { (date: cal(start + $0), value: 50 + Double(($0 * 5) % 17)) }
    }

    /// Distinct calendar weeks touched by `a...b` — the count of columns a chart that filled every empty
    /// week with a zero would draw.
    private func weeksSpanned(_ a: Date, _ b: Date) -> Int {
        let c = Calendar.current
        guard let start = c.dateInterval(of: .weekOfYear, for: a)?.start,
              let end = c.dateInterval(of: .weekOfYear, for: b)?.start else { return 0 }
        return (c.dateComponents([.weekOfYear], from: start, to: end).weekOfYear ?? 0) + 1
    }

    /// The threshold, pinned on BOTH sides off the constant itself, in the unit the constant is now
    /// in: DAYS OF SPAN.
    ///
    /// `dense(n)` lays down n consecutive days, which SPANS n − 1. So a window spanning exactly the
    /// limit keeps daily bars — every column a measurement, nothing to disclose — and one day more
    /// flips the whole chart to weekly means. Red if the comparison becomes `>=` (the at-limit half
    /// fails) or `<` (the over-limit half fails).
    func testTheDensityThresholdIsPinnedOnBothSides() {
        let limit = PlottedSeries.dailySpanLimitDays
        let atLimit = PlottedSeries.make(window: dense(limit + 1))   // spans exactly `limit` days
        XCTAssertEqual(atLimit.columns.count, limit + 1)
        XCTAssertTrue(atLimit.columns.allSatisfy { $0.period == .day })
        XCTAssertTrue(atLimit.columns.allSatisfy { $0.days == 1 })
        XCTAssertNil(atLimit.caption, "daily bars ARE the measurements — there is nothing to disclose")

        let overLimit = PlottedSeries.make(window: dense(limit + 2))   // spans limit + 1
        XCTAssertTrue(overLimit.columns.allSatisfy { $0.period == .week })
        XCTAssertLessThan(overLimit.columns.count, limit)
        XCTAssertNotNil(overLimit.caption)
    }

    /// THE CASE THIS WAVE EXISTS FOR: a SPARSE year.
    ///
    /// 60 measured days scattered over 365 sits far under any point-count threshold, so 017 kept daily
    /// marks for it — and a daily mark's width is the plot over the window's SPAN, not over the number
    /// of points, so those bars measured 0.73 pt: exactly as unreadable as the dense 365 the threshold
    /// existed to catch. Span answers both cases with one rule.
    ///
    /// Turns red: decide on `window.count` instead of the span.
    func testASparseYearAggregatesToo() {
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: Date())
        // Every sixth day measured across a year — ~61 points, 365 days of span.
        let sparse: [(date: Date, value: Double)] = stride(from: -365, through: 0, by: 6).map {
            (cal.date(byAdding: .day, value: $0, to: day0)!, 60 + Double(abs($0) % 13))
        }
        XCTAssertLessThan(sparse.count, PlottedSeries.dailySpanLimitDays,
                          "premise: far under any point-count threshold")

        let plotted = PlottedSeries.make(window: sparse)
        XCTAssertTrue(plotted.columns.allSatisfy { $0.period == .week },
                      "a year-wide domain draws hairlines whether or not it is dense")
        XCTAssertEqual(plotted.chartUnit, .weekOfYear)
        XCTAssertNotNil(plotted.caption)
    }

    /// …and the other direction, which is what makes span the RIGHT rule rather than merely a stricter
    /// one: a user with three months of history who taps 1Y still gets daily bars. Their DATA does not
    /// span a year, so the chart must not pretend it does.
    ///
    /// Turns red: key the decision on the selected range instead of the window's own span.
    func testAShortHistoryOnAWideRangeKeepsDailyBars() {
        let plotted = PlottedSeries.make(window: dense(90))
        XCTAssertTrue(plotted.columns.allSatisfy { $0.period == .day })
        XCTAssertNil(plotted.caption)
    }

    /// The plan's own case: a year of measured days plots weeks and says so; a quarter — which can never
    /// exceed the threshold, since 90 days hold at most 90 points — plots days and says nothing. Also
    /// pins CHART ORDER, because the buckets are collected through a Dictionary and its iteration order
    /// is not the axis's. Red if the columns are emitted in `buckets.keys` order.
    func testAYearAggregatesAndAQuarterDoesNot() {
        let year = PlottedSeries.make(window: dense(365))
        XCTAssertTrue(year.columns.allSatisfy { $0.period == .week })
        XCTAssertTrue((52...53).contains(year.columns.count),
                      "365 days is 52 weeks and change: \(year.columns.count)")
        XCTAssertEqual(year.caption, "Weekly means — \(year.columns.count) weeks.")
        XCTAssertEqual(year.columns.map(\.date), year.columns.map(\.date).sorted(),
                       "columns must come out oldest → newest, the order the chart draws in")

        let quarter = PlottedSeries.make(window: dense(90))
        XCTAssertEqual(quarter.columns.count, 90)
        XCTAssertTrue(quarter.columns.allSatisfy { $0.period == .day })
        XCTAssertNil(quarter.caption)
    }

    /// A week nobody measured has NO column. The fixture leaves a 28-day hole — at least three whole
    /// calendar weeks with no measured day, wherever the local week starts. Red the moment empty weeks
    /// are emitted as zero-height columns (the count then equals the weeks spanned, and a 0 appears
    /// among the values), which on these sparse series would be the commonest mark on the chart.
    func testAWeekWithNoMeasuredDayHasNoColumn() {
        let window = dense(100) + dense(100, from: 128)          // days 0…99, hole, days 128…227
        let plotted = PlottedSeries.make(window: window)
        XCTAssertTrue(plotted.columns.allSatisfy { $0.period == .week })
        XCTAssertFalse(plotted.columns.contains { $0.value == 0 },
                       "an unmeasured week must be ABSENT — a zero column reads as a measured zero")
        XCTAssertTrue(plotted.columns.allSatisfy { $0.days >= 1 })
        XCTAssertLessThanOrEqual(plotted.columns.count, weeksSpanned(cal(0), cal(227)) - 3,
                                 "the 28-day hole must remove at least its three whole weeks")
    }

    /// Every column means EXACTLY the days its own week carries — no day dropped, none counted twice,
    /// and no mean taken over seven slots four of which were never measured. Red if the bucket key stops
    /// being the week start (days then land in the wrong column), or if `days` is hard-coded to 7.
    func testEachWeeklyColumnIsTheMeanOfExactlyTheDaysItsWeekCarries() throws {
        let window = (0..<365).map { (date: cal($0), value: Double($0)) }
        let plotted = PlottedSeries.make(window: window)
        let c = Calendar.current
        for column in plotted.columns {
            let inWeek = window.filter { c.dateInterval(of: .weekOfYear, for: $0.date)?.start == column.date }
            let mean = try XCTUnwrap(MetricMath.mean(inWeek.map(\.value)))
            XCTAssertEqual(column.days, inWeek.count)
            XCTAssertEqual(column.value, mean, accuracy: 1e-9)
        }
        XCTAssertEqual(plotted.columns.reduce(0) { $0 + $1.days }, 365,
                       "every measured day belongs to exactly one column")
    }

    /// A partial bucket is not a week, and this implementation KEEPS it and says what it is built from.
    /// The fixture's last point is a lone day 30 days after the run, so it owns its week bucket alone in
    /// every locale — the week's first day differs by region, the isolation does not. Red if partial
    /// buckets are dropped (the column disappears), or if `days` is assumed to be 7, or if the readout
    /// prints "mean of 1 days".
    func testAPartialWeekIsLabelledWithTheDaysItReallyMeans() throws {
        let window = dense(200) + [(date: cal(230), value: 91.0)]
        let plotted = PlottedSeries.make(window: window)
        let last = try XCTUnwrap(plotted.columns.last)
        XCTAssertEqual(last.period, .week)
        XCTAssertEqual(last.days, 1, "a one-day bucket is one day, never rounded up to a week")
        XCTAssertEqual(last.value, 91, accuracy: 1e-9, "its value is that day's own, not a padded mean")

        let readout = try XCTUnwrap(ScrubReadout.make(selection: last.date, columns: plotted.columns))
        XCTAssertEqual(readout.aggregateText, "mean of 1 day")
        XCTAssertTrue(readout.captionText.contains("mean of 1 day"),
                      "the caption must carry the label: \(readout.captionText)")
    }

    /// DECISION 5, both sides. The 64pt numeral is the same slot in both geometries, so the label is the
    /// only thing separating a mean from a measurement — and it must appear on exactly one of them. Red
    /// if `aggregateText` is dropped for weekly columns (the app then prints a mean as a measured day),
    /// and equally red if it is attached to daily ones (which would pass the weekly half while lying on
    /// every other range).
    func testAWeeklyColumnSaysItIsAMeanAndAMeasuredDayDoesNot() throws {
        let daily = columns(["2026-08-01", "2026-08-05"], [61, 44])
        let dayReadout = try XCTUnwrap(ScrubReadout.make(selection: daily[1].date, columns: daily))
        XCTAssertNil(dayReadout.aggregateText)
        XCTAssertEqual(dayReadout.captionText, dayReadout.dateText, "no label to compose")
        XCTAssertEqual(dayReadout.accessibilityText, "Reading for \(dayReadout.dateText)")

        let plotted = PlottedSeries.make(window: dense(365))
        // An INTERIOR column, so it is a whole week rather than a partial end bucket.
        let week = try XCTUnwrap(plotted.columns.dropFirst().dropLast().last)
        let weekReadout = try XCTUnwrap(ScrubReadout.make(selection: week.date, columns: plotted.columns))
        XCTAssertEqual(week.days, 7)
        XCTAssertEqual(weekReadout.aggregateText, "mean of 7 days")
        XCTAssertTrue(weekReadout.dateText.hasPrefix("Week of "),
                      "a week's caption must name a week, not a day: \(weekReadout.dateText)")
        XCTAssertEqual(weekReadout.captionText, "\(weekReadout.dateText) · mean of 7 days")
        XCTAssertEqual(weekReadout.accessibilityText, "\(weekReadout.dateText), mean of 7 days")
    }

    /// The band is computed over `PlottedSeries.values`, and those must be the columns' OWN values. This
    /// fixture makes banding the wrong population impossible to miss: a within-week sawtooth (0…60 by
    /// day of the run) has a wide daily spread and almost none once the weeks are meaned, so a band built
    /// on the daily values would stand several times too tall around the columns it exists to explain.
    /// Red if `values` is ever "simplified" to return the raw window.
    func testTheBandPopulationIsThePlottedOne() throws {
        let window = (0..<365).map { (date: cal($0), value: Double($0 % 7) * 10) }
        let plotted = PlottedSeries.make(window: window)
        XCTAssertEqual(plotted.values, plotted.columns.map(\.value))
        XCTAssertEqual(plotted.points.count, plotted.columns.count)

        let dailySd = try XCTUnwrap(MetricMath.standardDeviation(window.map(\.value)))
        let weeklySd = try XCTUnwrap(MetricMath.standardDeviation(plotted.values))
        XCTAssertGreaterThan(dailySd, 18, "the daily population is wide")
        XCTAssertLessThan(weeklySd, 8, "every whole week means to the same number — the plotted one is not")
    }

    /// An empty window plots nothing, discloses nothing, and selects nothing. Red if `make` force-reads
    /// a first point, or if the caption is built unconditionally (an empty chart would then caption
    /// itself "Weekly means — 0 weeks.").
    func testAnEmptyWindowPlotsNothingAndDisclosesNothing() {
        let plotted = PlottedSeries.make(window: [])
        XCTAssertTrue(plotted.columns.isEmpty)
        XCTAssertTrue(plotted.points.isEmpty)
        XCTAssertTrue(plotted.values.isEmpty)
        XCTAssertNil(plotted.caption)
        XCTAssertNil(ScrubReadout.make(selection: cal(0), columns: plotted.columns))
        XCTAssertNil(BandChart.nearestPointDate(to: cal(0), in: plotted.points))
    }

    // MARK: - The mark has to span the period it stands for

    /// Aggregation is only worth doing if it WIDENS the mark, and it is Charts' x-bin unit — not the
    /// number of points — that sets a bar's width.
    ///
    /// The first cut binned every mark at `.day`. Measured with an ImageRenderer harness, 365 daily
    /// bars and the 53 weekly means that replaced them BOTH rendered at 0.71 pt on a 320 pt plot: the
    /// aggregation widened nothing and stood each week's mean on its own first day with the other six
    /// blank. `PlottedSeries` now derives the unit from its own columns so the geometry and the
    /// aggregation cannot disagree.
    ///
    /// Turns red: return `.day` unconditionally from `PlottedSeries.chartUnit`.
    func testAggregatedColumnsSpanTheirWeekAndDailyOnesTheirDay() {
        let daily = PlottedSeries.make(window: series(days: 90))
        XCTAssertEqual(daily.chartUnit, .day, "under the threshold the marks ARE days")

        let weekly = PlottedSeries.make(window: series(days: 365))
        XCTAssertEqual(weekly.columns.first?.period, .week, "premise: this window aggregates")
        XCTAssertEqual(weekly.chartUnit, .weekOfYear,
                       "a weekly mean drawn one day wide is the bug this pins")
    }

    /// …and the scrub has to follow the mark it widened. A week-wide column's date is its FIRST day,
    /// so nearest-by-centre answers the NEXT week for any touch past the column's midpoint — half of
    /// every column, naming a week the finger is not over. Resolution matches the mark a touch is
    /// physically ON, falling back to nearest only where no mark covers it.
    ///
    /// Turns red: drop the containing-interval loop from `BandChart.nearestPointDate`.
    func testATouchInsideAWeeklyColumnResolvesToThatWeek() {
        let weekly = PlottedSeries.make(window: series(days: 365))
        let points = weekly.points
        guard points.count > 3 else { return XCTFail("fixture did not aggregate") }

        let column = points[2].0
        let cal = Calendar.current
        // Five days into a seven-day column: past its midpoint, so nearest-by-centre would answer the
        // NEXT week's start.
        let lateInTheWeek = cal.date(byAdding: .day, value: 5, to: column)!

        XCTAssertEqual(BandChart.nearestPointDate(to: lateInTheWeek, in: points, unit: .weekOfYear),
                       column,
                       "the finger is on THIS column; the readout must name its week")
        // The start of the column resolves to it too — both ends of the mark, so the fix cannot be
        // satisfied by an off-by-one that only works late in the week.
        XCTAssertEqual(BandChart.nearestPointDate(to: column, in: points, unit: .weekOfYear), column)
    }

    /// A sparse DAILY series keeps its nearest-point behaviour: most days carry no mark at all, so a
    /// touch on an empty day must still resolve to the closest real one rather than to nothing.
    ///
    /// Turns red: delete the nearest-point fallback and return nil when no mark contains the touch.
    func testATouchOnAnEmptyDayStillResolvesToTheNearestMeasuredOne() {
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: Date())
        func at(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: day0)! }
        // A ten-day gap, the normal shape of these series.
        let points: [(Date, Double)] = [(at(-20), 50), (at(-10), 60)]

        XCTAssertEqual(BandChart.nearestPointDate(to: at(-13), in: points, unit: .day), at(-10),
                       "nearest, not the point before")
        XCTAssertEqual(BandChart.nearestPointDate(to: at(-17), in: points, unit: .day), at(-20))
    }

    /// `days` consecutive measured days ending today — dense enough to cross the threshold at 365.
    private func series(days: Int) -> [(date: Date, value: Double)] {
        let cal = Calendar.current
        let day0 = cal.startOfDay(for: Date())
        return (0..<days).map { i in
            (cal.date(byAdding: .day, value: -(days - 1 - i), to: day0)!, 60 + Double(i % 17))
        }
    }
}
