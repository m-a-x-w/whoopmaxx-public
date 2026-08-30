import XCTest
@testable import whoopmaxx

/// `WallFreshness` — when a Data-wall tile has to say WHEN its value was measured.
///
/// The wall renders `entry.series.last` for every metric that has one, with nothing to place that
/// point in time: a Naps tile still showing last Tuesday's credit read exactly like a nap this
/// morning. The caption fixes that, and it must fire in ONE direction only — the reference is the
/// wall's own freshest point, so a wearer three days behind on syncing sees a bare wall, not a date
/// stamped on every tile.
final class StaleTileTests: XCTestCase {

    private func day(_ key: String) -> Date { MetricCatalog.date(fromDayKey: key)! }

    // MARK: - Both directions

    /// A metric matching the wall's freshest point is unchanged: the caption slot is still just its unit.
    func testAMetricAtTheWallsFreshestPointCarriesNoDate() {
        let d = day("2026-07-15")
        XCTAssertEqual(WallFreshness.caption(unit: "ms", measured: d, freshest: d), "ms")
    }

    /// Three days behind the wall, the tile says the date it was measured — and says the MEASURED
    /// day, not the wall's freshest one.
    func testThreeDaysBehindCarriesTheMeasuredDate() {
        let caption = WallFreshness.caption(unit: "ms", measured: day("2026-07-12"),
                                            freshest: day("2026-07-15"))
        guard let caption else { return XCTFail("a three-day-old value must be dated") }
        XCTAssertTrue(caption.hasPrefix("ms "), "the unit survives — \(caption)")
        XCTAssertTrue(caption.contains("12"), "names the day it was measured — \(caption)")
        XCTAssertFalse(caption.contains("15"), "must not name the wall's freshest day — \(caption)")
    }

    // MARK: - The boundary, pinned from both sides

    /// One day behind is the NORMAL shape of a fully-synced wall (last night's vitals sit on
    /// yesterday's key beside today's still-accumulating step count), so it is not captioned.
    func testOneDayBehindIsStillCurrent() {
        XCTAssertNil(WallFreshness.caption(unit: nil, measured: day("2026-07-14"),
                                           freshest: day("2026-07-15")))
    }

    /// Two days behind is over the line and gets its date.
    func testTwoDaysBehindIsCaptioned() {
        XCTAssertNotNil(WallFreshness.caption(unit: nil, measured: day("2026-07-13"),
                                              freshest: day("2026-07-15")))
    }

    // MARK: - The reference is the wall, never the clock

    /// A wall whose freshest point is itself years old is still a CURRENT wall: every tile agrees with
    /// every other, so nothing is lagging and nothing is captioned. Comparing against `Date()` instead
    /// would date every tile a lapsed wearer owns.
    func testAWholeWallLeftBehindIsNotCaptioned() {
        let d = day("2020-01-01")
        XCTAssertNil(WallFreshness.caption(unit: nil, measured: d, freshest: d))
        XCTAssertEqual(WallFreshness.caption(unit: "bpm", measured: d, freshest: d), "bpm")
    }

    // MARK: - The caption run

    /// A unitless metric (Effort, Rest, Steps, Regularity) shows the date alone — no orphaned separator.
    func testAUnitlessMetricShowsTheDateAlone() {
        let caption = WallFreshness.caption(unit: nil, measured: day("2026-07-12"),
                                            freshest: day("2026-07-15"))
        guard let caption else { return XCTFail("a three-day-old value must be dated") }
        XCTAssertFalse(caption.contains("\u{00B7}"), "no separator without a unit — \(caption)")
        XCTAssertTrue(caption.contains("12"), "names the day it was measured — \(caption)")
    }

    /// A unitless metric that is current carries no caption at all — an empty run, not an empty string.
    func testAUnitlessCurrentMetricStaysBare() {
        let d = day("2026-07-15")
        XCTAssertNil(WallFreshness.caption(unit: nil, measured: d, freshest: d))
    }

    // MARK: - The year, only when it is a different one

    /// A metric that stopped arriving months ago names its year: a bare "Nov 3" would be read as this
    /// year's.
    func testACrossYearDateNamesItsYear() {
        let caption = WallFreshness.caption(unit: "%", measured: day("2025-11-03"),
                                            freshest: day("2026-07-15"))
        guard let caption else { return XCTFail("a value from last year must be dated") }
        XCTAssertTrue(caption.contains("2025"), "names the year it was measured — \(caption)")
    }

    /// Within one year the year is left off — the wall stays terse.
    func testASameYearDateOmitsTheYear() {
        let caption = WallFreshness.caption(unit: "%", measured: day("2026-07-12"),
                                            freshest: day("2026-07-15"))
        guard let caption else { return XCTFail("a three-day-old value must be dated") }
        XCTAssertFalse(caption.contains("2026"), "same year needs no year — \(caption)")
    }

    // MARK: - The wall's freshest point

    /// The reference is the NEWEST point anywhere on the wall, whatever order the metrics arrive in.
    func testTheFreshestPointIsTheNewestAcrossEveryMetric() {
        let dates = [day("2026-07-10"), day("2026-07-15"), day("2026-07-01")]
        XCTAssertEqual(WallFreshness.newest(dates), day("2026-07-15"))
    }

    /// An empty wall has no reference — and draws no tiles to caption.
    func testAnEmptyWallHasNoFreshestPoint() {
        XCTAssertNil(WallFreshness.newest([]))
    }

    /// Without a reference the caption slot is exactly what it was before this rule existed.
    func testNoReferenceLeavesTheUnitUntouched() {
        XCTAssertEqual(WallFreshness.caption(unit: "kcal", measured: day("2026-07-12"), freshest: nil),
                       "kcal")
    }
}
