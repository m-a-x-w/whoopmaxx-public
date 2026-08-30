import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class NightMovementTests: XCTestCase {

    private func samples(_ xs: [(Int, Double)]) -> [NightMovement.Sample] {
        xs.map { NightMovement.Sample(ts: $0.0, intensity: $0.1) }
    }

    func testOneRollOverIsOneStirNotADozen() {
        // The movement takes several samples to subside and each is over threshold. Without the
        // debounce a single roll-over reads as a restless night.
        let s = samples((0..<10).map { ($0, 1.0) })
        XCTAssertEqual(NightMovement.stirCount(s, threshold: 0.35, debounceSec: 90), 1)
    }

    func testStirsSeparatedByQuietAreCountedApart() {
        var xs: [(Int, Double)] = (0..<5).map { ($0, 1.0) }
        xs += (5..<200).map { ($0, 0.0) }
        xs += (200..<205).map { ($0, 1.0) }
        XCTAssertEqual(NightMovement.stirCount(samples(xs), threshold: 0.35, debounceSec: 90), 2)
    }

    func testQuietRunShorterThanTheDebounceDoesNotRearm() {
        var xs: [(Int, Double)] = [(0, 1.0)]
        xs += (1..<30).map { ($0, 0.0) }        // under the 90 s debounce
        xs += [(30, 1.0)]
        XCTAssertEqual(NightMovement.stirCount(samples(xs), threshold: 0.35, debounceSec: 90), 1)
    }

    func testAStillNightHasNoStirs() {
        let s = samples((0..<1000).map { ($0, 0.0) })
        XCTAssertEqual(NightMovement.stirCount(s, threshold: 0.35, debounceSec: 90), 0)
    }

    func testStillestStretchIsMeasuredInClockTime() {
        // A sparse quiet stretch and a dense one of the same real duration must compare equally.
        let dense = samples((0..<100).map { ($0, 0.0) })
        let sparse = samples(stride(from: 0, to: 100, by: 10).map { ($0, 0.0) })
        XCTAssertEqual(NightMovement.stillestStretch(dense, quietThreshold: 0.12)?.durationSec, 99)
        XCTAssertEqual(NightMovement.stillestStretch(sparse, quietThreshold: 0.12)?.durationSec, 90)
    }

    func testStillestStretchPicksTheLongestRun() {
        var xs: [(Int, Double)] = (0..<10).map { ($0, 0.0) }      // short quiet run
        xs += [(10, 1.0)]
        xs += (11..<100).map { ($0, 0.0) }                        // long quiet run
        let best = NightMovement.stillestStretch(samples(xs), quietThreshold: 0.12)
        XCTAssertEqual(best?.start, 11)
        XCTAssertEqual(best?.end, 99)
    }

    func testNoQuietSamplesMeansNoStretch() {
        let s = samples((0..<50).map { ($0, 1.0) })
        XCTAssertNil(NightMovement.stillestStretch(s, quietThreshold: 0.12))
    }

    func testIntensityIsNormalisedAgainstTheNightsOwnPeak() {
        // Two nights are not comparable in raw units; "restless relative to how still this person
        // got" is.
        let g = (0..<100).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.01, y: 0, z: 1) }
        let a = NightMovement.fromGravity(g, start: 0, end: 100)
        XCTAssertTrue(a.samples.allSatisfy { $0.intensity <= 1.0 })
        XCTAssertEqual(a.samples.map(\.intensity).max()!, 1.0, accuracy: 1e-9)
    }

    func testPeakIsCarriedSoAStillNightIsDistinguishable() {
        // Normalisation scales a motionless night's noise up to fill the range; without the peak a
        // caller cannot tell it from a genuinely restless one.
        let tiny = (0..<100).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.0001, y: 0, z: 1) }
        let big = (0..<100).map { GravitySample(ts: $0, x: Double($0 % 2), y: 0, z: 1) }
        XCTAssertLessThan(NightMovement.fromGravity(tiny, start: 0, end: 100).peak,
                          NightMovement.fromGravity(big, start: 0, end: 100).peak)
    }

    func testAPerfectlyStillNightDoesNotDivideByZero() {
        let g = (0..<100).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let a = NightMovement.fromGravity(g, start: 0, end: 100)
        XCTAssertTrue(a.samples.allSatisfy { $0.intensity.isFinite })
        XCTAssertEqual(a.stirCount, 0)
    }

    func testEmptyNight() {
        let a = NightMovement.fromGravity([], start: 0, end: 100)
        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(a.stirCount, 0)
        XCTAssertNil(a.stillest)
        XCTAssertEqual(a.peak, 0)
    }

    func testEpochMotionReconstructsTimestampsFromTheSessionStart() {
        let a = NightMovement.fromEpochMotion([0, 1, 0, 0], sessionStart: 1000, end: 1120, epochSeconds: 30)
        XCTAssertEqual(a.source, .epochMotion)
        XCTAssertEqual(a.samples.map(\.ts), [1000, 1030, 1060, 1090])
    }

    func testSourceIsCarriedSoNightsAreNotComparedAcrossLanes() {
        let g = NightMovement.fromGravity([GravitySample(ts: 0, x: 0, y: 0, z: 1)], start: 0, end: 1)
        XCTAssertEqual(g.source, .gravity)
    }
}
