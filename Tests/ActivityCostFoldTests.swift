import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// ActivityCostFold (011 W1.6): the app-side fold between the two published caches and
/// `ActivityCostEngine`, and the empty-reason the engine itself cannot express.
///
/// Two things are pinned here that nothing else can pin. (1) Sport is FREE TEXT — catalogue picks,
/// WHOOP's concatenated camelCase, and hand relabels — so an unfolded key splits one sport's evidence
/// across three keys, each of which then falls under `minSessions` and vanishes. (2) `evaluate` answers
/// "your baseline is contaminated" and "you haven't logged four of anything" with the SAME `[]`, so the
/// fold has to test the baseline precondition itself or the screen prints the wrong sentence.
final class ActivityCostFoldTests: XCTestCase {

    // MARK: - Fixture helpers

    /// "2026-03-01" + i, through the same fixed-UTC stepper the engine joins on.
    private func dayKey(_ i: Int) -> String { ScoreEngine.shiftDay("2026-03-01", by: i)! }

    /// Midday LOCAL on `key` — the hour matters: `sportDays` tags a session on
    /// `Repository.logicalDayKey(startTs)`, and midday folds back to the same civil day in every zone and
    /// on both DST edges (a midnight stamp would not). Midday is also above the 04:00 rollover, so the
    /// logical and calendar keys agree here — which is why these fixtures cannot see the post-midnight
    /// behaviour and `testPostMidnightSessionTagsTheEveningItBelongsTo` exists.
    private func middayTs(_ key: String) throws -> Int {
        let start = try XCTUnwrap(DayKey.date(from: key))
        return Int(start.addingTimeInterval(12 * 3_600).timeIntervalSince1970)
    }

    private func workout(_ sport: String, onDay i: Int) throws -> WorkoutRow {
        let ts = try middayTs(dayKey(i))
        return Fixtures.workoutRow(startTs: ts, endTs: ts + 3_600, sport: sport, source: "manual")
    }

    // MARK: - Day tagging

    /// A 00:30 session belongs to the EVENING before it, not to the calendar day it happens to stamp.
    ///
    /// The engine reads a session's cost as `Charge[D + 1]` — the next morning. Tagged on its calendar
    /// day, a post-midnight session paired with the morning about thirty hours later, across a whole
    /// other night's sleep, while the morning it actually produced was excluded from that sport's mean.
    /// Every other fixture here is built at midday, where the logical and calendar keys agree, so
    /// nothing else in this file can catch a regression on this line.
    func testPostMidnightSessionTagsTheEveningItBelongsTo() throws {
        let key = dayKey(3)
        let start = try XCTUnwrap(DayKey.date(from: key))
        let ts = Int(start.addingTimeInterval(30 * 60).timeIntervalSince1970)   // 00:30 on `key`
        let rows = [Fixtures.workoutRow(startTs: ts, endTs: ts + 3_600,
                                        sport: "Running", source: "manual")]

        let days = try XCTUnwrap(ActivityCostFold.sportDays(rows).daysByKey["running"])
        XCTAssertEqual(days, Set([dayKey(2)]),
                       "a 00:30 session belongs to the previous logical day, so D+1 is the morning "
                       + "its own sleep produced — got \(days)")
        XCTAssertFalse(days.contains(key),
                       "tagging the calendar day pairs this session with a morning ~30 h away")
    }

    // MARK: - Sport keying

    func testCaseAndWhitespaceVariantsFoldToOneSport() throws {
        let rows = [try workout("Running", onDay: 0),
                    try workout("running", onDay: 2),
                    try workout("  Running  ", onDay: 4),
                    try workout("RUNNING", onDay: 6)]
        let folded = ActivityCostFold.sportDays(rows)

        XCTAssertEqual(folded.daysByKey.count, 1, "one sport in four spellings is one key")
        let days = try XCTUnwrap(folded.daysByKey["running"])
        XCTAssertEqual(days, Set([dayKey(0), dayKey(2), dayKey(4), dayKey(6)]),
                       "all four sessions must land under the folded key, not be split across it")
        // The LABEL is not the key: it keeps the user's own capitalisation (first spelling in the
        // newest-first cache), whitespace-collapsed.
        XCTAssertEqual(folded.labels["running"], "Running")
    }

    /// The relabel path: `WorkoutRepository.relabelDetected` writes the spaced spelling while the WHOOP
    /// import writes the concatenated one, so the two must key the same or a relabelled sport starts a
    /// second, thinner column of evidence.
    func testCamelCaseAndSpacedSpellingsAreTheSameSport() {
        XCTAssertEqual(ActivityCostFold.sportKey("TraditionalStrengthTraining"),
                       "traditional strength training")
        XCTAssertEqual(ActivityCostFold.sportKey("Traditional Strength Training"),
                       ActivityCostFold.sportKey("TraditionalStrengthTraining"))
    }

    // MARK: - The Charge fold

    func testDaysWithNoChargeAreAbsentNotZero() {
        let days = [Fixtures.dailyMetric(day: "2026-03-01", recovery: 55),
                    Fixtures.dailyMetric(day: "2026-03-02"),
                    Fixtures.dailyMetric(day: "2026-03-03", recovery: 61)]
        // A `?? 0` here would post a Charge of 0 on an unscored night and drag every baseline down.
        XCTAssertEqual(ActivityCostFold.recoveryByDay(days),
                       ["2026-03-01": 55, "2026-03-03": 61])
    }

    // MARK: - The two empties

    /// The trap: a user who trains at least every 7 days has NO day outside some session's
    /// D+1…D+7 after-effect window, the engine's baseline guard (`ActivityCostEngine.swift:149`) fires,
    /// and the answer is a bare `[]` that looks exactly like "not enough sessions".
    func testEveryScoredDayInsideAnAfterEffectWindowReadsAsNoRestDays() throws {
        let rows = try [0, 5, 10, 15, 20].map { try workout("Running", onDay: $0) }
        let days = (0...25).map { Fixtures.dailyMetric(day: dayKey($0), recovery: 60) }

        let bySport = ActivityCostFold.sportDays(rows).daysByKey
        let recovery = ActivityCostFold.recoveryByDay(days)
        XCTAssertEqual(bySport["running"]?.count, 5,
                       "5 tagged days clears minSessions — the [] below is NOT a thinness verdict")
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: bySport,
                                                  recoveryByDay: recovery).isEmpty,
                      "no untouched day → no baseline → the engine returns []")

        // The fold names WHICH empty it is, so the block prints the untouched-baseline line.
        XCTAssertFalse(ActivityCostFold.hasUntouchedDay(daysBySport: bySport, recoveryByDay: recovery))
        XCTAssertEqual(ActivityCostFold.readout(workouts: rows, days: days), .noRestDays)
    }

    /// The ordering that keeps the OTHER empty honest: with sessions but not one scored day,
    /// `hasUntouchedDay` is vacuously false, so an unguarded check would tell a user with no Charge
    /// history that every day carrying a Charge score is a session day.
    func testNoChargeHistoryReadsAsTooFewPairs() throws {
        let rows = [try workout("Running", onDay: 0), try workout("Running", onDay: 2)]
        let bySport = ActivityCostFold.sportDays(rows).daysByKey
        XCTAssertFalse(ActivityCostFold.hasUntouchedDay(daysBySport: bySport, recoveryByDay: [:]))
        XCTAssertEqual(ActivityCostFold.readout(workouts: rows, days: []), .tooFewPairs)
    }

    // MARK: - The minSessions gate, through the fold

    func testThreePairsAreOmittedAndFourAppear() throws {
        // Sessions live in days 0…12; their after-effect windows reach day 19, so days 20…49 are the
        // untouched baseline. Running's four next mornings sit 10 points under it, Yoga's do not matter.
        var rows = try [0, 2, 4, 6].map { try workout("Running", onDay: $0) }
        rows += try [8, 10, 12].map { try workout("Yoga", onDay: $0) }
        let runningMornings = Set([1, 3, 5, 7].map(dayKey))
        let yogaMornings = Set([9, 11, 13, 15].map(dayKey))
        let days = (0...49).map { i -> DailyMetric in
            let key = dayKey(i)
            if runningMornings.contains(key) { return Fixtures.dailyMetric(day: key, recovery: 60) }
            if yogaMornings.contains(key) { return Fixtures.dailyMetric(day: key, recovery: 65) }
            return Fixtures.dailyMetric(day: key, recovery: 70)
        }

        guard case .ranked(let ranked) = ActivityCostFold.readout(workouts: rows, days: days) else {
            return XCTFail("30 untouched days is a baseline — the readout must be .ranked")
        }
        XCTAssertEqual(ranked.map(\.label), ["Running"],
                       "Yoga's 3 next-morning pairs are under minSessions and it is omitted entirely")
        let running = try XCTUnwrap(ranked.first)
        XCTAssertEqual(running.cost.n, 4)
        XCTAssertEqual(running.cost.baselineMean, 70, accuracy: 0.001)
        XCTAssertEqual(running.cost.delta, 10, accuracy: 0.001)
        // The sign convention the row's chip inverts: a POSITIVE delta means the morning after sits
        // BELOW the baseline, and the engine's own sentence says so in words.
        XCTAssertTrue(running.cost.sentence().contains("cost you"), running.cost.sentence())

        // One more Yoga session — its 4th pair — and the sport appears. The gate is n, not the sport.
        rows.append(try workout("Yoga", onDay: 14))
        guard case .ranked(let widened) = ActivityCostFold.readout(workouts: rows, days: days) else {
            return XCTFail("adding a session must not remove the baseline")
        }
        XCTAssertEqual(widened.map(\.label), ["Running", "Yoga"],
                       "ranked by |delta|: Running's 10 points lead Yoga's smaller move")
        XCTAssertEqual(try XCTUnwrap(widened.last).cost.n, 4)
    }
}
