import Foundation
import SQLite3

/// File-level housekeeping performed on the store FILE before the app opens it — the seam for work that
/// needs exclusive access, so it cannot run alongside our own connection.
///
/// TWO jobs, both about space already banked by a shipped defect:
///
///  1. `purgeDegenerateRespSamplesIfNeeded` — run-once, deletes the degenerate raw-respiration channel.
///  2. `reclaimFreelistIfNeeded` — a `VACUUM`, self-gated on the freelist, that hands reclaimed pages back
///     to the filesystem. This is the counterpart to `SampleRetention`: SQLite never shrinks a file on its
///     own, so without it a user who banked months of samples before retention shipped would keep their
///     peak file size forever, as freelist. It is deliberately NOT run-once and NOT recurring — see its doc.
///
/// Job 1's warrant: `RespChannelGate` stops the rows being written from now on, but an existing install has
/// already paid for them — on the real 17-day store this measured (dbstat, 4 KB pages):
///
///     respSample b-tree               36,110,336 B
///     sqlite_autoindex_respSample_1   36,253,696 B   ← the non-INTEGER (deviceId, ts) PK's second b-tree
///     ────────────────────────────────────────────
///     total                           72,364,032 B   = 16.35% of the 442,634,240 B database
///
/// for 1,433,848 rows carrying exactly TWO distinct values, i.e. ~50.5 bytes per bit of real information.
///
/// WHY HERE AND NOT IN StrapStore. This is neither a schema change nor a migration — the table and its
/// columns are untouched, only rows are removed — and `Packages/StrapStore` is vendored/frozen. Core
/// already owns the store's path (`StorePaths.defaultDatabasePath()`) and already talks to the file with
/// the system SQLite for exactly this kind of out-of-band work (`BackupImport`'s table probe and
/// journal-mode normalisation), so this follows that established seam.
///
/// SAFETY. Every step is conservative and non-fatal:
///  - it runs at most once per install (`respPurgeDefaultsKey`), and never at all once that flag is set;
///  - it DELETES only after proving the channel degenerate on this exact database — a store whose
///    `respSample` carries ≥ 3 distinct raw values (a genuine waveform from some other firmware/layout)
///    is left completely alone and the flag is set so we never look again;
///  - `VACUUM` (which needs transient free space up to the size of the database) is attempted only when
///    the volume can afford it, and its failure is not the purge's failure — the freed pages stay in the
///    file's freelist and get reused, so the database simply stops growing instead of shrinking;
///  - any SQLite error leaves the flag UNSET, so the work is retried on the next launch rather than
///    half-done and forgotten.
enum StoreMaintenance {

    /// Set once the respiration purge has reached a definitive verdict (purged, or proven not degenerate).
    /// Versioned so a future maintenance pass can re-run deliberately under a new key.
    ///
    /// STORE-SCOPED, so it is registered in `RestoreHealReset` and re-armed by a landed restore
    /// (`BackupImport` Gate 9). Without that, a user who restores a pre-gate backup onto an install that
    /// already purged carries the dead channel forever: measured on the real backup, the healed install
    /// answered `alreadyRun` and the file stayed at 442,634,240 B, where a re-armed pass returned
    /// `purged(rows: 1_433_848, vacuumed: true)` and left it at 349,495,296 B — 93.1 MB stranded.
    ///
    /// SAFE TO RE-RUN, which is the bar for that registry: the pass below re-proves degeneracy against
    /// the LANDED database and returns `.notDegenerate` (deleting nothing) for any store carrying ≥ 3
    /// distinct raw values. The cost is one slower launch — the launch the user just asked for by
    /// restoring — which is the same trade this type's doc already accepts.
    /// BUMPED TO v2 alongside the `RespChannelGate.RollingJudge` ingest fix, which is the only reason a
    /// re-arm is worth a launch. v1's purge was real but its warrant was not: the chunk-local gate never
    /// fired on the ~50-record high-freq-sync chunks that actually carry the channel, so a store refilled
    /// at ~4.3 MB/day immediately after being purged, and the run-once flag guaranteed it was never
    /// reclaimed again. Re-arming without the ingest fix buys one VACUUM and then refills; with it, the
    /// purge is finally terminal. Measured on the 2026-07-30 store: 67,559 rows / ~3.4 MB, 13.85% of the
    /// file, for ~19 h of wear.
    ///
    /// Changing this string re-runs the pass for EVERY existing install (one slower launch). That is the
    /// intended cost. `.v1` stores that already answered `alreadyRun` are exactly the ones carrying the
    /// banked rows, so a new key is the only way to reach them.
    static let respPurgeDefaultsKey = "wm.maintenance.respSamplePurge.v2"

    /// What `purgeDegenerateRespSamplesIfNeeded` did. Returned (and logged) for observability + tests.
    enum RespPurgeOutcome: Equatable {
        /// The flag was already set — nothing was opened.
        case alreadyRun
        /// No database file yet, or the schema hasn't created `respSample` yet (fresh install, pre-open).
        /// The flag is deliberately NOT set: the next launch, after the store's migrations, will decide.
        case notReady
        /// Fewer than `RespChannelGate.minSamples` rows, or ≥ 3 distinct raw values (a real waveform).
        /// Nothing deleted; the flag IS set — this store has nothing to reclaim, now or later.
        case notDegenerate
        /// Rows removed. `vacuumed` is false when the volume couldn't afford the temporary copy.
        case purged(rows: Int, vacuumed: Bool)
        /// SQLite refused (typically a busy VACUUM against a connection the BLE stack already holds).
        /// The flag stays unset so the next launch retries.
        case failed(String)
    }

    /// Delete the banked degenerate `respSample` rows, once, if this database's channel really is degenerate.
    ///
    /// SYNCHRONOUS and potentially multi-second on a large store (a full scan plus a `VACUUM` that rewrites
    /// the file) — callers must run it OFF the main actor. Never throws; every failure mode is an outcome.
    @discardableResult
    static func purgeDegenerateRespSamplesIfNeeded(databaseAt path: String,
                                                  defaults: UserDefaults = .standard) -> RespPurgeOutcome {
        if defaults.bool(forKey: respPurgeDefaultsKey) { return .alreadyRun }
        guard FileManager.default.fileExists(atPath: path) else { return .notReady }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return .failed(why)
        }
        defer { sqlite3_close(db) }
        // Don't fight the BLE stack's connection for the writer lock; the retry is a launch away.
        sqlite3_busy_timeout(db, 2_000)

        guard scalar(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='respSample'") == 1
        else { return .notReady }

        // Is the channel degenerate ON THIS DATABASE? Both probes are LIMIT-bounded, so the "genuine
        // waveform" answer costs a partial scan, not a full one.
        let sampled = scalar(db, "SELECT COUNT(*) FROM (SELECT 1 FROM respSample LIMIT \(RespChannelGate.minSamples))")
        let levels = scalar(db, "SELECT COUNT(*) FROM (SELECT DISTINCT raw FROM respSample LIMIT \(RespChannelGate.maxDegenerateLevels + 1))")
        guard let sampled, let levels else { return .failed(String(cString: sqlite3_errmsg(db))) }
        // TOO FEW ROWS IS NOT A VERDICT. A fresh install reaches this on its second launch with an
        // essentially empty respSample and, by burning the one-shot flag, permanently disarmed itself
        // from zero evidence — so if the channel later banked the degenerate register, nothing would ever
        // reclaim it. Only a store that has actually shown us >= minSamples rows can answer the question;
        // below that we simply come back next launch.
        guard sampled >= RespChannelGate.minSamples else { return .notReady }
        guard levels <= RespChannelGate.maxDegenerateLevels else {
            defaults.set(true, forKey: respPurgeDefaultsKey)   // a genuine waveform — settled forever
            return .notDegenerate
        }

        guard sqlite3_exec(db, "DELETE FROM respSample", nil, nil, nil) == SQLITE_OK else {
            return .failed("DELETE: " + String(cString: sqlite3_errmsg(db)))
        }
        let deleted = Int(sqlite3_changes(db))

        // VACUUM rewrites the whole database through a temporary copy, so it needs free space up to the
        // current file size. Short on disk → skip it: the pages are already on the freelist and will be
        // reused by future inserts, which is the substance of the win.
        var vacuumed = false
        if volumeCanAfford(bytes: fileSize(atPath: path), near: path) {
            vacuumed = sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK
            if !vacuumed {
                NSLog("StoreMaintenance: respSample rows deleted but VACUUM failed (\(String(cString: sqlite3_errmsg(db)))) — space stays on the freelist.")
            }
        }

        defaults.set(true, forKey: respPurgeDefaultsKey)
        NSLog("StoreMaintenance: purged \(deleted) degenerate respSample row(s); vacuumed=\(vacuumed).")
        return .purged(rows: deleted, vacuumed: vacuumed)
    }

    // MARK: - Freelist reclaim (the one-shot behind SampleRetention)

    /// Freed bytes at/above which a full `VACUUM` is worth its cost, AND the fraction of the file they must
    /// represent. Both must hold, so a merely large database is never rewritten for nothing.
    ///
    /// Sized from the measurement that motivates this: `SampleRetention` bounds a store growing 24.4 MB per
    /// calendar day, so the FIRST sweep on a user who banked a year before it shipped frees multiple GB at
    /// once — and SQLite never shrinks a file on its own, so without this their peak size would persist
    /// forever as freelist. In STEADY STATE the freelist self-balances instead: measured over 4 cycles of
    /// {prune the oldest day, insert a fresh 1 Hz day} the file moved 422.1 → 422.8 MB, i.e. +0.7 MB total
    /// rather than +100 MB, because each prune's ~25 MB is consumed exactly by the next day's inserts. So
    /// no RECURRING vacuum is needed or wanted; these thresholds are set well above that equilibrium.
    static let reclaimMinFreeBytes = 128 * 1_024 * 1_024
    static let reclaimMinFreeFraction = 0.20

    /// What `reclaimFreelistIfNeeded` did.
    enum ReclaimOutcome: Equatable {
        /// No file yet, or the pragmas wouldn't read.
        case notReady
        /// The freelist is below `reclaimMinFreeBytes` / `reclaimMinFreeFraction` — nothing worth doing.
        case notNeeded(freeBytes: Int)
        /// The volume couldn't spare the transient copy a `VACUUM` needs. The pages stay on the freelist and
        /// are reused by future inserts, so the database simply stops growing instead of shrinking.
        case skippedNoSpace(freeBytes: Int)
        case vacuumed(freedBytes: Int)
        case failed(String)
    }

    /// Rewrite the database to hand reclaimed pages back to the filesystem, when — and only when — enough
    /// have accumulated to be worth a full rewrite.
    ///
    /// WHY A FULL VACUUM AND NOT `incremental_vacuum`. Measured on the real store: `PRAGMA auto_vacuum` is
    /// 0 (NONE), and with `auto_vacuum = NONE` an incremental vacuum is a provable no-op — deleting
    /// 1,521,264 rows on a copy left the file at 422.1 MB with `freelist_count` 20,541 (80.2 MB), and
    /// `PRAGMA incremental_vacuum(100000)` changed NOTHING: same file size, same freelist. Only a full
    /// `VACUUM` reclaims. (Flipping the file to `auto_vacuum = INCREMENTAL` during a vacuum costs just
    /// +0.2 MB and would make future reclaims incremental — but it rewrites the file format by adding
    /// pointer-map pages, so it is deliberately left as a decision to take explicitly, not a side effect.)
    ///
    /// SYNCHRONOUS and multi-second on a large store (measured 1.5 s for a 422 MB file) — callers must run
    /// it OFF the main actor, and BEFORE the app's own store handle exists, since `VACUUM` needs exclusive
    /// access. Never throws. No run-once flag is needed or wanted: a successful `VACUUM` clears the very
    /// condition that triggered it, so this self-limits, while a user who later frees another few GB gets
    /// the reclaim they need instead of being locked out by a stale flag.
    @discardableResult
    static func reclaimFreelistIfNeeded(databaseAt path: String) -> ReclaimOutcome {
        guard FileManager.default.fileExists(atPath: path) else { return .notReady }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return .failed(why)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        guard let freeList = scalar(db, "PRAGMA freelist_count"),
              let pageSize = scalar(db, "PRAGMA page_size"), pageSize > 0
        else { return .notReady }

        let freeBytes = freeList * pageSize
        let size = fileSize(atPath: path)
        guard freeBytes >= reclaimMinFreeBytes,
              size > 0, Double(freeBytes) / Double(size) >= reclaimMinFreeFraction
        else { return .notNeeded(freeBytes: freeBytes) }

        // VACUUM rewrites the whole database through a temporary copy, so it needs free space up to the
        // current file size.
        guard volumeCanAfford(bytes: size, near: path) else { return .skippedNoSpace(freeBytes: freeBytes) }
        guard sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else {
            let why = String(cString: sqlite3_errmsg(db))
            NSLog("StoreMaintenance: VACUUM failed (\(why)) — \(freeBytes) B stay on the freelist for reuse.")
            return .failed(why)
        }
        let freed = size - fileSize(atPath: path)
        NSLog("StoreMaintenance: VACUUM reclaimed \(freed) B (freelist was \(freeBytes) B).")
        return .vacuumed(freedBytes: freed)
    }

    // MARK: - Small helpers

    /// First column of the first row as an Int; nil when the statement wouldn't prepare/step.
    private static func scalar(_ db: OpaquePointer, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func fileSize(atPath path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// Can the volume holding `path` spare `bytes` right now? Unknown capacity answers NO — a VACUUM that
    /// runs the device out of space is far worse than one that never runs.
    ///
    /// INTERNAL rather than private (013): `BackupImport`'s pre-restore check asks this exact question of
    /// this exact volume, and a restore is the one place where discovering the answer halfway through
    /// costs the user data rather than a skipped optimisation. One predicate, one answer — the
    /// strictly-greater comparison below is the app's only definition of "can afford".
    ///
    /// NOTE for that caller: `bytes <= 0` answers NO, i.e. "unknown size" and "no space" are the same
    /// conservative answer here. That is right for a VACUUM and wrong for a refusal, so the restore gate
    /// never reaches this with an unmeasured size — see `BackupImport.requiredFreeBytes`.
    static func volumeCanAfford(bytes: Int, near path: String) -> Bool {
        guard bytes > 0 else { return false }
        guard let available = volumeAvailableBytes(near: path) else { return false }
        return available > Int64(bytes)
    }

    /// Bytes the volume holding `path` will hand out for important usage right now; nil when the read
    /// fails (nothing exists at `path` to stat, typically).
    ///
    /// Split out of `volumeCanAfford` so a refusal can NAME the free space it measured instead of
    /// asserting "not enough" with no number behind it (013 decision 9 — the app never prints a number
    /// it did not measure, and never states a shortfall it did not either). Same read, same key, one
    /// implementation; only `volumeCanAfford` turns nil into a verdict.
    static func volumeAvailableBytes(near path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
