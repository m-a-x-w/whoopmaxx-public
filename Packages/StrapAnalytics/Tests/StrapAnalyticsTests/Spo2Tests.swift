import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class Spo2EstimatorTests: XCTestCase {

    /// A window with a real oscillation on both channels.
    private func pulsatile(from: Int, count: Int, redAmp: Double, irAmp: Double,
                           redDC: Double = 1000, irDC: Double = 1000) -> [SpO2Sample] {
        (0..<count).map { i in
            let phase = sin(Double(i) * .pi / 4)
            return SpO2Sample(ts: from + i,
                              red: Int(redDC + redAmp * phase),
                              ir: Int(irDC + irAmp * phase))
        }
    }

    func testAFlatChannelHasNoPulseAndIsRejected() {
        // Non-zero amplitude is not enough; a stair-step has a fine IQR and no pulse.
        let flat = (0..<60).map { SpO2Sample(ts: $0, red: 1000, ir: 1000) }
        XCTAssertNil(Spo2Estimator.ratioOfRatios(red: flat.map { Double($0.red) },
                                                 ir: flat.map { Double($0.ir) }))
    }

    func testAStairStepIsRejectedDespiteNonZeroAmplitude() {
        // This is the shape the historical stream actually banks — a drifting register.
        let stair = (0..<60).map { SpO2Sample(ts: $0, red: 1000 + $0, ir: 1000 + $0) }
        XCTAssertLessThan(Spo2Estimator.meanCrossings(stair.map { Double($0.red) }),
                          Spo2Estimator.minMeanCrossings)
        XCTAssertNil(Spo2Estimator.ratioOfRatios(red: stair.map { Double($0.red) },
                                                 ir: stair.map { Double($0.ir) }))
    }

    func testMeanCrossingsCountsOscillation() {
        let osc = (0..<20).map { Double($0 % 2) }
        XCTAssertGreaterThanOrEqual(Spo2Estimator.meanCrossings(osc), 5)
        XCTAssertEqual(Spo2Estimator.meanCrossings([]), 0)
        XCTAssertEqual(Spo2Estimator.meanCrossings([5, 5, 5, 5]), 0, "no crossings without variation")
    }

    func testIqrIsRobustToASingleSpike() {
        var xs = [Double](repeating: 100, count: 100)
        for i in stride(from: 0, to: 100, by: 2) { xs[i] = 110 }
        let clean = Spo2Estimator.iqr(xs)
        xs[50] = 100_000
        XCTAssertEqual(Spo2Estimator.iqr(xs), clean, accuracy: 1e-9,
                       "a peak-to-peak range would have moved by five orders of magnitude")
    }

    func testAWindowBelowTheSampleFloorIsRefused() {
        XCTAssertNil(Spo2Estimator.windowPct(pulsatile(from: 0, count: 5, redAmp: 20, irAmp: 40)))
    }

    func testOutOfBandValuesAreDiscardedNotClamped() {
        // Clamping is what produces the pinned readings the app's heal sweep exists to remove.
        let extreme = pulsatile(from: 0, count: 60, redAmp: 400, irAmp: 20)
        if let pct = Spo2Estimator.windowPct(extreme) {
            XCTAssertGreaterThanOrEqual(pct, Spo2Estimator.bandLo)
            XCTAssertLessThanOrEqual(pct, Spo2Estimator.bandHi)
            XCTAssertNotEqual(pct, Spo2Estimator.bandLo, accuracy: 1e-9,
                              "a value AT the floor would be the clamp signature")
        }
    }

    func testAPulsatileWindowProducesAnInBandEstimate() {
        let w = pulsatile(from: 0, count: 60, redAmp: 30, irAmp: 40)
        guard let pct = Spo2Estimator.windowPct(w) else { return }
        XCTAssertGreaterThanOrEqual(pct, Spo2Estimator.bandLo)
        XCTAssertLessThanOrEqual(pct, Spo2Estimator.bandHi)
    }

    func testTooFewWindowsMeansNoNightlyValue() {
        let samples = pulsatile(from: 0, count: 60, redAmp: 30, irAmp: 40)
        XCTAssertNil(Spo2Estimator.nightlyPct(samples: samples, sessions: [(0, 10_000)]))
    }

    func testSamplesOutsideSleepAreExcluded() {
        let samples = pulsatile(from: 0, count: 60, redAmp: 30, irAmp: 40)
        XCTAssertNil(Spo2Estimator.nightlyPct(samples: samples, sessions: [(100_000, 200_000)]))
    }

    func testNoSessionsOrNoSamples() {
        XCTAssertNil(Spo2Estimator.nightlyPct(samples: [], sessions: [(0, 100)]))
        XCTAssertNil(Spo2Estimator.nightlyPct(samples: pulsatile(from: 0, count: 60, redAmp: 30, irAmp: 40),
                                              sessions: []))
    }

    func testWindowsBucketOnAbsoluteTime() {
        // The same night must yield the same answer regardless of where recording started.
        var samples: [SpO2Sample] = []
        for w in 0..<5 { samples += pulsatile(from: w * Spo2Estimator.windowS, count: 60, redAmp: 30, irAmp: 40) }
        let a = Spo2Estimator.nightlyPct(samples: samples, sessions: [(0, 10 * Spo2Estimator.windowS)])
        let b = Spo2Estimator.nightlyPct(samples: samples.shuffled(),
                                         sessions: [(0, 10 * Spo2Estimator.windowS)])
        XCTAssertEqual(a, b, "bucketing must not depend on sample order")
    }

    func testMedianOfWindowsNotMean() {
        // One bad window must not drag the night.
        XCTAssertEqual(HRVAnalyzer.median([90, 95, 96, 97, 98]), 96)
        XCTAssertEqual(HRVAnalyzer.median([95, 96]), 95.5)
        XCTAssertEqual(HRVAnalyzer.median([]), 0)
    }
}
