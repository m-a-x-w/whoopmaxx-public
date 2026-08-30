import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SleepSessionsTests: XCTestCase {

    private let day0 = 1_800_000_000 - 1_800_000_000 % 86_400
    private func h(_ x: Double) -> Int { Int(x * 3600) }

    /// Still gravity plus low heart rate over `[from, from+seconds)`.
    private func asleep(_ from: Int, _ seconds: Int, bpm: Int = 50)
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        var g: [GravitySample] = [], hr: [HRSample] = [], rr: [RRInterval] = []
        for i in 0..<seconds {
            g.append(GravitySample(ts: from + i, x: 0, y: 0, z: 1))
            hr.append(HRSample(ts: from + i, bpm: bpm))
            rr.append(RRInterval(ts: from + i, rrMs: 60_000 / bpm + (i % 2 == 0 ? 40 : -40)))
        }
        return (g, hr, rr)
    }

    private func awake(_ from: Int, _ seconds: Int, bpm: Int = 78)
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        var g: [GravitySample] = [], hr: [HRSample] = [], rr: [RRInterval] = []
        for i in 0..<seconds {
            g.append(GravitySample(ts: from + i, x: Double(i % 2) * 0.5, y: 0, z: 1))
            hr.append(HRSample(ts: from + i, bpm: bpm))
            rr.append(RRInterval(ts: from + i, rrMs: 60_000 / bpm))
        }
        return (g, hr, rr)
    }

    private func join(_ parts: [(g: [GravitySample], h: [HRSample], r: [RRInterval])])
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        (parts.flatMap(\.g), parts.flatMap(\.h), parts.flatMap(\.r))
    }

    /// A night from 23:00 to 06:00 with an awake evening and morning either side.
    private func night() -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        join([awake(day0 + h(21), h(2)),
              asleep(day0 + h(23), h(7)),
              awake(day0 + h(30), h(2))])
    }

    func testAPlainNightIsFoundAndStaged() throws {
        let n = night()
        let s = SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g)
        XCTAssertEqual(s.count, 1)
        let night = try XCTUnwrap(s.first)
        XCTAssertEqual(night.start, day0 + h(23), accuracy: 900)
        XCTAssertFalse(night.lowConfidence)
        XCTAssertFalse(night.stages.isEmpty)
        XCTAssertEqual(night.stages.first?.start, night.start)
        XCTAssertEqual(night.stages.last?.end, night.end)
        XCTAssertNotNil(night.restingHR)
    }

    func testNoGravityMeansNoNight() {
        let n = night()
        XCTAssertTrue(SleepSessions.detectSleep(hr: n.h, gravity: []).isEmpty)
    }

    func testAnImplausiblySpanIsFlaggedNotDropped() throws {
        // Erasing it leaves a hole where a night should be, with nothing able to say why.
        let g = (0..<(20 * 3600)).map { GravitySample(ts: day0 + h(20) + $0, x: 0, y: 0, z: 1) }
        let hr = (0..<(20 * 3600)).map { HRSample(ts: day0 + h(20) + $0, bpm: 48) }
        let s = SleepSessions.detectSleep(hr: hr, gravity: g)
        let kept = try XCTUnwrap(s.first)
        XCTAssertTrue(kept.lowConfidence)
        XCTAssertGreaterThan(kept.end - kept.start, SleepDetection.maxMainSleepSpanS)
    }

    func testAnOffWristStretchIsRejected() {
        let n = night()
        let off = [(start: day0 + h(23), end: day0 + h(28))]
        XCTAssertTrue(SleepSessions.detectSleep(hr: n.h, gravity: n.g, wristOff: off).isEmpty)
    }

    func testAnHRHoleIsItsOwnEvidenceOfOffWrist() {
        // No wear events at all: a dense stream that simply stops is the proxy.
        var n = night()
        n.h.removeAll { $0.ts >= day0 + h(23) && $0.ts < day0 + h(28) }
        XCTAssertTrue(SleepSessions.detectSleep(hr: n.h, gravity: n.g).isEmpty)
    }

    // MARK: - Daytime

    func testAnAfternoonSitIsNotANap() {
        // Still and unremarkable: exactly what an afternoon on a sofa looks like.
        let day = join([awake(day0 + h(11), h(1), bpm: 70),
                        asleep(day0 + h(12), h(2), bpm: 66),
                        awake(day0 + h(14), h(1), bpm: 70)])
        XCTAssertTrue(SleepSessions.detectSleep(hr: day.h, rr: day.r, gravity: day.g).isEmpty)
    }

    func testAGenuineAfternoonNapIsKept() {
        // Same shape, with a real cardiac dip against the day's own baseline.
        let day = join([awake(day0 + h(11), h(1), bpm: 82),
                        asleep(day0 + h(12), h(2), bpm: 48),
                        awake(day0 + h(14), h(1), bpm: 82)])
        let s = SleepSessions.detectSleep(hr: day.h, rr: day.r, gravity: day.g)
        XCTAssertEqual(s.count, 1)
    }

    func testANapIsBelowTheOvernightFloorButAboveTheDaytimeOne() {
        // 45 minutes: under the hour a night needs, over the half hour a nap needs.
        let day = join([awake(day0 + h(11), h(1), bpm: 82),
                        asleep(day0 + h(12), 45 * 60, bpm: 46),
                        awake(day0 + h(12) + 45 * 60, h(1), bpm: 82)])
        XCTAssertEqual(SleepSessions.detectSleep(hr: day.h, rr: day.r, gravity: day.g).count, 1)
        XCTAssertGreaterThan(SleepDetection.minSleepMin, SleepDetection.daytimeMinSleepMin)
    }

    func testTheTimezoneDecidesWhatCountsAsDaytime() {
        // The same UTC instants, read on two clocks: a night in one is midday in the other.
        let n = join([awake(day0 + h(21), h(2), bpm: 80),
                      asleep(day0 + h(23), h(7), bpm: 66),
                      awake(day0 + h(30), h(2), bpm: 80)])
        XCTAssertEqual(SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g,
                                                 tzOffsetSeconds: 0).count, 1)
        XCTAssertTrue(SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g,
                                                tzOffsetSeconds: h(12)).isEmpty,
                      "shifted into the daytime band, it must clear the stricter bar")
    }

    func testANightTailIsNotAnIsolatedNap() throws {
        // Wake at 10:40, back to sleep 11:10 until 12:30 — centred in the daytime band, but it
        // continues the night.
        let n = join([awake(day0 + h(21), h(2)),
                      asleep(day0 + h(23), h(11) + 40 * 60),
                      awake(day0 + h(34) + 40 * 60, 30 * 60),
                      asleep(day0 + h(35) + 10 * 60, h(1) + 20 * 60),
                      awake(day0 + h(36) + 30 * 60, h(1))])
        let s = SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g)
        XCTAssertGreaterThanOrEqual(s.count, 2, "the tail is part of the night, not dropped")
    }

    // MARK: - Guards in isolation

    func testTheDaytimeBarRejectsOnMissingEvidence() {
        // Unlike a night, a daytime still stretch is far likelier to be sitting than sleeping.
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 7200)
        XCTAssertFalse(SleepDetection.passesDaytimeGuard(p, nil, 60))
        XCTAssertFalse(SleepDetection.passesDaytimeGuard(p, 50, nil))
        XCTAssertTrue(SleepDetection.passesDaytimeGuard(p, 50, 60))
        let brief = SleepDetection.Period(stage: "sleep", start: 0, end: 600)
        XCTAssertFalse(SleepDetection.passesDaytimeGuard(brief, 40, 60))
    }

    func testTheHRVGuardOnlyEverRejects() {
        XCTAssertTrue(SleepDetection.passesDaytimeHRVGuard(nil, 80), "no reading, no verdict")
        XCTAssertTrue(SleepDetection.passesDaytimeHRVGuard(20, nil), "no night to compare against")
        XCTAssertTrue(SleepDetection.passesDaytimeHRVGuard(20, 0))
        XCTAssertTrue(SleepDetection.passesDaytimeHRVGuard(66, 80), "0.83 of the night")
        XCTAssertFalse(SleepDetection.passesDaytimeHRVGuard(33, 80), "0.41 of the night")
    }

    func testTheMorningWindowRaisesTheBar() {
        // Residual post-wake stillness is the commonest phantom nap.
        let p = SleepDetection.Period(stage: "sleep", start: 10_000, end: 10_000 + 3600)
        let wake = 9_000
        // Clears the ordinary bar (0.95) but not the re-onset bar (0.90).
        XCTAssertTrue(SleepDetection.passesMorningStillnessGuard(p, 56, 60, nil, []))
        XCTAssertFalse(SleepDetection.passesMorningStillnessGuard(p, 56, 60, wake, []))
        XCTAssertTrue(SleepDetection.passesMorningStillnessGuard(p, 53, 60, wake, []))
    }

    func testTheStrapsOwnStateCanRescueABorderlineReOnset() {
        let p = SleepDetection.Period(stage: "sleep", start: 10_000, end: 10_000 + 3600)
        let state = (0..<100).map { (ts: 10_000 + $0 * 30, state: 2) }
        XCTAssertTrue(SleepDetection.passesMorningStillnessGuard(p, 56, 60, 9_000, state))
    }

    func testAbsentBandStateNeverConfirms() {
        // It may only ever rescue a block the strap scored asleep, never invent one.
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 3600)
        XCTAssertFalse(SleepDetection.bandStateConfirmsAsleep(p, []))
        XCTAssertFalse(SleepDetection.bandStateConfirmsAsleep(p, [(ts: 99_999, state: 2)]))
        let mixed = (0..<10).map { (ts: $0 * 300, state: $0 < 5 ? 2 : 0) }
        XCTAssertFalse(SleepDetection.bandStateConfirmsAsleep(p, mixed), "half is not predominantly")
    }

    func testTheTwoOffWristProxiesAreComplementary() {
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 7200)
        let flat = (0..<7200).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let deltas = SleepDetection.gravityDeltas(flat)
        let denseHR = (0..<7200).map { HRSample(ts: $0, bpm: 55) }
        let sparseHR = stride(from: 0, to: 7200, by: 1200).map { HRSample(ts: $0, bpm: 55) }

        // Dense HR: the gap proxy owns the decision, the gravity proxy stays out of it.
        XCTAssertTrue(SleepDetection.offWristGravitySpans(p, flat, deltas, denseHR).isEmpty)
        // Sparse HR: the gap proxy mutes itself, and dead-flat gravity takes over.
        XCTAssertTrue(SleepDetection.offWristHRGapSpans(p, sparseHR).isEmpty)
        XCTAssertFalse(SleepDetection.offWristGravitySpans(p, flat, deltas, sparseHR).isEmpty)
    }

    func testAnHRGapBecomesOffWristCoverage() {
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 7200)
        let hr = (0..<3600).map { HRSample(ts: $0, bpm: 55) }
        let frac = SleepDetection.offWristFraction(p, hr, [])
        XCTAssertEqual(frac, 0.5, accuracy: 0.01)
    }

    // MARK: - Forced window

    func testAForcedWindowSkipsEveryGate() {
        // The human asserted it; the job is to label it, not to re-litigate it.
        let sit = join([asleep(day0 + h(13), h(2), bpm: 70)])
        XCTAssertTrue(SleepSessions.detectSleep(hr: sit.h, rr: sit.r, gravity: sit.g).isEmpty)
        let forced = SleepSessions.stageWindow(start: day0 + h(13), end: day0 + h(15),
                                               hr: sit.h, rr: sit.r, gravity: sit.g)
        XCTAssertEqual(forced.start, day0 + h(13))
        XCTAssertEqual(forced.end, day0 + h(15))
        XCTAssertFalse(forced.stages.isEmpty)
        XCTAssertEqual(forced.stages.last?.end, forced.end)
    }

    func testBothStagersTileTheSameWindow() {
        let n = night()
        let a = SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g, method: .bands)
        let b = SleepSessions.detectSleep(hr: n.h, rr: n.r, gravity: n.g, method: .path)
        XCTAssertEqual(a.map(\.start), b.map(\.start), "the stager must not move a boundary")
        XCTAssertEqual(a.map(\.end), b.map(\.end))
    }

    // MARK: - Respiration

    func testNightlyBreathingRateIsPlausible() {
        // 1000 ms beats modulated at 12 breaths/min.
        let rr = (0..<600).map { i in
            RRInterval(ts: i, rrMs: Int(1000 + 40 * sin(2 * Double.pi * Double(i) / 5.0)))
        }
        let rate = SleepSessions.respRateFromRR(rr, start: 0, end: 600)
        XCTAssertEqual(rate, 12, accuracy: 3)
    }

    func testTooFewBeatsYieldsNoRate() {
        XCTAssertTrue(SleepSessions.respRateFromRR([], start: 0, end: 600).isNaN)
        let few = (0..<4).map { RRInterval(ts: $0, rrMs: 1000) }
        XCTAssertTrue(SleepSessions.respRateFromRR(few, start: 0, end: 600).isNaN)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) vs \(b)", file: file, line: line)
}
