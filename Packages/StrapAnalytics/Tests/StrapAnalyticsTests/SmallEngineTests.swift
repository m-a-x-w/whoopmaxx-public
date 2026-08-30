import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class StressIndexTests: XCTestCase {

    func testTightlyClusteredBeatsScoreHigherThanSpreadOnes() throws {
        // The index measures histogram CONCENTRATION, which is a different question from
        // beat-to-beat change.
        let tight = (0..<200).map { 1000.0 + Double($0 % 3) }
        let spread = (0..<200).map { i -> Double in 1000.0 + Double((i * 37) % 300) - 150.0 }
        let t = try XCTUnwrap(StressIndex.stressIndex(rawRR: tight))
        let s = try XCTUnwrap(StressIndex.stressIndex(rawRR: spread))
        XCTAssertGreaterThan(t, s)
    }

    func testComponentsAreCoherent() throws {
        let c = try XCTUnwrap(StressIndex.components(rawRR: (0..<200).map { 900.0 + Double($0 % 40) }))
        XCTAssertGreaterThan(c.moSec, 0)
        XCTAssertGreaterThan(c.aMoPercent, 0)
        XCTAssertLessThanOrEqual(c.aMoPercent, 100)
        XCTAssertGreaterThan(c.mxDMnSec, 0)
        XCTAssertEqual(c.si, c.aMoPercent / (2 * c.moSec * c.mxDMnSec), accuracy: 1e-9)
    }

    func testPerfectlyEqualBeatsAreUndefinedNotEnormous() {
        // A zero variation range would divide to infinity.
        XCTAssertNil(StressIndex.stressIndex(rawRR: [Double](repeating: 1000, count: 100)))
    }

    func testTooFewBeats() {
        XCTAssertNil(StressIndex.stressIndex(rawRR: [Double](repeating: 1000, count: 5)))
        XCTAssertNil(StressIndex.stressIndex(rawRR: []))
    }

    func testCleaningHappensFirst() {
        // The index divides by the variation RANGE, so one artefact widens the range and drives
        // the result toward zero — the opposite of what the artefact implies.
        var beats = (0..<200).map { 1000.0 + Double($0 % 3) }
        let clean = StressIndex.stressIndex(rawRR: beats)!
        beats[100] = 5000                                   // impossible interval
        let dirty = StressIndex.stressIndex(rawRR: beats)!
        XCTAssertEqual(clean, dirty, accuracy: clean * 0.05)
    }

    func testTheRRIntervalOverloadAgrees() throws {
        let raw = (0..<200).map { 1000.0 + Double($0 % 20) }
        let rr = raw.enumerated().map { RRInterval(ts: $0.offset, rrMs: Int($0.element)) }
        XCTAssertEqual(try XCTUnwrap(StressIndex.stressIndex(rr: rr)),
                       try XCTUnwrap(StressIndex.stressIndex(rawRR: raw)), accuracy: 1e-9)
    }
}

final class TimeZoneShiftTests: XCTestCase {

    func testAnEastwardShift() {
        XCTAssertEqual(TimeZoneShift.shiftHours(homeOffsetSeconds: 0,
                                                destOffsetSeconds: 8 * 3600), 8, accuracy: 1e-9)
    }

    func testALongHaulTakesTheShortWayRound() {
        // Flying east 20 hours is flying west 4. Unwrapped, every long-haul trip would claim
        // roughly twice the adaptation burden the body actually faces.
        XCTAssertEqual(TimeZoneShift.normalizedShift(20), -4, accuracy: 1e-9)
        XCTAssertEqual(TimeZoneShift.normalizedShift(-20), 4, accuracy: 1e-9)
    }

    func testShiftStaysWithinHalfADay() {
        for raw in stride(from: -30.0, through: 30.0, by: 0.5) {
            let s = TimeZoneShift.normalizedShift(raw)
            XCTAssertLessThanOrEqual(s, 12.0001)
            XCTAssertGreaterThanOrEqual(s, -12.0001)
        }
    }

    func testNoShift() {
        XCTAssertEqual(TimeZoneShift.shiftHours(homeOffsetSeconds: -5 * 3600,
                                                destOffsetSeconds: -5 * 3600), 0, accuracy: 1e-9)
    }
}

final class HydrationGoalTests: XCTestCase {

    func testBaselinesBySex() {
        XCTAssertEqual(HydrationGoal.baselineForSex("male"), HydrationGoal.baselineMaleML)
        XCTAssertEqual(HydrationGoal.baselineForSex(" Female "), HydrationGoal.baselineFemaleML)
        XCTAssertEqual(HydrationGoal.baselineForSex("m"), HydrationGoal.baselineMaleML)
        XCTAssertEqual(HydrationGoal.baselineForSex(""), HydrationGoal.baselineOtherML,
                       "unset falls to the midpoint, not to a default sex")
        XCTAssertEqual(HydrationGoal.baselineForSex("nonbinary"), HydrationGoal.baselineOtherML)
    }

    func testEffortAddsButIsBounded() {
        // The baseline already covers ordinary activity; an unbounded bump would prescribe
        // implausible volumes after one hard session.
        XCTAssertEqual(HydrationGoal.effortBump(effort: 0), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: 100), HydrationGoal.maxEffortBumpML)
        XCTAssertEqual(HydrationGoal.effortBump(effort: 500), HydrationGoal.maxEffortBumpML)
        XCTAssertEqual(HydrationGoal.effortBump(effort: -20), 0)
    }

    func testANonFiniteEffortAddsNothing() {
        // A NaN here would make the whole goal unrenderable.
        XCTAssertEqual(HydrationGoal.effortBump(effort: .nan), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: .infinity), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: nil), 0)
    }

    func testGoalIsRoundedToAReadableStep() {
        // A target of 3,847 ml implies a precision nobody has.
        let g = HydrationGoal.dailyGoalML(sex: "male", effort: 47)
        XCTAssertEqual(g % HydrationGoal.roundToML, 0)
        XCTAssertGreaterThan(g, HydrationGoal.baselineMaleML)
    }

    func testRoundToNearest() {
        XCTAssertEqual(HydrationGoal.roundToNearest(3724, step: 50), 3700)
        XCTAssertEqual(HydrationGoal.roundToNearest(3725, step: 50), 3750)
        XCTAssertEqual(HydrationGoal.roundToNearest(100, step: 0), 100, "a zero step is a no-op")
    }

    func testProgressCannotOverfillOrInvert() {
        XCTAssertEqual(HydrationGoal.fraction(totalML: 0, goalML: 3000), 0)
        XCTAssertEqual(HydrationGoal.fraction(totalML: 1500, goalML: 3000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HydrationGoal.fraction(totalML: 9000, goalML: 3000), 1.0)
        XCTAssertEqual(HydrationGoal.fraction(totalML: -100, goalML: 3000), 0)
        XCTAssertEqual(HydrationGoal.fraction(totalML: 100, goalML: 0), 0, "no goal, no progress")
    }

    func testCardString() {
        XCTAssertEqual(HydrationGoal.cardValueString(totalML: 1500, goalML: 3000), "1.5 / 3.0 L")
    }

    func testCommonVolumesAreOrdered() {
        XCTAssertLessThan(HydrationGoal.sipML, HydrationGoal.cupML)
        XCTAssertLessThan(HydrationGoal.cupML, HydrationGoal.bottleML)
    }
}
