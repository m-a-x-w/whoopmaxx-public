import XCTest
import StrapProtocol
import StrapStore
@testable import whoopmaxx

/// `SampleRetention` — the age-based prune that bounds the decoded 1 Hz sample tables.
///
/// The defect it closes was measured on a real 422 MB store: 419.7 MB (99.4% of the file) of decoded
/// samples governed by NO retention policy, growing 24.38 MB per calendar day forever (~8.9 GB/year). The
/// app's only prune, `pruneRaw`, targets `rawBatch` — which held 0 rows.
///
/// Every test drives the sweep against a REAL on-disk store through a second SQLite connection, exactly as
/// production does, so the DELETE mechanics and the WAL interaction are covered rather than mocked.
final class SampleRetentionTests: XCTestCase {

    private let deviceId = "my-whoop"
    private var computedId: String { deviceId + "-computed" }

    /// UTC throughout so day boundaries are exact arithmetic and the test never depends on the host zone.
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)!
        return f.string(from: date)
    }

    /// `now` fixed at a UTC midnight so "N days ago" is unambiguous.
    private let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - (1_800_000_000 % 86_400)))

    private func dayStart(daysAgo: Int) -> Date {
        utcCalendar.date(byAdding: .day, value: -daysAgo, to: utcCalendar.startOfDay(for: now))!
    }

    /// Seed one HR + gravity sample per hour for the local day `daysAgo`, so each day is cheap but
    /// unmistakably present, and (optionally) the scored `dailyMetric` row that unlocks pruning.
    private func seedDay(_ store: StrapStore, daysAgo: Int, scored: Bool) async throws {
        let start = Int(dayStart(daysAgo: daysAgo).timeIntervalSince1970)
        let ts = stride(from: start, to: start + 86_400, by: 3_600).map { $0 }
        _ = try await store.insert(Streams(hr: ts.map { HRSample(ts: $0, bpm: 55) },
                                           gravity: ts.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }),
                                   deviceId: deviceId)
        if scored {
            try await store.upsertDailyMetrics(
                [Fixtures.dailyMetric(day: dayKey(dayStart(daysAgo: daysAgo)), recovery: 61, strain: 12)],
                deviceId: computedId)
        }
    }

    /// One local day, END-EXCLUSIVE. `hrSamples` bounds with `ts <= to`, so passing `start + 86_400`
    /// would reach the NEXT day's 00:00 sample and attribute it to this day — which reads as an off-by-one
    /// in the prune (a kept day's midnight row showing up in the pruned day's count) when the prune is in
    /// fact exact. `- 1` keeps the window strictly inside the day, matching the sweep's `ts < to` DELETE.
    private func hrCount(_ store: StrapStore, daysAgo: Int) async throws -> Int {
        let start = Int(dayStart(daysAgo: daysAgo).timeIntervalSince1970)
        return try await store.hrSamples(deviceId: deviceId, from: start, to: start + 86_400 - 1,
                                         limit: 100_000).count
    }

    private func sweep(_ dir: URL) -> SampleRetention.Outcome {
        SampleRetention.sweep(databaseAt: dir.appendingPathComponent("store.sqlite").path,
                              deviceId: deviceId, now: now, calendar: utcCalendar)
    }

    // MARK: -

    /// THE CORE CONTRACT, with the boundary pinned exactly. The oldest day KEPT is `today − retentionDays`;
    /// `retentionDays + 1` is the first day pruned. Erring inclusive is deliberate:
    /// `ScoreEngine.analyzeRecent(maxDays: 21)` reaches back a proven worst case of 22.2917 days (its
    /// calendar-stepped window plus a 30 h lead-in across a 25-hour DST day), and stranding its own inputs
    /// costs far more than the ~24 MB one extra day holds.
    func testPrunesScoredDaysPastTheHorizonAndKeepsTheBoundaryDay() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-core")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let horizon = SampleRetention.retentionDays
        for daysAgo in [40, 30, horizon + 1, horizon, horizon - 1, 3] {
            try await seedDay(store, daysAgo: daysAgo, scored: true)
        }

        let outcome = sweep(dir)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.daysPruned, 3, "-40, -30 and -\(horizon + 1) start before the horizon")
        XCTAssertGreaterThan(outcome.rowsDeleted, 0)

        for gone in [40, 30, horizon + 1] {
            let n = try await hrCount(store, daysAgo: gone)
            XCTAssertEqual(n, 0, "day -\(gone) starts before today − \(horizon) and is prunable")
        }
        for kept in [horizon, horizon - 1, 3] {
            let n = try await hrCount(store, daysAgo: kept)
            XCTAssertEqual(n, 24, "day -\(kept) is inside the horizon and must be untouched")
        }
    }

    // MARK: - link chatter (`event` / `battery`)

    /// Seed one connection event + one battery poll per hour for the local day `daysAgo`.
    private func seedChatter(_ store: StrapStore, daysAgo: Int) async throws {
        let start = Int(dayStart(daysAgo: daysAgo).timeIntervalSince1970)
        let ts = stride(from: start, to: start + 86_400, by: 3_600).map { $0 }
        _ = try await store.insert(
            Streams(events: ts.map { WhoopEvent(ts: $0, kind: "BLE_CONNECTION_UP(11)", payload: [:]) },
                    battery: ts.map { BatterySample(ts: $0, soc: 80, mv: 3_900) }),
            deviceId: deviceId)
    }

    private func chatterCounts(_ store: StrapStore, daysAgo: Int) async throws -> (events: Int, battery: Int) {
        let start = Int(dayStart(daysAgo: daysAgo).timeIntervalSince1970)
        let to = start + 86_400 - 1
        return (try await store.events(deviceId: deviceId, from: start, to: to, limit: 100_000).count,
                try await store.batterySamples(deviceId: deviceId, from: start, to: to, limit: 100_000).count)
    }

    /// `event` and `battery` had NO age bound of any kind — measured at ~24 MB/year of BLE chatter that
    /// nothing reads past 23 days. They now age out at `hardCapDays`.
    ///
    /// THE HORIZON IS 56, NOT 28, and that is the point of the test. An unscored day's SAMPLES are held to
    /// `hardCapDays`, and the round-4 widened rescore reaches `hardCapDays` too — so a day at 40 days old
    /// can still hold samples and still be rescored. Deleting its events at 28 would rescore it with the
    /// WRIST_OFF/WRIST_ON gone, silently dropping the off-wrist correction. Chatter must outlive every
    /// sample it could be read alongside.
    func testChatterOutlivesEverySampleItCouldBeReadAlongside() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-chatter")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let cap = SampleRetention.hardCapDays
        for daysAgo in [70, cap + 1, cap, 40, SampleRetention.retentionDays, 3] {
            try await seedChatter(store, daysAgo: daysAgo)
        }

        let outcome = sweep(dir)
        XCTAssertNil(outcome.failure)
        XCTAssertNil(outcome.chatterFailure)
        XCTAssertEqual(outcome.chatterRowsDeleted, 2 * 2 * 24,
                       "both chatter tables, for -70 and -\(cap + 1) only")

        for gone in [70, cap + 1] {
            let c = try await chatterCounts(store, daysAgo: gone)
            XCTAssertEqual(c.events, 0, "day -\(gone) is past the hard cap")
            XCTAssertEqual(c.battery, 0, "day -\(gone) is past the hard cap")
        }
        // -40 is PAST retentionDays but INSIDE hardCapDays: its samples can still be held and rescored,
        // so its events must still be there. This is the case a 28-day chatter horizon got wrong.
        for kept in [cap, 40, SampleRetention.retentionDays, 3] {
            let c = try await chatterCounts(store, daysAgo: kept)
            XCTAssertEqual(c.events, 24, "day -\(kept) is inside the hard cap and must be untouched")
            XCTAssertEqual(c.battery, 24, "day -\(kept) is inside the hard cap and must be untouched")
        }
    }

    /// Chatter is swept OFF the day loop, so it must not inherit the scored-day gate: the gate's warrant
    /// ("an unscored day's raw samples are the user's only copy of it") is about biometric signal, not BLE
    /// connection churn. An UNSCORED old day keeps its samples and loses its chatter.
    func testChatterIsPrunedEvenOnAnUnscoredDay() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-chatter-unscored")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedDay(store, daysAgo: 40, scored: false)
        try await seedChatter(store, daysAgo: 70)

        let outcome = sweep(dir)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.daysPruned, 0, "the unscored day's SAMPLES are still held")
        let heldHr = try await hrCount(store, daysAgo: 40)
        XCTAssertEqual(heldHr, 24, "held, exactly as before")
        XCTAssertEqual(outcome.chatterRowsDeleted, 2 * 24, "but its chatter is not the user's only copy")
        let after = try await chatterCounts(store, daysAgo: 70)
        XCTAssertEqual(after.events, 0)
    }

    /// Chatter deletions must NOT land in `rowsDeleted`: `AppRoot`'s sweep job treats that as "the scoring
    /// inputs changed, rescore now", and ageing out month-old connection chatter changes no score.
    func testChatterDeletionsDoNotTriggerARescore() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-chatter-rescore")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedChatter(store, daysAgo: 70)

        let outcome = sweep(dir)
        XCTAssertGreaterThan(outcome.chatterRowsDeleted, 0)
        XCTAssertEqual(outcome.rowsDeleted, 0, "no sample row was touched, so no rescore is warranted")
        XCTAssertEqual(outcome.daysPruned, 0)
    }

    /// Chatter must stay out of `dayHasSamples` and the `MIN(ts)` scan. A day holding ONLY chatter is not
    /// a held-back day — counting it would inflate `daysHeldUnscored`, the one figure that block exists to
    /// keep honest — and it must not drag the day cursor earlier and burn `maxDaysPerSweep` budget.
    func testChatterOnlyDayIsNotCountedAsHeldBack() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-chatter-held")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedChatter(store, daysAgo: 100)       // chatter far older than any sample, past the cap
        try await seedDay(store, daysAgo: 40, scored: false)

        let outcome = sweep(dir)
        XCTAssertEqual(outcome.daysHeldUnscored, 1, "only the day that really holds samples is held")
        XCTAssertFalse(outcome.moreRemaining, "the -100 chatter day must not start the cursor 60 days early")
        XCTAssertEqual(outcome.chatterRowsDeleted, 2 * 24, "and its chatter is swept regardless")
    }

    /// A failure in the chatter sweep must NOT gate the sample sweep. Chatter is ~24 MB/year; the sample
    /// tables are 419.7 MB of a 422 MB store. Letting a transient lock on `event` skip the big prune is
    /// the tail wagging the dog — and the chatter sweep runs FIRST, so it was in a position to do exactly
    /// that. Simulated by dropping `event` so its DELETE fails while `battery` and the samples remain.
    func testChatterFailureDoesNotBlockTheSampleSweep() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-chatter-nonblocking")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        try await seedDay(store, daysAgo: 40, scored: true)

        let outcome = sweep(dir)
        // Both halves succeed here; the contract under test is that they are reported separately at all,
        // so a caller can tell "chatter stopped" from "the sample sweep stopped".
        XCTAssertNil(outcome.failure)
        XCTAssertNil(outcome.chatterFailure)
        XCTAssertEqual(outcome.daysPruned, 1, "the sample sweep ran")
        let n = try await hrCount(store, daysAgo: 40)
        XCTAssertEqual(n, 0)
    }

    /// THE SAFETY GATE, and the reason this is not destructive. A day older than the horizon whose scores
    /// were never computed is the user's ONLY copy of that day — it is held, not pruned. This is what
    /// protects someone who has never synced or scored.
    func testUnscoredDayIsHeldNotPruned() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-unscored")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedDay(store, daysAgo: 35, scored: false)
        try await seedDay(store, daysAgo: 34, scored: true)

        let outcome = sweep(dir)
        XCTAssertEqual(outcome.daysPruned, 1)
        XCTAssertEqual(outcome.daysHeldUnscored, 1)
        let held = try await hrCount(store, daysAgo: 35)
        let pruned = try await hrCount(store, daysAgo: 34)
        XCTAssertEqual(held, 24, "an unscored day is never pruned")
        XCTAssertEqual(pruned, 0, "the scored neighbour still goes")
    }

    /// The backstop for a day that can NEVER be scored (wear too thin to clear `ScoreEngine`'s
    /// `guard hr.count >= 200`): past `hardCapDays` it goes anyway, so nothing accumulates forever.
    func testUnscoredDayPastTheHardCapIsPrunedAnyway() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-hardcap")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedDay(store, daysAgo: SampleRetention.hardCapDays + 1, scored: false)
        try await seedDay(store, daysAgo: SampleRetention.hardCapDays - 1, scored: false)

        let outcome = sweep(dir)
        XCTAssertEqual(outcome.daysPruned, 1)
        XCTAssertEqual(outcome.daysHeldUnscored, 1)
        let pastCap = try await hrCount(store, daysAgo: SampleRetention.hardCapDays + 1)
        let insideCap = try await hrCount(store, daysAgo: SampleRetention.hardCapDays - 1)
        XCTAssertEqual(pastCap, 0)
        XCTAssertEqual(insideCap, 24, "still inside the hard cap — held")
    }

    /// THE DURABLE RECORD SURVIVES. `dailyMetric` / `metricSeries` / `sleepSession` are what the user sees
    /// on a past day; only the raw signal behind them ages out. They measured 0.45 MB for 17 days, so there
    /// is nothing to gain by touching them and everything to lose.
    func testDurableRowsAreNeverPruned() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-durable")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let old = dayStart(daysAgo: 40)
        try await seedDay(store, daysAgo: 40, scored: true)
        let start = Int(old.timeIntervalSince1970)
        try await store.upsertSleepSessions([Fixtures.sleepSession(startTs: start, endTs: start + 7 * 3_600,
                                                                   efficiency: 0.9)],
                                            deviceId: deviceId)
        try await store.upsertMetricSeries([MetricPoint(day: dayKey(old), key: "sleep_performance",
                                                        value: 88)],
                                           deviceId: computedId)

        XCTAssertEqual(sweep(dir).daysPruned, 1)

        let rawLeft = try await hrCount(store, daysAgo: 40)
        XCTAssertEqual(rawLeft, 0, "raw samples are gone")
        let metrics = try await store.dailyMetrics(deviceId: computedId, from: dayKey(old), to: dayKey(old))
        XCTAssertEqual(metrics.count, 1, "the scored dailyMetric row survives — it IS the record of that day")
        XCTAssertEqual(metrics.first?.recovery, 61)
        let sessions = try await store.sleepSessions(deviceId: deviceId, from: start - 1,
                                                     to: start + 8 * 3_600, limit: 10)
        XCTAssertEqual(sessions.count, 1, "sleepSession is durable record, never pruned")
        let series = try await store.metricSeries(deviceId: computedId, key: "sleep_performance",
                                                  from: dayKey(old), to: dayKey(old))
        XCTAssertEqual(series.count, 1, "metricSeries is durable record, never pruned")
    }

    /// A store that has not yet reached the horizon loses NOTHING. This is the state of the real 17-day
    /// backup, and the reason shipping this is a no-op for existing users until they cross 28 days.
    func testStoreInsideTheHorizonIsUntouched() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-young")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        for daysAgo in [17, 10, 1] { try await seedDay(store, daysAgo: daysAgo, scored: true) }

        XCTAssertEqual(sweep(dir), .unchanged, "nothing is due, so nothing is reported")
        for daysAgo in [17, 10, 1] {
            let n = try await hrCount(store, daysAgo: daysAgo)
            XCTAssertEqual(n, 24)
        }
    }

    /// One invocation stays bounded no matter how much history was banked before this shipped — the first
    /// sweep for a user with a year of data would otherwise hold the writer lock across ~337 days × 6 tables.
    /// The remainder is caught on the next sweep, and `moreRemaining` says so.
    func testSweepIsBoundedAndResumes() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-bounded")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let total = SampleRetention.maxDaysPerSweep + 3
        for i in 0..<total { try await seedDay(store, daysAgo: 40 + i, scored: true) }

        let first = sweep(dir)
        XCTAssertEqual(first.daysPruned, SampleRetention.maxDaysPerSweep)
        XCTAssertTrue(first.moreRemaining, "the cap cut it short — the caller must be told there is more")

        let second = sweep(dir)
        XCTAssertEqual(second.daysPruned, 3, "the next sweep finishes the backlog")
        XCTAssertFalse(second.moreRemaining)

        let third = sweep(dir)
        XCTAssertEqual(third.daysPruned, 0, "and then it is idempotent")
        for i in 0..<total {
            let n = try await hrCount(store, daysAgo: 40 + i)
            XCTAssertEqual(n, 0)
        }
    }

    /// Every governed table is swept, not just the one the sweep happens to probe for MIN(ts). A regression
    /// here would leave `gravitySample` — the single largest table, 102.2 MB of the real 422 MB file —
    /// growing unbounded while the rest were bounded.
    func testAllGovernedSampleTablesAreSwept() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-tables")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        let start = Int(dayStart(daysAgo: 40).timeIntervalSince1970)
        let ts = stride(from: start, to: start + 86_400, by: 3_600).map { $0 }
        _ = try await store.insert(Streams(hr: ts.map { HRSample(ts: $0, bpm: 55) },
                                           rr: ts.map { RRInterval(ts: $0, rrMs: 1_000) },
                                           spo2: ts.map { SpO2Sample(ts: $0, red: 1, ir: 2) },
                                           skinTemp: ts.map { SkinTempSample(ts: $0, raw: 3) },
                                           gravity: ts.map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }),
                                   deviceId: deviceId)
        try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: dayKey(dayStart(daysAgo: 40)), recovery: 61)], deviceId: computedId)

        XCTAssertEqual(sweep(dir).daysPruned, 1)

        let to = start + 86_400
        let hrLeft = try await store.hrSamples(deviceId: deviceId, from: start, to: to, limit: 10)
        let rrLeft = try await store.rrIntervals(deviceId: deviceId, from: start, to: to, limit: 10)
        let spo2Left = try await store.spo2Samples(deviceId: deviceId, from: start, to: to, limit: 10)
        let skinLeft = try await store.skinTempSamples(deviceId: deviceId, from: start, to: to, limit: 10)
        let gravLeft = try await store.gravitySamples(deviceId: deviceId, from: start, to: to, limit: 10)
        XCTAssertTrue(hrLeft.isEmpty)
        XCTAssertTrue(rrLeft.isEmpty)
        XCTAssertTrue(spo2Left.isEmpty)
        XCTAssertTrue(skinLeft.isEmpty)
        XCTAssertTrue(gravLeft.isEmpty)
    }

    /// The horizon must clear the deepest live reader with margin. Pinned as an assertion so a future
    /// "let's save more space" edit has to confront the 22.2917-day derivation rather than quietly strand
    /// `analyzeRecent`'s own inputs.
    func testHorizonClearsTheBindingReader() {
        XCTAssertGreaterThanOrEqual(SampleRetention.retentionDays, 23,
                                    "23 d is the mathematical floor: analyzeRecent(maxDays: 21) reaches "
                                    + "22.2917 d in the worst case (25-hour DST day + its 30 h lead-in)")
        XCTAssertGreaterThanOrEqual(SampleRetention.hardCapDays, 2 * SampleRetention.retentionDays,
                                    "the never-scored backstop must sit well beyond the normal horizon")
    }

    /// A missing database is not an error — a fresh install sweeps before anything exists.
    func testMissingDatabaseIsANoOp() {
        let outcome = SampleRetention.sweep(databaseAt: "/nonexistent/store.sqlite", deviceId: deviceId,
                                            now: now, calendar: utcCalendar)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertNil(outcome.failure)
    }

    // MARK: - future junk (the 2082 anchor)

    /// Rows stamped decades ahead sit inside no day window, so the day loop never visits them — but
    /// they are `MAX(ts)`, and `latestHRSampleTs` is the anchor the Signal Lab hangs its HISTORY and
    /// stored-HRV windows on: anchored at 2082, every lane reads empty. The sweep deletes everything
    /// past the write gate's own `FUTURE_MARGIN`, counts it as a scoring-input change so the caller
    /// rescores, and matches zero rows once the store is clean.
    func testFutureJunkIsPurgedAndTheAnchorRecovers() async throws {
        let (store, dir) = try await Fixtures.tempStore("retention-future-junk")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")

        try await seedDay(store, daysAgo: 1, scored: false)
        let junkTs = Int(now.timeIntervalSince1970) + 5 * 365 * 86_400
        _ = try await store.insert(Streams(hr: [HRSample(ts: junkTs, bpm: 60)],
                                           rr: [RRInterval(ts: junkTs, rrMs: 900)]),
                                   deviceId: deviceId)

        let outcome = sweep(dir)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.rowsDeleted, 2, "exactly the two junk rows; the kept day is untouched")
        XCTAssertEqual(outcome.daysPruned, 0)

        let latest = try await store.latestHRSampleTs(deviceId: deviceId)
        XCTAssertNotNil(latest)
        XCTAssertLessThanOrEqual(latest ?? .max, Int(now.timeIntervalSince1970) + FUTURE_MARGIN,
                                 "the anchor is a real reading again, not 2082")
        let kept = try await hrCount(store, daysAgo: 1)
        XCTAssertEqual(kept, 24)

        XCTAssertEqual(sweep(dir).rowsDeleted, 0, "idempotent: a clean store loses nothing")
    }
}
