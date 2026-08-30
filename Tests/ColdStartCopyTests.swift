import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// Surfaces that described a fresh install's absent history as if it were a record.
final class ColdStartCopyTests: XCTestCase {

    /// A workout logged before any night was scored ran against the 60 bpm default resting HR, and the
    /// ordinary "never lower a stored value" rule then froze it there forever. Those rows are
    /// identifiable, so they can be corrected once a real resting HR exists.
    func testWorkoutsBeforeTheFirstMeasuredRestingHRAreIdentifiable() {
        let off = 0
        let day2 = "2026-07-30"
        // A bout on 2026-07-29, before the first measured night on the 30th.
        let earlier = GapScan.localDayStart("2026-07-29", offsetSec: off)! + 12 * 3_600
        XCTAssertTrue(ScoreEngine.predatesMeasuredRestingHR(startTs: earlier,
                                                            firstMeasuredDay: day2, offsetSec: off))

        // A bout on the 30th itself is NOT before it — that day has the measurement.
        let sameDay = GapScan.localDayStart(day2, offsetSec: off)! + 12 * 3_600
        XCTAssertFalse(ScoreEngine.predatesMeasuredRestingHR(startTs: sameDay,
                                                             firstMeasuredDay: day2, offsetSec: off))
    }

    /// With no measured resting HR anywhere yet, every manual row qualifies — they were all scored
    /// against the default.
    func testWithNoMeasuredNightEveryWorkoutQualifies() {
        let ts = GapScan.localDayStart("2026-07-29", offsetSec: 0)! + 12 * 3_600
        XCTAssertTrue(ScoreEngine.predatesMeasuredRestingHR(startTs: ts, firstMeasuredDay: nil,
                                                            offsetSec: 0))
    }

    /// `improves` must still refuse to lower a stored value on the ORDINARY path — the rewrite is only
    /// unlocked for rows scored before a real resting HR existed.
    func testStrainRewriteIsOptIn() {
        let lower = ManualWorkoutRescore.Scored(avgHr: 120, maxHr: 150, strain: 10, kcal: 100)

        XCTAssertFalse(ManualWorkoutRescore.improves(lower, over: 500, currentStrain: 40),
                       "the ordinary contract never lowers a stored value")
        XCTAssertTrue(ManualWorkoutRescore.improves(lower, over: 500, currentStrain: 40,
                                                    allowStrainRewrite: true),
                      "a row scored against a stranger's resting HR is correctable")
        XCTAssertFalse(ManualWorkoutRescore.improves(lower, over: 500, currentStrain: 10,
                                                     allowStrainRewrite: true),
                       "an unchanged strain is not an improvement")
    }
}
