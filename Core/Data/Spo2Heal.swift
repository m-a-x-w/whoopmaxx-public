import Foundation
import StrapAnalytics
import StrapStore

/// One-shot repair of the FABRICATED nightly SpO2 values persisted before `Spo2Estimator` stopped
/// clamping (that type's doc carries the full measurement).
///
/// The old estimator squashed an out-of-band linearization onto its lower clamp instead of rejecting
/// it. On the WHOOP historical `spo2Sample` stream — a 1 Hz sample-and-hold register whose red/IR
/// channels move in lockstep, so R collapses to DC_ir/DC_red > 1 by construction — `110 − 25·R < 85`
/// is an IDENTITY, and every scored night landed on exactly 85.0 %. Measured on a real 17-night
/// backup: 21/21 sleep sessions produced 85.0, and 17 of the 18 persisted `dailyMetric` rows carry it.
/// A sustained 85 % SpO2 reads as severe hypoxemia (below the <88 % supplemental-oxygen threshold);
/// the Data screen renders it as a real-but-bad reading and the Apple Health bridge writes it into the
/// user's permanent health record.
///
/// The fixed estimator returns nil there, and `MetricsCache.upsertDailyMetrics` OVERWRITES rather than
/// coalesces (`spo2Pct = excluded.spo2Pct`), so a rescore does genuinely clear a stale value — but only
/// for the days a rescore actually reaches. `ScoreEngine.analyzeRecent(maxDays: 21)` walks only the
/// trailing 21 local days (every caller takes the default), and inside it `guard hr.count >= 200 else
/// { continue }` skips — and therefore never upserts — any day whose raw HR has since been pruned.
/// Those rows would keep 85.0 forever. This sweep reaches all of them, exactly once.
///
/// Scoped STRICTLY to the computed `"<deviceId>-computed"` lane. An `spo2Pct` on the raw `"my-whoop"` lane
/// came from a WHOOP cloud export, is a genuinely measured value, and must never be cleared.
enum Spo2Heal {

    /// One-shot completion flag. Deliberately NOT in either settings whitelist (`BackupSettings` and
    /// `WmBackup.settingsWhitelist` are strict allowlists), so it never rides into a backup and a restore
    /// onto a FRESH install re-runs the sweep against the restored rows.
    ///
    /// That exclusion is necessary and was NOT sufficient. It says nothing about the install that has
    /// ALREADY healed: this flag describes an install, the sweep needs it to describe a database, and a
    /// restore swaps the database while leaving UserDefaults untouched. Measured on the user's real
    /// backup, a restore onto a healed install left all 17 fabricated 85.0 rows in place and re-exported
    /// them to Apple Health. `BackupImport`'s Gate 9 re-arms this key through `RestoreHealReset`.
    static let doneKey = "wm.heal.spo2ClampPinned.v1"

    /// How far back to sweep (days). Comfortably past `analyzeRecent`'s 21-day rescore window and past
    /// any window the dashboard reads, so a day no rescore can ever revisit is still reached once.
    static let lookbackDays = 400

    /// Clear the clamp-pinned `spo2Pct` rows on the computed lane, once per armed pass. After a clean
    /// pass this is a single `UserDefaults` bool read, so it is safe on the launch path. Silent unless it
    /// actually changed rows.
    ///
    /// WHAT COUNTS AS FABRICATED — `spo2Pct <= Spo2Estimator.bandLo`, not merely "non-nil". The fixed
    /// estimator treats `bandLo` (85.0) as a REJECT FLOOR: a window whose linearization lands at or below
    /// it returns nil, so a value at-or-below 85.0 on the computed lane cannot have been written by the
    /// current code and is provably a pre-fix clamp artefact. On the real 17-night backup every one of
    /// the 17 pinned rows is exactly 85.0, so this predicate clears the same 17 rows the original
    /// non-nil test did.
    ///
    /// WHY THE PREDICATE MATTERS NOW. `RestoreHealReset` re-arms this flag on every landed restore
    /// (`BackupImport` Gate 9), so this is no longer once-per-lifetime — it runs again each time the user
    /// restores. A blanket "null every non-nil computed spo2Pct" would then be a standing hazard: on
    /// hardware where the fixed estimator DOES score (the pulsatile fixtures still do), a legitimate
    /// value older than the raw-retention horizon has no raw left to re-derive it from, so nulling it
    /// would destroy it permanently rather than for one window. Days INSIDE the rescore window are safe
    /// either way — the forced pass at `AppRoot`'s `.rawHistory` re-derives them straight after this
    /// sweep — but the days beyond it are exactly the ones this sweep exists to reach. Bounding the
    /// sweep to the reject floor keeps it provably non-destructive however often it re-runs.
    ///
    /// `defaults` is injected so a test can drive the restore AND the heal through one throwaway suite;
    /// it defaults to `.standard`, which is the domain both production call chains use (the settings
    /// domain `BackupImport.restore` re-arms is `.standard` too — see Gate 9).
    ///
    /// The flag advances ONLY on a clean pass — a transient DB error must not consume the one-shot and
    /// strand the fabricated values (the same failure discipline `HealthExport`'s evictions use).
    @discardableResult
    static func runIfNeeded(store: StrapStore, deviceId: String, now: Date = Date(),
                            defaults: UserDefaults = .standard) async -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let computedId = deviceId + "-computed"
        let from = DayKey.local(now.addingTimeInterval(-Double(lookbackDays) * 86_400))
        let to = DayKey.local(now.addingTimeInterval(86_400))
        do {
            let pinned = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
                .filter { ($0.spo2Pct ?? .infinity) <= Spo2Estimator.bandLo }
            if !pinned.isEmpty {
                try await store.upsertDailyMetrics(pinned.map { $0.clearingSpo2() }, deviceId: computedId)
                NSLog("Spo2Heal: cleared fabricated spo2Pct on \(pinned.count) computed day(s) in \(from)…\(to)")
            }
            defaults.set(true, forKey: doneKey)
            return pinned.count
        } catch {
            NSLog("Spo2Heal: sweep FAILED (\(error)) — leaving the flag clear so the next launch retries")
            return 0
        }
    }
}

private extension DailyMetric {
    /// The same row with `spo2Pct` cleared. `DailyMetric` is an immutable value type with no `var`
    /// fields, so substituting one column means rebuilding it — the local twin of `ScoreEngine`'s
    /// `with(spo2Pct:)`, which is fileprivate there and deliberately stays that way (it is the scoring
    /// pass's fold seam, not a general mutator).
    func clearingSpo2() -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: nil, skinTempDevC: skinTempDevC, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    solMin: solMin, remLatencyMin: remLatencyMin, wasoMin: wasoMin)
    }
}
