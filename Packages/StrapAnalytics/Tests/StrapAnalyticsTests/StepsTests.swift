import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class StepsEstimateTests: XCTestCase {

    private func points(_ pairs: [(Double, Double)]) -> [StepsEstimateEngine.CalibrationPoint] {
        pairs.map { .init(motion: $0.0, steps: $0.1) }
    }

    func testAConsistentRelationshipFitsItsCoefficient() throws {
        let cal = try XCTUnwrap(StepsEstimateEngine.calibrate(
            points([(100, 500), (200, 1000), (150, 750), (300, 1500)])))
        XCTAssertEqual(cal.coefficient, 5.0, accuracy: 1e-9)
        XCTAssertFalse(cal.manual)
    }

    func testOneMisSyncedDayDoesNotDragTheCoefficient() throws {
        // A step count from a phone left on a desk would otherwise skew every later day.
        let clean = points([(100, 500), (200, 1000), (150, 750), (300, 1500), (120, 600)])
        let withBadDay = clean + points([(100, 20_000)])
        let a = try XCTUnwrap(StepsEstimateEngine.calibrate(clean))
        let b = try XCTUnwrap(StepsEstimateEngine.calibrate(withBadDay))
        XCTAssertEqual(a.coefficient, b.coefficient, accuracy: 0.01, "the median ignores the outlier")
    }

    func testABusyDayCarriesMoreWeightThanAStillOne() throws {
        // A busy day carries more evidence about the relationship than a mostly-still one.
        let pts = points([(10, 100), (10, 100), (10, 100), (1000, 3000), (1000, 3000), (1000, 3000)])
        let cal = try XCTUnwrap(StepsEstimateEngine.calibrate(pts))
        XCTAssertEqual(cal.coefficient, 3.0, accuracy: 0.01, "the high-motion days decide it")
    }

    func testTooFewUsableDaysHasNoFit() {
        XCTAssertNil(StepsEstimateEngine.calibrate(points([(100, 500), (200, 1000)])))
        XCTAssertNil(StepsEstimateEngine.calibrate([]))
    }

    func testDaysBelowTheMotionFloorAreNotUsable() {
        // A ratio from a barely-worn day is noise divided by noise.
        let pts = points([(0.1, 500), (0.2, 1000), (0.3, 750), (100, 500)])
        XCTAssertNil(StepsEstimateEngine.calibrate(pts))
    }

    func testDaysWithNoStepsAreNotUsable() {
        XCTAssertNil(StepsEstimateEngine.calibrate(points([(100, 0), (200, 0), (150, 0)])))
    }

    func testConfidenceGrowsWithDaysAndAgreement() throws {
        let few = try XCTUnwrap(StepsEstimateEngine.calibrate(
            points([(100, 500), (200, 1000), (150, 750)])))
        let many = try XCTUnwrap(StepsEstimateEngine.calibrate(
            (0..<20).map { .init(motion: Double(100 + $0), steps: Double(100 + $0) * 5) }))
        XCTAssertGreaterThan(many.confidence, few.confidence)

        let scattered = try XCTUnwrap(StepsEstimateEngine.calibrate(
            (0..<20).map { i in .init(motion: 100, steps: Double(100 + i * 60)) }))
        XCTAssertLessThan(scattered.confidence, many.confidence, "a noisy fit is honestly less trusted")
    }

    func testConfidenceStaysAProbability() throws {
        let cal = try XCTUnwrap(StepsEstimateEngine.calibrate(
            (0..<50).map { .init(motion: Double(100 + $0), steps: Double(100 + $0) * 5) }))
        XCTAssertGreaterThanOrEqual(cal.confidence, 0)
        XCTAssertLessThanOrEqual(cal.confidence, 1)
    }

    func testConfidenceTiers() {
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.1), .low)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.5), .medium)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.from(0.9), .high)
        XCTAssertEqual(StepsEstimateEngine.ConfidenceTier.high.word, "high confidence")
    }

    func testAManualCoefficientWins() throws {
        let cal = try XCTUnwrap(StepsEstimateEngine.calibrate(
            points([(100, 500), (200, 1000), (150, 750)]), manualOverride: 9))
        XCTAssertEqual(cal.coefficient, 9)
        XCTAssertTrue(cal.manual)
        XCTAssertEqual(cal.confidence, 1.0)
    }

    func testStatusExplainsWhatItIsWaitingFor() {
        // "2 of 3" is the difference between an app that looks broken and one that is waiting.
        guard case .needsMoreDays(let have, let need) =
                StepsEstimateEngine.status(points([(100, 500), (200, 1000)])) else {
            return XCTFail("expected needsMoreDays")
        }
        XCTAssertEqual(have, 2)
        XCTAssertEqual(need, StepsEstimateEngine.minCalibrationDays)
    }

    func testStatusReportsACalibratedFit() {
        guard case .calibrated(let k, let days, _) =
                StepsEstimateEngine.status(points([(100, 500), (200, 1000), (150, 750)])) else {
            return XCTFail("expected calibrated")
        }
        XCTAssertEqual(k, 5.0, accuracy: 1e-9)
        XCTAssertEqual(days, 3)
    }

    func testStatusReportsAManualOverride() {
        guard case .manual(let k, _) = StepsEstimateEngine.status([], manualOverride: 7) else {
            return XCTFail("expected manual")
        }
        XCTAssertEqual(k, 7)
    }

    func testEstimateAppliesTheCoefficient() {
        let cal = StepsEstimateEngine.Calibration(coefficient: 5, sampleDays: 10,
                                                  confidence: 0.8, manual: false)
        XCTAssertEqual(StepsEstimateEngine.estimate(motion: 1000, calibration: cal), 5000)
    }

    func testABarelyWornDayHasNoEstimateRatherThanZero() {
        // No step count is different from a day of zero steps.
        let cal = StepsEstimateEngine.Calibration(coefficient: 5, sampleDays: 10,
                                                  confidence: 0.8, manual: false)
        XCTAssertNil(StepsEstimateEngine.estimate(motion: 0.5, calibration: cal))
    }

    func testEstimateIsCapped() {
        // Beyond the cap the coefficient is wrong, not the person extraordinary.
        let cal = StepsEstimateEngine.Calibration(coefficient: 5000, sampleDays: 10,
                                                  confidence: 0.8, manual: false)
        XCTAssertEqual(StepsEstimateEngine.estimate(motion: 1000, calibration: cal),
                       StepsEstimateEngine.maxDailySteps)
    }

    func testDayMotionIntensityAccumulatesOrientationChange() {
        let still = (0..<100).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertEqual(StepsEstimateEngine.dayMotionIntensity(still), 0, accuracy: 1e-9)

        let moving = (0..<100).map { GravitySample(ts: $0, x: Double($0 % 2), y: 0, z: 1) }
        XCTAssertGreaterThan(StepsEstimateEngine.dayMotionIntensity(moving), 0)
        XCTAssertEqual(StepsEstimateEngine.dayMotionIntensity([]), 0)
    }

    func testWeightedMedianBasics() {
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 2, 3], weights: [1, 1, 1]), 2)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 2, 3], weights: [1, 100, 1]), 2)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 5], weights: [0, 1]), 5)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([], weights: []), 0)
        XCTAssertEqual(StepsEstimateEngine.weightedMedian([1, 2, 3], weights: [0, 0, 0]), 2,
                       "zero total weight falls back to the plain median")
    }
}
