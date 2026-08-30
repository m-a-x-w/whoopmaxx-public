import XCTest
@testable import StrapAnalytics

final class BehaviorEffectTests: XCTestCase {

    /// `n` days of `value`, keyed sequentially from day 1.
    private func days(_ n: Int, value: Double, from: Int = 1) -> [String: Double] {
        var out: [String: Double] = [:]
        for i in 0..<n { out[String(format: "2026-01-%02d", from + i)] = value }
        return out
    }

    private func keys(_ n: Int, from: Int = 1) -> Set<String> {
        Set((0..<n).map { String(format: "2026-01-%02d", from + $0) })
    }

    func testAClearEffectIsFound() throws {
        var outcome = days(10, value: 80, from: 1)              // without
        outcome.merge(days(10, value: 60, from: 11)) { a, _ in a }  // with
        let e = try XCTUnwrap(BehaviorInsights.effect(behaviorDays: keys(10, from: 11),
                                                      outcomeByDay: outcome,
                                                      behavior: "alcohol", outcome: "recovery"))
        XCTAssertEqual(e.meanWith, 60, accuracy: 1e-9)
        XCTAssertEqual(e.meanWithout, 80, accuracy: 1e-9)
        XCTAssertEqual(e.delta, -20, accuracy: 1e-9)
        XCTAssertEqual(e.pctChange!, -25, accuracy: 1e-9)
        XCTAssertTrue(e.significant)
    }

    func testOneLoggedDayIsNeverSignificant() {
        // Without a group floor, one evening against ninety days produces a tiny p and a
        // confident sentence.
        var outcome = days(90, value: 80, from: 1)
        outcome["2026-04-01"] = 20
        let e = BehaviorInsights.effect(behaviorDays: ["2026-04-01"], outcomeByDay: outcome,
                                        behavior: "x", outcome: "recovery")!
        XCTAssertEqual(e.nWith, 1)
        XCTAssertFalse(e.significant, "one day cannot carry a finding")
        XCTAssertLessThan(e.pApprox, 0.05, "even though the arithmetic says it could")
    }

    func testBothGroupsMustExist() {
        let outcome = days(10, value: 80)
        XCTAssertNil(BehaviorInsights.effect(behaviorDays: [], outcomeByDay: outcome,
                                             behavior: "x", outcome: "y"),
                     "a behaviour logged on no day has nothing to compare")
        XCTAssertNil(BehaviorInsights.effect(behaviorDays: keys(10), outcomeByDay: outcome,
                                             behavior: "x", outcome: "y"),
                     "a behaviour logged on every day has nothing to compare against")
    }

    func testTooFewPointsForAVarianceEstimate() {
        let outcome = ["2026-01-01": 50.0, "2026-01-02": 60.0]
        XCTAssertNil(BehaviorInsights.effect(behaviorDays: ["2026-01-01"], outcomeByDay: outcome,
                                             behavior: "x", outcome: "y"))
    }

    func testNoDifferenceIsReportedAsNone() throws {
        var outcome = days(10, value: 70, from: 1)
        outcome.merge(days(10, value: 70, from: 11)) { a, _ in a }
        let e = try XCTUnwrap(BehaviorInsights.effect(behaviorDays: keys(10, from: 11),
                                                      outcomeByDay: outcome,
                                                      behavior: "x", outcome: "recovery"))
        XCTAssertEqual(e.delta, 0)
        XCTAssertFalse(e.significant)
        XCTAssertEqual(e.pApprox, 1.0, "identical groups prove nothing")
    }

    func testAZeroBaselineHasNoPercentage() throws {
        var outcome = days(6, value: 0, from: 1)
        outcome.merge(days(6, value: 5, from: 11)) { a, _ in a }
        let e = try XCTUnwrap(BehaviorInsights.effect(behaviorDays: keys(6, from: 11),
                                                      outcomeByDay: outcome,
                                                      behavior: "x", outcome: "y"))
        XCTAssertNil(e.pctChange)
        XCTAssertEqual(e.delta, 5, accuracy: 1e-9, "the absolute change survives")
    }

    func testDegenerateGroupsDoNotProduceNaN() {
        // A NaN p would poison every sort that touches it.
        let e = BehaviorInsights.welchP(m1: 5, v1: 0, n1: 3, m2: 5, v2: 0, n2: 3)
        XCTAssertEqual(e, 1.0)
        XCTAssertEqual(BehaviorInsights.welchP(m1: 5, v1: 0, n1: 3, m2: 9, v2: 0, n2: 3), 0.0)
    }

    func testWelchDoesNotAssumeEqualVariance() {
        // The "with" group is usually smaller and more variable — people log unusual days — and
        // an equal-variance test would understate p exactly where evidence is thinnest.
        let tight = BehaviorInsights.welchP(m1: 60, v1: 1, n1: 10, m2: 65, v2: 1, n2: 10)
        let loose = BehaviorInsights.welchP(m1: 60, v1: 400, n1: 10, m2: 65, v2: 1, n2: 10)
        XCTAssertLessThan(tight, loose, "a noisy group earns a weaker claim")
    }

    func testCohensDIsZeroWithoutSpread() {
        XCTAssertEqual(BehaviorInsights.cohensD(m1: 5, m2: 9, n1: 3, v1: 0, n2: 3, v2: 0), 0)
    }

    func testSampleVariance() {
        XCTAssertEqual(BehaviorInsights.sampleVariance([2, 4, 6], mean: 4), 4, accuracy: 1e-9)
        XCTAssertEqual(BehaviorInsights.sampleVariance([5], mean: 5), 0)
    }
}

final class EffectRankingTests: XCTestCase {

    private func outcome(_ pairs: [(String, Double)]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    func testSignificantEffectsComeFirst() {
        var vals: [(String, Double)] = []
        for i in 1...10 { vals.append((String(format: "2026-01-%02d", i), 80)) }
        for i in 11...20 { vals.append((String(format: "2026-01-%02d", i), 50)) }
        let big = Set((11...20).map { String(format: "2026-01-%02d", $0) })
        let tiny = Set(["2026-01-01"])

        let ranked = BehaviorInsights.rank(behaviors: ["big": big, "tiny": tiny],
                                           outcomeByDay: outcome(vals), outcome: "recovery")
        XCTAssertEqual(ranked.first?.behavior, "big")
        XCTAssertTrue(ranked.first!.significant)
    }

    func testTiesBreakOnNameSoTheOrderIsStable() {
        // A dictionary's iteration order would otherwise reshuffle equal rows between launches.
        var vals: [(String, Double)] = []
        for i in 1...20 { vals.append((String(format: "2026-01-%02d", i), 70)) }
        let a = Set((1...5).map { String(format: "2026-01-%02d", $0) })
        let b = Set((6...10).map { String(format: "2026-01-%02d", $0) })
        for _ in 0..<10 {
            let ranked = BehaviorInsights.rank(behaviors: ["zebra": a, "apple": b],
                                               outcomeByDay: outcome(vals), outcome: "x")
            XCTAssertEqual(ranked.map(\.behavior), ["apple", "zebra"])
        }
    }

    func testBehavioursWithNoComparisonAreDropped() {
        var vals: [(String, Double)] = []
        for i in 1...10 { vals.append((String(format: "2026-01-%02d", i), 70)) }
        let everyDay = Set((1...10).map { String(format: "2026-01-%02d", $0) })
        let ranked = BehaviorInsights.rank(behaviors: ["always": everyDay],
                                           outcomeByDay: outcome(vals), outcome: "x")
        XCTAssertTrue(ranked.isEmpty)
    }
}

final class BehaviorSentenceTests: XCTestCase {

    private func effect(delta: Double, pct: Double?, nWith: Int = 8, nWithout: Int = 20) -> BehaviorEffect {
        BehaviorEffect(behavior: "alcohol", outcome: "recovery",
                       meanWith: 60, meanWithout: 60 - delta, delta: delta, pctChange: pct,
                       nWith: nWith, nWithout: nWithout, cohensD: 0.5, pApprox: 0.01, significant: true)
    }

    func testTheSentenceAlwaysQuotesBothGroupSizes() {
        // "18% lower" with no n reads as more authority than the data carries.
        let s = BehaviorInsights.sentence(effect(delta: -12, pct: -18))
        XCTAssertTrue(s.contains("n=8 vs 20"))
        XCTAssertTrue(s.contains("18% lower"))
        XCTAssertTrue(s.contains("alcohol"))
    }

    func testDirectionWording() {
        XCTAssertTrue(BehaviorInsights.sentence(effect(delta: 10, pct: 20)).contains("higher"))
        XCTAssertTrue(BehaviorInsights.sentence(effect(delta: -10, pct: -20)).contains("lower"))
        XCTAssertTrue(BehaviorInsights.sentence(effect(delta: 0, pct: 0)).contains("no different"))
    }

    func testFallsBackToAbsoluteUnitsWithoutAPercentage() {
        let s = BehaviorInsights.sentence(effect(delta: -12.5, pct: nil))
        XCTAssertTrue(s.contains("12.5 lower"))
    }
}
