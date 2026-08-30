import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class WorkoutDetectorTests: XCTestCase {

    private func hr(from: Int, seconds: Int, bpm: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: from + $0, bpm: bpm) }
    }

    /// Vigorous wrist movement — alternating orientation clears the motion bar.
    private func moving(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { GravitySample(ts: from + $0, x: Double($0 % 2), y: 0, z: 1 - Double($0 % 2)) }
    }

    private func still(from: Int, seconds: Int) -> [GravitySample] {
        (0..<seconds).map { GravitySample(ts: from + $0, x: 0, y: 0, z: 1) }
    }

    func testHeartRateAndMotionAreBothRequired() {
        // HR alone flags a stressful meeting; motion alone flags a bumpy drive.
        let restBase = hr(from: 0, seconds: 600, bpm: 55)

        let hrOnly = WorkoutDetector.detect(hr: restBase + hr(from: 600, seconds: 1800, bpm: 150),
                                            gravity: still(from: 0, seconds: 2400),
                                            restingHR: 55, maxHR: 190)
        XCTAssertTrue(hrOnly.isEmpty, "elevated HR without movement is not a workout")

        let motionOnly = WorkoutDetector.detect(hr: hr(from: 0, seconds: 2400, bpm: 58),
                                                gravity: moving(from: 0, seconds: 2400),
                                                restingHR: 55, maxHR: 190)
        XCTAssertTrue(motionOnly.isEmpty, "movement without effort is not a workout")
    }

    func testABoutWithBothIsDetected() throws {
        let hrs = hr(from: 0, seconds: 300, bpm: 55) + hr(from: 300, seconds: 1800, bpm: 150)
        let grav = still(from: 0, seconds: 300) + moving(from: 300, seconds: 1800)
        let s = try XCTUnwrap(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                                     restingHR: 55, maxHR: 190).first)
        XCTAssertGreaterThanOrEqual(s.durationS, 1500)
        XCTAssertEqual(s.avgHR, 150, accuracy: 1)
        XCTAssertEqual(s.peakHR, 150)
        XCTAssertNotNil(s.strain)
    }

    func testAShortBurstIsBelowTheDurationFloor() {
        let hrs = hr(from: 0, seconds: 300, bpm: 55) + hr(from: 300, seconds: 120, bpm: 150)
        let grav = still(from: 0, seconds: 300) + moving(from: 300, seconds: 120)
        XCTAssertTrue(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                             restingHR: 55, maxHR: 190).isEmpty)
    }

    func testASensorDropoutDoesNotShatterOneEffort() throws {
        // No readings mid-effort is a dropout, not a rest.
        var hrs = hr(from: 0, seconds: 900, bpm: 150)
        hrs += hr(from: 1000, seconds: 900, bpm: 150)          // 100 s hole
        let grav = moving(from: 0, seconds: 900) + moving(from: 1000, seconds: 900)
        let s = WorkoutDetector.detect(hr: hrs, gravity: grav, restingHR: 55, maxHR: 190)
        XCTAssertEqual(s.count, 1, "one workout, not two")
        XCTAssertGreaterThan(try XCTUnwrap(s.first).durationS, 1800)
    }

    func testARealRestSplitsTwoWorkouts() {
        // A lull carrying ordinary waking HR must NOT weld the day into one session.
        var hrs = hr(from: 0, seconds: 900, bpm: 150)
        hrs += hr(from: 900, seconds: 280, bpm: 62)            // genuinely resting
        hrs += hr(from: 1180, seconds: 900, bpm: 150)
        let grav = moving(from: 0, seconds: 900) + still(from: 900, seconds: 280)
                 + moving(from: 1180, seconds: 900)
        XCTAssertEqual(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                              restingHR: 55, maxHR: 190).count, 2)
    }

    func testIntensityCanSubstituteForMovementButNotEliminateIt() {
        // A hard effort with little wrist movement — a spin bike — is still exercise, so the
        // motion bar ramps down as %HRR rises.
        let easy = WorkoutDetector.motionRequirement(bpm: 100, restingHR: 55, hrReserve: 135)
        let hard = WorkoutDetector.motionRequirement(bpm: 175, restingHR: 55, hrReserve: 135)
        XCTAssertLessThan(hard, easy)
        XCTAssertGreaterThan(hard, 0, "but never to zero")
        XCTAssertEqual(WorkoutDetector.motionRequirement(bpm: 175, restingHR: 55, hrReserve: nil),
                       WorkoutDetector.motionThreshold,
                       "with no known ceiling it falls back to the fixed bar")
    }

    func testRestingHeartRateIsAPercentileNotTheMinimum() {
        // The minimum of a day is a dropout beat.
        var seg = (0..<1000).map { (ts: $0, bpm: 60.0) }
        seg[500] = (ts: 500, bpm: 3.0)
        XCTAssertEqual(WorkoutDetector.deriveRestingHR(seg), 60, accuracy: 1)
    }

    func testNearestRefusesAReadingFromTooFarAway() {
        // Motion and HR arrive on different cadences; pairing a movement with a reading a minute
        // away attributes effort to the wrong moment.
        let ts = [0, 100, 200]
        let vals = [60.0, 70, 80]
        XCTAssertEqual(WorkoutDetector.nearest(ts, vals, 102, 5), 70)
        XCTAssertNil(WorkoutDetector.nearest(ts, vals, 150, 5))
        XCTAssertNil(WorkoutDetector.nearest([], [], 0, 5))
    }

    func testHRmaxSourceTravelsWithTheNumber() throws {
        let hrs = hr(from: 0, seconds: 300, bpm: 55) + hr(from: 300, seconds: 1800, bpm: 150)
        let grav = still(from: 0, seconds: 300) + moving(from: 300, seconds: 1800)
        let given = try XCTUnwrap(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                                         restingHR: 55, maxHR: 190).first)
        XCTAssertEqual(given.hrmaxSource, "caller")

        let derived = try XCTUnwrap(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                                           restingHR: 55, age: 30).first)
        XCTAssertNotEqual(derived.hrmaxSource, "caller")
    }

    func testAnObservedCeilingOnlyWinsWhenItExceedsTheFormula() {
        // A strap that has never seen hard effort reports a low percentile; adopting it would
        // compress every zone upward and inflate the whole training history.
        let easyHistory = [Double](repeating: 90, count: 1000)
        let (v, src) = StrainScorer.estimateHRmax(easyHistory, age: 30)
        XCTAssertEqual(src, "tanaka")
        XCTAssertEqual(v, HRZones.tanakaMaxHR(age: 30), accuracy: 1e-9)

        // A SINGLE spike does not move the 99.5th percentile — that robustness is the reason a
        // percentile is used rather than the maximum, which one artefact would own outright.
        let oneSpike = [Double](repeating: 120, count: 999) + [200]
        XCTAssertEqual(StrainScorer.estimateHRmax(oneSpike, age: 30).1, "tanaka")

        // Sustained hard efforts do move it.
        let repeatedlyHard = [Double](repeating: 120, count: 980) + [Double](repeating: 200, count: 20)
        let (v2, src2) = StrainScorer.estimateHRmax(repeatedlyHard, age: 30)
        XCTAssertEqual(src2, "observed")
        XCTAssertGreaterThan(v2, HRZones.tanakaMaxHR(age: 30))
    }

    func testNoAgeAndNoHistoryLeavesTheCeilingUnknown() {
        let (v, src) = StrainScorer.estimateHRmax([], age: nil)
        XCTAssertEqual(v, 0)
        XCTAssertEqual(src, "unknown")
    }

    func testEmptyInputs() {
        XCTAssertTrue(WorkoutDetector.detect(hr: [], gravity: moving(from: 0, seconds: 100)).isEmpty)
        XCTAssertTrue(WorkoutDetector.detect(hr: hr(from: 0, seconds: 100, bpm: 150), gravity: []).isEmpty)
    }

    func testZoneBreakdownSumsToAHundred() throws {
        let hrs = hr(from: 0, seconds: 300, bpm: 55) + hr(from: 300, seconds: 1800, bpm: 150)
        let grav = still(from: 0, seconds: 300) + moving(from: 300, seconds: 1800)
        let s = try XCTUnwrap(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                                     restingHR: 55, maxHR: 190).first)
        XCTAssertEqual(s.zoneTimePct.values.reduce(0, +), 100, accuracy: 0.5)
        XCTAssertNotNil(s.avgHRRPct)
    }

    func testCaloriesOnlyWhenAProfileIsGiven() throws {
        let hrs = hr(from: 0, seconds: 300, bpm: 55) + hr(from: 300, seconds: 1800, bpm: 150)
        let grav = still(from: 0, seconds: 300) + moving(from: 300, seconds: 1800)
        let without = try XCTUnwrap(WorkoutDetector.detect(hr: hrs, gravity: grav,
                                                           restingHR: 55, maxHR: 190).first)
        XCTAssertNil(without.caloriesKcal)

        let with = try XCTUnwrap(WorkoutDetector.detect(
            hr: hrs, gravity: grav, restingHR: 55, maxHR: 190,
            profile: UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: "male")).first)
        XCTAssertNotNil(with.caloriesKcal)
        XCTAssertEqual(with.caloriesKJ!, with.caloriesKcal! * 4.184, accuracy: 1e-6)
    }
}
