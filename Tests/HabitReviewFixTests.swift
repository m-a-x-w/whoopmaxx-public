import XCTest
@testable import whoopmaxx

/// Locks the 008 code-review fixes that live in pure helpers: cadence-aware display neutralization
/// (weekly/anytime never render a per-day miss) and midnight-crossing buzz windows.
final class HabitReviewFixTests: XCTestCase {

    private func r(_ s: HabitDayResult.State) -> HabitDayResult { HabitDayResult(state: s, source: .manual) }

    // MARK: - displayState neutralization

    func testWeeklyAndAnytimeMissNeutralizedToPending() {
        XCTAssertEqual(HabitEvaluator.displayState(r(.missed), cadence: .weekly(3)).state, .pending)
        XCTAssertEqual(HabitEvaluator.displayState(r(.missed), cadence: .anytime).state, .pending)
    }

    func testDailyAndWeekdaysMissKept() {
        XCTAssertEqual(HabitEvaluator.displayState(r(.missed), cadence: .daily).state, .missed)
        XCTAssertEqual(HabitEvaluator.displayState(r(.missed), cadence: .weekdays(0b0_1111100)).state, .missed)
    }

    func testDoneNeverNeutralized() {
        for cadence: HabitCadence in [.weekly(2), .anytime, .daily] {
            XCTAssertEqual(HabitEvaluator.displayState(r(.done), cadence: cadence).state, .done)
        }
    }

    // MARK: - Buzz window (midnight-crossing)

    func testSameDayWindow() {
        XCTAssertTrue(HabitBuzz.windowOpen(now: 570, start: 540, end: 600))   // 9:30 in 9:00–10:00
        XCTAssertFalse(HabitBuzz.windowOpen(now: 480, start: 540, end: 600))  // before
        XCTAssertFalse(HabitBuzz.windowOpen(now: 660, start: 540, end: 600))  // after
    }

    func testMidnightCrossingWindow() {
        // Wind-down 23:00 (1380) → 00:30 (30).
        XCTAssertTrue(HabitBuzz.windowOpen(now: 1410, start: 1380, end: 30))  // 23:30 → open
        XCTAssertTrue(HabitBuzz.windowOpen(now: 15, start: 1380, end: 30))    // 00:15 → open
        XCTAssertFalse(HabitBuzz.windowOpen(now: 60, start: 1380, end: 30))   // 01:00 → closed
        XCTAssertFalse(HabitBuzz.windowOpen(now: 720, start: 1380, end: 30))  // noon → closed
    }

    func testMidnightCrossingWindowFiresViaDue() {
        let h = Habit(id: "wd", name: "Wind down", kind: .windDown, cadence: .daily,
                      buzz: HabitBuzzWindow(start: 1380, end: 30), createdAt: 0)
        XCTAssertEqual(HabitBuzz.due(now: 20, habits: [h], doneToday: [], buzzedToday: [])?.id, "wd")
    }
}
