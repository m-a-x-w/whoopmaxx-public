import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// Journal insights assembly (007 F1): `JournalInsightsModel.compute` joins tag days to NEXT-day
/// outcomes through the vendored lag machinery (`EffectRanker.bestLag` → `CorrelationEngine.
/// shiftDay`, fixed-UTC day arithmetic — so the join survives month boundaries), gates groups at
/// n ≥ 5 per side, and applies Benjamini–Hochberg across the whole behavior × outcome family.
final class JournalInsightsTests: XCTestCase {

    /// "2026-01-01" + i, fixed-UTC (the same arithmetic shiftDay uses).
    private func dayKey(_ i: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(year: 2026, month: 1, day: 1)
        let d = cal.date(byAdding: .day, value: i, to: cal.date(from: start)!)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 60 days with a deterministic HRV wobble; every 6th day is an alcohol day and the FOLLOWING
    /// day's HRV is depressed by 15 ms. Spans Jan → Mar, so several tag→next-day pairs cross a
    /// month boundary (e.g. Jan 31 → Feb 1) and exercise shiftDay's calendar arithmetic.
    private func alcoholFixture() -> (days: [DailyMetric], alcoholDays: Set<String>) {
        let wobble: [Double] = [0, 3, -2, 5, -4, 2, -1, 4]
        var days: [DailyMetric] = []
        var alcohol: Set<String> = []
        for i in 0..<60 {
            var hrv = 70 + wobble[i % wobble.count]
            if i >= 1 && (i - 1) % 6 == 0 { hrv -= 15 }        // morning after an alcohol day
            if i % 6 == 0 { alcohol.insert(dayKey(i)) }
            days.append(Fixtures.dailyMetric(day: dayKey(i), avgHrv: hrv))
        }
        return (days, alcohol)
    }

    // MARK: - Lag join

    func testAlcoholNextDayDipRanksAtLagOne() throws {
        let fx = alcoholFixture()
        XCTAssertTrue(fx.alcoholDays.contains("2026-01-31"),
                      "fixture must include a month-boundary pair (Jan 31 → Feb 1)")
        let rows = JournalInsightsModel.compute(tagDays: ["alcohol": fx.alcoholDays],
                                                days: fx.days, restSeries: [:])
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.key, "alcohol")
        XCTAssertEqual(row.label, "Alcohol")
        XCTAssertEqual(row.loggedDays, 10)
        let effect = try XCTUnwrap(row.effect, "10 tagged days must clear the n≥5 group gate")
        XCTAssertEqual(effect.lag, 1, "the baked effect lands the NEXT morning, not same-day")
        XCTAssertEqual(effect.outcome, "HRV")
        XCTAssertLessThan(effect.effect.delta, -10, "the −15 ms dip must survive the join")
        XCTAssertTrue(row.significant, "a clean 15 ms dip across 10 days is significant")
    }

    // MARK: - Group gate

    func testBelowFiveLoggedDaysShowsNoEffect() throws {
        let fx = alcoholFixture()
        let sauna: Set<String> = [dayKey(2), dayKey(9), dayKey(17)]     // only 3 logged days
        let rows = JournalInsightsModel.compute(tagDays: ["alcohol": fx.alcoholDays,
                                                          "sauna": sauna],
                                                days: fx.days, restSeries: [:])
        let saunaRow = try XCTUnwrap(rows.first { $0.key == "sauna" })
        XCTAssertNil(saunaRow.effect,
                     "below minGroupForSignificance no effect (and no number) is ever shown")
        XCTAssertFalse(saunaRow.significant)
        XCTAssertNil(saunaRow.qValue)
        XCTAssertEqual(saunaRow.loggedDays, 3)
    }

    // MARK: - Benjamini–Hochberg gate

    func testFamilyCorrectionInflatesQAndKeepsNullTagsInsignificant() throws {
        let fx = alcoholFixture()
        // A null behavior with plenty of logged days (period 7, no baked effect).
        let lateMeal = Set((0..<60).filter { $0 % 7 == 3 }.map(dayKey))
        let rows = JournalInsightsModel.compute(tagDays: ["alcohol": fx.alcoholDays,
                                                          "late_meal": lateMeal],
                                                days: fx.days, restSeries: [:])
        let alcohol = try XCTUnwrap(rows.first { $0.key == "alcohol" })
        let meal = try XCTUnwrap(rows.first { $0.key == "late_meal" })

        XCTAssertTrue(alcohol.significant, "the real effect must survive the family correction")
        XCTAssertFalse(meal.significant, "a null tag must not stargaze its way to significance")

        // BH never shrinks a p-value: each row's q is ≥ its chosen pair's raw p.
        for row in [alcohol, meal] {
            let q = try XCTUnwrap(row.qValue)
            let p = try XCTUnwrap(row.effect).effect.pApprox
            XCTAssertGreaterThanOrEqual(q + 1e-12, p, "q must be ≥ raw p (family inflation)")
        }
        // Ordering: significant rows lead.
        XCTAssertEqual(rows.first?.key, "alcohol")
    }

    // MARK: - Outcome family

    func testRestSeriesJoinsAsFourthOutcome() throws {
        // Only the Rest series carries the dip → the chosen pair must be the Rest outcome.
        var rest: [String: Double] = [:]
        var alcohol: Set<String> = []
        let wobble: [Double] = [0, 2, -1, 3, -2, 1]
        for i in 0..<60 {
            var v = 82 + wobble[i % wobble.count]
            if i >= 1 && (i - 1) % 6 == 0 { v -= 12 }
            if i % 6 == 0 { alcohol.insert(dayKey(i)) }
            rest[dayKey(i)] = v
        }
        let rows = JournalInsightsModel.compute(tagDays: ["alcohol": alcohol],
                                                days: [], restSeries: rest)
        let row = try XCTUnwrap(rows.first)
        let effect = try XCTUnwrap(row.effect)
        XCTAssertEqual(effect.outcome, "Rest")
        XCTAssertEqual(effect.lag, 1)
        XCTAssertLessThan(effect.effect.delta, 0)
    }
}
