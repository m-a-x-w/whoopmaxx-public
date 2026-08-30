import XCTest
@testable import StrapAnalytics

final class HRVFormulaTests: XCTestCase {

    func testRmssdAgainstAHandComputedCase() {
        // differences 100, 100 → RMSSD = 100
        XCTAssertEqual(HRVAnalyzer.rmssdRaw([800, 900, 1000])!, 100, accuracy: 1e-9)
        // differences +100, -100 → still 100; RMSSD is direction-blind by construction
        XCTAssertEqual(HRVAnalyzer.rmssdRaw([800, 900, 800])!, 100, accuracy: 1e-9)
    }

    func testSdnnUsesTheSampleDeviation() {
        // These beats are a sample of the night, not the population, so the divisor is n-1.
        // [800, 900, 1000]: mean 900, ss = 20000, /2 = 10000, sqrt = 100
        XCTAssertEqual(HRVAnalyzer.sdnnRaw([800, 900, 1000])!, 100, accuracy: 1e-9)
    }

    func testConstantIntervalsHaveNoVariability() {
        let flat = [Double](repeating: 850, count: 30)
        XCTAssertEqual(HRVAnalyzer.rmssdRaw(flat)!, 0, accuracy: 1e-12)
        XCTAssertEqual(HRVAnalyzer.sdnnRaw(flat)!, 0, accuracy: 1e-12)
        XCTAssertEqual(HRVAnalyzer.pnn50Raw(flat)!, 0, accuracy: 1e-12)
    }

    func testPnn50CountsPairsNotBeats() {
        // 3 beats = 2 pairs; one pair differs by 100 ms, the other by 0.
        XCTAssertEqual(HRVAnalyzer.pnn50Raw([800, 900, 900])!, 0.5, accuracy: 1e-9)
        XCTAssertNil(HRVAnalyzer.pnn50Raw([800]), "one beat is no pairs, not zero pairs")
    }

    func testFormulasNeedTwoBeats() {
        XCTAssertNil(HRVAnalyzer.rmssdRaw([800]))
        XCTAssertNil(HRVAnalyzer.sdnnRaw([]))
        XCTAssertNil(HRVAnalyzer.meanNNRaw([]))
    }
}

final class HRVCleaningTests: XCTestCase {

    func testRangeFilterDropsTheImpossible() {
        let kept = HRVAnalyzer.rangeFilter([100, 300, 850, 2000, 5000])
        XCTAssertEqual(kept, [300, 850, 2000], "the bounds are inclusive")
    }

    func testEctopicBeatIsRejectedAgainstItsNeighbours() {
        var beats = [Double](repeating: 850, count: 11)
        beats[5] = 400                                  // a beat far from its local reference
        let clean = HRVAnalyzer.rejectEctopic(beats)
        XCTAssertFalse(clean.contains(400))
        XCTAssertEqual(clean.count, 10)
    }

    func testOneMissedBeatWouldOtherwiseDominateRmssd() {
        // The reason cleaning exists: a single artefact contributes a difference the size of a
        // whole interval, which outweighs every real beat-to-beat change in the window.
        var beats = [Double](repeating: 850, count: 40)
        beats[20] = 1700                                // two beats merged into one
        let dirty = HRVAnalyzer.rmssdRaw(beats)!
        let clean = HRVAnalyzer.analyze(beats).rmssd!
        XCTAssertGreaterThan(dirty, 100)
        XCTAssertLessThan(clean, 1, "after cleaning, a flat recording reads as flat")
    }

    func testGradualDriftIsNotMistakenForEctopy() {
        // A rising heart rate is real signal. Rejecting it would erase exactly the variability
        // the metric is meant to see.
        let beats = (0..<40).map { 800.0 + Double($0) * 2 }
        XCTAssertEqual(HRVAnalyzer.rejectEctopic(beats).count, beats.count)
    }

    func testAnalyzeRefusesBelowTheBeatFloorButStillReportsCounts() {
        let r = HRVAnalyzer.analyze([Double](repeating: 850, count: 5))
        XCTAssertNil(r.rmssd, "too few clean beats to say anything")
        XCTAssertEqual(r.nInput, 5)
        XCTAssertEqual(r.nClean, 5, "the counts still distinguish 'too few' from 'nothing at all'")
    }

    func testRejectedFractionReportsWhatCleaningRemoved() {
        var beats = [Double](repeating: 850, count: 30)
        for i in 0..<10 { beats[i] = 50 }               // impossible intervals
        let r = HRVAnalyzer.analyze(beats)
        XCTAssertEqual(r.rejectedFraction, 1.0 / 3.0, accuracy: 0.01)
        XCTAssertGreaterThan(r.rejectedFraction, HRVAnalyzer.defaultSpotMaxRejectedFraction - 0.02)
    }

    func testIndexedCleaningKeepsTheMappingBackToTheClock() {
        // Without the original index a caller cannot line a surviving beat up with its timestamp.
        var beats = [Double](repeating: 850, count: 11)
        beats[5] = 5000
        let kept = HRVAnalyzer.cleanRRIndexed(beats)
        XCTAssertFalse(kept.contains { $0.index == 5 })
        XCTAssertEqual(kept.last?.index, 10, "indices refer to the ORIGINAL sequence")
    }

    func testRollingRmssdWalksTheWindow() {
        let beats = [Double](repeating: 850, count: 60)
        let out = HRVAnalyzer.rollingRmssd(beats, window: 30, step: 10)
        XCTAssertEqual(out.count, 4)
        XCTAssertTrue(out.allSatisfy { $0 < 1 })
    }

    func testSpliceAwareRmssdIgnoresPairsThatBridgeAGap() {
        // Across a recording gap the "difference" is between two unrelated moments, and it is
        // large. A handful of splices otherwise dominate the night.
        var beats = [Double](repeating: 850, count: 20)
        beats[10] = 1500                                 // first beat after the strap came back
        let naive = HRVAnalyzer.rmssdRaw(beats)!
        let spliced = HRVAnalyzer.rmssdExcludingSplices(beats, spliceIndices: [10, 11])!
        XCTAssertGreaterThan(naive, 100)
        XCTAssertLessThan(spliced, 1)
    }
}

final class PoincareTests: XCTestCase {

    func testSd1IsRmssdOverRootTwo() {
        let d = Poincare.descriptors(rmssd: 100, sdnn: 120, meanNN: 850, n: 50)!
        XCTAssertEqual(d.sd1, 100 / 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testSd2FollowsFromSdnnAndSd1() {
        // sd2² = 2·SDNN² − SD1²
        let d = Poincare.descriptors(rmssd: 100, sdnn: 120, meanNN: 850, n: 50)!
        let expected = (2 * 120 * 120 - d.sd1 * d.sd1).squareRoot()
        XCTAssertEqual(d.sd2, expected, accuracy: 1e-9)
        XCTAssertEqual(d.ratio, d.sd2 / d.sd1, accuracy: 1e-9)
    }

    func testImpossibleCombinationIsRefusedRatherThanRendered() {
        // Mixing a night's SDNN with an unrelated spot RMSSD drives sd2² negative. Returning a
        // number there would be a square root of a negative shown as a plausible width.
        XCTAssertNil(Poincare.descriptors(rmssd: 500, sdnn: 10, meanNN: 850, n: 50))
    }

    func testDescriptorsFromBeatsAgreeWithTheDerivedForm() throws {
        let beats = (0..<60).map { 850.0 + (($0 % 2 == 0) ? 20 : -20) }
        let d = try XCTUnwrap(Poincare.descriptors(nn: beats))
        let viaMetrics = try XCTUnwrap(Poincare.descriptors(rmssd: HRVAnalyzer.rmssdRaw(beats)!,
                                                           sdnn: HRVAnalyzer.sdnnRaw(beats)!,
                                                           meanNN: HRVAnalyzer.meanNNRaw(beats)!,
                                                           n: beats.count))
        XCTAssertEqual(d.sd1, viaMetrics.sd1, accuracy: 1e-9)
        XCTAssertEqual(d.sd2, viaMetrics.sd2, accuracy: 1e-9)
    }

    func testEllipseSitsOnTheIdentityLine() throws {
        let d = try XCTUnwrap(Poincare.descriptors(rmssd: 60, sdnn: 90, meanNN: 900, n: 40))
        let e = try XCTUnwrap(Poincare.ellipse(descriptors: d))
        XCTAssertEqual(e.centerX, 900, accuracy: 1e-9)
        XCTAssertEqual(e.centerY, 900, accuracy: 1e-9)
        XCTAssertEqual(e.angleRadians, .pi / 4, accuracy: 1e-12)
    }

    func testTooFewBeatsHasNoShape() {
        XCTAssertNil(Poincare.descriptors(nn: [850, 860]))
        XCTAssertNil(Poincare.descriptors(rmssd: 50, sdnn: 60, meanNN: 850, n: 2))
    }
}
