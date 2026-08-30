import XCTest
import StrapStore
@testable import whoopmaxx

/// Repository's day-key / today / widget-anchor logic — the behaviour the original hardened across
/// #144 (anti-blank guard), #304 (pre-04:00 carve-out), #547 (future-day guard), #911 (single
/// anchor). The resolvers are pure over explicit keys, so these run deterministically in any
/// simulator timezone; the clock-derived key tests build their dates through `Calendar.current`,
/// the same zone the formatter uses.
final class DayKeyTests: XCTestCase {

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    // MARK: - Logical day (04:00 rollover)

    @MainActor
    func testLogicalDayStaysOnYesterdayBeforeFourAM() {
        // 02:30 local: the calendar day is the 15th, but the logical day is still the 14th.
        let at0230 = localDate(year: 2026, month: 7, day: 15, hour: 2, minute: 30)
        XCTAssertEqual(Repository.localDayKey(at0230), "2026-07-15")
        XCTAssertEqual(Repository.logicalDayKey(at0230), "2026-07-14")
    }

    @MainActor
    func testLogicalDayRollsAtExactlyFourAM() {
        let at0400 = localDate(year: 2026, month: 7, day: 15, hour: 4)
        XCTAssertEqual(Repository.logicalDayKey(at0400), "2026-07-15")
        // …and one minute before, it hasn't.
        let at0359 = localDate(year: 2026, month: 7, day: 15, hour: 3, minute: 59)
        XCTAssertEqual(Repository.logicalDayKey(at0359), "2026-07-14")
    }

    @MainActor
    func testLogicalAndLocalDayAgreeMidday() {
        let noon = localDate(year: 2026, month: 7, day: 15, hour: 12)
        XCTAssertEqual(Repository.logicalDayKey(noon), Repository.localDayKey(noon))
        // Just before midnight both keys are still the same calendar day.
        let lateNight = localDate(year: 2026, month: 7, day: 15, hour: 23, minute: 59)
        XCTAssertEqual(Repository.logicalDayKey(lateNight), "2026-07-15")
        XCTAssertEqual(Repository.localDayKey(lateNight), "2026-07-15")
    }

    // MARK: - resolveToday (#304 carve-out + #144 anti-blank)

    func testResolveTodayPrefersLocalRowWithBankedNightBeforeFourAM() {
        // Pre-04:00: logical = 14th, local = 15th. The 15th already has a banked night
        // (totalSleepMin set), so "today" is the LOCAL row — the just-slept night shows at 2 am.
        let days = [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 60),
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420)]
        let resolved = Repository.resolveToday(days: days,
                                               logicalKey: "2026-07-14", localKey: "2026-07-15")
        XCTAssertEqual(resolved?.day, "2026-07-15")
    }

    func testResolveTodayFallsBackToLogicalRowWhenLocalHasNoNight() {
        // Pre-04:00 but the new calendar day has no banked night yet → stay on the logical day
        // (the #144 anti-blank guard: Today never goes empty at midnight).
        let days = [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 60),
                    Fixtures.dailyMetric(day: "2026-07-15")]   // exists, but no night banked
        let resolved = Repository.resolveToday(days: days,
                                               logicalKey: "2026-07-14", localKey: "2026-07-15")
        XCTAssertEqual(resolved?.day, "2026-07-14")
    }

    func testResolveTodayUsesLogicalRowMidday() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 60),
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420, recovery: 71)]
        let resolved = Repository.resolveToday(days: days,
                                               logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(resolved?.day, "2026-07-15")
    }

    func testResolveTodayNilOnEmptyStore() {
        XCTAssertNil(Repository.resolveToday(days: [],
                                             logicalKey: "2026-07-15", localKey: "2026-07-15"))
    }

    // MARK: - widgetAnchor (#911 single anchor + #547 future-day guard)

    func testWidgetAnchorUsesTodayWhenScored() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 60),
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420, recovery: 71)]
        let anchor = Repository.widgetAnchor(days: days,
                                             logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-15")
        XCTAssertEqual(anchor?.recovery, 71)
    }

    func testWidgetAnchorCarriesFreshestPriorScoredDay() {
        // Today exists but is unscored (recovery nil) → carry the freshest STRICTLY-PRIOR scored day.
        let days = [Fixtures.dailyMetric(day: "2026-07-12", totalSleepMin: 380, recovery: 55),
                    Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 390, recovery: 64),
                    Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400),   // unscored
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420)]   // today, unscored
        let anchor = Repository.widgetAnchor(days: days,
                                             logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-13")
    }

    func testWidgetAnchorIgnoresFutureDatedScoredRow() {
        // A stray future-dated scored row must never surface AS today (#547): the carry bound is
        // strictly `day < carriedKey`.
        let days = [Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 390, recovery: 64),
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420),   // today, unscored
                    Fixtures.dailyMetric(day: "2026-07-20", totalSleepMin: 400, recovery: 90)]   // future junk
        let anchor = Repository.widgetAnchor(days: days,
                                             logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-13")
    }

    func testWidgetAnchorWithNoTodayRowCarriesFromLogicalKey() {
        // No row for today at all → carriedKey falls back to the logical key and the freshest
        // prior scored day anchors.
        let days = [Fixtures.dailyMetric(day: "2026-07-12", totalSleepMin: 380, recovery: 55),
                    Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 390, recovery: 64)]
        let anchor = Repository.widgetAnchor(days: days,
                                             logicalKey: "2026-07-15", localKey: "2026-07-15")
        XCTAssertEqual(anchor?.day, "2026-07-13")
    }

    func testWidgetAnchorNilWhenNothingScored() {
        let days = [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400),
                    Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 420)]
        XCTAssertNil(Repository.widgetAnchor(days: days,
                                             logicalKey: "2026-07-15", localKey: "2026-07-15"))
    }
}
