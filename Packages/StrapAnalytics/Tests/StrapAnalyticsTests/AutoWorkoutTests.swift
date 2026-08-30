import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class AutoWorkoutDetectorTests: XCTestCase {

    private func hr(from: Int, seconds: Int, bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0..<seconds).map { (ts: from + $0, bpm: bpm) }
    }

    func testASustainedElevationIsSuggested() throws {
        let seg = hr(from: 0, seconds: 300, bpm: 60) + hr(from: 300, seconds: 1200, bpm: 140)
        let w = try XCTUnwrap(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55).first)
        XCTAssertEqual(w.avgBpm, 140)
        XCTAssertEqual(w.peakBpm, 140)
        XCTAssertGreaterThanOrEqual(w.durationMin, 19)
    }

    func testABriefDipDoesNotSplitAWorkout() {
        // A workout is not over because someone paused at a traffic light — and splitting there
        // leaves two fragments that each miss the duration floor.
        var seg = hr(from: 0, seconds: 600, bpm: 140)
        seg += hr(from: 600, seconds: 60, bpm: 70)          // 60 s dip, under maxDipS
        seg += hr(from: 660, seconds: 600, bpm: 140)
        let out = AutoWorkoutDetector.detect(hr: seg, restingBpm: 55)
        XCTAssertEqual(out.count, 1)
    }

    func testALongDipEndsTheSpan() {
        var seg = hr(from: 0, seconds: 800, bpm: 140)
        seg += hr(from: 800, seconds: 600, bpm: 65)         // a real rest
        seg += hr(from: 1400, seconds: 800, bpm: 140)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55).count, 2)
    }

    func testTooShortToSuggest() {
        let seg = hr(from: 0, seconds: 300, bpm: 60) + hr(from: 300, seconds: 300, bpm: 140)
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55).isEmpty)
    }

    func testTheBarIsHigherThanABriskWalk() {
        // A suggestion should be obviously a workout.
        let walk = hr(from: 0, seconds: 1800, bpm: 80)
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: walk, restingBpm: 55).isEmpty)
    }

    func testAnAlreadySavedWorkoutIsNotSuggestedAgain() {
        // Overlap, not equality: a saved workout rarely shares exact boundaries with a fresh
        // detection, and an equality check would offer the same session back every sync.
        let seg = hr(from: 0, seconds: 1500, bpm: 140)
        let saved = [SavedWorkoutSpan(startSec: 100, endSec: 900)]
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55, savedSpans: saved).isEmpty)
    }

    func testANonOverlappingSavedWorkoutDoesNotSuppress() {
        let seg = hr(from: 0, seconds: 1500, bpm: 140)
        let saved = [SavedWorkoutSpan(startSec: 100_000, endSec: 101_000)]
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55, savedSpans: saved).count, 1)
    }

    func testMotionConfirmsButIsNotRequired() {
        let seg = hr(from: 0, seconds: 1500, bpm: 140)
        // With no motion series supplied, HR alone still suggests — the user decides.
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55).count, 1)

        let stillMotion = (0..<1500).map { AutoWorkoutDetector.MotionPoint(ts: $0, intensity: 0) }
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55, motion: stillMotion).isEmpty,
                      "supplied motion that shows stillness rules the window out")

        let realMotion = (0..<1500).map { AutoWorkoutDetector.MotionPoint(ts: $0, intensity: 0.5) }
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55, motion: realMotion).count, 1)
    }

    func testAnEmptyMotionSeriesIsTreatedAsAbsent() {
        let seg = hr(from: 0, seconds: 1500, bpm: 140)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55, motion: []).count, 1)
    }

    func testNearbySpansMerge() {
        var seg = hr(from: 0, seconds: 800, bpm: 140)
        seg += hr(from: 800, seconds: 120, bpm: 65)
        seg += hr(from: 920, seconds: 800, bpm: 140)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: 55).count, 1)
    }

    func testDefaultRestingIsUsedWhenNoneIsGiven() {
        let seg = hr(from: 0, seconds: 1500, bpm: 95)      // 60 + 30 = 90 floor
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: seg, restingBpm: nil).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: [], restingBpm: 55).isEmpty)
    }

    func testOverlapPredicate() {
        XCTAssertTrue(AutoWorkoutDetector.overlaps(0, 10, 5, 15))
        XCTAssertTrue(AutoWorkoutDetector.overlaps(0, 10, 10, 20), "touching counts")
        XCTAssertFalse(AutoWorkoutDetector.overlaps(0, 10, 11, 20))
    }

    func testMotionPointsFromGravity() {
        let g = (0..<10).map { GravitySample(ts: $0, x: Double($0 % 2), y: 0, z: 1) }
        let pts = AutoWorkoutDetector.motionPoints(g)
        XCTAssertEqual(pts.count, 10)
        XCTAssertEqual(pts[0].intensity, 0)
        XCTAssertGreaterThan(pts[1].intensity, 0)
    }
}

final class BreathPacerTests: XCTestCase {

    func testTwoCuesPerCycle() {
        let s = BreathPacer.schedule(bpm: 6, cycles: 5)
        XCTAssertEqual(s.count, 10)
        XCTAssertEqual(s.filter { $0.phase == .inhale }.count, 5)
    }

    func testExhaleIsTheLongerHalf() {
        // The longer exhale is the point of paced breathing; an even split makes it a metronome.
        let s = BreathPacer.schedule(bpm: 6, cycles: 1)
        let cycleMs = 10_000
        let inhaleMs = s[1].offsetMs - s[0].offsetMs
        XCTAssertLessThan(inhaleMs, cycleMs - inhaleMs)
        XCTAssertLessThan(BreathPacer.defaultInhaleFraction, 0.5)
    }

    func testThePhasesAreDistinguishableWithoutLooking() {
        let s = BreathPacer.schedule(bpm: 6, cycles: 1)
        XCTAssertNotEqual(s[0].loops, s[1].loops)
    }

    func testOffsetsAreExactAndDoNotDrift() {
        // A timer recalculating each cue accumulates drift across a ten-minute session, and a
        // breathing pace that slides is worse than no pace at all.
        let s = BreathPacer.schedule(bpm: 6, cycles: 60)
        let inhales = s.filter { $0.phase == .inhale }.map(\.offsetMs)
        for i in 1..<inhales.count {
            XCTAssertEqual(inhales[i] - inhales[i - 1], 10_000, "cycle \(i)")
        }
        XCTAssertEqual(inhales.last!, 59 * 10_000)
    }

    func testRateIsClamped() {
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 0.1, cycles: 1),
                       BreathPacer.sessionDurationMs(bpm: BreathPacer.minBpm, cycles: 1))
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 100, cycles: 1),
                       BreathPacer.sessionDurationMs(bpm: BreathPacer.maxBpm, cycles: 1))
    }

    func testInhaleFractionIsClamped() {
        let s = BreathPacer.schedule(bpm: 6, inhaleFraction: 0.0, cycles: 1)
        XCTAssertGreaterThan(s[1].offsetMs - s[0].offsetMs, 0, "an inhale is never zero-length")
        let t = BreathPacer.schedule(bpm: 6, inhaleFraction: 1.0, cycles: 1)
        XCTAssertLessThan(t[1].offsetMs - t[0].offsetMs, 10_000, "and never the whole cycle")
    }

    func testSessionDuration() {
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 6, cycles: 30), 300_000)
        XCTAssertEqual(BreathPacer.sessionDurationMs(bpm: 6, cycles: 0), 0)
        XCTAssertTrue(BreathPacer.schedule(bpm: 6, cycles: 0).isEmpty)
    }
}
