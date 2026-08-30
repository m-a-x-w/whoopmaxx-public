import XCTest
import StrapProtocol
@testable import StrapAnalytics

private func gravity(_ samples: [(Int, Double, Double, Double)]) -> [GravitySample] {
    samples.map { GravitySample(ts: $0.0, x: $0.1, y: $0.2, z: $0.3) }
}

final class MotionTests: XCTestCase {

    func testAStillWristReadsZeroAtAnyAngle() {
        // The strap reports ORIENTATION. A magnitude-based measure could not tell a still wrist
        // held vertically from a moving one.
        for vec in [(1.0, 0.0, 0.0), (0.0, 0.0, 1.0), (0.577, 0.577, 0.577)] {
            let g = gravity((0..<10).map { ($0, vec.0, vec.1, vec.2) })
            let series = Motion.activitySeries(g)
            XCTAssertTrue(series.allSatisfy { $0.intensity < 1e-12 })
        }
    }

    func testIntensityIsTheTurnBetweenConsecutiveVectors() {
        let g = gravity([(0, 0, 0, 1), (1, 1, 0, 0)])
        let s = Motion.activitySeries(g)
        XCTAssertEqual(s[0].intensity, 0, "no previous vector to compare against")
        XCTAssertEqual(s[1].intensity, 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testFirstSampleIsZeroNotTheVectorMagnitude() {
        // Seeding from magnitude would open every series with a spurious spike.
        let s = Motion.activitySeries(gravity([(0, 0, 0, 1)]))
        XCTAssertEqual(s.first?.intensity, 0)
    }

    func testUnsortedInputIsOrdered() {
        let s = Motion.activitySeries(gravity([(5, 0, 0, 1), (1, 0, 0, 1), (3, 0, 0, 1)]))
        XCTAssertEqual(s.map(\.ts), [1, 3, 5])
    }

    func testSmoothingWindowsByTimeNotSampleCount() {
        // The sample rate is not constant. A fixed count would average over three seconds in one
        // stretch and three minutes in another.
        let dense = (0..<100).map { Motion.ActivityPoint(ts: $0, intensity: 1) }
        let sparse = (0..<100).map { Motion.ActivityPoint(ts: $0 * 60, intensity: 1) }
        XCTAssertEqual(Motion.smoothedIntensity(dense, windowS: 10).last!, 1, accuracy: 1e-9)
        XCTAssertEqual(Motion.smoothedIntensity(sparse, windowS: 10).last!, 1, accuracy: 1e-9)
    }

    func testSmoothingAveragesOverTheWindow() {
        var pts = (0..<20).map { Motion.ActivityPoint(ts: $0, intensity: 0) }
        pts[19] = Motion.ActivityPoint(ts: 19, intensity: 10)
        let out = Motion.smoothedIntensity(pts, windowS: 10)
        XCTAssertGreaterThan(out.last!, 0)
        XCTAssertLessThan(out.last!, 10, "a single spike is diluted across its window")
    }

    func testNonFiniteIntensityDoesNotPoisonTheRunningSum() {
        // One NaN in a running sum makes every later value NaN.
        var pts = (0..<10).map { Motion.ActivityPoint(ts: $0, intensity: 1) }
        pts[3] = Motion.ActivityPoint(ts: 3, intensity: .nan)
        XCTAssertTrue(Motion.smoothedIntensity(pts, windowS: 5).allSatisfy(\.isFinite))
    }

    func testEmptyInput() {
        XCTAssertTrue(Motion.activitySeries([]).isEmpty)
        XCTAssertTrue(Motion.smoothedIntensity([], windowS: 10).isEmpty)
    }
}

final class SedentaryDetectorTests: XCTestCase {

    /// A still hour: one sample a second, unchanging orientation.
    private func stillSpan(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { GravitySample(ts: from + $0, x: 0, y: 0, z: 1) }
    }

    /// Motion large enough to clear the walking threshold once smoothed.
    private func movingSpan(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { i in
            GravitySample(ts: from + i, x: Double(i % 2), y: 0, z: 1 - Double(i % 2))
        }
    }

    func testAStillHourIsOneBout() {
        let bouts = SedentaryDetector.detectSedentaryBouts(stillSpan(from: 0, seconds: 3600))
        XCTAssertEqual(bouts.count, 1)
        XCTAssertEqual(bouts[0].durationS, 3599, accuracy: 1)
    }

    func testShortStillnessIsNotABout() {
        let bouts = SedentaryDetector.detectSedentaryBouts(stillSpan(from: 0, seconds: 60))
        XCTAssertTrue(bouts.isEmpty, "a minute of sitting is not a sedentary bout")
    }

    func testMovementSplitsTheDayIntoSeparateBouts() {
        let g = stillSpan(from: 0, seconds: 1800)
            + movingSpan(from: 1800, seconds: 900)
            + stillSpan(from: 2700, seconds: 1800)
        let bouts = SedentaryDetector.detectSedentaryBouts(g)
        XCTAssertEqual(bouts.count, 2)
    }

    func testAGapEndsARunRatherThanBeingSpanned() {
        // No samples is indistinguishable from perfect stillness. Bridging would report a
        // two-hour sedentary bout for a two-hour shower.
        let g = stillSpan(from: 0, seconds: 1200) + stillSpan(from: 1200 + 3600, seconds: 1200)
        let bouts = SedentaryDetector.detectSedentaryBouts(g)
        XCTAssertEqual(bouts.count, 2)
        XCTAssertLessThan(bouts[0].durationS, 1300)
    }

    func testConstantMotionProducesNoBouts() {
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts(movingSpan(from: 0, seconds: 3600)).isEmpty)
    }

    func testTooFewSamples() {
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts([]).isEmpty)
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts(stillSpan(from: 0, seconds: 1)).isEmpty)
    }

    func testThresholdIsConfigurable() {
        let g = stillSpan(from: 0, seconds: 3600)
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts(g, moveThresholdG: -1).isEmpty,
                      "a threshold below zero makes everything read as motion")
    }
}
