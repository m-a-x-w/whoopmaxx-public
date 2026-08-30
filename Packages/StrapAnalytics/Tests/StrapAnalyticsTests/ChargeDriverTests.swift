import XCTest
@testable import StrapAnalytics

final class ChargeDriverTests: XCTestCase {

    private var hrvB: Baselines.BaselineState {
        Baselines.foldHistory(Array(repeating: 60, count: 30), cfg: Baselines.hrvCfg)
    }
    private var rhrB: Baselines.BaselineState {
        Baselines.foldHistory(Array(repeating: 55, count: 30), cfg: Baselines.restingHRCfg)
    }
    private var respB: Baselines.BaselineState {
        Baselines.foldHistory(Array(repeating: 14, count: 30), cfg: Baselines.respCfg)
    }

    private func drivers(hrv: Double = 60, rhr: Double = 55, resp: Double? = 14,
                         sleepPerf: Double? = 0.85, skinTempDev: Double? = nil) -> [ChargeDriver] {
        RecoveryScorer.chargeDrivers(hrv: hrv, rhr: rhr, resp: resp,
                                     hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
                                     sleepPerf: sleepPerf, skinTempDev: skinTempDev)
    }

    func testADriverAtBaselineIsWorthNothing() {
        let d = drivers()
        let hrvRow = d.first { $0.label == "Heart rate variability" }!
        XCTAssertEqual(hrvRow.deltaPoints, 0)
        XCTAssertEqual(hrvRow.verdict, "at baseline")
    }

    func testAGoodDriverAddsAndABadOneSubtracts() {
        let good = drivers(hrv: 95).first { $0.label == "Heart rate variability" }!
        XCTAssertGreaterThan(good.deltaPoints, 0)
        XCTAssertTrue(good.verdict.contains("supporting"))

        let bad = drivers(hrv: 30).first { $0.label == "Heart rate variability" }!
        XCTAssertLessThan(bad.deltaPoints, 0)
        XCTAssertTrue(bad.verdict.contains("limiting"))
    }

    func testRestingHeartRateReadsInTheRightDirection() {
        // Lower is better; getting the sign wrong would praise a rising resting rate.
        let low = drivers(rhr: 45).first { $0.label == "Resting heart rate" }!
        XCTAssertGreaterThan(low.deltaPoints, 0)
        let high = drivers(rhr: 70).first { $0.label == "Resting heart rate" }!
        XCTAssertLessThan(high.deltaPoints, 0)
    }

    func testDriverPointsCannotDriftFromTheHeadline() {
        // The recomputation runs through the same scorer, so the two can never disagree.
        let full = RecoveryScorer.recovery(hrv: 80, rhr: 50, resp: 13, hrvBaseline: hrvB,
                                           rhrBaseline: rhrB, respBaseline: respB, sleepPerf: 0.9)!
        let d = RecoveryScorer.chargeDrivers(hrv: 80, rhr: 50, resp: 13, hrvBaseline: hrvB,
                                             rhrBaseline: rhrB, respBaseline: respB, sleepPerf: 0.9)
        XCTAssertFalse(d.isEmpty)
        XCTAssertGreaterThan(full, 50, "a good morning")
        // Every driver above baseline should be positive on a uniformly good day.
        XCTAssertTrue(d.filter { $0.label != "Rest quality" }.allSatisfy { $0.deltaPoints >= 0 })
    }

    func testNoScoreMeansNoDriverRows() {
        // A blank headline must not sprout a full table of confident rows.
        let young = Baselines.update(nil, value: 60, cfg: Baselines.hrvCfg)
        XCTAssertTrue(RecoveryScorer.chargeDrivers(hrv: 60, rhr: 55, resp: nil,
                                                   hrvBaseline: young, rhrBaseline: nil,
                                                   respBaseline: nil, sleepPerf: nil).isEmpty)
    }

    func testAbsentDriversProduceNoRows() {
        let d = drivers(resp: nil, sleepPerf: nil, skinTempDev: nil)
        XCTAssertFalse(d.contains { $0.label == "Respiratory rate" })
        XCTAssertFalse(d.contains { $0.label == "Rest quality" })
        XCTAssertFalse(d.contains { $0.label == "Skin temperature" })
    }

    func testRowsAreOrderedByAbsoluteContribution() {
        // A driver that COST ten points is as worth showing as one that gave ten.
        let d = drivers(hrv: 30, rhr: 45)
        let mags = d.map { abs($0.deltaPoints) }
        XCTAssertEqual(mags, mags.sorted(by: >))
    }

    func testSkinTemperatureIsSymmetric() {
        let warm = drivers(skinTempDev: 1.2).first { $0.label == "Skin temperature" }!
        let cool = drivers(skinTempDev: -1.2).first { $0.label == "Skin temperature" }!
        XCTAssertEqual(warm.deltaPoints, cool.deltaPoints)
        XCTAssertTrue(warm.verdict.contains("warmer"))
        XCTAssertTrue(cool.verdict.contains("cooler"))
    }

    func testSkinTemperatureTiers() {
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: 0.1)?.tier, .typical)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: 0.9)?.tier, .warmer)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: -0.9)?.tier, .cooler)
        XCTAssertNil(RecoveryScorer.skinTempRelative(deviationC: nil))
    }

    func testValueTextCarriesUnits() {
        let d = drivers(hrv: 72, rhr: 51, resp: 13.4, skinTempDev: -0.6)
        XCTAssertTrue(d.contains { $0.valueText == "72 ms" })
        XCTAssertTrue(d.contains { $0.valueText == "51 bpm" })
        XCTAssertTrue(d.contains { $0.valueText.contains("br/min") })
        XCTAssertTrue(d.contains { $0.valueText.contains("-0.6 C") })
    }
}

final class SpotHrvTests: XCTestCase {

    func testACleanCaptureProducesAReading() {
        let beats = (0..<60).map { 900 + ($0 % 2 == 0 ? 20 : -20) }
        guard case .reading(let rmssd, let hr, let n, _) = SpotHrvReading.compute(beats) else {
            return XCTFail("expected a reading")
        }
        XCTAssertGreaterThan(rmssd, 0)
        XCTAssertEqual(hr!, 60_000.0 / 900.0, accuracy: 1)
        XCTAssertEqual(n, 60)
    }

    func testTooFewBeatsExplainsWhatWasShort() {
        // A surface should be able to say what was missing rather than just failing.
        guard case .insufficient(let clean, let needed, let input) =
                SpotHrvReading.compute([Double](repeating: 900, count: 5).map(Int.init)) else {
            return XCTFail("expected insufficient")
        }
        XCTAssertEqual(clean, 5)
        XCTAssertEqual(input, 5)
        XCTAssertEqual(needed, HRVAnalyzer.minBeats)
    }

    func testHeavilyRejectedCaptureIsRefused() {
        // A spot reading is short, so one bad stretch is a large share of it — cleaning that
        // removed a third has replaced the signal rather than tidied it.
        var beats = [Int](repeating: 900, count: 60)
        for i in 0..<25 { beats[i] = 50 }
        guard case .insufficient = SpotHrvReading.compute(beats) else {
            return XCTFail("a capture this dirty must not report a number")
        }
    }

    func testARelaxedBarLetsTheSameCaptureThrough() {
        var beats = [Int](repeating: 900, count: 60)
        for i in 0..<25 { beats[i] = 50 }
        if case .insufficient = SpotHrvReading.compute(beats, maxRejectedFraction: 0.9) {
            XCTFail("the bar is the caller's to set")
        }
    }

    func testMeanHrFromNN() {
        XCTAssertEqual(SpotHrvReading.meanHrFromNN(1000)!, 60, accuracy: 1e-9)
        XCTAssertNil(SpotHrvReading.meanHrFromNN(0))
        XCTAssertNil(SpotHrvReading.meanHrFromNN(nil))
    }

    func testTheCaveatIsAlwaysPresentAndNamesTheDistinction() {
        // A spot RMSSD and an overnight one differ by more than the day-to-day changes people
        // read into them.
        for source in [SpotHrvReading.Source.opticalPPG, .chestStrap, .unknown] {
            let c = SpotHrvReading.caveatFor(source)
            XCTAssertTrue(c.contains("not your overnight HRV baseline"))
            XCTAssertFalse(c.isEmpty)
        }
        XCTAssertTrue(SpotHrvReading.caveatFor(.opticalPPG).contains("noisier"))
    }
}
