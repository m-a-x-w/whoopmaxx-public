import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class EffectRankerTests: XCTestCase {

    private func day(_ n: Int) -> String { CorrelationEngine.shiftDay("2026-01-01", by: n - 1)! }

    /// 60 days around `base`, with overrides on specific day numbers.
    ///
    /// Deliberately jittered: a constant series has zero variance in both groups, which makes
    /// Cohen's d undefined and drives it to 0 — see `testAPerfectlySeparatedEffectScoresZeroD`.
    private func outcome(base: Double, overrides: [Int: Double] = [:]) -> [String: Double] {
        var out: [String: Double] = [:]
        for i in 1...60 {
            let jitter = Double((i * 17) % 9) - 4.0
            out[day(i)] = (overrides[i] ?? base) + jitter
        }
        return out
    }

    func testANextMorningEffectIsFoundAtLagOne() throws {
        let behaviourDays = [2, 8, 14, 20, 26, 32, 38, 44]
        var overrides: [Int: Double] = [:]
        for d in behaviourDays { overrides[d + 1] = 45 }
        let r = try XCTUnwrap(EffectRanker.bestLag(behaviorDays: Set(behaviourDays.map(day)),
                                                   outcomeByDay: outcome(base: 80, overrides: overrides),
                                                   behavior: "alcohol", outcome: "Charge"))
        XCTAssertEqual(r.lag, 1)
        XCTAssertEqual(r.leadLagText, "next morning")
        XCTAssertTrue(r.sentence().contains("next morning"))
    }

    func testASameDayEffectIsFoundAtLagZero() throws {
        let behaviourDays = [2, 8, 14, 20, 26, 32, 38, 44]
        var overrides: [Int: Double] = [:]
        for d in behaviourDays { overrides[d] = 45 }
        let r = try XCTUnwrap(EffectRanker.bestLag(behaviorDays: Set(behaviourDays.map(day)),
                                                   outcomeByDay: outcome(base: 80, overrides: overrides),
                                                   behavior: "x", outcome: "Charge"))
        XCTAssertEqual(r.lag, 0)
        XCTAssertEqual(r.leadLagText, "same day")
    }

    func testALagOnlyCompetesWhenBothGroupsAreBigEnough() {
        // Searching several lags and keeping the best is a multiple-comparison problem in
        // miniature; without the group gate a two-day lag wins on a handful of days.
        let thin = [2, 8]
        var overrides: [Int: Double] = [:]
        for d in thin { overrides[d + 2] = 20 }
        XCTAssertNil(EffectRanker.bestLag(behaviorDays: Set(thin.map(day)),
                                          outcomeByDay: outcome(base: 80, overrides: overrides),
                                          behavior: "x", outcome: "Charge"))
    }

    func testAPerfectlySeparatedEffectScoresZeroD() {
        // A real edge, pinned: with zero variance in BOTH groups the pooled deviation is zero and
        // Cohen's d is undefined. It comes back 0, so a perfectly consistent effect sorts LAST in
        // any |d| ranking — even though its p is 0 and it is flagged significant. Real data always
        // carries variance; a synthetic or heavily rounded series can hit it.
        func flatDay(_ n: Int) -> String { day(n) }
        let behaviourDays = [2, 8, 14, 20, 26, 32, 38, 44]
        var o: [String: Double] = [:]
        for i in 1...60 { o[flatDay(i)] = behaviourDays.contains(i) ? 45 : 80 }
        let e = BehaviorInsights.effect(behaviorDays: Set(behaviourDays.map(day)),
                                        outcomeByDay: o, behavior: "x", outcome: "y")!
        XCTAssertEqual(e.meanWith, 45, accuracy: 1e-9)
        XCTAssertEqual(e.meanWithout, 80, accuracy: 1e-9)
        XCTAssertEqual(e.cohensD, 0, "undefined, reported as zero")
        XCTAssertTrue(e.significant, "and still significant, which is why rank keys on that first")
    }

    func testConfidenceLadder() {
        XCTAssertEqual(EffectRanker.confidence(forPairs: 2), .calibrating)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 7), .building)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 12), .solid)
    }

    func testShiftedOutcomeReKeysBackward() {
        let src = ["2026-01-02": 5.0]
        let shifted = EffectRanker.shiftedOutcome(src, byLag: 1)
        XCTAssertEqual(shifted["2026-01-01"], 5.0, "day 2's outcome belongs to day 1's behaviour")
        XCTAssertEqual(EffectRanker.shiftedOutcome(src, byLag: 0), src)
    }

    func testRankingIsDeterministicAndOrderedBySignificanceThenSize() {
        let a = [2, 8, 14, 20, 26, 32, 38, 44]
        let b = [3, 9, 15, 21, 27, 33, 39, 45]
        var overrides: [Int: Double] = [:]
        for d in a { overrides[d + 1] = 40 }
        let o = outcome(base: 80, overrides: overrides)
        let behaviours = ["alcohol": Set(a.map(day)), "zzz": Set(b.map(day))]

        var previous: [String]?
        for _ in 0..<10 {
            let ranked = EffectRanker.rank(behaviors: behaviours, outcomeByDay: o, outcome: "Charge")
            // Deterministic: a dictionary's iteration order must not reshuffle the list.
            if let previous { XCTAssertEqual(ranked.map(\.behavior), previous) }
            previous = ranked.map(\.behavior)

            // Significance first, then descending effect size — verified against the rows
            // themselves rather than against a hard-coded winner.
            for i in 1..<max(ranked.count, 1) {
                let lhs = ranked[i - 1], rhs = ranked[i]
                if lhs.effect.significant != rhs.effect.significant {
                    XCTAssertTrue(lhs.effect.significant)
                } else {
                    XCTAssertGreaterThanOrEqual(abs(lhs.effect.cohensD), abs(rhs.effect.cohensD))
                }
            }
        }
        XCTAssertEqual(previous?.count, 2)
    }

    func testLagIsNamedInTheSentence() {
        // "Alcohol lowers your Charge" and "...two mornings later" are different claims, and only
        // one of them is what was measured.
        let e = BehaviorEffect(behavior: "alcohol", outcome: "Charge", meanWith: 50, meanWithout: 80,
                               delta: -30, pctChange: -37.5, nWith: 8, nWithout: 40,
                               cohensD: -1.2, pApprox: 0.001, significant: true)
        let r = RankedEffect(behavior: "alcohol", outcome: "Charge", lag: 2,
                             effect: e, confidence: .solid)
        XCTAssertEqual(r.leadLagText, "2 mornings later")
        XCTAssertTrue(r.sentence().hasSuffix("(2 mornings later)."))
    }
}

final class DayOwnerResolverTests: XCTestCase {

    private func c(_ id: String, _ p: Int, _ hasData: Bool = true) -> DayOwnerResolver.Candidate {
        .init(deviceId: id, priority: p, hasData: hasData)
    }

    func testLowestPriorityWithDataWins() {
        XCTAssertEqual(DayOwnerResolver.resolve(day: "2026-01-01", lockedOwner: nil,
                                                candidates: [c("import", 2), c("strap", 0)]), "strap")
    }

    func testALockedOwnerShortCircuitsEverything() {
        // Locked means a person decided, and this resolver runs on a schedule.
        XCTAssertEqual(DayOwnerResolver.resolve(day: "2026-01-01", lockedOwner: "chosen",
                                                candidates: [c("strap", 0)]), "chosen")
    }

    func testACandidateWithNoDataCannotWinAndBlankTheDay() {
        XCTAssertEqual(DayOwnerResolver.resolve(day: "2026-01-01", lockedOwner: nil,
                                                candidates: [c("strap", 0, false), c("import", 2)]),
                       "import")
    }

    func testNoCandidates() {
        XCTAssertNil(DayOwnerResolver.resolve(day: "2026-01-01", lockedOwner: nil, candidates: []))
        XCTAssertNil(DayOwnerResolver.resolve(day: "2026-01-01", lockedOwner: nil,
                                              candidates: [c("a", 0, false)]))
    }
}

final class ManualRescoreTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: "male")

    private func samples(_ n: Int, bpm: Int) -> [HRSample] {
        (0..<n).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testAWorkoutSavedBeforeItsHeartRateArrivedLooksUnderScored() {
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: nil))
        XCTAssertTrue(ManualWorkoutRescore.looksUnderScored(currentKcal: 2))
        XCTAssertFalse(ManualWorkoutRescore.looksUnderScored(currentKcal: 400))
    }

    func testScoringNeedsAtLeastTwoSamples() {
        XCTAssertNil(ManualWorkoutRescore.scored(windowSamples: [], profile: profile, hrMax: 190))
        XCTAssertNotNil(ManualWorkoutRescore.scored(windowSamples: samples(600, bpm: 150),
                                                    profile: profile, hrMax: 190))
    }

    func testZeroEnergyIsNoEstimateRatherThanAnEstimateOfNothing() {
        let s = ManualWorkoutRescore.scored(windowSamples: samples(2, bpm: 60),
                                            profile: profile, hrMax: 190)!
        XCTAssertTrue(s.kcal == nil || s.kcal! > 0)
    }

    func testAMarginStopsFloatNoiseRewritingEveryPass() {
        let s = ManualWorkoutRescore.Scored(avgHr: 150, maxHr: 170, strain: 12, kcal: 300.5)
        XCTAssertFalse(ManualWorkoutRescore.improves(s, over: 300.0))
        XCTAssertTrue(ManualWorkoutRescore.improves(s, over: 250.0))
    }

    func testStrainOnlyFillIsOptInAndOnlyFillsAGap() {
        let s = ManualWorkoutRescore.Scored(avgHr: 150, maxHr: 170, strain: 12, kcal: 100)
        XCTAssertFalse(ManualWorkoutRescore.improves(s, over: 400, currentStrain: nil))
        XCTAssertTrue(ManualWorkoutRescore.improves(s, over: 400, currentStrain: nil,
                                                    allowStrainOnlyFill: true))
        XCTAssertFalse(ManualWorkoutRescore.improves(s, over: 400, currentStrain: 9,
                                                     allowStrainOnlyFill: true),
                       "a filled strain is not a gap")
    }

    func testStrainRewriteIsSeparatelyOptIn() {
        let s = ManualWorkoutRescore.Scored(avgHr: 150, maxHr: 170, strain: 12, kcal: 100)
        XCTAssertTrue(ManualWorkoutRescore.improves(s, over: 400, currentStrain: 9,
                                                    allowStrainRewrite: true))
    }
}

final class Spo2ReTraceTests: XCTestCase {

    func testEveryFieldIsRenderedIncludingAbsentOnes() {
        // A trace that omitted absent fields would be unparseable as a table.
        let line = Spo2ReTrace.recordLine(frame: [0xAA, 0x01], version: 24, unix: nil,
                                          red: 100, ir: nil, skinRaw: 830)
        XCTAssertTrue(line.contains("v=24"))
        XCTAssertTrue(line.contains("unix=null"))
        XCTAssertTrue(line.contains("ir=null"))
        XCTAssertTrue(line.contains("len=2"))
    }

    func testTheRawBytesAreAlwaysAppended() {
        // Without them the line cannot be re-decoded, which is the only reason it is written.
        let line = Spo2ReTrace.recordLine(frame: [0xAA, 0xFF], version: nil, unix: nil,
                                          red: nil, ir: nil, skinRaw: nil)
        XCTAssertTrue(line.hasSuffix("raw=aaff"))
    }
}
