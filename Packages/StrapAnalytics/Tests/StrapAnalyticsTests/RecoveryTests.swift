import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class RestingHRTests: XCTestCase {

    private func night(_ bpm: [Int], everyS: Int = 60) -> [HRSample] {
        bpm.enumerated().map { HRSample(ts: $0.offset * everyS, bpm: $0.element) }
    }

    func testASingleDropoutIsDilutedButNotEliminated() {
        // A raw minimum over samples would report the artefact itself — 3 bpm. Binning dilutes it
        // to its bin's mean instead.
        //
        // KNOWN LIMIT, pinned rather than papered over: at this sample rate a bin holds only five
        // readings, so one bad beat is 20% of it and still drags the resting rate down about
        // 10 bpm. Binning bounds the damage; it does not remove it. Rejecting a bin on internal
        // spread would, and is the obvious next improvement.
        var beats = [Int](repeating: 55, count: 480)
        beats[100] = 3
        let rhr = RecoveryScorer.restingHR(night(beats), start: 0, end: 480 * 60)!
        XCTAssertGreaterThan(rhr, 40, "far above the artefact itself")
        XCTAssertLessThan(rhr, 55, "but not fully rejected either")
    }

    func testADenseBinAbsorbsAnArtefactAlmostEntirely() {
        // The same artefact in a 1 Hz bin is one reading in three hundred.
        var beats = [Int](repeating: 55, count: 3600)
        beats[100] = 3
        let rhr = RecoveryScorer.restingHR(night(beats, everyS: 1), start: 0, end: 3600)!
        XCTAssertEqual(rhr, 55, "dilution scales with how well populated the bin is")
    }

    func testTheLowestWellPopulatedBinWins() {
        // 8 hours at 60, with one quiet half hour at 48.
        var beats = [Int](repeating: 60, count: 480)
        for i in 200..<230 { beats[i] = 48 }
        XCTAssertEqual(RecoveryScorer.restingHR(night(beats), start: 0, end: 480 * 60), 48)
    }

    func testASubPhysiologicalBinCannotWin() {
        var beats = [Int](repeating: 55, count: 480)
        for i in 100..<110 { beats[i] = 10 }         // a dropout stretch, not a heart rate
        let rhr = RecoveryScorer.restingHR(night(beats), start: 0, end: 480 * 60)!
        XCTAssertGreaterThanOrEqual(Double(rhr), RecoveryScorer.restingHRMinPlausibleBpm)
    }

    func testASparseNightFallsBackRatherThanReturningNothing() {
        // A rough resting rate beats a blank row.
        let sparse = night([58, 57, 59], everyS: 3600)
        XCTAssertNotNil(RecoveryScorer.restingHR(sparse, start: 0, end: 4 * 3600))
    }

    func testNoDataInTheWindow() {
        XCTAssertNil(RecoveryScorer.restingHR([], start: 0, end: 1000))
        XCTAssertNil(RecoveryScorer.restingHR(night([60, 60]), start: 100_000, end: 200_000))
    }
}

final class RecoveryScoreTests: XCTestCase {

    private let hrvB = RecoveryScorer.DriverBaseline(mean: 60, spread: 10)
    private let rhrB = RecoveryScorer.DriverBaseline(mean: 55, spread: 3)
    private let respB = RecoveryScorer.DriverBaseline(mean: 14, spread: 1)

    private func score(hrv: Double = 60, rhr: Double = 55, resp: Double? = 14,
                       sleepPerf: Double? = 0.85, skinTempDev: Double? = nil) -> Double? {
        RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: resp,
                                hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
                                sleepPerf: sleepPerf, skinTempDev: skinTempDev)
    }

    func testAnAverageDayLandsSlightlyAboveFifty() {
        // A scale where the typical morning reads as a failing grade is not one anyone can act on.
        let s = score()!
        XCTAssertGreaterThan(s, 50)
        XCTAssertLessThan(s, 65)
    }

    func testHigherHrvScoresBetterAndLowerScoresWorse() {
        XCTAssertGreaterThan(score(hrv: 90)!, score()!)
        XCTAssertLessThan(score(hrv: 35)!, score()!)
    }

    func testLowerRestingHeartRateScoresBetter() {
        // The RHR term is inverted; getting the sign wrong would reward a rising resting rate.
        XCTAssertGreaterThan(score(rhr: 48)!, score()!)
        XCTAssertLessThan(score(rhr: 65)!, score()!)
    }

    func testLowerRespiratoryRateScoresBetter() {
        XCTAssertGreaterThan(score(resp: 12)!, score()!)
        XCTAssertLessThan(score(resp: 18)!, score()!)
    }

    func testSkinTemperaturePenaltyIsSymmetric() {
        // Running cold is as much a signal as running hot; a signed term lets them cancel.
        let base = score()!
        let hot = score(skinTempDev: 1.5)!
        let cold = score(skinTempDev: -1.5)!
        XCTAssertLessThan(hot, base)
        XCTAssertLessThan(cold, base)
        XCTAssertEqual(hot, cold, accuracy: 1e-9)
    }

    func testScoreStaysInRangeAtExtremes() {
        for hrv in [0.1, 5.0, 60.0, 500.0] {
            for rhr in [20.0, 55.0, 200.0] {
                let s = RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: nil,
                                                hrvBaseline: hrvB, rhrBaseline: rhrB,
                                                respBaseline: nil, sleepPerf: nil)!
                XCTAssertGreaterThanOrEqual(s, 0)
                XCTAssertLessThanOrEqual(s, 100)
            }
        }
    }

    func testAMissingDriverIsNotTreatedAsAverage() {
        // Re-weighting over what is present; a missing respiratory rate must not read as a
        // perfectly average one.
        let withResp = score(resp: 14)!
        let withoutResp = score(resp: nil)!
        XCTAssertEqual(withResp, withoutResp, accuracy: 0.001,
                       "an exactly-average driver and an absent one agree here by construction")

        let poorResp = score(resp: 20)!
        XCTAssertNotEqual(poorResp, withoutResp, accuracy: 0.01,
                          "but a bad reading must move the score, and its absence must not")
    }

    func testNoUsableHrvBaselineRefusesToScore() {
        // HRV carries more than half the weight. A score built from the rest would look exactly
        // like a real one while measuring something else.
        XCTAssertNil(RecoveryScorer.recovery(hrv: 60, rhr: 55, resp: 14,
                                             hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
                                             sleepPerf: 0.85, hrvBaselineUsable: false))
    }

    func testNoDriversAtAll() {
        XCTAssertNil(RecoveryScorer.recovery(hrv: 60, rhr: 55, resp: nil,
                                             hrvBaseline: nil, rhrBaseline: nil, respBaseline: nil,
                                             sleepPerf: nil))
    }

    func testCalibratingBaselineRefusesThroughTheStateOverload() {
        let young = Baselines.update(nil, value: 60, cfg: Baselines.hrvCfg)
        XCTAssertFalse(young.usable)
        XCTAssertNil(RecoveryScorer.recovery(hrv: 60, rhr: 55, resp: nil,
                                             hrvBaseline: young, rhrBaseline: nil,
                                             respBaseline: nil, sleepPerf: nil))

        let settled = Baselines.foldHistory(Array(repeating: 60, count: 20), cfg: Baselines.hrvCfg)
        XCTAssertTrue(settled.usable)
        XCTAssertNotNil(RecoveryScorer.recovery(hrv: 60, rhr: 55, resp: nil,
                                                hrvBaseline: settled, rhrBaseline: nil,
                                                respBaseline: nil, sleepPerf: nil))
    }

    func testSleepPerformanceIsScoredAgainstAFixedTarget() {
        // Baselining it would quietly normalise a chronic shortfall into "fine".
        XCTAssertGreaterThan(score(sleepPerf: 1.0)!, score(sleepPerf: 0.6)!)
    }

    func testBands() {
        XCTAssertEqual(RecoveryScorer.band(10), "red")
        XCTAssertEqual(RecoveryScorer.band(33.9), "red")
        XCTAssertEqual(RecoveryScorer.band(34), "yellow")
        XCTAssertEqual(RecoveryScorer.band(66.9), "yellow")
        XCTAssertEqual(RecoveryScorer.band(67), "green")
        XCTAssertEqual(RecoveryScorer.band(100), "green")
    }

    func testWeightsSumToOne() {
        let total = RecoveryScorer.wHRV + RecoveryScorer.wRHR + RecoveryScorer.wResp
                  + RecoveryScorer.wSleep + RecoveryScorer.wSkinTemp
        XCTAssertEqual(total, 1.0, accuracy: 1e-12)
        XCTAssertGreaterThan(RecoveryScorer.wHRV, 0.5, "HRV dominates by design")
    }

    func testCalibrationNightsCountsDown() {
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: []), Baselines.minNightsSeed)
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: [60, 61]),
                       Baselines.minNightsSeed - 2)
        XCTAssertEqual(RecoveryScorer.calibrationNights(nightlyHrv: Array(repeating: 60, count: 30)), 0)
    }
}
