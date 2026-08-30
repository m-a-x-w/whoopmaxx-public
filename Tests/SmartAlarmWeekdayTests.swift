import XCTest
@testable import whoopmaxx

/// Regression pins for the weekday-restriction and minutes-wrap paths of
/// `SmartAlarmCoordinator.nextSmartAlarmDate` (the today/tomorrow/late-edge paths are already covered by
/// `SmartAlarmTests`). Fixed UTC calendar so the date math is deterministic.
final class SmartAlarmWeekdayTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - Weekday restriction

    /// With only the target weekday enabled, the scan skips the intervening days and lands on the next
    /// matching occurrence. now = 2026-06-17 06:00; enabling only 2026-06-19's weekday → 2026-06-19 07:00.
    func testWeekdayRestrictedSkipsToNextMatch() {
        let now = date(2026, 6, 17, 6, 0)
        let target = date(2026, 6, 19, 7, 0)
        let onlyThatWeekday: Set<Int> = [utc.component(.weekday, from: target)]
        XCTAssertEqual(
            SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, weekdays: onlyThatWeekday,
                                                     from: now, calendar: utc),
            target)
    }

    /// When today's weekday is enabled and the wake time is still ahead, it fires today.
    func testWeekdayRestrictedFiresTodayWhenAhead() {
        let now = date(2026, 6, 17, 6, 0)
        let todayWeekday: Set<Int> = [utc.component(.weekday, from: now)]
        XCTAssertEqual(
            SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, weekdays: todayWeekday,
                                                     from: now, calendar: utc),
            date(2026, 6, 17, 7, 0))
    }

    /// A non-empty weekday set with no valid entries (outside 1…7) → nil.
    func testInvalidWeekdaySetIsNil() {
        XCTAssertNil(SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [8, 9],
                                                              from: date(2026, 6, 17, 6, 0), calendar: utc))
    }

    /// The empty set means "every day" → the next occurrence, no weekday gating.
    func testEmptyWeekdaySetIsEveryDay() {
        XCTAssertEqual(
            SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 7 * 60, weekdays: [],
                                                     from: date(2026, 6, 17, 6, 0), calendar: utc),
            date(2026, 6, 17, 7, 0))
    }

    // MARK: - minutes wrap (mod one day)

    /// minutes ≥ 1440 wraps mod one day: 1860 (1440 + 420) behaves like 07:00.
    func testMinutesOverADayWrap() {
        XCTAssertEqual(
            SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 1860, from: date(2026, 6, 17, 6, 0),
                                                     calendar: utc),
            date(2026, 6, 17, 7, 0))
    }

    /// Exactly 1440 wraps to 00:00 → today's midnight is already past, so tomorrow's.
    func testMinutesExactlyOneDayWrapsToMidnight() {
        XCTAssertEqual(
            SmartAlarmCoordinator.nextSmartAlarmDate(minutes: 1440, from: date(2026, 6, 17, 6, 0),
                                                     calendar: utc),
            date(2026, 6, 18, 0, 0))
    }
}
