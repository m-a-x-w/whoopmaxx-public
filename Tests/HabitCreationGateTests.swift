import XCTest
@testable import whoopmaxx

/// "A day BEFORE the habit existed is not a miss" — the rule `historyDated` and `trailingAdherence`
/// already applied on the Manage surfaces. It never reached `rowVM`, which is the ONLY assembler behind
/// Today's Habits section, so Today kept inventing a failure record: browsing back rendered a
/// warn-coloured miss square, and every pre-creation weekday in the current week counted toward `target`
/// in `periodAdherence`, deflating the fraction. Manage and Today disagreed about the identical habit
/// and day.
@MainActor
final class HabitCreationGateTests: XCTestCase {

    private func store() -> HabitsStore { HabitsStore(repo: Repository()) }

    /// A habit created at local noon on `dayKey`.
    private func habit(createdOn dayKey: String, cadence: HabitCadence = .daily) -> Habit {
        let noon = DayKey.hourFormatter.date(from: dayKey + " 12")!
        return Habit(id: UUID().uuidString, name: "Test", kind: .manual, cadence: cadence,
                     createdAt: Int(noon.timeIntervalSince1970))
    }

    /// Yesterday's key relative to a reference key, via the app's own shift.
    private func shift(_ key: String, _ days: Int) -> String {
        TodayModel.shiftKey(key, by: days)!
    }

    // MARK: - Per-day verdict

    /// The regression: a day before creation must read `.notScheduled`, never `.missed`.
    func testDayBeforeCreationIsNotAMiss() {
        let s = store()
        let today = s.todayKey()
        let h = habit(createdOn: today)

        let vm = s.rowVM(h, selectedKey: shift(today, -3))

        XCTAssertEqual(vm.today.state, .notScheduled,
                       "the app must not invent a failure for a day the habit did not exist on")
    }

    /// A day on or after creation is still evaluated normally — the gate must not swallow real misses.
    func testDayOnOrAfterCreationIsStillEvaluated() {
        let s = store()
        let today = s.todayKey()
        let h = habit(createdOn: shift(today, -5))

        let past = s.rowVM(h, selectedKey: shift(today, -3))

        XCTAssertNotEqual(past.today.state, .notScheduled,
                          "an unlogged past day the habit DID exist on is a genuine miss")
    }

    /// The creation day itself counts — the gate is `< created`, not `<= created`.
    func testCreationDayItselfIsEvaluated() {
        let s = store()
        let today = s.todayKey()
        let created = shift(today, -2)
        let h = habit(createdOn: created)

        XCTAssertNotEqual(s.rowVM(h, selectedKey: created).today.state, .notScheduled)
    }

    // MARK: - Current-period adherence

    /// The second half of the defect: pre-creation weekdays inflated `target`, deflating the fraction.
    func testWeeklyAdherenceExcludesPreCreationDays() {
        let s = store()
        let today = s.todayKey()
        let fresh = s.rowVM(habit(createdOn: today, cadence: .weekly(4)), selectedKey: today)
        let old = s.rowVM(habit(createdOn: shift(today, -60), cadence: .weekly(4)), selectedKey: today)

        guard let freshTarget = fresh.adherence?.target, let oldTarget = old.adherence?.target else {
            return XCTFail("weekly cadence must produce an adherence fraction")
        }
        XCTAssertLessThanOrEqual(freshTarget, oldTarget,
                                 "a habit created today cannot owe more than one created two months ago")
    }

    /// A long-standing habit is completely unaffected — the gate must be inert for it.
    func testLongStandingHabitIsUnaffected() {
        let s = store()
        let today = s.todayKey()
        let h = habit(createdOn: shift(today, -365), cadence: .weekly(3))

        let vm = s.rowVM(h, selectedKey: shift(today, -10))

        XCTAssertNotEqual(vm.today.state, .notScheduled)
        XCTAssertNotNil(vm.adherence)
    }

    /// The gate must key on the LOGICAL clock, not the plain local one. They diverge between 00:00 and
    /// the 04:00 rollover, so a habit created at 01:00 has a local creation day one AHEAD of the logical
    /// today it was created on — which would make its own Today checkbox inert until 04:00.
    func testHabitCreatedBeforeTheRolloverIsLoggableOnItsOwnLogicalDay() {
        let s = store()
        // 01:30 local on a fixed date: logical day is the PREVIOUS calendar day, local day is this one.
        guard let created = DayKey.hourFormatter.date(from: "2026-08-05 01") else {
            return XCTFail("fixture date must parse")
        }
        let logicalToday = Repository.logicalDayKey(created)
        let h = Habit(id: UUID().uuidString, name: "Late", kind: .manual, cadence: .daily,
                      createdAt: Int(created.timeIntervalSince1970))

        // Sanity: the two clocks really do disagree for this instant, or the test proves nothing.
        XCTAssertNotEqual(logicalToday, TodayModel.key(from: created),
                          "01:00 must fall on the previous LOGICAL day")

        let vm = s.rowVM(h, selectedKey: logicalToday)

        XCTAssertNotEqual(vm.today.state, .notScheduled,
                          "a habit must be loggable on the logical day it was created on")
    }

    /// The Manage surfaces walk the LOGICAL clock too (`historyDated` seeds from `todayKey()`), so the
    /// creation gate must be on that same clock. Keying it on the plain local day put two clocks in one
    /// function: a habit created at 01:00 had a creation day one AHEAD of the logical day it was created
    /// on, so its first day was erased from the history strip and the trailing adherence — while Today
    /// wrote its log to the earlier key.
    func testManageHistoryIncludesTheCreationDayForAnEarlyMorningHabit() {
        let s = store()
        // 01:00 local: the logical day is the PREVIOUS calendar day.
        guard let created = DayKey.hourFormatter.date(from: "2026-08-05 01") else {
            return XCTFail("fixture date must parse")
        }
        XCTAssertNotEqual(Repository.logicalDayKey(created), TodayModel.key(from: created),
                          "01:00 must fall on the previous LOGICAL day, or this proves nothing")

        let h = Habit(id: UUID().uuidString, name: "Early", kind: .manual, cadence: .daily,
                      createdAt: Int(created.timeIntervalSince1970))
        let logicalCreationDay = Repository.logicalDayKey(created)

        // The same gate `historyDated` and `trailingAdherence` apply must admit the creation day itself.
        XCTAssertNotEqual(s.rowVM(h, selectedKey: logicalCreationDay).today.state, .notScheduled,
                          "the logical day the habit was created on is not a pre-creation day")
    }

    /// `anytime` is never a miss by definition, before or after creation.
    func testAnytimeIsNeverAMiss() {
        let s = store()
        let today = s.todayKey()
        let h = habit(createdOn: today, cadence: .anytime)

        XCTAssertNotEqual(s.rowVM(h, selectedKey: shift(today, -3)).today.state, .missed)
        XCTAssertNotEqual(s.rowVM(h, selectedKey: today).today.state, .missed)
    }
}
