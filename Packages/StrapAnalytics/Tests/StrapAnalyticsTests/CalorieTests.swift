import XCTest
import StrapProtocol
@testable import StrapAnalytics

private func hr(_ bpm: Int, count: Int, everyS: Int = 1) -> [HRSample] {
    (0..<count).map { HRSample(ts: $0 * everyS, bpm: bpm) }
}

final class CalorieTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: "male")

    func testHarderWorkBurnsMore() {
        let easy = Calories.estimateBoutCalories(hr(90, count: 600), profile: profile,
                                                 hrmax: 185, restingHR: 55).0
        let hard = Calories.estimateBoutCalories(hr(160, count: 600), profile: profile,
                                                 hrmax: 185, restingHR: 55).0
        XCTAssertGreaterThan(hard, easy)
    }

    func testKjIsKcalTimesTheConversion() {
        let (kcal, kj) = Calories.estimateBoutCalories(hr(140, count: 600), profile: profile,
                                                       hrmax: 185, restingHR: 55)
        XCTAssertEqual(kj, kcal * 4.184, accuracy: 1e-9)
    }

    func testASparseStreamIsNotUndercounted() {
        // Summing one second per sample is only correct at 1 Hz; a 30 s cadence would collapse a
        // real session toward a couple of kcal.
        let dense = hr(150, count: 600, everyS: 1)
        let sparse = hr(150, count: 20, everyS: 30)
        let d = Calories.estimateBoutCalories(dense, profile: profile, hrmax: 185, restingHR: 55).0
        let s = Calories.estimateBoutCalories(sparse, profile: profile, hrmax: 185, restingHR: 55).0
        XCTAssertEqual(s, d, accuracy: d * 0.05, "same ten minutes, same energy")
    }

    func testAWearGapCannotInflateOneReading() {
        var samples = hr(150, count: 10)
        samples.append(HRSample(ts: 10 + 6 * 3600, bpm: 150))
        let withGap = Calories.estimateBoutCalories(samples, profile: profile,
                                                    hrmax: 185, restingHR: 55).0
        let contiguous = Calories.estimateBoutCalories(hr(150, count: 200), profile: profile,
                                                       hrmax: 185, restingHR: 55).0
        XCTAssertLessThan(withGap, contiguous, "the gap is capped, not billed in full")
    }

    func testHeartRateAboveTheAssumedMaxIsCapped() {
        // Extrapolating the fit past its range produces a confident large number.
        let sane = Calories.estimateBoutCalories(hr(185, count: 600), profile: profile,
                                                 hrmax: 185, restingHR: 55).0
        let absurd = Calories.estimateBoutCalories(hr(300, count: 600), profile: profile,
                                                   hrmax: 185, restingHR: 55).0
        XCTAssertEqual(sane, absurd, accuracy: 1e-9)
    }

    func testTheDayGateIsHigherThanTheBoutGate() {
        // Over a day, ordinary standing and walking billed at an exercise rate inflates the total.
        XCTAssertGreaterThan(Calories.dayActiveHRRFraction, Calories.activeHRRFraction)
        let moderate = hr(110, count: 3600)   // above the bout gate, below the day gate
        let bout = Calories.estimateBoutCalories(moderate, profile: profile, hrmax: 185, restingHR: 55).0
        let day = Calories.estimateDayCalories(moderate, profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertGreaterThan(bout, day)
    }

    func testAWornSecondNeverBurnsLessThanRestingMetabolism() {
        // The Keytel fit dips below basal for some profiles just above the gate, which would make
        // a moderately active minute cost less than lying still.
        let light = UserProfile(weightKg: 45, heightCm: 150, age: 20, sex: "female")
        let active = Calories.estimateDayCalories(hr(150, count: 3600), profile: light,
                                                  hrmax: 190, restingHR: 55)
        let rest = Calories.estimateDayCalories(hr(50, count: 3600), profile: light,
                                                hrmax: 190, restingHR: 55)
        XCTAssertGreaterThanOrEqual(active, rest)
    }

    func testUnsetProfileFieldsFallBackRatherThanReadingAsZero() {
        // A zero weight is "unknown", not a weightless user.
        let empty = UserProfile(weightKg: 0, heightCm: 0, age: 0, sex: "")
        let kcal = Calories.estimateDayCalories(hr(60, count: 3600), profile: empty,
                                                hrmax: nil, restingHR: nil)
        XCTAssertGreaterThan(kcal, 0)
        XCTAssertLessThan(kcal, 1000, "an hour of resting metabolism, not a fabricated number")
    }

    func testNonbinaryUsesTheMidpointNotOneOfTheOthers() {
        let nb = Calories.resolveCoeffs("nonbinary")
        XCTAssertEqual(nb.workoutHR, (Calories.male.workoutHR + Calories.female.workoutHR) / 2,
                       accuracy: 1e-9)
        XCTAssertEqual(Calories.resolveCoeffs("unrecognised").workoutHR, nb.workoutHR,
                       "an unknown value falls to the midpoint, not to a default sex")
    }

    func testHeavierBurnsMoreAtRest() {
        let light = UserProfile(weightKg: 55, heightCm: 170, age: 30, sex: "male")
        let heavy = UserProfile(weightKg: 95, heightCm: 170, age: 30, sex: "male")
        let l = Calories.estimateDayCalories(hr(50, count: 3600), profile: light, hrmax: 190, restingHR: 55)
        let h = Calories.estimateDayCalories(hr(50, count: 3600), profile: heavy, hrmax: 190, restingHR: 55)
        XCTAssertGreaterThan(h, l)
    }

    func testEmptyStreams() {
        XCTAssertEqual(Calories.estimateDayCalories([], profile: profile, hrmax: 185, restingHR: 55), 0)
        XCTAssertEqual(Calories.estimateBoutCalories([], profile: profile, hrmax: 185, restingHR: 55).0, 0)
    }
}
