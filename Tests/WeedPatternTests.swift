import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// `WeedPattern` (009 F3) — the descriptive counts the Weed screen shows. No statistics: effect
/// analysis stays in the untouched shared journal family, and these are counts of what was logged.
///
/// The load-bearing rule is the RUN: it is counted over COVERED days (day keys with a `DailyMetric`
/// row), because `tagsByDay` cannot distinguish "logged no" from "logged nothing" — a false row
/// exists only where the user explicitly toggled OFF. A day the app has no data for therefore
/// neither BREAKS nor EXTENDS a logged-free run.
final class WeedPatternTests: XCTestCase {

    /// "2026-01-01" + i, fixed-UTC — the same arithmetic `WeedPattern` steps its window with.
    private func dayKey(_ i: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(year: 2026, month: 1, day: 1)
        let d = cal.date(byAdding: .day, value: i, to: cal.date(from: start)!)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func keys(_ range: Range<Int>) -> [String] { range.map(dayKey) }

    // MARK: - The run over covered days

    func testANoDataDayNeitherBreaksNorExtendsARun() {
        // Days 0…9, weed on the two ends, and day 5 has NO DailyMetric row.
        let covered = keys(0..<10).filter { $0 != dayKey(5) }
        let p = WeedPattern.compute(weedDays: [dayKey(0), dayKey(9)], sessionsByDay: [:],
                                    coveredDays: covered, today: dayKey(9))
        XCTAssertEqual(p.longestFreeRun, 7,
                       "days 1-4 and 6-8 are one run of 7: the no-data day is skipped, not counted "
                       + "(breaking it would give 4, counting it as free would give 8)")
        XCTAssertEqual(p.coveredDays, 9)
    }

    func testARunIsBoundedByTheWindowEdges() {
        // Nothing logged at all → the run is the whole covered window, not an open-ended number.
        let all = WeedPattern.compute(weedDays: [], sessionsByDay: [:],
                                      coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(all.longestFreeRun, 10)
        XCTAssertNil(all.daysSinceLast)

        // A run that starts at the first covered day still counts…
        let leading = WeedPattern.compute(weedDays: [dayKey(9)], sessionsByDay: [:],
                                          coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(leading.longestFreeRun, 9)
        // …and so does one that runs to the last.
        let trailing = WeedPattern.compute(weedDays: [dayKey(0)], sessionsByDay: [:],
                                           coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(trailing.longestFreeRun, 9)
    }

    func testTheLongestRunIsTakenNotTheLast() {
        // Breaks at 3 and 5 → runs of 3, 1 and 4. Every weed day resets the count.
        let p = WeedPattern.compute(weedDays: [dayKey(3), dayKey(5)], sessionsByDay: [:],
                                    coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(p.longestFreeRun, 4)
    }

    func testFutureCoveredDaysAreDropped() {
        // The daily read window admits rows keyed up to TOMORROW (#547), and a run must never be
        // extended by a night that has not happened.
        let p = WeedPattern.compute(weedDays: [], sessionsByDay: [:],
                                    coveredDays: keys(0..<12), today: dayKey(9))
        XCTAssertEqual(p.coveredDays, 10)
        XCTAssertEqual(p.longestFreeRun, 10)
    }

    // MARK: - Days since last

    func testDaysSinceLastIsAbsentWhenTheWindowHoldsNoWeedDay() {
        let p = WeedPattern.compute(weedDays: [], sessionsByDay: [:],
                                    coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertNil(p.daysSinceLast, "nil is absence — the screen says '120+' off the newest session, "
                     + "never a fabricated 0")
    }

    func testDaysSinceLastCountsFromTheNewestWeedDay() {
        let today = WeedPattern.compute(weedDays: [dayKey(3), dayKey(9)], sessionsByDay: [:],
                                        coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(today.daysSinceLast, 0)

        let gap = WeedPattern.compute(weedDays: [dayKey(3), dayKey(6)], sessionsByDay: [:],
                                      coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(gap.daysSinceLast, 3)
    }

    func testDaysSinceLastReadsTheBooleanSoALegacyDayCounts() {
        // A chip-only day has no session row at all. It is still a weed day, and the hero must not
        // skip past it to an older one that happens to carry sessions.
        let p = WeedPattern.compute(weedDays: [dayKey(2), dayKey(7)],
                                    sessionsByDay: [dayKey(2): [session(day: 2)]],
                                    coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(p.daysSinceLast, 2)
    }

    func testDaysSinceLastIgnoresAFutureDatedKeyAndCrossesAMonthBoundary() {
        // A restored bad-clock row can key ahead of today; counting from it would print a negative.
        let p = WeedPattern.compute(weedDays: [dayKey(6), dayKey(14)], sessionsByDay: [:],
                                    coveredDays: keys(0..<10), today: dayKey(9))
        XCTAssertEqual(p.daysSinceLast, 3)

        // Jan 31 → Feb 3, the boundary a fixed-30-day subtraction gets wrong.
        let across = WeedPattern.compute(weedDays: ["2026-01-31"], sessionsByDay: [:],
                                         coveredDays: [], today: "2026-02-03")
        XCTAssertEqual(across.daysSinceLast, 3)
    }

    // MARK: - Sessions vs logged days

    func testSessionsAreCountedSeparatelyFromLoggedDays() {
        // Three weed days: one with four sessions, one with two, one legacy chip-only.
        let sessions: [String: [WeedSession]] = [
            dayKey(3): (0..<4).map { session(day: 3, i: $0) },
            dayKey(5): (0..<2).map { session(day: 5, i: $0) },
        ]
        let p = WeedPattern.compute(weedDays: [dayKey(3), dayKey(5), dayKey(8)],
                                    sessionsByDay: sessions, coveredDays: keys(0..<10),
                                    today: dayKey(9))
        XCTAssertEqual(p.sessions30d, 6, "sessions, not days")
        XCTAssertEqual(p.loggedDays30d, 3, "the legacy day counts as a logged day with zero sessions")
    }

    func testTheThirtyDayWindowExcludesOlderSessionsAndDays() {
        // today = day 40, so the window is days 11…40 inclusive.
        let sessions: [String: [WeedSession]] = [
            dayKey(10): [session(day: 10)],          // one day outside
            dayKey(11): [session(day: 11)],          // the window's first day
            dayKey(40): [session(day: 40)],
        ]
        let p = WeedPattern.compute(weedDays: [dayKey(10), dayKey(11), dayKey(40)],
                                    sessionsByDay: sessions, coveredDays: keys(0..<41),
                                    today: dayKey(40))
        XCTAssertEqual(WeedPattern.windowDays, 30)
        XCTAssertEqual(p.sessions30d, 2)
        XCTAssertEqual(p.loggedDays30d, 2)
        XCTAssertEqual(p.coveredDays, 41, "the covered window is the caller's, not the 30-day one")
    }

    // MARK: - The habitual note

    func testHabitualNoteFiresAtExactlyTheThreshold() {
        XCTAssertEqual(WeedPattern.habitualShare, 0.8)
        // 16/20 is exactly 0.8 — the boundary is inclusive.
        let at = WeedPattern.compute(weedDays: Set(keys(0..<16)), sessionsByDay: [:],
                                     coveredDays: keys(0..<20), today: dayKey(19))
        XCTAssertEqual(at.coveredDays, 20)
        XCTAssertEqual(at.loggedCoveredDays, 16)
        XCTAssertTrue(at.isHabitual)

        // 15/20 = 0.75 is not "most nights".
        let below = WeedPattern.compute(weedDays: Set(keys(0..<15)), sessionsByDay: [:],
                                        coveredDays: keys(0..<20), today: dayKey(19))
        XCTAssertFalse(below.isHabitual)
    }

    func testHabitualNoteStaysSilentBelowTheBaselineTrustFloor() {
        // Every covered day logged, but only 13 of them — under `Baselines.minNightsTrust` the share
        // is noise, and this is the one caption that tells a user their baseline absorbed the effect.
        XCTAssertEqual(Baselines.minNightsTrust, 14)
        let thin = WeedPattern.compute(weedDays: Set(keys(0..<13)), sessionsByDay: [:],
                                       coveredDays: keys(0..<13), today: dayKey(12))
        XCTAssertEqual(thin.loggedCoveredDays, 13)
        XCTAssertFalse(thin.isHabitual)

        let enough = WeedPattern.compute(weedDays: Set(keys(0..<14)), sessionsByDay: [:],
                                         coveredDays: keys(0..<14), today: dayKey(13))
        XCTAssertTrue(enough.isHabitual)
    }

    func testHabitualShareCountsOnlyWeedDaysTheAppHasDataFor() {
        // 20 weed days but only 14 covered ones, 10 of which are weed days → 10/14 = 0.71. Counting
        // the uncovered weed days against a covered denominator would print a share above 1.
        let p = WeedPattern.compute(weedDays: Set(keys(0..<20)), sessionsByDay: [:],
                                    coveredDays: keys(0..<10) + keys(20..<24), today: dayKey(23))
        XCTAssertEqual(p.coveredDays, 14)
        XCTAssertEqual(p.loggedCoveredDays, 10)
        XCTAssertFalse(p.isHabitual)
    }

    // MARK: - Support

    private func session(day: Int, i: Int = 0) -> WeedSession {
        WeedSession(id: "d\(day)-\(i)", day: dayKey(day), ts: 1_784_000_000 + day * 86_400 + i * 3_600)
    }
}
