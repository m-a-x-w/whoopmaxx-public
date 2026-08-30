import XCTest
import StrapProtocol
@testable import StrapAnalytics

private func hr(_ bpm: Int, count: Int, everyS: Int = 1, from: Int = 0) -> [HRSample] {
    (0..<count).map { HRSample(ts: from + $0 * everyS, bpm: bpm) }
}

final class StrainScorerTests: XCTestCase {

    func testEffortIsRelativeToTheReserveNotRawBpm() {
        // The whole point of a personal score: the same bpm is different work for two people.
        //
        // At a FIXED absolute bpm the higher resting rate scores LOWER, and that is correct — the
        // reserve shrinks from the bottom, so 140 sits a smaller distance ABOVE resting even
        // though the span above it is narrower. (140-45)/145 = 65% against (140-75)/115 = 57%.
        let stream = hr(140, count: 700)
        let lowResting = StrainScorer.strain(stream, maxHR: 190, restingHR: 45)!
        let highResting = StrainScorer.strain(stream, maxHR: 190, restingHR: 75)!
        XCTAssertGreaterThan(lowResting, highResting)
        XCTAssertNotEqual(lowResting, highResting, accuracy: 0.5,
                          "the same bpm must not score identically for different people")
    }

    func testPctHRRIsClamped() {
        // Below resting is not negative effort; above the assumed max means the assumption is
        // wrong, not that the person exceeded their physiology.
        XCTAssertEqual(StrainScorer.pctHRR(30, restingHR: 60, hrReserve: 130), 0)
        XCTAssertEqual(StrainScorer.pctHRR(999, restingHR: 60, hrReserve: 130), 100)
        XCTAssertEqual(StrainScorer.pctHRR(125, restingHR: 60, hrReserve: 130), 50, accuracy: 0.001)
    }

    func testZoneWeightsFollowTheLadder() {
        let (rest, reserve) = (60.0, 100.0)
        XCTAssertEqual(StrainScorer.zoneWeight(100, restingHR: rest, hrReserve: reserve), 0, "under 50%")
        XCTAssertEqual(StrainScorer.zoneWeight(115, restingHR: rest, hrReserve: reserve), 1)
        XCTAssertEqual(StrainScorer.zoneWeight(125, restingHR: rest, hrReserve: reserve), 2)
        XCTAssertEqual(StrainScorer.zoneWeight(135, restingHR: rest, hrReserve: reserve), 3)
        XCTAssertEqual(StrainScorer.zoneWeight(145, restingHR: rest, hrReserve: reserve), 4)
        XCTAssertEqual(StrainScorer.zoneWeight(155, restingHR: rest, hrReserve: reserve), 5)
    }

    func testZeroReserveDoesNotDivideByZero() {
        XCTAssertEqual(StrainScorer.pctHRR(100, restingHR: 60, hrReserve: 0), 0)
        XCTAssertEqual(StrainScorer.zoneWeight(100, restingHR: 60, hrReserve: 0), 0)
        XCTAssertNil(StrainScorer.strain(hr(140, count: 700), maxHR: 60, restingHR: 60))
    }

    func testAWearGapIsNotCreditedAsEffort() {
        // Uncapped, one sample either side of a six-hour gap is credited with six hours of load
        // and can max out the day on its own.
        var stream = hr(150, count: 300)
        stream += hr(150, count: 300, from: 300 + 6 * 3600)
        let durs = StrainScorer.intervalMinutes(stream)
        XCTAssertEqual(durs.max()!, StrainScorer.mergeGapS / 60.0, accuracy: 1e-9)
    }

    func testTheFinalSampleIsCappedToo() {
        // The tail cap compares seconds against seconds; comparing minutes against 150 would
        // silently never trigger.
        let sparse = hr(150, count: 30, everyS: 3600)
        XCTAssertEqual(StrainScorer.intervalMinutes(sparse).last!,
                       StrainScorer.mergeGapS / 60.0, accuracy: 1e-9)
    }

    func testTrimpToStrainIsMonotonicAndBounded() {
        var last = -1.0
        for t in [0.0, 1, 10, 100, 1000, 7201, 100_000] {
            let s = StrainScorer.trimpToStrain(t)
            XCTAssertGreaterThanOrEqual(s, last)
            XCTAssertLessThanOrEqual(s, StrainScorer.maxStrain)
            last = s
        }
        XCTAssertEqual(StrainScorer.trimpToStrain(0), 0)
        XCTAssertEqual(StrainScorer.trimpToStrain(StrainScorer.strainDenominator - 1),
                       StrainScorer.maxStrain, accuracy: 0.01)
    }

    func testLogScaleKeepsEasyDaysDistinguishable() {
        // Linear mapping would flatten every ordinary day against one extreme one.
        let easy = StrainScorer.trimpToStrain(50)
        let moderate = StrainScorer.trimpToStrain(200)
        XCTAssertGreaterThan(moderate - easy, 5, "ordinary days stay visibly apart")
    }

    func testNoDataScoresNilNotZero() {
        // A day with no data and a day spent resting are different facts.
        XCTAssertNil(StrainScorer.strain([]))
        XCTAssertNil(StrainScorer.strain(hr(60, count: 5)))
        XCTAssertEqual(StrainScorer.strain(hr(50, count: 700), maxHR: 190, restingHR: 60), 0,
                       "a real day spent below the first zone scores zero, and that is a measurement")
    }

    func testASparseButSustainedStreamStillScores() {
        // Some straps report every ~30 s; rejecting those blanks the score for a device family.
        let sparse = hr(150, count: 25, everyS: 30)
        XCTAssertNotNil(StrainScorer.strain(sparse, maxHR: 190, restingHR: 60))
    }

    func testSparseAndBriefIsStillRefused() {
        XCTAssertNil(StrainScorer.strain(hr(150, count: 25, everyS: 1), maxHR: 190, restingHR: 60))
    }

    func testBanisterIsSmoothWhereEdwardsSteps() {
        // Near a zone boundary a single bpm changes an Edwards minute by a whole weight.
        // maxHR 190 / resting 60 puts the 70% zone edge at 151 bpm, so this pair straddles it.
        let below = hr(150, count: 700)
        let above = hr(152, count: 700)
        func jump(_ m: StrainScorer.Method) -> Double {
            abs(StrainScorer.strain(above, maxHR: 190, restingHR: 60, method: m)!
              - StrainScorer.strain(below, maxHR: 190, restingHR: 60, method: m)!)
        }
        XCTAssertLessThan(jump(.banister), jump(.edwards))
    }

    func testBanisterUsesTheSexSpecificConstant() {
        let stream = hr(150, count: 700)
        let m = StrainScorer.strain(stream, maxHR: 190, restingHR: 60, method: .banister, sex: "male")!
        let f = StrainScorer.strain(stream, maxHR: 190, restingHR: 60, method: .banister, sex: "female")!
        XCTAssertNotEqual(m, f, accuracy: 0)
    }

    func testDefaultMaxHR() {
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 30), 190)
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 50), 170)
    }

    func testPercentileInterpolates() {
        let xs = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(StrainScorer.percentile(xs, 0), 1)
        XCTAssertEqual(StrainScorer.percentile(xs, 100), 5)
        XCTAssertEqual(StrainScorer.percentile(xs, 50), 3, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([], 50), 0)
        XCTAssertEqual(StrainScorer.percentile([7], 99), 7)
    }
}
