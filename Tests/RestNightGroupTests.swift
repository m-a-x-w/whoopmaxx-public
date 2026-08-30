import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// The Rest screen used to resolve "last night" with a bare longest-span `max`, while every other
/// consumer — `analyzeDay`'s stage/efficiency rollup and `NapCredit`'s nap classification — goes through
/// `SleepGrouping.mainNightGroupIndices`. On a night the split-night bridge spans across several
/// fragments the max can only ever return ONE of them, so the hero showed the whole group's Asleep total
/// while the stage rows, hypnogram, bed/wake and arousal forensics described a single fragment.
final class RestNightGroupTests: XCTestCase {

    /// A stagesJSON payload of one light-sleep span, so `stageTotals` has something to sum.
    private func stages(from start: Int, to end: Int) -> String {
        "[{\"start\":\(start),\"end\":\(end),\"stage\":\"light\"}]"
    }

    private func session(_ start: Int, _ end: Int, efficiency: Double? = nil) -> CachedSleepSession {
        Fixtures.sleepSession(startTs: start, endTs: end, efficiency: efficiency,
                              stagesJSON: stages(from: start, to: end))
    }

    // MARK: - Selector

    /// A day with exactly one session: that session IS the night, and nothing is a nap.
    func testSingleSessionDayIsTheWholeNight() {
        let s = session(1_800_000_000, 1_800_025_200)
        let day = Repository.localDayKey(Date(timeIntervalSince1970: 1_800_025_200))

        let night = NapCredit.mainNightSessions(for: day, sleeps: [s])
        let naps = NapCredit.naps(for: day, sleeps: [s])

        XCTAssertEqual(night.count, 1)
        XCTAssertTrue(naps.isEmpty)
    }

    /// The invariant that makes the shared selector worth having: every session on a day lands in
    /// EXACTLY one lane. A session can never be both a nap row and part of the night.
    func testNightAndNapsPartitionTheDayExactly() {
        // Two overnight fragments plus a clear afternoon nap, all ending on the same local day.
        let base = 1_800_000_000
        let all = [session(base, base + 18_000),                 // 00:00–05:00-ish
                   session(base + 25_000, base + 39_000),        // after a ~2h gap
                   session(base + 60_000, base + 63_000)]        // short, much later
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(base + 63_000)))
        let onDay = all.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.endTs))) == day
        }

        let night = NapCredit.mainNightSessions(for: day, sleeps: onDay)
        let naps = NapCredit.naps(for: day, sleeps: onDay)

        let key: (CachedSleepSession) -> String = { "\($0.effectiveStartTs):\($0.endTs)" }
        let nightKeys = Set(night.map(key)), napKeys = Set(naps.map(key))
        XCTAssertTrue(nightKeys.isDisjoint(with: napKeys), "no session may be both night and nap")
        XCTAssertEqual(nightKeys.count + napKeys.count, onDay.count, "every session must land somewhere")
    }

    // MARK: - RestNight over a group

    /// The regression: a bridged night's hypnogram, bed and wake must span the WHOLE group.
    func testGroupNightSpansEveryFragment() {
        let base = 1_800_000_000
        let a = session(base, base + 18_000)
        let b = session(base + 25_000, base + 39_000)
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 533)

        let night = RestNight(day: day, score: 82, sessions: [a, b])

        XCTAssertEqual(night.bed, Date(timeIntervalSince1970: TimeInterval(base)),
                       "bed is the FIRST fragment's start")
        XCTAssertEqual(night.wake, Date(timeIntervalSince1970: TimeInterval(base + 39_000)),
                       "wake is the LAST fragment's end — not the longest fragment's")
        XCTAssertEqual(night.segments.count, 2, "the hypnogram covers every fragment")
    }

    /// Fragments arrive in whatever order the store hands them over; the group must sort itself.
    func testGroupIsOrderIndependent() {
        let base = 1_800_000_000
        let a = session(base, base + 18_000)
        let b = session(base + 25_000, base + 39_000)
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 533)

        let forward = RestNight(day: day, score: 82, sessions: [a, b])
        let reversed = RestNight(day: day, score: 82, sessions: [b, a])

        XCTAssertEqual(forward.bed, reversed.bed)
        XCTAssertEqual(forward.wake, reversed.wake)
        XCTAssertEqual(forward.segments.count, reversed.segments.count)
    }

    /// Stage totals sum ACROSS the group — the old single-fragment totals silently replaced the day's
    /// authoritative group-summed minutes.
    func testStageTotalsSumAcrossTheGroup() {
        let base = 1_800_000_000
        let a = session(base, base + 3_600)            // 60 min light
        let b = session(base + 7_200, base + 12_600)   // 90 min light
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 150)

        let night = RestNight(day: day, score: 80, sessions: [a, b])

        XCTAssertEqual(night.lightMin ?? 0, 150, accuracy: 0.01, "60 + 90, not just the longer fragment")
    }

    /// The out-of-bed gap between fragments is awake time, and `analyzeDay` already folds it into the
    /// day's waso — so the awake row must not under-report it.
    func testInterFragmentGapCountsAsAwake() {
        let base = 1_800_000_000
        let a = session(base, base + 3_600)
        let b = session(base + 7_200, base + 12_600)   // a 60-minute gap after `a`
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 150)

        let night = RestNight(day: day, score: 80, sessions: [a, b])

        XCTAssertEqual(night.wakeMin ?? 0, 60, accuracy: 0.01, "the 60-minute out-of-bed gap is awake time")
    }

    /// A single-fragment night must be byte-identical to the old single-session path — that is what
    /// keeps every existing RestNight test meaningful.
    func testSingleFragmentMatchesTheLegacyInitializer() {
        let base = 1_800_000_000
        let s = session(base, base + 25_200, efficiency: 0.91)
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 420)

        let legacy = RestNight(day: day, score: 82, session: s)
        let group = RestNight(day: day, score: 82, sessions: [s])

        XCTAssertEqual(legacy.bed, group.bed)
        XCTAssertEqual(legacy.wake, group.wake)
        XCTAssertEqual(legacy.efficiency, group.efficiency)
        XCTAssertEqual(legacy.deepMin, group.deepMin)
        XCTAssertEqual(legacy.remMin, group.remMin)
        XCTAssertEqual(legacy.lightMin, group.lightMin)
        XCTAssertEqual(legacy.wakeMin, group.wakeMin)
        XCTAssertEqual(legacy.segments.count, group.segments.count)
    }

    /// No sessions at all: the day row still drives the hero, exactly as before.
    func testEmptyGroupFallsBackToTheDayRow() {
        let day = Fixtures.dailyMetric(day: "2026-08-01", totalSleepMin: 420, deepMin: 90, remMin: 100)

        let night = RestNight(day: day, score: 82, sessions: [])

        XCTAssertNil(night.bed)
        XCTAssertNil(night.wake)
        XCTAssertEqual(night.deepMin, 90)
        XCTAssertEqual(night.remMin, 100)
        XCTAssertTrue(night.segments.isEmpty)
    }
}
