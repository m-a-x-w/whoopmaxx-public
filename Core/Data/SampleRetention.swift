import Foundation
import SQLite3
import StrapProtocol

/// Age-based retention for the decoded 1 Hz sample tables — the one thing standing between this app and
/// unbounded disk growth.
///
/// THE PROBLEM, MEASURED ON A REAL 422 MB STORE (17.21 days of continuous WHOOP 4.0 wear). The six decoded
/// sample tables have no retention policy of any kind. `StrapStore.pruneRaw` — the app's only prune, called
/// from `Collector.prune()` — issues DELETEs against `rawBatch` ALONE, and `rawBatch` holds 0 rows (raw
/// frames are discarded immediately after decode), so the "retention policy" runs against an empty table.
/// An exhaustive audit of every DELETE in the codebase found only three others that can touch a sample row,
/// none of them age-based: `StoreMaintenance`'s one-shot degenerate-channel purge, `TimestampHeal`'s
/// out-of-plausible-range heal, and `DeviceRegistryStore`'s full device wipe.
///
/// dbstat over that file (b-tree + `sqlite_autoindex`, 4 KB pages):
///
///     gravitySample  67.6 + 34.6 = 102.2 MB     hrSample       33.1 + 34.6 =  67.6 MB
///     spo2Sample     38.5 + 34.6 =  73.0 MB     rrInterval     18.2 + 20.7 =  38.8 MB
///     skinTempSample 34.4 + 34.6 =  69.0 MB     ─────────────────────────────────────
///     respSample     34.4 + 34.6 =  69.0 MB     SAMPLES              419.7 MB
///
/// 419.7 MB of a 422.1 MB file — 99.4% — growing at a measured 24.38 MB per CALENDAR day / 25.29 MB per
/// WORN day, i.e. ~8.9 GB per year, forever. (Roughly half of each table is the duplicate b-tree SQLite
/// builds for the non-INTEGER `(deviceId, ts)` PRIMARY KEY. Removing that needs `WITHOUT ROWID`, i.e. a
/// schema change in the frozen `Packages/StrapStore` — out of scope, which is why the lever here is age.)
///
/// WHY 28 DAYS. Derived, not guessed. The binding constraint is `ScoreEngine.analyzeRecent(maxDays: 21)`
/// (every production caller takes the default), which steps by CALENDAR day and reads each day from
/// `dayStart - 30 h`. Replaying that exact arithmetic over every local day and hour of a year in
/// America/New_York, including both DST transitions, the worst case is 1,925,999 s = **22.2917 days** (at
/// 2026-11-01 23:59, inside the 25-hour fall-back day). So a flat 21- or 22-day horizon is provably UNSAFE;
/// 23 days is the mathematical floor. 28 adds ~5.7 days of margin for timezone travel (up to +1 day), the
/// tick period, and the Rest screen's retrospective readers.
///
/// EVERY LIVE READER OF RAW SAMPLES, oldest-first (days before now) — this is the table that sets the floor:
///
///     22.2917  ScoreEngine.analyzeRecent          ← BINDING CONSTRAINT
///      14.00   BodyClockEngine.windowDays
///       8.00   StrapHealth.windowDays (+1 d event lead-in)
///       7.00   WorkoutRepository.autoDetectCandidates(daysBack: 7)
///       6.33   BodyClockEngine tempMinNights (measured over the real 21 sessions)
///       1.25   Signal Lab (24 h max preset + 25% read pad; pan/zoom is clamped to the loaded bounds,
///              so it can never reach past what it loaded)
///       1.00   Repository.hrSamples, SignalLabHRV, WakeWindowSection
///     120.00   NightTape + ArousalForensicsLoader — these DEGRADE rather than break: NightTape falls back
///              to the persisted per-epoch motionJSON and ArousalForensics simply returns fewer arousals.
///
/// WHAT IS NEVER PRUNED. `dailyMetric`, `metricSeries` and `sleepSession` are the durable record and are
/// left alone forever: 21 sessions + 18 daily rows + 92 series rows measured 0.45 MB total, ~0.025 MB/day
/// (~9 MB/year). Everything the user sees on a past day survives; only the raw signal behind it ages out.
/// That list is the durable record ONLY — it is not the list of everything this policy leaves alone. The
/// `(deviceId, ts)`-keyed link chatter (`event`, `battery`) is neither durable record nor biometric signal;
/// it is governed by `chatterTables` on the same horizon, by its own sweep. See that doc for why it cannot
/// simply be appended to `sampleTables`.
///
/// PROJECTED STEADY STATE: 28 × 24.08 MB/worn-day ≈ **675 MB** (≈ 562 MB once the already-shipped
/// degenerate-`respSample` purge lands), versus ~8.9 GB after one unbounded year — a 13–16× reduction, and
/// BOUNDED rather than linear. Honest caveat: ~560–675 MB is still large, because the per-day cost is set by
/// 1 Hz storage plus that duplicated PK index. The next levers are per-channel tiering (`gravitySample`
/// alone is 6.16 MB/worn-day and its only post-horizon reader already has a fallback) or `WITHOUT ROWID` —
/// both blocked by the package freeze.
///
/// ON THIS 17-DAY STORE THE POLICY DELETES NOTHING, which is correct: the user has not yet accumulated 28
/// days. The fix is a no-op today and only ever bites once the horizon is exceeded.
enum SampleRetention {

    // MARK: - Policy

    /// The retention horizon, in local days. The oldest day KEPT is `today − retentionDays`; a day is
    /// prunable only when it starts strictly BEFORE that, so the window is inclusive at both ends and
    /// covers `retentionDays + 1` calendar days. Erring inclusive is deliberate — the cost of one extra
    /// day is ~24 MB, the cost of one day too few is stranding `analyzeRecent`'s own inputs.
    ///
    /// See the type doc for the 22.2917-day derivation that makes 23 the hard floor; this carries ~5.7
    /// days of margin on top of it.
    static let retentionDays = 28

    /// Backstop for a day that can NEVER satisfy the scored-day gate — e.g. wear too thin to clear
    /// `ScoreEngine`'s `guard hr.count >= 200`. Past 2× the horizon such a day is pruned unconditionally, so
    /// nothing accumulates forever. (0 of the 18 real days fail that guard, so this is belt-and-braces.)
    static let hardCapDays = 56

    /// Ceiling on local days removed by ONE sweep, so a single invocation stays bounded no matter how much
    /// history a user banked before this shipped (a year of data is ~337 prunable days). The remainder is
    /// caught on the next sweep. In steady state exactly one day is due per sweep, so this never binds.
    static let maxDaysPerSweep = 14

    /// The decoded sample tables governed by this policy — every table keyed `(deviceId, ts)` whose rows are
    /// re-derivable signal rather than durable record. `stepSample` / `ppgHrSample` / `sleepStateSample` are
    /// empty on WHOOP 4.0 but are listed for symmetry, so a future firmware that fills them is covered the
    /// day it lands rather than silently re-opening this bug.
    static let sampleTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "sleepStateSample",
    ]

    /// Link CHATTER: `(deviceId, ts)`-keyed tables that are neither re-derivable biometric signal nor
    /// durable record — BLE connection/haptics/alarm events and battery polls. Governed by the same
    /// `retentionDays` horizon as the sample tables, but by their own sweep below rather than the day loop.
    ///
    /// THE HORIZON IS `hardCapDays` (56), NOT `retentionDays` (28). Events must never predecease the
    /// samples of the same day, or a day gets rescored from HR with its WRIST_OFF/WRIST_ON gone.
    ///
    /// It is tempting to go the other way and give events a SHORT horizon, on the grounds that Strap Health
    /// only looks back 8 days. That is the first trap: `ScoreEngine` reads `store.events` over the SAME
    /// window as its `hrSamples` read and feeds them to `DayEngine.offWristIntervals`, so any event
    /// horizon under 23 days breaks the off-wrist sleep backstop on days 9–22 — exactly the days
    /// `analyzeRecent` still rescores.
    ///
    /// Matching `retentionDays` is the SECOND trap, and subtler. A day's samples are not actually gone at
    /// 28 days: the scored-day gate HOLDS an unscored day's samples all the way to `hardCapDays`, and the
    /// round-4 widened rescore scans to `hardCapDays` too. So a day at 40 days old can still hold samples
    /// and still be rescored — and at a 28-day event horizon it would be rescored with its events already
    /// deleted, silently losing the off-wrist correction on exactly the days most likely to need it. 56
    /// makes the events outlive every sample they could be read alongside. The cost is ~28 extra days of a
    /// ~145 B/row × ~500 rows/day table: about 2 MB.
    ///
    /// WHY A SEPARATE SWEEP, NOT `sampleTables`. Three reasons, each a regression if folded in:
    ///  • the scored-day gate must NOT apply. Its warrant is "an unscored day's raw samples are the user's
    ///    only copy of it" — true of biometric signal, meaningless for connection chatter. Folded in, a day
    ///    with BLE churn but no scoreable wear would be HELD to `hardCapDays` instead of pruned at 28;
    ///  • `dayHasSamples` would start counting chatter as samples, inflating `daysHeldUnscored` — the one
    ///    figure that block exists to keep honest;
    ///  • the `MIN(ts)` scan would start the day cursor earlier whenever events predate samples, burning
    ///    `maxDaysPerSweep` budget on event-only days and delaying real sample pruning by a whole sweep.
    /// With no per-day gate to honour, one ranged DELETE per table is all this needs — and it rides the
    /// `(deviceId, ts)` PK prefix on both (`event` is keyed `(deviceId, ts, kind)`), so it is a range
    /// delete, not a scan.
    ///
    /// SIZE. Measured on the 2026-07-30 store: `event` ~145 B/row gross at ~500 rows/day ≈ 24 MB/year;
    /// `battery` ~52 B/row at ~81 rows/day ≈ 1.5 MB/year. `event` is 94% of it — `battery` is listed for
    /// symmetry, the same argument the sample list makes for `stepSample`.
    static let chatterTables = ["event", "battery"]

    /// What one sweep did. Returned (and logged) for observability + tests.
    struct Outcome: Equatable, Sendable {
        /// Local days whose samples were removed.
        var daysPruned: Int = 0
        /// Rows removed across all tables and days.
        var rowsDeleted: Int = 0
        /// Rows removed from `chatterTables`. Kept SEPARATE from `rowsDeleted` on purpose: callers treat a
        /// non-zero `rowsDeleted` as "the scoring inputs changed, rescore now" (AppRoot's sweep job), and
        /// deleting month-old BLE connection chatter changes no score.
        var chatterRowsDeleted: Int = 0
        /// Why the chatter sweep stopped, if it did. SEPARATE from `failure` so a busy `event` table — 24 MB
        /// a year — can never gate the sample sweep, which governs 419.7 MB. The chatter sweep runs first
        /// (it must not inherit the day loop's exit conditions), and an early SQLITE_BUSY there used to
        /// abort the whole invocation.
        var chatterFailure: String? = nil
        /// Days that were old enough and ACTUALLY HELD SAMPLES, but had not been scored, so they were
        /// deliberately kept. Empty days inside the swept span (a gap in wear) are not counted — nothing
        /// was held back on a day that has nothing.
        var daysHeldUnscored: Int = 0
        /// True when `maxDaysPerSweep` cut the sweep short — more remains for the next run.
        var moreRemaining: Bool = false
        /// Set when SQLite refused; the sweep is a no-op and will simply be retried.
        var failure: String? = nil

        static let unchanged = Outcome()
    }

    // MARK: - Sweep

    /// Delete decoded samples for local days older than `retentionDays`, one day per statement.
    ///
    /// THE SAFETY GATE. A day is pruned only when BOTH hold: it is older than `retentionDays`, AND it HAS
    /// BEEN SCORED (a `dailyMetric` row exists on the computed `"<deviceId>-computed"` lane for that local day
    /// key). Rule two is what makes this non-destructive for a user who has never synced or scored — their
    /// only copy of that day is never touched. Scored days stay readable by construction: `ScoreEngine`'s
    /// `guard hr.count >= 200 else { continue }` skips a day whose raw is gone and leaves its persisted
    /// `dailyMetric` intact, exactly the behaviour `Spo2Heal` already documents and depends on.
    ///
    /// WHY A SECOND CONNECTION. This is neither a schema change nor a migration — only rows are removed —
    /// and `Packages/StrapStore` is vendored/frozen, so this follows the seam `StoreMaintenance` already
    /// established: Core owns the store path and talks to the file with the system SQLite for out-of-band
    /// row work. WAL already serializes writers and `sqlite3_busy_timeout` covers the overlap.
    ///
    /// WHY ONE DAY PER STATEMENT. `DELETE … WHERE deviceId = ? AND ts >= ? AND ts < ?` chunks naturally at
    /// ~86 k rows / ~25 MB, so the writer lock is taken and released once per day instead of being held for
    /// the whole sweep. On a first run against a large backlog that is the difference between a series of
    /// short writes and one multi-second stall.
    ///
    /// SYNCHRONOUS and potentially multi-second — callers must run it OFF the main actor. Never throws;
    /// every failure mode is an `Outcome`.
    @discardableResult
    static func sweep(databaseAt path: String, deviceId: String, now: Date = Date(),
                      calendar: Calendar = .current) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return .unchanged }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return Outcome(failure: why)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        // Only tables this database actually has (a store opened before a migration, or a future schema).
        let tables = sampleTables.filter { tableExists(db, $0) }

        // The first local day we KEEP. Anchored on `startOfDay` and stepped with `date(byAdding: .day:)`
        // so the 23- and 25-hour DST days are exact rather than 86 400-second approximations.
        let today = calendar.startOfDay(for: now)
        guard let keepFrom = calendar.date(byAdding: .day, value: -retentionDays, to: today),
              let hardCapFrom = calendar.date(byAdding: .day, value: -hardCapDays, to: today)
        else { return .unchanged }

        var out = Outcome()

        // LINK CHATTER FIRST, and deliberately BEFORE the sample-table guards below. It is governed by the
        // same horizon but shares none of the day loop's machinery (see `chatterTables`), so it must not
        // inherit the day loop's exit conditions either: a store with no sample rows at all — every sample
        // table pruned away, or a fresh schema — still accumulates BLE connection chatter, and returning
        // early on `tables.isEmpty` / a nil `MIN(ts)` would leave it unbounded in exactly that case.
        // With no per-day gate to honour, one ranged DELETE per table covers all of history at once.
        // `hardCapFrom`, NOT `keepFrom` — chatter must outlive every sample it could be read alongside.
        let chatterKeepFromTs = Int(hardCapFrom.timeIntervalSince1970)
        for t in chatterTables where tableExists(db, t) {
            let (n, why) = deleteRange(db, table: t, deviceId: deviceId, from: 0, to: chatterKeepFromTs)
            guard why == nil else {
                // Report and stop the CHATTER sweep — but fall through to the sample sweep regardless.
                // These tables are two orders of magnitude smaller than the sample tables; letting a
                // transient lock on `event` skip a 419.7 MB prune would be the tail wagging the dog.
                out.chatterFailure = "\(t): \(why!)"
                NSLog("SampleRetention: chatter sweep stopped on \(t) — \(out.chatterFailure!)")
                break
            }
            out.chatterRowsDeleted += n
        }

        // FUTURE JUNK, before the day loop. A pre-gate build persisted a handful of live-lane rows
        // stamped decades ahead — a mis-set strap clock run through unchecked reference arithmetic;
        // 48 rows at 2082-04-02 on the real store. They sit inside no day window, so the loop below
        // never visits them — but they ARE `MAX(ts)`, and that is the anchor `latestHRSampleTs`
        // hands the Signal Lab: the HISTORY scope and the stored-HRV window end in 2082 and render
        // every lane empty. The write side has gated at `wallNow + FUTURE_MARGIN` since 1.9.0 (39),
        // so anything past that same bound is junk by definition and this DELETE is idempotent —
        // in steady state it matches zero rows. Counted into `rowsDeleted` deliberately: removing
        // the anchor junk changes what readers see, and the caller's rescore is the refresh.
        let futureCutTs = Int(now.timeIntervalSince1970) + FUTURE_MARGIN
        for t in tables {
            let (n, why) = deleteRange(db, table: t, deviceId: deviceId, from: futureCutTs, to: .max)
            guard why == nil else { out.failure = "\(t) future purge: \(why!)"; return out }
            out.rowsDeleted += n
        }

        guard !tables.isEmpty else { return out }

        // Oldest sample instant anywhere in the governed tables. Each MIN(ts) rides the (deviceId, ts) PK,
        // so this is a handful of index seeks, not a scan.
        var oldest: Int?
        for t in tables {
            guard let m = scalar(db, "SELECT MIN(ts) FROM \(t) WHERE deviceId = ?", deviceId) else { continue }
            oldest = min(oldest ?? m, m)
        }
        guard let oldestTs = oldest else { return out }   // chatter already swept above

        let computedId = deviceId + "-computed"
        var cursor = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(oldestTs)))

        while cursor < keepFrom {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            if out.daysPruned >= maxDaysPerSweep { out.moreRemaining = true; break }

            let key = dayKey(cursor, zone: calendar.timeZone)
            // Scored, or past the hard cap? Otherwise hold the day — an unscored day's raw samples are the
            // user's only copy of it.
            let scored = scalar(db, "SELECT COUNT(*) FROM dailyMetric WHERE deviceId = ? AND day = ?",
                                computedId, key) ?? 0
            let from = Int(cursor.timeIntervalSince1970), to = Int(next.timeIntervalSince1970)
            guard scored > 0 || cursor < hardCapFrom else {
                // Count only days that actually hold something. The cursor walks EVERY calendar day from
                // the oldest sample to the horizon, so most days in a gap of wear are simply empty — and an
                // empty day is not "held back", it has nothing to hold. Counting them made the figure track
                // the width of the swept span rather than the data being protected.
                if dayHasSamples(db, tables: tables, deviceId: deviceId, from: from, to: to) {
                    out.daysHeldUnscored += 1
                }
                cursor = next
                continue
            }

            var dayRows = 0
            for t in tables {
                let (n, why) = deleteRange(db, table: t, deviceId: deviceId, from: from, to: to)
                guard why == nil else {
                    // Partial progress is safe (whole days already removed stay removed); report and stop.
                    out.failure = "\(t): \(why!)"
                    out.rowsDeleted += dayRows
                    NSLog("SampleRetention: sweep aborted on \(key) — \(out.failure!)")
                    return out
                }
                dayRows += n
            }
            out.rowsDeleted += dayRows
            out.daysPruned += 1
            cursor = next
        }

        if out.daysPruned > 0 || out.daysHeldUnscored > 0 || out.chatterRowsDeleted > 0
            || out.chatterFailure != nil {
            NSLog("SampleRetention: pruned \(out.rowsDeleted) row(s) across \(out.daysPruned) day(s) "
                  + "older than \(retentionDays) d; held \(out.daysHeldUnscored) unscored day(s); "
                  + "chatter \(out.chatterRowsDeleted) row(s); moreRemaining=\(out.moreRemaining).")
        }
        return out
    }

    // MARK: - Small helpers

    /// `SQLITE_TRANSIENT`: tell SQLite to COPY the bound text, because the Swift `String`'s C buffer is only
    /// guaranteed alive for the duration of the `sqlite3_bind_text` call itself. The constant is a sentinel
    /// pointer value the C header defines as `((sqlite3_destructor_type)-1)` and is not imported into Swift.
    private static let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `yyyy-MM-dd` in the sweep's own zone. `DayKey.local` is hard-wired to the DEVICE zone, which is right
    /// in the app but would silently disagree with an injected test calendar — the day key MUST come from
    /// the same zone as the day boundaries the DELETE ranges were built from, or the scored-day gate checks
    /// the wrong row.
    private static func dayKey(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone
        return f.string(from: date)
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        (scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", name) ?? 0) == 1
    }

    /// `DELETE FROM <table> WHERE deviceId = ? AND ts >= ? AND ts < ?` — one local day.
    /// Returns the rows removed, plus a non-nil message when SQLite refused.
    private static func deleteRange(_ db: OpaquePointer, table: String, deviceId: String,
                                    from: Int, to: Int) -> (rows: Int, failure: String?) {
        var stmt: OpaquePointer?
        let sql = "DELETE FROM \(table) WHERE deviceId = ? AND ts >= ? AND ts < ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (0, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, deviceId, -1, transientText)
        sqlite3_bind_int64(stmt, 2, Int64(from))
        sqlite3_bind_int64(stmt, 3, Int64(to))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            return (0, String(cString: sqlite3_errmsg(db)))
        }
        return (Int(sqlite3_changes(db)), nil)
    }

    /// Does this day hold ANY governed sample row? Runs only on the held path, so `daysHeldUnscored`
    /// counts days whose data was genuinely kept back rather than every empty calendar day between the
    /// oldest sample and the horizon. Each probe is a `(deviceId, ts)` PK range seek stopped at the first
    /// row by `LIMIT 1`, and the loop short-circuits on the first table that has one.
    private static func dayHasSamples(_ db: OpaquePointer, tables: [String], deviceId: String,
                                      from: Int, to: Int) -> Bool {
        for t in tables {
            var stmt: OpaquePointer?
            let sql = "SELECT 1 FROM \(t) WHERE deviceId = ? AND ts >= ? AND ts < ? LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, deviceId, -1, transientText)
            sqlite3_bind_int64(stmt, 2, Int64(from))
            sqlite3_bind_int64(stmt, 3, Int64(to))
            if sqlite3_step(stmt) == SQLITE_ROW { return true }
        }
        return false
    }

    /// First column of the first row as an Int, with optional TEXT bindings; nil when the statement
    /// wouldn't prepare/step or the value was NULL.
    private static func scalar(_ db: OpaquePointer, _ sql: String, _ text: String...) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, t) in text.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), t, -1, transientText)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
