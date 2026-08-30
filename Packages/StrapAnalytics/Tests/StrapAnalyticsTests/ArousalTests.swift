import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class ArousalForensicsTests: XCTestCase {

    /// A night: sleep, a mid-sleep wake, more sleep — with settle-in and terminal wake either side.
    private func night(wakeStart: Int, wakeEnd: Int) -> SleepSession {
        SleepSession(start: 0, end: 28_800, efficiency: 0.9, stages: [
            StageSegment(start: 0, end: 600, stage: "wake"),            // settling in
            StageSegment(start: 600, end: wakeStart, stage: "light"),
            StageSegment(start: wakeStart, end: wakeEnd, stage: "wake"),
            StageSegment(start: wakeEnd, end: 27_000, stage: "light"),
            StageSegment(start: 27_000, end: 28_800, stage: "wake"),    // terminal wake
        ], restingHR: 52, avgHRV: 60)
    }

    private func flat(_ n: Int) -> [Double] { [Double](repeating: 0.05, count: n) }

    private func classify(_ session: SleepSession,
                          motion: [Double] = [], hr: [HRSample] = [], rr: [RRInterval] = [],
                          resp: [RespSample] = [], skin: [SkinTempSample] = [],
                          gravity: [GravitySample] = []) -> [Arousal] {
        ArousalForensics.classify(session: session, motionEpochs: motion, hr: hr, rr: rr,
                                  resp: resp, skinTemp: skin, gravity: gravity, family: .whoop5)
    }

    func testOnlyMidSleepWakesAreClassified() {
        // Settling in and the final wake are not awakenings; tagging them would put two
        // meaningless events on every night.
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].start, 10_000)
    }

    func testABriefStirIsNotAnEvent() {
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_060), motion: flat(960))
        XCTAssertTrue(a.isEmpty, "a minute of wake is normal architecture")
    }

    func testMovementIsTaggedPositional() {
        var m = flat(960)
        for i in 333...347 { m[i] = 5.0 }             // a burst across the wake window
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: m)
        XCTAssertEqual(a.first?.cause, .positional)
        XCTAssertEqual(a.first?.evidence, "movement")
    }

    func testAnOrientationChangeIsTaggedAsARollOver() {
        // A roll-over can be smooth, so orientation alone must be enough.
        var g = (9_000..<10_000).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        g += (10_000..<10_400).map { GravitySample(ts: $0, x: 1, y: 0, z: 0) }
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960), gravity: g)
        XCTAssertEqual(a.first?.cause, .positional)
        XCTAssertEqual(a.first?.evidence, "roll-over")
    }

    func testMovementSuppressesTheCardiacTest() {
        // Moving raises heart rate. Without the suppression every roll-over would also read as a
        // cardiac event and the two categories would be indistinguishable.
        var m = flat(960)
        for i in 333...347 { m[i] = 5.0 }
        var hr = (9_000..<10_000).map { HRSample(ts: $0, bpm: 50) }
        hr += (10_000..<10_400).map { HRSample(ts: $0, bpm: 95) }
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: m, hr: hr)
        XCTAssertEqual(a.first?.cause, .positional, "movement wins, cardiac is not even tested")
    }

    func testAHeartRateSurgeWithoutMovementIsCardiac() {
        var hr = (9_000..<10_000).map { HRSample(ts: $0, bpm: 50) }
        hr += (10_000..<10_400).map { HRSample(ts: $0, bpm: 90) }
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960), hr: hr)
        XCTAssertEqual(a.first?.cause, .cardiac)
        XCTAssertTrue(a.first!.evidence.contains("HR +"))
    }

    func testASkinTemperatureRiseIsThermal() {
        var s = (9_000..<10_000).map { SkinTempSample(ts: $0, raw: 3300) }
        s += (10_000..<10_400).map { SkinTempSample(ts: $0, raw: 3380) }   // +0.8 degC on whoop5
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960), skin: s)
        XCTAssertEqual(a.first?.cause, .thermal)
        XCTAssertTrue(a.first!.evidence.contains("skin"))
    }

    func testRisingBeatVariabilityIsRespiratory() {
        var rr = (0..<400).map { RRInterval(ts: 9_000 + $0 * 2, rrMs: 1000) }
        rr += (0..<200).map { i in
            RRInterval(ts: 10_000 + i * 2, rrMs: 1000 + (i % 2 == 0 ? 300 : -300))
        }
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960), rr: rr)
        XCTAssertEqual(a.first?.cause, .respiratory)
    }

    func testNothingClearedIsNamedUnexplained() {
        // A wrong explanation is worse than none, because it invites a change of behaviour.
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960))
        XCTAssertEqual(a.first?.cause, .unexplained)
        XCTAssertEqual(a.first?.evidence, "no clear signal")
    }

    func testAStillBaselineDoesNotMakeEveryTwitchThreefold() {
        // Without the absolute floor, a perfectly still baseline turns any movement at all into a
        // threefold increase.
        var m = [Double](repeating: 0.0, count: 960)
        for i in 333...347 { m[i] = 0.2 }             // small, under the floor
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: m)
        XCTAssertNotEqual(a.first?.cause, .positional)
    }

    func testDurationIsReported() throws {
        let a = classify(night(wakeStart: 10_000, wakeEnd: 10_400), motion: flat(960))
        XCTAssertEqual(try XCTUnwrap(a.first).durationMin, 400.0 / 60.0, accuracy: 1e-9)
    }

    func testANightWithNoStages() {
        let empty = SleepSession(start: 0, end: 100, efficiency: 0, stages: [],
                                 restingHR: nil, avgHRV: nil)
        XCTAssertTrue(classify(empty).isEmpty)
    }

    func testANightThatIsAllWake() {
        let allWake = SleepSession(start: 0, end: 3600, efficiency: 0,
                                   stages: [StageSegment(start: 0, end: 3600, stage: "wake")],
                                   restingHR: nil, avgHRV: nil)
        XCTAssertTrue(classify(allWake).isEmpty, "with no sleep there is no mid-sleep")
    }

    func testAngleBetweenVectors() {
        XCTAssertEqual(ArousalForensics.angleDeg((1, 0, 0), (0, 1, 0))!, 90, accuracy: 1e-6)
        XCTAssertEqual(ArousalForensics.angleDeg((1, 0, 0), (1, 0, 0))!, 0, accuracy: 1e-6)
        XCTAssertEqual(ArousalForensics.angleDeg((1, 0, 0), (-1, 0, 0))!, 180, accuracy: 1e-6)
        XCTAssertNil(ArousalForensics.angleDeg((0, 0, 0), (1, 0, 0)))
    }

    func testParallelVectorsDoNotProduceNaN() {
        // Floating-point error pushes the cosine a hair past 1 and acos returns NaN, which would
        // silently disable roll detection.
        let v = (x: 0.577, y: 0.577, z: 0.577)
        XCTAssertTrue(ArousalForensics.angleDeg(v, v)!.isFinite)
    }

    func testCoefficientOfVariation() {
        XCTAssertNil(ArousalForensics.cv([5]))
        XCTAssertEqual(ArousalForensics.cv([Double](repeating: 100, count: 10))!, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(ArousalForensics.cv([90, 110, 90, 110])!, 0)
    }
}
