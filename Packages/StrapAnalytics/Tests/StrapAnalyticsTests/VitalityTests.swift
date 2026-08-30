import XCTest
@testable import StrapAnalytics

final class VitalityEngineTests: XCTestCase {

    private func inputs(age: Double = 40, rhr: Double? = 55, sleep: Double? = 7.5,
                        consistency: Double? = 0.9, rmssd: Double? = 40,
                        steps: Double? = 9000) -> VitalityEngine.Inputs {
        VitalityEngine.Inputs(chronoAge: age, restingHR: rhr, sleepHours: sleep,
                              sleepConsistency: consistency, rmssd: rmssd,
                              rmssdNorm: VitalityEngine.rmssdNorm(forAge: age), steps: steps)
    }

    func testGoodHabitsReadYoungerAndBadOnesOlder() throws {
        let good = try XCTUnwrap(VitalityEngine.compute(inputs()))
        let bad = try XCTUnwrap(VitalityEngine.compute(
            inputs(rhr: 85, sleep: 5, consistency: 0.3, rmssd: 15, steps: 2000)))
        XCTAssertLessThan(good.bodyAge, bad.bodyAge)
        XCTAssertGreaterThan(good.vitality, bad.vitality)
    }

    func testFewerThanThreeFactorsSaysNothing() {
        // A body age from one habit is an opinion about that habit dressed as a measurement of
        // a person.
        XCTAssertNil(VitalityEngine.compute(
            VitalityEngine.Inputs(chronoAge: 40, restingHR: 55)))
        XCTAssertNil(VitalityEngine.compute(
            VitalityEngine.Inputs(chronoAge: 40, restingHR: 55, sleepHours: 7.5)))
        XCTAssertNotNil(VitalityEngine.compute(
            VitalityEngine.Inputs(chronoAge: 40, restingHR: 55, sleepHours: 7.5, steps: 9000)))
    }

    func testAnAbsentFactorContributesNothingNotAverage() {
        // A missing factor must not quietly pull the result toward the middle.
        let keys = VitalityEngine.contributions(inputs(steps: nil)).map(\.key)
        XCTAssertFalse(keys.contains("steps"))
    }

    func testAnUnknownAgeIsRefused() {
        XCTAssertNil(VitalityEngine.compute(inputs(age: 0)))
    }

    func testTheBandIsAlwaysCarried() {
        // A body age quoted to the year would claim a precision this method does not have.
        let r = VitalityEngine.compute(inputs())!
        XCTAssertEqual(r.bandYears, VitalityEngine.bandYears)
        XCTAssertGreaterThan(r.bandYears, 0)
    }

    func testBodyAgeIsClamped() {
        let absurd = VitalityEngine.compute(
            inputs(age: 25, rhr: 200, sleep: 2, consistency: 0, rmssd: 1, steps: 0))!
        XCTAssertLessThanOrEqual(absurd.bodyAge, 90)
        let saintly = VitalityEngine.compute(
            inputs(age: 25, rhr: 35, sleep: 7.5, consistency: 1, rmssd: 120, steps: 11_000))!
        XCTAssertGreaterThanOrEqual(saintly.bodyAge, 20)
    }

    func testVitalityStaysAScore() {
        for age in [20.0, 45, 80] {
            for rhr in [35.0, 65, 110] {
                let r = VitalityEngine.compute(inputs(age: age, rhr: rhr))!
                XCTAssertGreaterThanOrEqual(r.vitality, 0)
                XCTAssertLessThanOrEqual(r.vitality, 100)
            }
        }
    }

    func testSleepRiskIsSymmetricAroundTheOptimum() {
        // Both too little and too much sleep carry risk; a signed term would let one cancel the
        // other.
        func sleepHazard(_ h: Double) -> Double {
            VitalityEngine.contributions(inputs(sleep: h)).first { $0.key == "sleep" }!.lnHazard
        }
        XCTAssertEqual(sleepHazard(5.5), sleepHazard(9.5), accuracy: 1e-9)
        XCTAssertEqual(sleepHazard(7.5), 0, accuracy: 1e-9, "the optimum is neutral")
        XCTAssertEqual(sleepHazard(7.9), 0, accuracy: 1e-9, "and so is the half-hour either side")
    }

    func testStepProtectionCapsOut() {
        // Uncapped, a very high step count would offset everything else.
        func stepHazard(_ s: Double) -> Double {
            VitalityEngine.contributions(inputs(steps: s)).first { $0.key == "steps" }!.lnHazard
        }
        XCTAssertEqual(stepHazard(11_000), stepHazard(40_000), accuracy: 1e-9)
        XCTAssertGreaterThan(stepHazard(2_000), stepHazard(9_000))
    }

    func testHrvIsJudgedAgainstAnAgeNorm() {
        // Judging a 60-year-old against a 25-year-old's normal would report every older user as
        // ageing badly.
        XCTAssertGreaterThan(VitalityEngine.rmssdNorm(forAge: 25),
                             VitalityEngine.rmssdNorm(forAge: 60))
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 10),
                       VitalityEngine.rmssdNorm(forAge: 20), "clamped below the first anchor")
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 99),
                       VitalityEngine.rmssdNorm(forAge: 80), "and above the last")
        XCTAssertEqual(VitalityEngine.rmssdNorm(forAge: 35), 36.5, accuracy: 0.01, "interpolated")
    }

    func testTheOverlapShrinkIsApplied() {
        // Fitness, resting HR and HRV are three views of one cardiovascular state; adding their
        // hazards as if independent double-counts.
        XCTAssertLessThan(VitalityEngine.overlapShrink, 1.0)
        let r = VitalityEngine.compute(inputs(rhr: 85))!
        let rawSum = VitalityEngine.contributions(inputs(rhr: 85)).reduce(0) { $0 + $1.lnHazard }
        let unshrunkAge = 40 + rawSum / VitalityEngine.lnHazardPerYear
        XCTAssertLessThan(abs(r.bodyAge - 40), abs(unshrunkAge - 40))
    }

    func testSleepConsistencyIsRelative() {
        // An hour of swing means something different for a five-hour sleeper than a nine-hour one.
        let steady = VitalityEngine.sleepConsistency(nightlyHours: [7.5, 7.5, 7.5, 7.5])!
        let erratic = VitalityEngine.sleepConsistency(nightlyHours: [4, 10, 5, 9])!
        XCTAssertGreaterThan(steady, erratic)
        XCTAssertEqual(steady, 1.0, accuracy: 1e-9)
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [7, 8]))
        XCTAssertNil(VitalityEngine.sleepConsistency(nightlyHours: [0, 0, 0]))
    }

    func testContributionsAreLabelled() {
        for c in VitalityEngine.contributions(inputs()) {
            XCTAssertFalse(c.label.isEmpty)
            XCTAssertFalse(c.key.isEmpty)
        }
    }
}

final class DoseResponsePriorTests: XCTestCase {

    func testDefaultOutcomes() {
        XCTAssertEqual(DoseResponsePriors.defaultOutcome(for: .alcohol), "Charge")
        XCTAssertEqual(DoseResponsePriors.defaultOutcome(for: .caffeine), "HRV")
    }

    func testEveryPriorPointsTheRightWay() {
        for b in [DosedBehavior.alcohol, .caffeine] {
            let p = DoseResponsePriors.prior(for: b)!
            XCTAssertLessThan(p.slopePerUnit, 0, "more of either is expected to hurt")
            XCTAssertLessThan(p.clampLow, p.clampHigh)
        }
    }

    func testAnUndocumentedPairHasNoPrior() {
        // The engine then cannot shrink, so a thin personal fit is reported unshrunk rather than
        // pulled toward a number nobody published.
        XCTAssertNil(DoseResponsePriors.prior(for: .alcohol, outcome: "Steps"))
    }
}
