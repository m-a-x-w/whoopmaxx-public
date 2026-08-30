import XCTest
import StrapStore
@testable import whoopmaxx

/// The Sleep Regularity Index (011 W2.1) is the first number this app derives from sleep TIMING rather
/// than from a stream, and every way it can go wrong is a way of printing something that was not
/// measured. These pin the four rules that stop that:
///
/// 1. **The usability gate earns its keep.** A day with no banked night takes BOTH of its comparisons
///    with it instead of scoring as a night spent awake. The gated / ungated split is pinned over one
///    corpus-shaped fixture, so a later "simplification" that drops the gate moves a number a test
///    watches rather than a number nobody watches.
/// 2. **DST minutes are not fabricated.** A 23 h day has 60 slots that never happen and a 25 h day has
///    60 that happen twice; both must leave the comparison at 1380 minutes rather than 1440, and must
///    not manufacture a disagreement for a sleeper who did not change anything.
/// 3. **Naps count.** The index is over sleep/wake state, not over the main night, so an afternoon hour
///    on one day of a pair has to move that pair.
/// 4. **Timing, not staging.** `sleepStateSample` holds 0 rows and `sleepSession.sleepStateJSON` is
///    NULL on every real session, so the index is built on `(startTs, endTs)` alone — a session whose
///    `stagesJSON` contradicts its own bounds must change nothing.
///
/// Every expected value below is derived by hand from the fixture's minute masks (each fixture states
/// its own arithmetic), never by running the code under test.
final class SleepRegularityTests: XCTestCase {

    // MARK: - Calendar / instants
    //
    // A FIXED zone, driven through the injected calendar rather than by overriding the process zone —
    // the `DstDayKeyTests` precedent, and the reason `SleepRegularity` takes a `Calendar` at all.

    private static let zone = TimeZone(identifier: "America/New_York")!

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.zone
        return c
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = SleepRegularityTests.zone
        return f
    }()

    /// The `now` every fixture reads against. `analyze` and `series` refuse to grid a minute that has
    /// not happened yet, so a fixture dated after the wall clock would grid as entirely unmeasured —
    /// which is exactly how the 25 h November window failed when that refusal landed. Pinning it here
    /// keeps every case below deterministic whatever day the suite is run on; the refusal itself is
    /// exercised deliberately in `testMinutesThatHaveNotHappenedYetAreNotMeasuredWake`.
    private static let fixtureNow = Date(timeIntervalSince1970: 1_830_000_000)   // 2028-01-01

    /// A wall-clock instant on `key`, in the fixture zone. Built from date COMPONENTS, so a fixture
    /// time is the time the user would have read off a clock.
    private func instant(_ key: String, _ hour: Int, _ minute: Int = 0) -> Int {
        let p = key.split(separator: "-").compactMap { Int($0) }
        let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2],
                                              hour: hour, minute: minute))!
        return Int(d.timeIntervalSince1970)
    }

    /// `count` consecutive day keys starting at `start`, stepped by CALENDAR day so a DST date is not
    /// skipped. Deliberately not `SleepRegularity.shift` — the fixture must not be built by the code
    /// it is testing.
    private func keys(from start: String, count: Int) -> [String] {
        var out: [String] = []
        var date = Self.keyFormatter.date(from: start)!
        for _ in 0..<count {
            out.append(Self.keyFormatter.string(from: date))
            date = cal.date(byAdding: .day, value: 1, to: date)!
        }
        return out
    }

    private func shiftKey(_ key: String, by delta: Int) -> String {
        let d = Self.keyFormatter.date(from: key)!
        return Self.keyFormatter.string(from: cal.date(byAdding: .day, value: delta, to: d)!)
    }

    private func banked(_ keys: [String], missing: Set<String> = []) -> [DailyMetric] {
        keys.map { Fixtures.dailyMetric(day: $0, totalSleepMin: missing.contains($0) ? nil : 480) }
    }

    private struct NotAReading: Error { let got: String }

    private func reading(_ outcome: SleepRegularity.Outcome?,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> SleepRegularity.Reading {
        guard case .reading(let r)? = outcome else {
            XCTFail("expected a reading, got \(String(describing: outcome))", file: file, line: line)
            throw NotAReading(got: String(describing: outcome))
        }
        return r
    }

    // MARK: - The corpus-shaped fixture
    //
    // Eighteen nights with a hole on the fifteenth — the shape of the real 2026-07-15 (a 12.5 h gap
    // documented at `Repository.swift:48-52`), which is the day the plan's own replay found the gate
    // was worth several points on.
    //
    // The sleeper alternates by two hours, which is what puts the index in the sixties rather than at
    // 100. Odd-numbered days sleep 00:00–06:00 (from the previous evening's 22:00 start); even days
    // sleep 00:00–08:00 and start again at 22:00. So, in minute-of-day slots:
    //
    //   odd  day → asleep {0…359}                       = 360 minutes
    //   even day → asleep {0…479} ∪ {1320…1439}         = 600 minutes
    //
    // An odd/even pair therefore differs on {360…479} ∪ {1320…1439} = 240 minutes, agreeing on 1200 of
    // 1440. Day 15 is emptied by truncating the night before it at midnight and starting the night
    // after it at midnight, so it banks NO sleep and is fully awake; each of its two pairs differs on
    // all 600 of its neighbour's asleep minutes, agreeing on 840.
    //
    //   GATED   — day 15 unusable, so its two pairs drop:  15 × 1200 / (15 × 1440) → 200·(5/6) − 100 = 66.67
    //   UNGATED — all 17 pairs count: (15 × 1200 + 840 + 840) / (17 × 1440) = 19680/24480 → 60.78

    private static let corpusDays = 18
    private static let holeIndex = 15          // 1-based, i.e. 2026-07-15

    private func corpusKey(_ index: Int) -> String {
        index == 0 ? "2026-06-30" : String(format: "2026-07-%02d", index)
    }

    /// The 19 sessions behind the fixture, indexes 0…18. Even `k` is an evening start, odd `k` a
    /// midnight start; `k == holeIndex − 1` is truncated at midnight so day 15 banks nothing.
    private var corpusSessions: [CachedSleepSession] {
        (0...Self.corpusDays).map { k -> CachedSleepSession in
            if k == Self.holeIndex - 1 {
                return Fixtures.sleepSession(startTs: instant(corpusKey(k), 22),
                                             endTs: instant(corpusKey(k + 1), 0))
            }
            if k % 2 == 0 {
                return Fixtures.sleepSession(startTs: instant(corpusKey(k), 22),
                                             endTs: instant(corpusKey(k + 1), 6))
            }
            return Fixtures.sleepSession(startTs: instant(corpusKey(k + 1), 0),
                                         endTs: instant(corpusKey(k + 1), 8))
        }
    }

    private var corpusKeys: [String] { (1...Self.corpusDays).map(corpusKey) }

    private func corpusOutcome(gated: Bool) -> SleepRegularity.Outcome? {
        let missing = gated ? Set([corpusKey(Self.holeIndex)]) : Set<String>()
        return SleepRegularity.analyze(days: banked(corpusKeys, missing: missing),
                                       sleeps: corpusSessions,
                                       endKey: corpusKey(Self.corpusDays),
                                       windowDays: Self.corpusDays,
                                       now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true)
    }

    /// THE GATE'S VALUE, pinned on both sides of it. Same 19 sessions, same 18 days; the ONLY
    /// difference is whether day 15 is allowed to claim a banked night.
    func testTheUsabilityGateIsWorthTheDifferenceBetweenSixtySevenAndSixtyOne() throws {
        let gated = try reading(corpusOutcome(gated: true))
        let ungated = try reading(corpusOutcome(gated: false))

        XCTAssertEqual(gated.sri, 200.0 * 18_000 / 21_600 - 100, accuracy: 0.001)   // 66.67
        XCTAssertEqual(gated.sri, 66.667, accuracy: 0.001)
        XCTAssertEqual(ungated.sri, 200.0 * 19_680 / 24_480 - 100, accuracy: 0.001) // 60.78
        XCTAssertEqual(ungated.sri, 60.784, accuracy: 0.001)
        XCTAssertGreaterThan(gated.sri - ungated.sri, 5,
                             "the gate is not decoration — dropping it moves the index by ~6 points")
    }

    /// The unbanked night takes BOTH of its comparisons, not one, and the honesty line's two counts
    /// describe the window rather than the pairs.
    func testAnUnbankedNightRemovesBothOfItsComparisons() throws {
        let outcome = corpusOutcome(gated: true)
        let gated = try reading(outcome)
        XCTAssertEqual(gated.pairs.count, 15, "17 adjacent pairs minus the two touching day 15")
        XCTAssertEqual(gated.nightsUsable, 17)
        XCTAssertEqual(gated.nightsConsidered, 18)
        // The copy hangs off the OUTCOME, not the reading — it has a calibrating case to spell too.
        XCTAssertEqual(outcome?.detailLine, "17 of 18 nights compared. "
                       + "Naps count; a night with no banked sleep is left out.")

        // No pair is filed under the hole day or the day after it — those are the two that were dropped.
        let filed = Set(gated.pairs.map(\.dayKey))
        XCTAssertFalse(filed.contains(corpusKey(Self.holeIndex)))
        XCTAssertFalse(filed.contains(corpusKey(Self.holeIndex + 1)))

        // Every surviving pair is a whole ordinary day, and every one is the 1200/1440 alternation.
        XCTAssertEqual(gated.pairs.reduce(0) { $0 + $1.compared }, 21_600)
        XCTAssertTrue(gated.pairs.allSatisfy { $0.agreeing == 1_200 && $0.compared == 1_440 })

        // The ungated control keeps them, and they are the two bad ones (840 of 1440).
        let ungated = try reading(corpusOutcome(gated: false))
        XCTAssertEqual(ungated.pairs.count, 17)
        XCTAssertEqual(ungated.pairs.filter { $0.agreeing == 840 }.count, 2)
    }

    /// The persisted `sleep_regularity` series is the SAME reading rolled forward a day at a time, and
    /// it withholds rather than placeholding: a day whose trailing window holds fewer than
    /// `minimumPairs` comparisons is absent from the map, never a 0 (which on this scale is a real
    /// reading — the two nights agreed on exactly half the day).
    func testTheSeriesWithholdsUntilTheWindowHasEnoughComparisons() throws {
        let series = SleepRegularity.series(days: banked(corpusKeys, missing: [corpusKey(Self.holeIndex)]),
                                            sleeps: corpusSessions,
                                            dayKeys: corpusKeys,
                                            now: Self.fixtureNow, calendar: cal)
        // Day 8 is the first with 7 comparisons behind it (pairs 2→8); day 7 has only 6.
        XCTAssertNil(series["2026-07-07"], "6 comparisons is below the floor")
        XCTAssertNotNil(series["2026-07-08"], "7 comparisons clears it")
        XCTAssertEqual(series.count, 11, "days 8…18 inclusive")
        XCTAssertFalse(series.keys.contains { $0 < "2026-07-08" })
        // The newest day's 14-night window holds pairs 5…18 minus the two the hole removed — 12
        // ordinary 1200/1440 pairs, so the same 66.67 the whole-record gated reading gives.
        XCTAssertEqual(try XCTUnwrap(series["2026-07-18"]), 66.667, accuracy: 0.001)
    }

    // MARK: - DST
    //
    // Both premises are asserted before they are relied on, so a tzdata change fails loudly instead of
    // quietly testing an ordinary day.

    /// A regular sleeper: asleep 23:00 → 07:00 every night of `keys`, plus the night before the first
    /// so day one has a morning too. Every day's mask is {0…419} ∪ {1380…1439}.
    private func regularSessions(_ keys: [String]) -> [CachedSleepSession] {
        ([shiftKey(keys[0], by: -1)] + keys).map {
            Fixtures.sleepSession(startTs: instant($0, 23), endTs: instant(shiftKey($0, by: 1), 7))
        }
    }

    private func dayLength(_ key: String) -> TimeInterval {
        let start = cal.startOfDay(for: Self.keyFormatter.date(from: key)!)
        return cal.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince(start)
    }

    /// Spring forward: the hour 02:00–02:59 never happens, so 60 slots do not exist and must not be
    /// counted. A sleeper who changed nothing must still read 100 — the missing minutes are dropped,
    /// not scored as a disagreement.
    func testAtwentyThreeHourDayComparesThirteenHundredAndEightyMinutes() throws {
        XCTAssertEqual(dayLength("2026-03-08"), 23 * 3_600,
                       "2026-03-08 must be the 23 h day in \(Self.zone.identifier)")
        let window = keys(from: "2026-03-02", count: 14)
        let r = try reading(SleepRegularity.analyze(days: banked(window),
                                                    sleeps: regularSessions(window),
                                                    endKey: window.last, windowDays: 14, now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
        XCTAssertEqual(r.pairs.count, 13)
        let shortened = r.pairs.filter { $0.compared == SleepRegularity.slotsPerDay - 60 }
        XCTAssertEqual(Set(shortened.map(\.dayKey)), ["2026-03-08", "2026-03-09"],
                       "only the pairs that touch the short day lose minutes")
        XCTAssertEqual(r.pairs.count - shortened.count, 11)
        XCTAssertTrue(r.pairs.allSatisfy { $0.agreeing == $0.compared },
                      "a sleeper who changed nothing must not be handed a disagreement by the clock")
        XCTAssertEqual(r.sri, 100, accuracy: 0.0001)
    }

    /// Fall back: the hour 01:00–01:59 happens twice, and which of the two a timestamp belongs to is
    /// not knowable from the timestamp. Those 60 slots are dropped for the same reason the missing ones
    /// are — the alternative is picking one and calling it measured.
    func testATwentyFiveHourDayDropsItsRepeatedHourRatherThanGuessing() throws {
        XCTAssertEqual(dayLength("2026-11-01"), 25 * 3_600,
                       "2026-11-01 must be the 25 h day in \(Self.zone.identifier)")
        let window = keys(from: "2026-10-26", count: 14)
        let r = try reading(SleepRegularity.analyze(days: banked(window),
                                                    sleeps: regularSessions(window),
                                                    endKey: window.last, windowDays: 14, now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
        XCTAssertEqual(r.pairs.count, 13)
        let shortened = r.pairs.filter { $0.compared == SleepRegularity.slotsPerDay - 60 }
        XCTAssertEqual(Set(shortened.map(\.dayKey)), ["2026-11-01", "2026-11-02"])
        XCTAssertTrue(r.pairs.allSatisfy { $0.agreeing == $0.compared })
        XCTAssertEqual(r.sri, 100, accuracy: 0.0001)
    }

    // MARK: - Naps, and what the input actually is

    /// Ten identical nights: every day's mask is {0…419} ∪ {1380…1439}, so all nine pairs agree on all
    /// 1440 minutes and the index is exactly 100.
    private var tenIdenticalNights: (days: [DailyMetric], sleeps: [CachedSleepSession], keys: [String]) {
        let window = keys(from: "2026-07-01", count: 10)
        return (banked(window), regularSessions(window), window)
    }

    private func tenNightOutcome(extra: [CachedSleepSession] = [],
                                 stagesJSON: String? = nil) -> SleepRegularity.Outcome? {
        let base = tenIdenticalNights
        let sleeps = base.sleeps.map {
            Fixtures.sleepSession(startTs: $0.startTs, endTs: $0.endTs, stagesJSON: stagesJSON)
        } + extra
        return SleepRegularity.analyze(days: base.days, sleeps: sleeps,
                                       endKey: base.keys.last, windowDays: 10, now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true)
    }

    /// A one-hour afternoon nap on ONE day of the window moves the two pairs that day is in by exactly
    /// its 60 minutes, and nothing else. If naps were filtered out — the "main night" reading of the
    /// input — the index would stay at a flat 100.
    func testANapMovesExactlyItsOwnMinutes() throws {
        XCTAssertEqual(try reading(tenNightOutcome()).sri, 100, accuracy: 0.0001)

        let napDay = tenIdenticalNights.keys[5]
        let nap = Fixtures.sleepSession(startTs: instant(napDay, 14), endTs: instant(napDay, 15))
        let r = try reading(tenNightOutcome(extra: [nap]))

        let moved = r.pairs.filter { $0.agreeing != $0.compared }
        XCTAssertEqual(moved.count, 2, "a nap sits between two comparisons")
        XCTAssertTrue(moved.allSatisfy { $0.compared - $0.agreeing == 60 },
                      "60 minutes of nap, 60 minutes of disagreement — no more, no less")
        // 7 whole pairs + 2 × 1380 agreeing, over 9 × 1440 compared.
        XCTAssertEqual(r.sri, 200.0 * 12_840 / 12_960 - 100, accuracy: 0.0001)
        XCTAssertEqual(r.sri, 98.148, accuracy: 0.001)
    }

    /// The input is `(startTs, endTs)` and NOTHING else. `sleepStateSample` has 0 rows and
    /// `sleepSession.sleepStateJSON` is NULL on every real session, so an engine that reached for
    /// staging would read nothing on the real store — and here, a `stagesJSON` claiming the whole night
    /// was spent awake must leave the reading byte-identical to the same sessions with it NULL.
    func testStagingIsNotAnInputEvenWhenItContradictsTheBounds() throws {
        let withoutStages = try reading(tenNightOutcome())
        let allWakeStages = "[{\"start\":0,\"end\":2145916800,\"stage\":0}]"
        let withStages = try reading(tenNightOutcome(stagesJSON: allWakeStages))
        XCTAssertEqual(withoutStages, withStages)
        XCTAssertEqual(withStages.sri, 100, accuracy: 0.0001)
    }

    // MARK: - The refusals

    /// The floor, pinned on both sides. Seven usable nights give six comparisons and no number at all;
    /// the eighth night is what turns the em-dash into a reading.
    func testUnderSevenComparisonsThereIsNoNumber() throws {
        let window = keys(from: "2026-07-01", count: 8)
        let sleeps = regularSessions(window)

        // `recordFloor` = the fixture's own first day: this record genuinely starts there, so a window
        // running off it is calibrating rather than clipped by a cache.
        let short = SleepRegularity.analyze(days: banked(Array(window.prefix(7))), sleeps: sleeps,
                                            endKey: window[6], windowDays: 10,
                                            now: Self.fixtureNow, calendar: cal,
                                            daysReachRecordStart: true)
        XCTAssertEqual(short, SleepRegularity.Outcome.calibrating(pairs: 6,
                                                                  needed: SleepRegularity.minimumPairs))
        XCTAssertEqual(short?.numeral, "\u{2014}", "a partial window has no index to print")
        XCTAssertEqual(short?.summaryLine(isNewest: true), "Calibrating \u{2014} 6 of 7 night-to-night comparisons so far.")
        XCTAssertNil(short?.detailLine)

        let full = try reading(SleepRegularity.analyze(days: banked(window), sleeps: sleeps,
                                                       endKey: window[7], windowDays: 10, now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
        XCTAssertEqual(full.pairs.count, 7)
        XCTAssertEqual(full.sri, 100, accuracy: 0.0001)
    }

    /// A window with nothing banked in it is not "calibrating" — there is no measurement in progress to
    /// report. The section is absent entirely.
    func testAWindowWithNoBankedNightRendersNothingAtAll() {
        let window = keys(from: "2026-07-01", count: 10)
        let unbanked = window.map { Fixtures.dailyMetric(day: $0) }
        XCTAssertNil(SleepRegularity.analyze(days: unbanked, sleeps: regularSessions(window),
                                             endKey: window.last, windowDays: 10, now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
        XCTAssertNil(SleepRegularity.analyze(days: [], sleeps: [], now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
    }

    /// 011 decision 5: every string this produces describes the user's own record — no condition name,
    /// no probability, no instruction. Pinned so a later copy edit cannot slide the section into a
    /// verdict about the sleeper.
    func testEveryProducedStringStaysInTheDescriptiveRegister() throws {
        let banned = ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                      "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"]
        let outcomes: [SleepRegularity.Outcome] = [
            try XCTUnwrap(corpusOutcome(gated: true)),
            .calibrating(pairs: 3, needed: SleepRegularity.minimumPairs),
        ]
        for outcome in outcomes {
            for text in [outcome.numeral, outcome.summaryLine(isNewest: true), outcome.detailLine ?? ""] {
                for word in banned {
                    XCTAssertFalse(text.lowercased().contains(word), "\"\(word)\" is banned from \"\(text)\"")
                }
            }
        }
        // And the summary states what was measured, in minutes of the user's own day.
        let gated = try reading(corpusOutcome(gated: true))
        XCTAssertEqual(gated.agreementFraction, 0.8333, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(outcomes.first).summaryLine(isNewest: true),
                       "Your sleep and wake times matched the night before across 83% of the day's minutes.")
    }

    /// The Data tab's entry is READ-ONLY plumbing over the persisted series (011 decision 2 — nothing
    /// here feeds a score), and it reads through `MetricSeriesSet` rather than off a daily column, so an
    /// absent day must chart as a gap and not as a zero.
    func testTheCatalogEntryReadsTheSeriesAndSkipsAbsentDays() throws {
        let def = try XCTUnwrap(MetricCatalog.all.first { $0.key == "sleep_regularity" })
        XCTAssertEqual(def.domain, .rest)
        let days = ["2026-07-01", "2026-07-02", "2026-07-03"].map { Fixtures.dailyMetric(day: $0) }
        let set = MetricSeriesSet(regularity: ["2026-07-01": 66.7, "2026-07-03": 71.2])
        let series = def.series(days: days, series: set)
        XCTAssertEqual(series.count, 2, "the middle day has no reading, so it has no point")
        XCTAssertEqual(series.map(\.value), [66.7, 71.2])
    }

    // MARK: - The two entry points must agree

    /// `analyze` (the Rest hero) and `series` (the persisted Data-tab lane) are documented as the same
    /// rolling reading, so for any day they must return the same number. They did not: `series` summed
    /// `windowDays` pair indices, and since `pairs[i]` compares day `i−1` with day `i`, that reached one
    /// night further back than `analyze`'s window — a 15-night pool against a 14-night one.
    ///
    /// THE FIXTURE IS THE TEST. The pooled index is a RATIO, so a window of uniform pairs gives the same
    /// value however many of them are summed — over the corpus fixture (every surviving pair exactly
    /// 1200/1440) this assertion holds under the bug and pins nothing. So the fixture below is regular
    /// EXCEPT for one nap, placed on the single day that lies inside the old window and outside the new
    /// one. That is the only position where the two bounds can be told apart.
    ///
    /// windowDays = 10, ending on day 13: `analyze` walks days 4…13 and pools the 9 pairs filed on days
    /// 5…13. The old `series` bound also pooled the pair filed on day 4 — which the nap makes
    /// 1320/1440 while every other pair is 1440/1440. Post-fix 98.148, pre-fix 96.667.
    func testTheSeriesAndTheHeroAgreeOnEveryDay() throws {
        let window = keys(from: "2026-07-01", count: 14)
        var sleeps = regularSessions(window)
        // A two-hour afternoon nap on day 4 — sleep, so it moves the two pairs that touch that day.
        sleeps.append(Fixtures.sleepSession(startTs: instant(window[4], 13),
                                            endTs: instant(window[4], 15)))
        let days = banked(window)

        let series = SleepRegularity.series(days: days, sleeps: sleeps, dayKeys: window,
                                            windowDays: 10, now: Self.fixtureNow, calendar: cal)
        XCTAssertFalse(series.isEmpty)
        for (key, value) in series {
            let hero = try reading(SleepRegularity.analyze(days: days, sleeps: sleeps, endKey: key,
                                                           windowDays: 10, now: Self.fixtureNow,
                                                           calendar: cal, daysReachRecordStart: true))
            XCTAssertEqual(value, hero.sri, accuracy: 0.0001,
                           "series and analyze disagree on \(key)")
        }

        // Pin the value itself, so the equality above cannot be satisfied by both sides drifting.
        // 8 pairs at 1440/1440 + the nap pair at 1320/1440 = 12840/12960.
        XCTAssertEqual(try XCTUnwrap(series[window[13]]), 98.148, accuracy: 0.001)
    }

    // MARK: - Zones that spring forward AT midnight

    /// In America/Havana, America/Santiago, Africa/Cairo, Asia/Beirut and Atlantic/Azores, local 00:00
    /// does not exist on the spring-forward date — the day begins at 01:00, and the elapsed span to the
    /// next midnight is still exactly 24 h. That combination sailed through the uniform-day fast path
    /// and labelled 01:00 as minute-of-day 0, sliding the whole grid an hour early and running it an
    /// hour into the following date.
    ///
    /// The sleeper below never changes, so every pair must still agree on every minute it compares. A
    /// re-anchored grid compares a day's 01:00 against its neighbour's 00:00 and manufactures a
    /// disagreement out of the clock.
    func testAMidnightSpringForwardDoesNotReanchorTheDayGrid() throws {
        var havana = Calendar(identifier: .gregorian)
        havana.timeZone = TimeZone(identifier: "America/Havana")!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = havana.timeZone

        // Assert the premise before relying on it, so a tzdata change fails loudly. Parsed at NOON and
        // snapped back — `fmt.date(from: "2026-03-08")` is nil in this zone, because the midnight it is
        // asked for is the very instant that does not exist. That is the whole point of the case.
        let noon = havana.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        XCTAssertEqual(havana.dateComponents([.hour], from: havana.startOfDay(for: noon)).hour, 1,
                       "2026-03-08 must begin at 01:00 in Havana")

        var window: [String] = []
        var d = havana.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!
        for _ in 0..<14 { window.append(fmt.string(from: d)); d = havana.date(byAdding: .day, value: 1, to: d)! }

        // A steady 23:00 → 07:00 sleeper, built from wall-clock components in the Havana zone.
        func at(_ key: String, _ hour: Int) -> Int {
            let p = key.split(separator: "-").compactMap { Int($0) }
            let c = DateComponents(year: p[0], month: p[1], day: p[2], hour: hour)
            return Int(havana.date(from: c)!.timeIntervalSince1970)
        }
        // Every day of the window gets BOTH a morning and an evening — the night before the first day
        // and the night of the last included, exactly as `regularSessions` does. Without the brackets
        // the two edge days are short a sleep block and the edge pairs disagree on their own account,
        // which has nothing to do with the clock this case is about.
        func nextKey(_ key: String) -> String {
            let p = key.split(separator: "-").compactMap { Int($0) }
            let noon = havana.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
            return fmt.string(from: havana.date(byAdding: .day, value: 1, to: noon)!)
        }
        let firstNoon = havana.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12))!
        let firstEve = fmt.string(from: havana.date(byAdding: .day, value: -1, to: firstNoon)!)
        let sleeps = ([firstEve] + window).map {
            Fixtures.sleepSession(startTs: at($0, 23), endTs: at(nextKey($0), 7))
        }

        let r = try reading(SleepRegularity.analyze(
            days: banked(window), sleeps: sleeps, endKey: window.last,
            windowDays: 14, now: Self.fixtureNow, calendar: havana, daysReachRecordStart: true))

        XCTAssertTrue(r.pairs.allSatisfy { $0.agreeing == $0.compared },
                      "an unchanged sleeper must not be handed a disagreement by the clock")
        // The skipped hour is 00:00–00:59, so the pairs touching it compare 1380 minutes, not 1440.
        let shortened: Set<String> = Set(r.pairs
            .filter { $0.compared == SleepRegularity.slotsPerDay - 60 }
            .map { $0.dayKey })
        XCTAssertEqual(shortened, ["2026-03-08", "2026-03-09"])
        XCTAssertEqual(r.sri, 100, accuracy: 0.0001)
    }

    // MARK: - The population the persisted series is derived from

    /// A day the scan SKIPPED must keep the sessions a previous pass derived for it.
    ///
    /// The scan drops any day whose raw samples were pruned or were never dense enough (`hr.count >=
    /// 200`), so such a day contributes nothing to this pass's `cachedSleep`. Its `totalSleepMin`
    /// survives in the merged dailies, so the usability gate still calls it usable — and a usable day
    /// with no intervals grids as awake for all 1440 minutes, scoring both its pairs as a night spent
    /// awake. Replacing by TIME (everything newer than the scan window) threw those sessions away;
    /// replacing by DAY keeps them.
    func testASkippedDayKeepsThePreviouslyDerivedSleepItWasNotRescoredFrom() {
        let scored = corpusKey(10), skipped = corpusKey(9)
        let storedForSkipped = Fixtures.sleepSession(startTs: instant(corpusKey(8), 23),
                                                     endTs: instant(skipped, 7))
        let storedForScored = Fixtures.sleepSession(startTs: instant(skipped, 23),
                                                    endTs: instant(scored, 6))     // the stale copy
        let rederivedForScored = Fixtures.sleepSession(startTs: instant(skipped, 23),
                                                       endTs: instant(scored, 8))  // this pass's

        let population = ScoreEngine.sriSleepPopulation(
            stored: [storedForSkipped, storedForScored],
            rederived: [rederivedForScored])

        XCTAssertTrue(population.contains { $0.endTs == storedForSkipped.endTs },
                      "the skipped day's own night must survive, or it grids as awake")
        XCTAssertFalse(population.contains { $0.endTs == storedForScored.endTs },
                       "the rescored day's stale copy must be replaced, not duplicated")
        XCTAssertTrue(population.contains { $0.endTs == rederivedForScored.endTs })
        XCTAssertEqual(population.count, 2, "one night per day — no duplicate for the rescored day")
    }

    /// The whole reason the above matters: a day that is USABLE but carries no sleep is scored as a
    /// night spent awake. This pins the hazard itself, so the population rule can never be loosened
    /// without a test noticing what it costs.
    func testAUsableDayCarryingNoSleepScoresAsANightSpentAwake() throws {
        let window = keys(from: "2026-07-01", count: 10)
        // Every day banked (so all are "usable"), but the middle day's night is missing entirely.
        var sleeps = regularSessions(window)
        let holed = window[5]
        sleeps.removeAll { $0.endTs == instant(holed, 7) }

        let r = try reading(SleepRegularity.analyze(days: banked(window), sleeps: sleeps,
                                                    endKey: window.last, windowDays: 10,
                                                    now: Self.fixtureNow, calendar: cal, daysReachRecordStart: true))
        let touching = r.pairs.filter { $0.dayKey == holed || $0.dayKey == shiftKey(holed, by: 1) }
        XCTAssertEqual(touching.count, 2)
        XCTAssertTrue(touching.allSatisfy { $0.agreeing < $0.compared },
                      "a usable day with no intervals reads as awake and drags its two pairs down")
        XCTAssertLessThan(r.sri, 100)
    }

    // MARK: - The part of today that has not happened

    /// The newest day in the window is TODAY, and its evening has not occurred. Gridding those minutes
    /// as measured wake made the freshest bar — the one at full strength on the Rest strip — report a
    /// night of wakefulness the user had not yet lived through.
    func testMinutesThatHaveNotHappenedYetAreNotMeasuredWake() throws {
        let window = keys(from: "2026-07-01", count: 10)
        var sleeps: [CachedSleepSession] = []
        for (i, k) in window.enumerated() where i + 1 < window.count {
            sleeps.append(Fixtures.sleepSession(startTs: instant(k, 22), endTs: instant(window[i + 1], 6)))
        }
        let last = window.last!
        // 10:00 on the final day: it has been awake since 06:00, and 10:00→24:00 has not happened.
        let now = Date(timeIntervalSince1970: TimeInterval(instant(last, 10)))

        let r = try reading(SleepRegularity.analyze(days: banked(window), sleeps: sleeps,
                                                    endKey: last, windowDays: 10,
                                                    now: now, calendar: cal, daysReachRecordStart: true))
        let newest = try XCTUnwrap(r.pairs.last)
        XCTAssertEqual(newest.dayKey, last)
        XCTAssertEqual(newest.compared, 600, "only 00:00–09:59 has happened on the final day")
        XCTAssertEqual(newest.agreeing, 600, "and the sleeper matched across every one of them")
        // The earlier pairs are whole days, so the partial one must not be the only thing measured.
        XCTAssertTrue(r.pairs.dropLast().allSatisfy { $0.compared == SleepRegularity.slotsPerDay })
    }
}
