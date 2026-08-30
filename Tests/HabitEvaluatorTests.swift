import XCTest
import StrapStore
@testable import whoopmaxx

/// Pins the pure habit verdict + adherence logic (008, manual-only): log-driven per-day verdicts,
/// legacy "override"-source rows reading as manual, no-data exclusion in the rate, current-period
/// rates, and cadence display neutralization.
final class HabitEvaluatorTests: XCTestCase {

    private func habit(cadence: HabitCadence = .daily) -> Habit {
        Habit(id: "h", name: "H", kind: .manual, cadence: cadence, createdAt: 0)
    }

    private func log(_ done: Bool, _ source: String) -> HabitLog {
        HabitLog(habitId: "h", day: "2026-07-01", done: done, source: source, value: nil, stampedAt: 0)
    }

    // MARK: - Per-day verdict (log-driven)

    func testLogDoneReadsDoneWithManualSource() {
        let r = HabitEvaluator.dayResult(habit(), closed: true, log: log(true, "manual"))
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(r.source, .manual)
    }

    func testLogFalseReadsMissed() {
        let r = HabitEvaluator.dayResult(habit(), closed: false, log: log(false, "manual"))
        XCTAssertEqual(r.state, .missed)
        XCTAssertEqual(r.source, .manual)
    }

    func testNoLogPendingWhenOpenMissedWhenClosed() {
        let open = HabitEvaluator.dayResult(habit(), closed: false, log: nil)
        XCTAssertEqual(open.state, .pending)
        XCTAssertEqual(open.source, HabitDayResult.Source.none)
        let closed = HabitEvaluator.dayResult(habit(), closed: true, log: nil)
        XCTAssertEqual(closed.state, .missed)
        XCTAssertEqual(closed.source, HabitDayResult.Source.none)
    }

    func testLegacyOverrideSourceLogReadsAsManual() {
        // Old auto-habit override rows persist "override" in the source column — they must keep
        // deciding done/missed exactly like a manual log.
        let done = HabitEvaluator.dayResult(habit(), closed: true, log: log(true, "override"))
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.source, .manual)
        let missed = HabitEvaluator.dayResult(habit(), closed: true, log: log(false, "override"))
        XCTAssertEqual(missed.state, .missed)
        XCTAssertEqual(missed.source, .manual)
    }

    // MARK: - Adherence

    func testDailyAdherenceExcludesNoDataAndPending() {
        // The evaluator no longer emits `.noData`, but legacy-shaped results must still be excluded
        // from the rate — construct one directly.
        let results: [HabitDayResult] = [
            .init(state: .done, source: .manual),
            .init(state: .missed, source: .none),
            .init(state: .noData, source: .none),
            .init(state: .pending, source: .none),
        ]
        let a = HabitEvaluator.periodAdherence(results: results, cadence: .daily)
        XCTAssertEqual(a.done, 1)
        XCTAssertEqual(a.target, 2)          // done + missed only
        XCTAssertEqual(a.excludedNoData, 1)
    }

    func testWeeklyAdherenceCountsDoneAgainstN() {
        let results = Array(repeating: HabitDayResult(state: .done, source: .manual), count: 5)
        let a = HabitEvaluator.periodAdherence(results: results, cadence: .weekly(4))
        XCTAssertEqual(a.done, 4)            // capped at N
        XCTAssertEqual(a.target, 4)
    }

    // MARK: - Display neutralization

    func testWeeklyAndAnytimeMissNeutralizedDailyKept() {
        let miss = HabitDayResult(state: .missed, source: .none)
        XCTAssertEqual(HabitEvaluator.displayState(miss, cadence: .weekly(3)).state, .pending)
        XCTAssertEqual(HabitEvaluator.displayState(miss, cadence: .anytime).state, .pending)
        XCTAssertEqual(HabitEvaluator.displayState(miss, cadence: .daily).state, .missed)
    }

    // MARK: - Scheduling

    func testWeekdaysMaskSchedule() {
        // Bit for Calendar weekday: Monday = 2.
        let monHabit = habit(cadence: .weekdays(1 << 2))
        XCTAssertTrue(HabitEvaluator.isScheduled(monHabit, weekday: 2))
        XCTAssertFalse(HabitEvaluator.isScheduled(monHabit, weekday: 1))   // Sunday
        XCTAssertFalse(HabitEvaluator.isScheduled(habit(cadence: .anytime), weekday: 2))
    }
}
