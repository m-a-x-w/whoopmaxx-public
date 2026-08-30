import XCTest
@testable import whoopmaxx

/// The reach of the forced rescore a journal tag write triggers (009 F1).
///
/// A tag is context for the night keyed D+1 (`ScoreEngine.nightContextTags`), so a BACK-DATED
/// toggle has to reach further back than `analyzeRecent`'s ordinary 21-day window or the night it
/// contexts keeps its "nothing logged to explain it" evaluation forever. `daysBack` is the pure day
/// arithmetic behind that widening: fixed-UTC over the two day KEYS, so month, year, leap and DST
/// boundaries are all exact rather than 86_400-second approximations.
final class JournalRescoreReachTests: XCTestCase {

    /// A local instant at noon — far from both midnight and any DST transition hour, so the local
    /// day key this resolves to is unambiguous in every simulator timezone.
    private func localNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    // MARK: - daysBack

    func testDaysBackCountsFromNowsLocalDay() {
        let now = localNoon(2026, 7, 15)
        XCTAssertEqual(Repository.localDayKey(now), "2026-07-15", "fixture must key to its own day")
        XCTAssertEqual(JournalStore.daysBack("2026-07-15", now: now), 0)
        XCTAssertEqual(JournalStore.daysBack("2026-07-14", now: now), 1)
        XCTAssertEqual(JournalStore.daysBack("2026-06-15", now: now), 30)
    }

    func testDaysBackCrossesMonthAndYearBoundaries() {
        // Feb → Mar in a non-leap year: 28 days in February.
        XCTAssertEqual(JournalStore.daysBack("2026-02-27", now: localNoon(2026, 3, 1)), 2)
        // Dec → Jan.
        XCTAssertEqual(JournalStore.daysBack("2025-12-31", now: localNoon(2026, 1, 2)), 2)
        XCTAssertEqual(JournalStore.daysBack("2025-11-30", now: localNoon(2026, 1, 1)), 32)
    }

    func testDaysBackCountsTheLeapDay() {
        // 2028-02-28 → 02-29 → 03-01 is TWO days, not one.
        XCTAssertEqual(JournalStore.daysBack("2028-02-28", now: localNoon(2028, 3, 1)), 2)
    }

    func testDaysBackIsExactAcrossADstTransition() {
        // Mar 1 → Mar 15 is 14 calendar days even where one of them is 23 hours long; a fixed
        // 86_400 s subtraction would floor that span to 13 and under-reach by a day.
        XCTAssertEqual(JournalStore.daysBack("2026-03-01", now: localNoon(2026, 3, 15)), 14)
        // …and the autumn 25-hour day, which the same subtraction would over-count.
        XCTAssertEqual(JournalStore.daysBack("2026-10-25", now: localNoon(2026, 11, 8)), 14)
    }

    func testDaysBackIsNegativeForAFutureKeyAndZeroForJunk() {
        let now = localNoon(2026, 7, 15)
        XCTAssertEqual(JournalStore.daysBack("2026-07-18", now: now), -3,
                       "a future-dated key (a restored bad-clock row) counts backwards")
        for junk in ["", "2026-07", "not-a-day", "2026-13-01", "2026-07-00"] {
            XCTAssertEqual(JournalStore.daysBack(junk, now: now), 0,
                           "an unparseable key must not widen the reach")
        }
    }

    // MARK: - rescoreReach

    func testReachFloorsAtTheOrdinaryWindowForRecentDays() {
        let now = localNoon(2026, 7, 15)
        // A live tap and anything inside the ordinary window must not NARROW the pass.
        for key in ["2026-07-15", "2026-07-14", "2026-07-01", "2026-06-27"] {
            XCTAssertEqual(JournalStore.rescoreReach(editedDay: key, now: now), 21)
        }
        // A future-dated key and junk fall back to the same floor.
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2026-08-01", now: now), 21)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "nonsense", now: now), 21)
    }

    func testReachCoversABackDatedEditPlusTheNightItContexts() {
        let now = localNoon(2026, 7, 15)
        // 40 days back: the scan's offsets are 0-based, so reaching that day needs 41 — and the
        // night it contexts (D+1) is nearer still.
        XCTAssertEqual(JournalStore.daysBack("2026-06-05", now: now), 40)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2026-06-05", now: now), 42)
    }

    func testReachClampsAtTheRawRetentionHorizon() {
        let now = localNoon(2026, 7, 15)
        // 53 days back is the last edit that widens on its own terms; 54 lands exactly on the cap
        // and anything older is clamped to it, because past `hardCapDays` the raw samples a day is
        // re-derived from are gone and the extra scan buys nothing.
        XCTAssertEqual(JournalStore.daysBack("2026-05-23", now: now), 53)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2026-05-23", now: now), 55)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2026-05-22", now: now),
                       SampleRetention.hardCapDays)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2026-05-21", now: now),
                       SampleRetention.hardCapDays)
        XCTAssertEqual(JournalStore.rescoreReach(editedDay: "2024-01-01", now: now),
                       SampleRetention.hardCapDays)
    }

    func testReachStaysInsideItsBoundsForEveryDayInTheChipWindow() {
        // The chip cache spans 120 days, so every key the UI can hand `set(tag:on:day:)` is in here.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = localNoon(2026, 7, 15)
        let base = cal.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        for back in 0...120 {
            let d = cal.date(byAdding: .day, value: -back, to: base)!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            let reach = JournalStore.rescoreReach(editedDay: key, now: now)
            XCTAssertGreaterThanOrEqual(reach, 21, "\(key) narrowed the ordinary pass")
            XCTAssertLessThanOrEqual(reach, SampleRetention.hardCapDays, "\(key) overshot the cap")
            if back <= 19 { XCTAssertEqual(reach, 21, "\(key) is inside the ordinary window") }
            if back >= 54 { XCTAssertEqual(reach, SampleRetention.hardCapDays, "\(key) must clamp") }
        }
    }
}
