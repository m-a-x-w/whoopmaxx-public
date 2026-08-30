import XCTest
@testable import whoopmaxx

/// `TodayModel.minBaselineSamples` exists so ONE prior night is never called a 30-day "typical" — the
/// floor that made Today agree with the Data tab. It was applied inside `priorMean`/`priorRestMean` only,
/// so three read-side surfaces that assembled their own window and called bare `mean` kept fabricating a
/// typical on day 2: the Today Signals deltas, the Charge detail caption, and the Rest hero verdict.
/// `typicalMean` is the shared floored spelling all three now go through.
final class TypicalBaselineFloorTests: XCTestCase {

    func testTypicalMeanReturnsNilBelowTheFloor() {
        XCTAssertNil(TodayModel.typicalMean([]))
        XCTAssertNil(TodayModel.typicalMean([50]), "one prior night is not a typical")
        XCTAssertNil(TodayModel.typicalMean([50, 60]))
    }

    func testTypicalMeanComputesAtAndAboveTheFloor() {
        XCTAssertEqual(TodayModel.typicalMean([50, 60, 70]) ?? 0, 60, accuracy: 0.0001)
        XCTAssertEqual(TodayModel.typicalMean([10, 20, 30, 40]) ?? 0, 25, accuracy: 0.0001)
    }

    /// The floor value itself is load-bearing: it must match what the Data tab requires, or the two
    /// surfaces contradict each other about the same day again.
    func testFloorMatchesTheDataTabRequirement() {
        XCTAssertEqual(TodayModel.minBaselineSamples, 3)
    }

    /// `typicalMean` must agree with `priorMean`, which already floors internally — same population,
    /// same answer, so routing a surface through either spelling is equivalent.
    func testTypicalMeanAgreesWithPriorMean() {
        let days = (1...5).map { Fixtures.dailyMetric(day: String(format: "2026-08-%02d", $0),
                                                      restingHr: 50 + $0) }
        let viaPrior = TodayModel.priorMean(days: days, before: "2026-08-05") {
            $0.restingHr.map(Double.init)
        }
        let viaTypical = TodayModel.typicalMean(days.filter { $0.day < "2026-08-05" }
            .compactMap { $0.restingHr.map(Double.init) })

        XCTAssertNotNil(viaPrior)
        XCTAssertEqual(viaPrior ?? 0, viaTypical ?? -1, accuracy: 0.0001)
    }

    /// Two prior days must be nil through BOTH spellings — this is the fresh-install / post-restore case
    /// where Today used to print a coloured delta while the trio above it drew no tick at all.
    func testTwoPriorDaysYieldNoTypicalEitherWay() {
        let days = (1...3).map { Fixtures.dailyMetric(day: String(format: "2026-08-%02d", $0),
                                                      restingHr: 50 + $0) }
        let viaPrior = TodayModel.priorMean(days: days, before: "2026-08-03") {
            $0.restingHr.map(Double.init)
        }
        let viaTypical = TodayModel.typicalMean(days.filter { $0.day < "2026-08-03" }
            .compactMap { $0.restingHr.map(Double.init) })

        XCTAssertNil(viaPrior)
        XCTAssertNil(viaTypical)
    }
}
