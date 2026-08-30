import XCTest
@testable import StrapAnalytics

final class ActivityCostTests: XCTestCase {

    /// Day `n` of a 120-day window starting 2026-01-01. Long enough that sessions spaced well
    /// apart still leave untouched days for a baseline — with a 7-day recovery window, four
    /// sessions block 32 days on their own.
    private func day(_ n: Int) -> String {
        CorrelationEngine.shiftDay("2026-01-01", by: n - 1)!
    }

    private func recovery(base: Double, overrides: [Int: Double] = [:]) -> [String: Double] {
        var out: [String: Double] = [:]
        for i in 1...120 { out[day(i)] = overrides[i] ?? base }
        return out
    }

    func testACostlySportIsMeasuredAgainstUntouchedDays() throws {
        let sessionDays = [1, 21, 41, 61, 81]
        var overrides: [Int: Double] = [:]
        for d in sessionDays { overrides[d + 1] = 50 }
        let costs = ActivityCostEngine.evaluate(
            activityDaysBySport: ["crossfit": Set(sessionDays.map(day))],
            recoveryByDay: recovery(base: 80, overrides: overrides))

        let c = try XCTUnwrap(costs.first)
        XCTAssertEqual(c.sport, "crossfit")
        XCTAssertEqual(c.meanNextMorning, 50, accuracy: 1e-9)
        XCTAssertEqual(c.baselineMean, 80, accuracy: 1e-9)
        XCTAssertEqual(c.delta, 30, accuracy: 1e-9)
        XCTAssertEqual(c.n, 5)
    }

    func testTheBaselineExcludesTheRecoveryWindow() throws {
        // The mornings after a session are exactly what a cost suppresses. Counting them as rest
        // contaminates the baseline with the thing being measured and understates every cost —
        // uniformly, in a way no single number looks wrong.
        let sessionDays = [1, 41, 81]
        var overrides: [Int: Double] = [:]
        for d in sessionDays { for k in 1...3 { overrides[d + k] = 40 } }
        let costs = ActivityCostEngine.evaluate(
            activityDaysBySport: ["hard": Set(sessionDays.map(day))],
            recoveryByDay: recovery(base: 85, overrides: overrides))
        // Only sessions with 3 tagged days — below minSessions — so nothing is reported, but the
        // baseline calculation itself is what this pins via the four-session case below.
        XCTAssertTrue(costs.isEmpty)

        let four = [1, 31, 61, 91]
        var o2: [Int: Double] = [:]
        for d in four { for k in 1...3 { o2[d + k] = 40 } }
        let c = try XCTUnwrap(ActivityCostEngine.evaluate(
            activityDaysBySport: ["hard": Set(four.map(day))],
            recoveryByDay: recovery(base: 85, overrides: o2)).first)
        XCTAssertEqual(c.baselineMean, 85, accuracy: 1e-9,
                       "the suppressed mornings never entered the baseline")
        XCTAssertEqual(c.delta, 45, accuracy: 1e-9)
    }

    func testAThinSportIsOmittedEntirely() {
        // Four sessions is already generous for a claim about how a workout affects you.
        let costs = ActivityCostEngine.evaluate(
            activityDaysBySport: ["rare": Set([day(1), day(40)])],
            recoveryByDay: recovery(base: 80))
        XCTAssertTrue(costs.isEmpty)
    }

    func testNoUntouchedDaysMeansNothingToSay() {
        // Every day tagged: no baseline exists, so no claim can be made.
        let all = Set((1...120).map(day))
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: ["everything": all],
                                                  recoveryByDay: recovery(base: 80)).isEmpty)
    }

    func testConfidenceLadder() throws {
        let five = [1, 21, 41, 61, 81]
        let c1 = try XCTUnwrap(ActivityCostEngine.evaluate(
            activityDaysBySport: ["s": Set(five.map(day))],
            recoveryByDay: recovery(base: 80)).first)
        XCTAssertEqual(c1.confidence, .building)

        let nine = [1, 11, 21, 31, 41, 51, 61, 71, 81]
        let c2 = try XCTUnwrap(ActivityCostEngine.evaluate(
            activityDaysBySport: ["s": Set(nine.map(day))],
            recoveryByDay: recovery(base: 80)).first)
        XCTAssertEqual(c2.confidence, .solid)
    }

    func testDaysToBaselineTracesForward() throws {
        // Poor the morning after, back to normal the day after that.
        let sessions = [1, 31, 61, 91]
        var overrides: [Int: Double] = [:]
        for d in sessions { overrides[d + 1] = 50 }
        let c = try XCTUnwrap(ActivityCostEngine.evaluate(
            activityDaysBySport: ["s": Set(sessions.map(day))],
            recoveryByDay: recovery(base: 80, overrides: overrides)).first)
        XCTAssertEqual(c.daysToBaseline, 2)
    }

    func testASportThatNeverRecoversInsideTheWindow() throws {
        let sessions = [1, 31, 61, 91]
        var overrides: [Int: Double] = [:]
        for d in sessions { for k in 1...7 where d + k <= 120 { overrides[d + k] = 30 } }
        let c = try XCTUnwrap(ActivityCostEngine.evaluate(
            activityDaysBySport: ["brutal": Set(sessions.map(day))],
            recoveryByDay: recovery(base: 85, overrides: overrides)).first)
        XCTAssertNil(c.daysToBaseline)
        XCTAssertFalse(c.sentence().contains("bounce back"))
    }

    func testRankingIsByAbsoluteImpactSoALiftIsNotBuried() {
        // A session that reliably lifts the next morning is as worth surfacing as one that costs.
        let costly = [1, 21, 41, 61], lifting = [81, 91, 101, 111]
        var overrides: [Int: Double] = [:]
        for d in costly { overrides[d + 1] = 55 }
        for d in lifting { overrides[d + 1] = 95 }
        let ranked = ActivityCostEngine.evaluate(
            activityDaysBySport: ["costly": Set(costly.map(day)), "yoga": Set(lifting.map(day))],
            recoveryByDay: recovery(base: 75, overrides: overrides))
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.map { abs($0.delta) }.sorted(by: >), ranked.map { abs($0.delta) })
        XCTAssertTrue(ranked.contains { $0.delta < 0 }, "the lift is present, not dropped")
    }

    func testRankingIsStableAcrossRuns() {
        let a = [1, 21, 41, 61], b = [81, 91, 101, 111]
        for _ in 0..<10 {
            let ranked = ActivityCostEngine.evaluate(
                activityDaysBySport: ["zebra": Set(a.map(day)), "apple": Set(b.map(day))],
                recoveryByDay: recovery(base: 80))
            XCTAssertEqual(ranked.map(\.sport), ["apple", "zebra"])
        }
    }

    func testEmptyInputs() {
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: [:],
                                                  recoveryByDay: recovery(base: 80)).isEmpty)
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: ["s": [day(1)]],
                                                  recoveryByDay: [:]).isEmpty)
    }
}

final class ActivityCostSentenceTests: XCTestCase {

    private func cost(delta: Double, days: Int?, n: Int = 6) -> ActivityCost {
        ActivityCost(sport: "run", delta: delta, meanNextMorning: 60, baselineMean: 60 + delta,
                     daysToBaseline: days, n: n, confidence: .building)
    }

    func testACostReadsAsACost() {
        let s = ActivityCostEngine.evaluate(activityDaysBySport: [:], recoveryByDay: [:])
        XCTAssertTrue(s.isEmpty)
        XCTAssertTrue(cost(delta: 12, days: 2).sentence().contains("cost you about 12 Charge points"))
        XCTAssertTrue(cost(delta: 12, days: 2).sentence().contains("2 days to bounce back"))
    }

    func testALiftReadsAsALift() {
        XCTAssertTrue(cost(delta: -8, days: nil).sentence().contains("lift about 8 Charge points"))
    }

    func testANegligibleEffectIsSaidPlainly() {
        // Reporting "0 Charge points" would look like a measurement rather than a shrug.
        let s = cost(delta: 0.4, days: 1).sentence()
        XCTAssertTrue(s.contains("barely move"))
        XCTAssertTrue(s.contains("n=6"))
    }

    func testSingularAndPlural() {
        XCTAssertTrue(cost(delta: 1, days: 1).sentence().contains("1 Charge point "))
        XCTAssertTrue(cost(delta: 1, days: 1).sentence().contains("1 day to bounce back"))
    }

    func testEverySentenceCarriesN() {
        XCTAssertTrue(cost(delta: 12, days: 2, n: 9).sentence().contains("n=9"))
        XCTAssertTrue(cost(delta: 0.2, days: nil, n: 9).sentence().contains("n=9"))
    }
}
