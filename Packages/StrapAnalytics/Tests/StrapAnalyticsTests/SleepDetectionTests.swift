import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SleepDetectionTests: XCTestCase {

    /// Still gravity at 1 Hz.
    private func still(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { GravitySample(ts: from + $0, x: 0, y: 0, z: 1) }
    }

    /// Moving gravity at 1 Hz — well over the stillness cut.
    private func moving(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { GravitySample(ts: from + $0, x: Double($0 % 2) * 0.5, y: 0, z: 1) }
    }

    private func hr(from: Int, seconds: Int, bpm: Int, everyS: Int = 1) -> [HRSample] {
        stride(from: 0, to: seconds, by: everyS).map { HRSample(ts: from + $0, bpm: bpm) }
    }

    /// A plausible night: active evening, 7 h still with low HR, active morning.
    private func night(sleepStart: Int = 3600, sleepSeconds: Int = 7 * 3600)
        -> (grav: [GravitySample], hr: [HRSample]) {
        let g = moving(from: 0, seconds: sleepStart)
            + still(from: sleepStart, seconds: sleepSeconds)
            + moving(from: sleepStart + sleepSeconds, seconds: 3600)
        let h = hr(from: 0, seconds: sleepStart, bpm: 75)
            + hr(from: sleepStart, seconds: sleepSeconds, bpm: 52)
            + hr(from: sleepStart + sleepSeconds, seconds: 3600, bpm: 75)
        return (g, h)
    }

    func testAPlainNightIsDetected() throws {
        let n = night()
        let s = SleepDetection.detectSleep(gravity: n.grav, hr: n.hr)
        XCTAssertEqual(s.count, 1)
        let win = try XCTUnwrap(s.first)
        XCTAssertEqual(Double(win.end - win.start), 7 * 3600, accuracy: 900)
    }

    func testStillnessAloneIsNotSleep() {
        // A long sit reads still. Heart rate is what says it was not a night.
        let g = still(from: 0, seconds: 4 * 3600)
        let h = hr(from: 0, seconds: 4 * 3600, bpm: 78)
        // Baseline is the sit's own HR, so confirmation passes; the point is that with a real
        // day around it the elevated stretch is rejected.
        let withDay = still(from: 0, seconds: 4 * 3600) + moving(from: 4 * 3600, seconds: 4 * 3600)
        let dayHr = hr(from: 0, seconds: 4 * 3600, bpm: 78) + hr(from: 4 * 3600, seconds: 4 * 3600, bpm: 62)
        XCTAssertTrue(SleepDetection.detectSleep(gravity: withDay, hr: dayHr).isEmpty)
        XCTAssertFalse(SleepDetection.detectSleep(gravity: g, hr: h).isEmpty,
                       "with nothing to compare against, stillness is all there is")
    }

    func testAShortNapIsBelowTheStandaloneFloor() {
        let g = moving(from: 0, seconds: 3600) + still(from: 3600, seconds: 30 * 60)
              + moving(from: 3600 + 30 * 60, seconds: 3600)
        let h = hr(from: 0, seconds: 3600, bpm: 75) + hr(from: 3600, seconds: 30 * 60, bpm: 55)
              + hr(from: 3600 + 30 * 60, seconds: 3600, bpm: 75)
        XCTAssertTrue(SleepDetection.detectSleep(gravity: g, hr: h).isEmpty)
    }

    func testAnImplausiblyLongSpanIsRejectedNotTrimmed() {
        // Cutting it to the cap would invent a boundary nothing measured.
        let g = still(from: 0, seconds: 20 * 3600)
        let h = hr(from: 0, seconds: 20 * 3600, bpm: 55)
        let s = SleepDetection.detectSleep(gravity: g, hr: h)
        XCTAssertTrue(s.isEmpty || s.allSatisfy { $0.end - $0.start <= SleepDetection.maxMainSleepSpanS })
    }

    func testAnOffWristNightIsRejected() {
        let n = night()
        let off = [(start: 3600, end: 3600 + 5 * 3600)]   // most of the window
        XCTAssertTrue(SleepDetection.detectSleep(gravity: n.grav, hr: n.hr, wristOff: off).isEmpty)
    }

    func testNoCadenceMeansNothingIsAssertedStill() {
        // Staging on a guessed cadence is how an awake day becomes 16 h of sleep.
        let erratic = [0, 1, 500, 501, 9000, 9001, 30_000].map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        XCTAssertTrue(SleepDetection.classifyStill(erratic,
                                                   SleepDetection.gravityDeltas(erratic))
                        .allSatisfy { $0 == false })
    }

    func testTheStillCutScalesWithCadence() {
        // As a bare g figure the threshold means "per whatever gap this device sends", so a faster
        // sensor reads as motionless everywhere.
        let fast = (0..<600).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.05, y: 0, z: 1) }
        let slow = stride(from: 0, to: 6000, by: 10).map {
            GravitySample(ts: $0, x: Double(($0 / 10) % 2) * 0.05, y: 0, z: 1)
        }
        let fastStill = SleepDetection.classifyStill(fast, SleepDetection.gravityDeltas(fast))
        let slowStill = SleepDetection.classifyStill(slow, SleepDetection.gravityDeltas(slow))
        XCTAssertFalse(fastStill.allSatisfy { $0 }, "0.05 g in one second is movement")
        XCTAssertTrue(slowStill.contains(true), "the same 0.05 g spread over ten seconds is not")
    }

    func testCadenceIgnoresDropoutGaps() {
        // A dropout is a minority of gaps and must not move the median; filtering long gaps first
        // is how a genuinely slow device becomes indistinguishable from an unusable stream.
        var ts = (0..<200).map { Double($0) }
        ts += [10_000, 10_001, 10_002]
        XCTAssertEqual(SleepDetection.sampleCadenceSeconds(ts)!, 1.0, accuracy: 0.01)
    }

    func testCadenceRefusesAnUnusableStream() {
        XCTAssertNil(SleepDetection.sampleCadenceSeconds([0]))
        XCTAssertNil(SleepDetection.sampleCadenceSeconds([0, 1000, 2000]),
                     "beyond the supported cadence")
    }

    func testAShortStirDoesNotEndTheNight() {
        var g = still(from: 3600, seconds: 3 * 3600)
        g += moving(from: 3600 + 3 * 3600, seconds: 120)          // a two-minute stir
        g += still(from: 3600 + 3 * 3600 + 120, seconds: 3 * 3600)
        let h = hr(from: 3600, seconds: 6 * 3600 + 120, bpm: 54)
        let s = SleepDetection.detectSleep(gravity: moving(from: 0, seconds: 3600) + g,
                                           hr: hr(from: 0, seconds: 3600, bpm: 78) + h)
        XCTAssertEqual(s.count, 1, "one night, not two")
    }

    func testHeartRateConfirmationAbstainsOnThinData() {
        // A window is not rejected for lack of evidence — stillness already proposed it.
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 7200)
        let thin = [HRSample(ts: 10, bpm: 99), HRSample(ts: 20, bpm: 99)]
        XCTAssertTrue(SleepDetection.confirmSleepWithHR(p, thin, 50))
        XCTAssertTrue(SleepDetection.confirmSleepWithHR(p, [], nil), "no baseline, no verdict")
    }

    func testHeartRateConfirmationRejectsAnElevatedWindow() {
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 7200)
        let busy = (0..<200).map { HRSample(ts: $0 * 30, bpm: 95) }
        XCTAssertFalse(SleepDetection.confirmSleepWithHR(p, busy, 60))
    }

    func testOffWristFractionMergesOverlappingSpans() {
        // A doubly-flagged stretch must not be counted twice.
        let p = SleepDetection.Period(stage: "sleep", start: 0, end: 1000)
        let f = SleepDetection.offWristFraction(p, [], [(start: 0, end: 600), (start: 300, end: 800)])
        XCTAssertEqual(f, 0.8, accuracy: 1e-9)
        XCTAssertEqual(SleepDetection.offWristFraction(p, [], []), 0)
    }

    func testSessionRestingHRIsABinMinimum() {
        // The lowest single sample of a night is a dropout beat.
        var beats = (0..<3600).map { HRSample(ts: $0, bpm: 58) }
        beats[900] = HRSample(ts: 900, bpm: 3)
        XCTAssertEqual(SleepDetection.sessionRestingHR(0, 3600, beats), 58)
        XCTAssertNil(SleepDetection.sessionRestingHR(0, 100, []))
    }

    func testSparseGravityIsRecognised() {
        let sparseG = stride(from: 0, to: 3600, by: 1800).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        let denseHr = (0..<7200).map { HRSample(ts: $0, bpm: 60) }
        XCTAssertTrue(SleepDetection.isGravitySparse(sparseG, denseHr))

        let denseG = (0..<7200).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertFalse(SleepDetection.isGravitySparse(denseG, denseHr))
    }

    func testEmptyInputs() {
        XCTAssertTrue(SleepDetection.detectSleep(gravity: [], hr: []).isEmpty)
        XCTAssertTrue(SleepDetection.detectSleep(gravity: still(from: 0, seconds: 1), hr: []).isEmpty)
    }
}
