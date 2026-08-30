import Foundation
import StrapStore

/// One-shot repair of the sleep/HRV columns the round-3 analytics fixes rewrite.
///
/// Three shipped defects were corrected in `StrapAnalytics` at once, and all three change values that
/// are already persisted (and already ridden into `.wmbak` backups and Apple Health):
///
///  1. **Nightly HRV was inflated by splice-differencing.** `HRVAnalyzer.rejectEctopic` returns a
///     concatenation of survivors with no record of where beats were removed, and `rmssdRaw` then
///     differenced across those holes — manufacturing a large ΔNN out of the artifact it had just
///     rejected. Because RMSSD is a sum of squares those few pairs dominate: on 2026-07-09, 1 081 of
///     17 685 pairs (6.11 %) straddle a dropped beat yet carry 46.95 % of the sum-of-squares.
///     Compounding it, `SleepStaging.sessionAvgHRV` had no per-window quality gate at all — it accepted
///     any 5-minute window with `cleaned.count >= 2` and averaged every window with EQUAL weight, so a
///     window that discarded 82 % of its own beats contributed its (largest, most fabricated) number at
///     full weight. Replayed over the real 2026-07-26 backup, all 21 stored `avgHrv` values reproduced
///     EXACTLY under the shipped code and then moved −4.8 % to −37.5 % (mean −18.7 %) under the fix.
///
///  2. **Deep sleep was starved by an un-cleaned per-epoch RMSSD.** `SleepStaging.extractFeatures` used a
///     bare `rangeFilter` where every other HRV consumer uses the full Malik chain, which INVERTED the
///     HR/RMSSD relationship and made the DEEP rule's two conjuncts mutually exclusive. Deep went from
///     1.55 % of TST (10 of 21 nights at exactly 0 minutes) to 4.21 %.
///
///  3. **`solMin` was never a sleep latency.** It is now always nil — see
///     `SleepStaging.HypnogramMetrics.leadingNonSleepS`.
///
/// WHY A HEAL IS NEEDED AT ALL. `ScoreEngine.analyzeRecent(maxDays: 21)` only rescores the trailing 21
/// local days (every production caller takes the default), and inside it a day whose raw HR has since
/// been pruned is skipped and never upserted. Days outside that reach keep their pre-fix `avgHrv`,
/// `deepMin` / `remMin`, `recovery` and `solMin` forever, so the history the user scrolls through would
/// be half corrected and half not.
///
/// WHAT THIS DOES — and, as importantly, what it deliberately does NOT do:
///
///  • **Widen the rescore, once.** `rescoreDays` spans the raw-sample retention horizon, so EVERY day
///    whose raw still exists is genuinely re-derived by the corrected code rather than patched. This is
///    a recompute, not a guess, and it is the only step that can restore a correct value.
///
///  • **Null the stale `solMin` rows.** The column is nil by contract now; a leftover number would keep
///    reading as a real latency and would ride into the next `.wmbak`.
///
///  • **NOT null `avgHrv` / `recovery` on days the rescore cannot reach.** Invalidating them was
///    considered and rejected on two grounds. First, they are the ONLY record those nights have — the
///    raw is gone, so the value can never come back. Second, and decisively, it would re-create the very
///    defect this round fixes elsewhere: `ScoreEngine`'s causal Charge gate folds its seed prefix over
///    the persisted per-day `avgHrv`, so blanking old days shrinks that prefix and starts suppressing —
///    and therefore NULLING — Charge on days that are legitimately seeded.
///    The usual argument for invalidating (a poisoned baseline) does not apply here: `analyzeRecent`
///    folds `baselines2.hrv` over the IMPORTED lane ∪ the days THIS pass scanned. Previously-persisted
///    computed-lane values never enter that fold, so once the wide rescore above has run, the HRV
///    baseline is built entirely from corrected values regardless of what the old rows still say.
///
/// The Apple Health half lives in `HealthExport.purgeStaleHrvIfNeeded` (the samples were exported with
/// the inflated numbers and its own 14-day window cannot reach back either).
enum SleepHrvHeal {

    /// One-shot completion flag. Deliberately NOT in either settings whitelist (`BackupSettings` and
    /// `WmBackup.settingsWhitelist` are strict allowlists), so it never rides into a backup and a restore
    /// onto a FRESH install re-runs the heal against the restored rows — which is exactly right, since a
    /// restored store carries the pre-fix values.
    ///
    /// That exclusion is necessary and was NOT sufficient, and the gap is the whole reason
    /// `RestoreHealReset` exists. The flag describes an INSTALL ("I have healed"); the heal needs it to
    /// describe a DATABASE ("these rows are healed"). A restore swaps the database and leaves
    /// UserDefaults untouched, so on an install that had already healed, the measured outcome was
    /// `isPending == false`, zero rows swept, and all 17 stale `solMin` values surviving the restore.
    /// `BackupImport`'s Gate 9 re-arms this key.
    ///
    /// SAFE TO RE-RUN, which is the bar for being in that registry: `AnalyticsEngine` now writes
    /// `solMin: nil` unconditionally, so a non-nil `solMin` on the computed lane can only ever be a
    /// pre-fix leftover. Re-running this sweep after a restore therefore cannot destroy a value the
    /// current code could have produced, however many times a user restores.
    static let doneKey = "wm.heal.sleepHrvSpliceAndDeep.v1"

    /// How far back the ONE widened rescore reaches, in local days. Matched to
    /// `SampleRetention.hardCapDays` — the outermost horizon at which decoded samples can still exist, so
    /// this reaches every day that is recomputable at all and wastes no work on days that are not.
    static let rescoreDays = SampleRetention.hardCapDays

    /// How far back the `solMin` sweep reaches (days). Comfortably past every rescore window and past any
    /// window the dashboard reads, so a day no rescore can revisit is still cleaned once.
    static let lookbackDays = 400

    /// True until the heal has completed a clean pass. One `UserDefaults` bool read, safe on the launch
    /// path.
    ///
    /// Reads `.standard` — the production domain, and the one `BackupImport`'s Gate 9 re-arms. A test that
    /// drives `finish(defaults:)` against an injected suite must read that suite's `doneKey` directly
    /// rather than this.
    static var isPending: Bool { !UserDefaults.standard.bool(forKey: doneKey) }

    /// Finish the heal: null every stale `solMin` on the computed lane and record completion.
    ///
    /// Call AFTER the widened rescore, so a day the rescore reached is already correct and this only
    /// mops up the days it could not.
    ///
    /// Scoped STRICTLY to the computed `"<deviceId>-computed"` lane. A `solMin` on the raw `"my-whoop"` lane
    /// came from a WHOOP cloud export — a genuinely measured latency from a device that DOES have an
    /// in-bed reference — and must never be cleared.
    ///
    /// The flag advances ONLY on a clean pass: a transient DB error must not consume the one-shot and
    /// strand the stale values (the same failure discipline `Spo2Heal` and `HealthExport`'s evictions
    /// use).
    ///
    /// `defaults` is injected so a test can drive the restore AND the heal through one throwaway suite;
    /// it defaults to `.standard` — the domain `isPending` reads and the domain `BackupImport.restore`
    /// re-arms in production (Gate 9).
    @discardableResult
    static func finish(store: StrapStore, deviceId: String, now: Date = Date(),
                       defaults: UserDefaults = .standard) async -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let computedId = deviceId + "-computed"
        let from = DayKey.local(now.addingTimeInterval(-Double(lookbackDays) * 86_400))
        let to = DayKey.local(now.addingTimeInterval(86_400))
        do {
            let stale = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
                .filter { $0.solMin != nil }
            if !stale.isEmpty {
                try await store.upsertDailyMetrics(stale.map { $0.clearingSol() }, deviceId: computedId)
                NSLog("SleepHrvHeal: cleared meaningless solMin on \(stale.count) computed day(s) in \(from)…\(to)")
            }
            defaults.set(true, forKey: doneKey)
            return stale.count
        } catch {
            NSLog("SleepHrvHeal: sweep FAILED (\(error)) — leaving the flag clear so the next launch retries")
            return 0
        }
    }
}

private extension DailyMetric {
    /// The same row with `solMin` cleared. `DailyMetric` is an immutable value type with no `var` fields,
    /// so substituting one column means rebuilding it — the local twin of `Spo2Heal.clearingSpo2()`.
    func clearingSol() -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    solMin: nil, remLatencyMin: remLatencyMin, wasoMin: wasoMin)
    }
}
