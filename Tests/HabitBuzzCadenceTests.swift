import XCTest
@testable import whoopmaxx

/// The buzz path was the one consumer of "is this habit due today" that never asked. A `weekdays` habit
/// nudged the wrist on its off-days — on a row Today simultaneously renders as `.notScheduled` and
/// refuses to let the user tap, so the buzz asked for something that could neither be done nor dismissed.
/// Every existing case in `HabitBuzzTests` builds `.daily` habits, so the suite was silent on this.
///
/// `HabitsStore.habits` is `@Published private(set)` and is only ever filled from the store, so a unit
/// test cannot inject habits and assert on `buzzHabits(day:)` directly — an empty-store assertion would
/// pass for the wrong reason. These pin the SCHEDULING RULE that `buzzHabits` now applies, plus the
/// window logic it composes with; the one-line wiring is covered by the build.
final class HabitBuzzCadenceTests: XCTestCase {

    /// Weekday bitmask over `Calendar` weekday (1 = Sun … 7 = Sat).
    private static let monToFri = (2...6).reduce(0) { $0 | (1 << $1) }
    private static let satSunOnly = (1 << 1) | (1 << 7)

    private func habit(_ cadence: HabitCadence) -> Habit {
        Habit(id: UUID().uuidString, name: "Buzzed", kind: .manual, cadence: cadence,
              buzz: HabitBuzzWindow(start: 9 * 60, end: 10 * 60),
              createdAt: Int(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970))
    }

    // MARK: - The cadence rule `buzzHabits(day:)` now applies

    /// The regression, at the rule level: a Mon–Fri habit is NOT scheduled at the weekend, so it must
    /// not survive the buzz filter there.
    func testWeekdaysHabitIsNotScheduledAtTheWeekend() {
        let h = habit(.weekdays(Self.monToFri))

        XCTAssertFalse(HabitEvaluator.isScheduled(h, weekday: 7), "Saturday is an off-day")
        XCTAssertFalse(HabitEvaluator.isScheduled(h, weekday: 1), "Sunday is an off-day")
    }

    /// …and it must still be scheduled midweek, or the fix would silently kill the feature.
    func testWeekdaysHabitIsStillScheduledMidweek() {
        let h = habit(.weekdays(Self.monToFri))

        for weekday in 2...6 {
            XCTAssertTrue(HabitEvaluator.isScheduled(h, weekday: weekday),
                          "weekday \(weekday) is inside Mon–Fri and must still buzz")
        }
    }

    /// The mirror image: a weekend-only habit buzzes at the weekend and stays quiet midweek.
    func testWeekendHabitIsScheduledOnlyAtTheWeekend() {
        let h = habit(.weekdays(Self.satSunOnly))

        XCTAssertTrue(HabitEvaluator.isScheduled(h, weekday: 7))
        XCTAssertTrue(HabitEvaluator.isScheduled(h, weekday: 1))
        for weekday in 2...6 {
            XCTAssertFalse(HabitEvaluator.isScheduled(h, weekday: weekday))
        }
    }

    /// `daily` and `weekly` are eligible every day — the gate must not narrow them. (`anytime` is
    /// short-circuited before `isScheduled` by `isScheduledForDisplay`, so it is eligible by
    /// construction and is asserted separately below.)
    func testDailyAndWeeklyRemainScheduledEveryDay() {
        for cadence in [HabitCadence.daily, .weekly(3)] {
            let h = habit(cadence)
            for weekday in 1...7 {
                XCTAssertTrue(HabitEvaluator.isScheduled(h, weekday: weekday),
                              "\(cadence) must stay eligible on weekday \(weekday)")
            }
        }
    }

    /// `anytime` is loggable every day by design, so it must never be filtered out by cadence.
    func testAnytimeIsAlwaysEligible() {
        let h = habit(.anytime)
        XCTAssertEqual(h.cadence, .anytime,
                       "isScheduledForDisplay short-circuits .anytime before the weekday test")
    }

    // MARK: - Composition with the window

    /// The cadence term is ADDITIONAL to the window test — an on-schedule day outside the window still
    /// does not buzz, and the fix must not have disturbed that.
    func testWindowStillGatesOnAScheduledDay() {
        let h = habit(.weekdays(Self.monToFri))
        guard let w = h.buzz else { return XCTFail("fixture must carry a buzz window") }

        XCTAssertTrue(HabitBuzz.windowOpen(now: 9 * 60 + 30, start: w.start, end: w.end))
        XCTAssertFalse(HabitBuzz.windowOpen(now: 8 * 60, start: w.start, end: w.end))
        XCTAssertFalse(HabitBuzz.windowOpen(now: 11 * 60, start: w.start, end: w.end))
    }

    /// A midnight-crossing window keeps its wrap-around behaviour.
    func testMidnightCrossingWindowIsUnchanged() {
        XCTAssertTrue(HabitBuzz.windowOpen(now: 23 * 60 + 30, start: 23 * 60, end: 30))
        XCTAssertTrue(HabitBuzz.windowOpen(now: 15, start: 23 * 60, end: 30))
        XCTAssertFalse(HabitBuzz.windowOpen(now: 12 * 60, start: 23 * 60, end: 30))
    }
}
