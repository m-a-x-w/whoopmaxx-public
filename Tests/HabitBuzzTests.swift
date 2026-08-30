import XCTest
@testable import whoopmaxx

/// Pins the pure windowed wrist-buzz scheduler (008): a buzz fires only inside an open window, once
/// per habit, never for an already-done habit, and the tightest window wins on overlap.
final class HabitBuzzTests: XCTestCase {

    private func habit(_ id: String, start: Int, end: Int) -> Habit {
        Habit(id: id, name: id, kind: .manual, cadence: .daily,
              buzz: HabitBuzzWindow(start: start, end: end), createdAt: 0)
    }

    func testFiresInsideWindow() {
        let h = habit("a", start: 540, end: 600)   // 9:00–10:00
        XCTAssertEqual(HabitBuzz.due(now: 570, habits: [h], doneToday: [], buzzedToday: [])?.id, "a")
        XCTAssertNil(HabitBuzz.due(now: 480, habits: [h], doneToday: [], buzzedToday: []))   // before
        XCTAssertNil(HabitBuzz.due(now: 660, habits: [h], doneToday: [], buzzedToday: []))   // after
    }

    func testSkipsDoneAndAlreadyBuzzed() {
        let h = habit("a", start: 540, end: 600)
        XCTAssertNil(HabitBuzz.due(now: 570, habits: [h], doneToday: ["a"], buzzedToday: []))
        XCTAssertNil(HabitBuzz.due(now: 570, habits: [h], doneToday: [], buzzedToday: ["a"]))
    }

    func testTightestWindowWinsOnOverlap() {
        let wide = habit("wide", start: 500, end: 800)
        let tight = habit("tight", start: 560, end: 580)
        let pick = HabitBuzz.due(now: 570, habits: [wide, tight], doneToday: [], buzzedToday: [])
        XCTAssertEqual(pick?.id, "tight")   // earliest end
    }

    func testNoBuzzWindowNeverFires() {
        let plain = Habit(id: "p", name: "p", kind: .manual, cadence: .daily, createdAt: 0)
        XCTAssertNil(HabitBuzz.due(now: 570, habits: [plain], doneToday: [], buzzedToday: []))
    }
}
