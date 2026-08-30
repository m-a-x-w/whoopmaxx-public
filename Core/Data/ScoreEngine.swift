import Foundation
import Combine
import StrapProtocol
import StrapStore
import StrapAnalytics

/// On-device score orchestration: computes Charge (recovery) / Effort (strain) / Rest (sleep) from the
/// raw strap streams, the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%,
/// sleep ~15%, respiration ~5%; Effort from cardiovascular load). This is what makes whoopmaxx
/// independent of WHOOP's cloud — for any day the strap collected raw data, the engine scores it itself.
///
/// Copy-and-prune of the original `IntelligenceEngine` (the load-bearing analyzeRecent day loop, the two-pass
/// baseline seeding, the sleep_performance series write, the sleep-session persistence + #899 dedup heal,
/// and the per-day owner resolution are kept verbatim in shape). W7 re-enables detected-workout
/// persistence (the gravity-gated bouts the pipeline already computes are folded, overlap-skipped against
/// real strap/manual/apple sessions, and delete+upsert-persisted idempotently under the computed id) plus
/// the post-sync `rescoreManualWorkouts` upgrade. PRUNED for whoopmaxx: the V5
/// illness/cycle/circadian signal refreshes, the Apple-Watch / wearable-import recovery folds, the
/// steps-estimate calibration, Fitness Age / Vitality weekly writes,
/// user-edited-sleep substitution, the Test Centre trace plumbing, and the #313/#547 one-shot
/// rescore/heal passes as DEDICATED passes — BLEManager's #547 re-heal poke lands on the
/// `IntelligenceEngine` shim in Core/Stubs and `analyzeRecent` DOES honour it: it reads-and-clears
/// `IntelligenceEngine.timestampHealKey` at the top of the pass and forces that pass past the #836
/// idle gate (a forced re-score, not the original's separate heal pass).
@MainActor
final class ScoreEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    /// The CANONICAL id under whose `-computed` sibling this engine WRITES the computed daily rows, and from
    /// which it reads the imported-only baseline (`hist`). STABLE on "my-whoop" — it must NOT follow the
    /// active strap, or a remove+re-add would orphan the computed history banked under the canonical id.
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    /// #899-A re-arm: a `force: true` recompute (a post-backfill rescore AppRoot kicks off after a sync)
    /// that arrives while an idle-tick pass already holds the `computing` lock would otherwise be silently
    /// dropped. Instead the dropped force records its WIDTH here; the in-flight pass's `defer` re-invokes
    /// `analyzeRecent(force: true)` ONCE when it clears. Single re-arm — no recompute storm.
    ///
    /// It carries `maxDays`, not a bare Bool, because the width is the whole point for one caller:
    /// `JournalStore.set` passes `rescoreReach(editedDay:)`, which widens to as much as
    /// `SampleRetention.hardCapDays` so a BACK-DATED tag actually reaches the night it contexts. A Bool
    /// re-armed at the HOLDER's `maxDays` — 21 for every other caller — so a tag toggled 40 days back
    /// while a sync-triggered pass was in flight silently re-scored only the last three weeks, and that
    /// night kept its pre-tag verdict forever (nothing retries: `JournalStore.set` ignores the return).
    /// Several dropped calls collapse into ONE widest pass, so this stays a single re-arm.
    private var pendingForcedRescoreDays: Int?
    /// #899 heal bound: true while the last heal already re-armed a rescore, so a heal firing again on
    /// the very next pass cannot re-arm a second time. Reset by any pass whose heal finds nothing.
    private var healRearmedThisCycle = false

    /// Who supplies the dashboard headline for a day: the engine's own computed row, or a WHOOP import
    /// that wins the per-day merge (imports win field-by-field — see Repository.mergeDaily).
    enum DaySource: Equatable {
        case computed
        case whoopImport

        var badge: String {
            switch self {
            case .computed:    return String(localized: "On-device")
            case .whoopImport: return "Whoop"
            }
        }

        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            }
        }

        static func classify(day: String, importedWhoopDays: Set<String>) -> DaySource {
            importedWhoopDays.contains(day) ? .whoopImport : .computed
        }
    }

    /// One day's off-actor scan output. Carries the pure `DayEngine.DayResult` produced by the
    /// off-main scan loop plus the pre-computed RHR floor-vs-mean diagnostic line (#691), so the main
    /// actor can replay it through the MainActor-bound `diagnosticSink` in the SAME per-day order.
    private struct DayScan {
        let result: DayEngine.DayResult
        let rhrLine: String?
        /// The resolved READ owner id this day was scored from + its HR-row count for the night window.
        let readOwner: String
        let hrRows: Int
        /// Nightly SpO2 %% ESTIMATE (uncalibrated ratio-of-ratios over the night's raw red/IR PPG,
        /// Spo2Estimator) — computed beside analyzeDay because the raw spo2 stream never rides into it.
        /// nil when the strap banks no spo2 stream or too few clean windows survived the gates.
        let spo2: Double?
        /// Wrist-orientation summary for this day's main night (011 W2.3) — computed beside analyzeDay
        /// because the raw gravity is already in memory there and the alternative is a second
        /// 200k-row read per night at persist time. nil when the night could not be read (no gravity,
        /// too little of it held still, or no orientation the night returned to) — and nil then means
        /// NO POINT IS WRITTEN, never a zero.
        let posture: PostureEngine.Summary?
        /// This day's LOCAL midnight (the loop's `dayStart`). Only days that cleared the 200-sample raw
        /// floor reach here, so the min over a pass is the oldest instant it actually RE-DERIVED — which
        /// is what bounds the detected-workout eviction below (C1's rule, applied to workouts).
        let dayStart: Int
        /// This day's sleep rows with the NIGHT-SILENCE flag folded in (030 Track A): byte-identical to
        /// `result.cachedSleep` except that a session whose STAGED SLEEP overlaps worn silence carries
        /// `lowConfidence = true`. Every other field — `stagesJSON` above all — is copied verbatim, so
        /// nothing downstream of the hypnogram (Apple Health export included) sees any change.
        let flaggedSleep: [CachedSleepSession]
        /// Staged ASLEEP minutes on this day that sit over worn silence (030 Track A). 0.0 is a REAL
        /// answer — "scanned, and none of the staged sleep sits over silence". nil means the question
        /// was not asked: the day banked no sleep session at all, or the HR read hit its row limit and
        /// its truncated tail would read as a phantom silence.
        let unmeasuredStagedMin: Double?
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        var source: DaySource = .computed
        /// CHARGE confidence only — the name is historical. Effort's tier rides `effortCoverage` below.
        var confidence: ScoreConfidence = .solid
        /// Waking-window capture coverage in [0,1] for the day, or nil when it was not graded. Effort is an
        /// ACCUMULATED score with no coverage term, so this is the only thing that distinguishes a genuine
        /// rest day from a half-captured one (the real 2026-07-15 scored 27.01 at 66.8% coverage, inside
        /// the full-coverage cluster).
        var effortCoverage: Double? = nil
        /// Ordered "what shaped it" Charge driver list, biggest mover first (W3+ Charge detail rows).
        var drivers: [ChargeDriver] = []
        /// The night's skin temperature as a RELATIVE deviation from the personal baseline.
        var skinTempRel: SkinTempRelative? = nil
        var id: String { day }
    }

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the shareable strap log
    /// (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the engine stays testable with no
    /// UI. AppRoot wires it to `live.append(log:domain:)`.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    /// Republish hook for the ONE pass that is its own caller: the `#899-A` re-arm below runs detached,
    /// so nothing is awaiting its return value to refresh the caches. AppRoot wires this to the
    /// `dataDidChange(.derivedRows)` seam. Refreshing `repo` alone here is NOT enough — a re-armed
    /// forced rescore can write detected workout rows, which live in `WorkoutRepository`'s cache, and
    /// they would otherwise surface only on the next sync or 15-minute tick. Defaults to a plain
    /// `repo.refresh()` so the engine stays usable (and testable) with no AppRoot.
    var onWroteRows: (() async -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// The per-day RHR floor-vs-mean diagnostic line (#691). whoopmaxx's `restingHr` is the WHOOP-style
    /// FLOOR (lowest sustained 5-min in-bed level); a "sleeping HR" app reports the night MEAN. Logging
    /// both makes a "RHR reads lower than my other app" report explainable. Counts/bpm only — no PII.
    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = whoopmaxx RHR; mean = sleeping-HR-app number)"
    }

    /// Cold-start floor for the personal sleep-need mean: below this many nights of trailing sleep
    /// history we fall back to `Rest.defaultNeedHours` (8 h) instead of trusting a thin mean.
    /// `nonisolated`: read by the nonisolated `personalNeedHours(days:)` below (an immutable `Int`).
    private nonisolated static let personalNeedMinNights = 7

    /// The PERSONALIZED nightly sleep need in HOURS: the trailing mean of nightly asleep hours
    /// (`totalSleepMin/60`, only nights with `tst > 0`), floored at 7.5 h; under
    /// `personalNeedMinNights` nights fall back to `Rest.defaultNeedHours` (8 h).
    /// Drives the Rest composite's 0.50 duration term. THE single derivation — the Rest screen's
    /// need-line + debt read this same function, so they can never disagree with the hero Rest
    /// score. Pure + nonisolated so tests can drive it without a store.
    nonisolated static func personalNeedHours(days: [DailyMetric]) -> Double {
        let perNight: [Double] = days.compactMap { d -> Double? in
            if let tst = d.totalSleepMin, tst > 0 { return tst / 60.0 }
            return nil
        }
        guard perNight.count >= Self.personalNeedMinNights else { return Rest.defaultNeedHours }
        return Swift.max(7.5, perNight.reduce(0, +) / Double(perNight.count))
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    ///
    /// Returns TRUE when the pass actually wrote rows (fresh dailies, a #899 heal that dropped stale
    /// sessions, or re-persisted detected workouts) — i.e. when the dashboard caches are now behind the
    /// store and the CALLER must re-read them. The engine deliberately does NOT refresh the Repository
    /// itself: it reads the store, the Repository publishes it, and a self-refresh made those two a
    /// cycle. `AppRoot.dataDidChange` is the one seam that owns the follow-up refresh/publish/export.
    @discardableResult
    func analyzeRecent(maxDays: Int = 21, force: Bool = true) async -> Bool {
        // #899-A: a concurrent pass already holds the lock. A non-forced idle tick is safe to drop, but
        // a FORCED call is a real update path (post-backfill rescore) — re-arm instead of dropping.
        guard !computing else {
            if force { pendingForcedRescoreDays = Swift.max(pendingForcedRescoreDays ?? 0, maxDays) }
            return false
        }
        // Check-and-acquire must be ATOMIC on the main actor: set the lock SYNCHRONOUSLY before the
        // first await (main-actor re-entrancy would otherwise let a second caller pass the guard while
        // this pass is suspended on a store read — two full scoring passes interleaving), and install
        // the release/re-arm defer FIRST so every early return below still releases the lock.
        computing = true
        // #899-A re-arm: clear the lock, then if a forced rescore was dropped while this pass held it,
        // run it ONCE (the flag is cleared BEFORE the re-invoke, so this can never recurse unbounded).
        // The re-armed pass is its OWN caller, so it honours the return contract above and republishes
        // when it wrote something — nobody else is awaiting this detached pass. It goes through
        // `onWroteRows` (the `.derivedRows` seam) rather than `repo.refresh()` directly, so the workout
        // cache — a separate object since the read/write split — is refreshed too.
        defer {
            computing = false
            if let pending = pendingForcedRescoreDays {
                pendingForcedRescoreDays = nil
                // Never NARROW: re-run at the widest width anyone asked for, including this pass's own.
                // Widening only re-derives more days from raw samples that still exist and upserts them —
                // the same safety argument the round-4 / weed one-shots run on, at the same width.
                let width = Swift.max(pending, maxDays)
                Task {
                    guard await self.analyzeRecent(maxDays: width, force: true) else { return }
                    if let hook = self.onWroteRows { await hook() } else { await self.repo.refresh() }
                }
            }
        }
        // #547: a sync that DROPPED implausible (bad-clock) records poked
        // `IntelligenceEngine.requestTimestampReheal()`, which raised this flag. Read-and-clear it here —
        // synchronously, in the same pre-await block that took the lock, so a poke landing mid-pass is
        // left for the NEXT pass instead of being swallowed by this one (a pass that bounced off the
        // `computing` guard above never reaches this, so it leaves the flag for the holder's successor).
        let healPending = UserDefaults.standard.bool(forKey: IntelligenceEngine.timestampHealKey)
        if healPending { UserDefaults.standard.removeObject(forKey: IntelligenceEngine.timestampHealKey) }
        // A pending heal makes this pass FORCED: dropping those records changes what the affected days
        // score from WITHOUT necessarily moving the raw-HR fingerprint, so the #836 gate below (which is
        // the ONLY thing `force` controls) must not short-circuit the very pass meant to heal them.
        // ── ROUND-4 ONE-SHOT RE-SCORE (staging + baseline spread) ────────────────────────────────────
        // Three round-4 changes rewrite values that are ALREADY persisted, and the ordinary pass only
        // reaches the trailing `maxDays` (21 on every production caller):
        //   • the V1 stager's reference-percentile pool is now motion-restricted (REM 12.60 % → 16.51 %
        //     of TST over the real 21 sessions) and its deep front-loading rule is gone (deep 4.42 % →
        //     6.99 %), so `deepMin` / `remMin` / `lightMin` / `totalSleepMin` / `efficiency` and the
        //     derived `sleep_performance` all move;
        //   • `Baselines`' spread EWMA no longer reports an un-removed floor-valued seed as measured
        //     dispersion, so every `recovery` computed while the baseline was young moves (on the real
        //     record the 14 scored days move −5.2…+7.6 points, 3 of them across a band boundary).
        // Days outside the ordinary window would keep their pre-change values forever, so the history
        // the user scrolls would be half corrected and half not — the same failure `SleepHrvHeal`
        // documents. Widen ONE pass to the raw-retention horizon so every day that is recomputable at
        // all is genuinely RE-DERIVED (not patched), then never again.
        //
        // Cannot destroy history: this only widens which days are recomputed. A day whose raw samples
        // have been pruned is skipped and never upserted, and the nil-write rules are exactly the ones
        // the ordinary pass already applies (`recoveryToPersist` carries a stored score forward whenever
        // the baseline WAS usable for that day, and writes nil only where the causal seed gate refuses —
        // which is the round-2 behaviour the widened window makes MORE correct, not less, because more
        // of the real record is in scope). `SleepHrvHeal` already ships a rescore of exactly this width,
        // so the blast radius is one already-shipped pass, repeated once.
        //
        // The restore gap this block once flagged is CLOSED: like `Spo2Heal` / `SleepHrvHeal`, this key is
        // registered in `BackupImport`'s restore re-arm list (`RestoreHealReset.storeScopedOneShots`), so a
        // `.wmbak` restore onto an already-healed install re-runs the widened pass against the restored rows.
        let round4Rescore = !UserDefaults.standard.bool(forKey: Self.round4RescoreDoneKey)
        // ── 009 WEED-CONFOUNDER ONE-SHOT RE-SCORE ────────────────────────────────────────────────────
        // 009 added `weed` to `IllnessSignalEngine.Context`, so a night whose D-1 carries the weed tag now
        // evaluates `.suppressed` where it previously evaluated `.raised`/`.mild`. Every night already
        // banked outside the ordinary 21-day window keeps its pre-weed `strain_level` forever otherwise —
        // the detail screen would read "with no logged behavior to explain them" with the weed chip lit on
        // D-1. Same shape, same width and same safety argument as the round-4 pass above: it only
        // re-derives days from raw samples that are still present and upserts, so it destroys nothing and
        // is safe to re-run — which is why it is registered in `RestoreHealReset` too.
        let weedRescore = !UserDefaults.standard.bool(forKey: Self.weedConfounderRescoreDoneKey)
        // The DAY WIDTH this pass actually scans. Every downstream window derives from this, not from
        // the `maxDays` parameter, so the widened one-shot really does reach the older days.
        let scanDays = (round4Rescore || weedRescore) ? Swift.max(maxDays, SampleRetention.hardCapDays) : maxDays
        // A widened one-shot is FORCED for the same reason a timestamp heal is: the raw-HR fingerprint
        // the #836 gate keys on has not moved, but what those days score from HAS.
        let forced = force || healPending || round4Rescore || weedRescore
        guard let store = await repo.storeHandle() else { note = String(localized: "No on-device store yet."); return false }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return false }

        // #836 (idle-tick gate): a cheap whole-history HR fingerprint (count+maxTs, indexed) lets a
        // NON-forced caller short-circuit when the raw stream is unchanged since the last completed run.
        let wmKey: String = (try? await store.hrFingerprint(deviceId: deviceId, from: 0, to: 9_999_999_999))
            .map { "\($0.count):\($0.maxTs)" } ?? ""
        if !forced, !wmKey.isEmpty,
           UserDefaults.standard.string(forKey: Self.analyzeWatermarkKey) == wmKey {
            return false
        }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        let tzOffset = TimeZone.current.secondsFromGMT()

        let computedId = deviceId + "-computed"
        // rhr / resp / skin honour the Charge-wide recalibration epoch; HRV its own. 0 = no-op. Read ONCE
        // here because pass 1's Effort fallback below needs it too (it used to be read only in pass 2).
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()
        // The computed lane's full persisted history. Read BEFORE pass 1 (it used to be read after the
        // scan loop) because two different things need it now: the round-3 causal Charge seed prefix in
        // pass 2, and pass 1's personal resting-HR fallback for Effort immediately below.
        let persistedComputed = ((try? await store.dailyMetrics(deviceId: computedId,
                                                                from: "0000-01-01", to: "9999-12-31")) ?? [])

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. Each night's
        // avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we harvest them to SEED the baseline
        // and re-score in pass 2. Read the imported rows DIRECTLY (not `repo.days`, the merged cache —
        // using the merge would contaminate this imported-only baseline with computed values).
        //
        // "IMPORTED-ONLY" is literal and is NOT a claim that the fold is usable: for the app's stated
        // strap-only user this lane has ZERO rows, so both folds below are `foldHistory([])` — nValid 0,
        // status `.calibrating`, `usable == false`, and a midpoint SEED for a baseline (75.0 bpm for
        // resting HR). Anything in `analyzeDay` that wants a personal number on the pass-1 path must
        // therefore be handed one from a lane that EXISTS; it cannot read it off `baselines1`. That is
        // exactly what `restingHRFallbackBpm` below is for.
        // The oldest instant this store holds anything, used to floor capture-coverage grading so a day
        // is never graded over hours that predate the install (see the `clampStart` call site below).
        let firstEverHrTs = try? await store.earliestHRSampleTs(deviceId: deviceId)

        let hist = ((try? await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, dayKeys: hist.map { $0.day }, cfg: hrvCfg,
                                             offsetSec: tzOffset)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, dayKeys: hist.map { $0.day },
                                             cfg: rhrCfg, baselineEpoch: recoveryEpoch,
                                             offsetSec: tzOffset)
        let baselines1 = DayEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // ── Effort's PERSONAL resting-HR fallback, for days that banked no sleep session ──────────────
        // `strain` is produced in pass 1 and pass 2 only substitutes recovery/skinTempDev (the day's HR
        // stream is deliberately dropped each iteration for memory), so the fallback has to be built HERE,
        // before the scan loop, from a lane that exists: the imported lane ∪ the computed lane's own
        // persisted `restingHr` (imported wins per day — the same precedence `chargeSeedSequence` uses for
        // avgHrv). `restingHr` is baseline-INDEPENDENT (it is the night's HR floor), so seeding a baseline
        // from it and then feeding that baseline back into Effort introduces no feedback loop.
        //
        // Gated on `usable`: an unusable fold returns `foldHistory([])`'s (30+120)/2 = 75.0 midpoint SEED,
        // which on the real 2026-07-15 scores Effort 17.93 against the generic 60's 27.01 and this user's
        // real ~46's 37.44 — i.e. worse than no fallback at all. A first-ever pass with no persisted lane
        // still falls to `StrainScorer.defaultRestingHR`, which is honest.
        //
        // Measured over the real 17-day record: `foldHistory(rhrSeq)` = 46.15 bpm, spread 2.10, nValid 17,
        // `.trusted`; the causal as-of-day fold reaches 46.23 by 2026-07-15 and both give Effort 37.44, so
        // the simpler global union is used. 17 of 18 days are byte-identical — only the no-session day moves.
        let restingHRFallbackBpm = Self.restingHRFallback(hist: hist, persistedComputed: persistedComputed,
                                                          recoveryEpoch: recoveryEpoch, offsetSec: tzOffset)

        // Keep each night's small result, NOT the raw streams — the hr/rr/resp/gravity arrays go out of
        // scope each iteration so memory stays bounded.
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            nightlySkin: Double?,
                            sessionMotion: [Int: [Double]],
                            sessionSleepState: [Int: [Int]],
                            workouts: [ExerciseSession],
                            // Wrist-orientation summary for the main night (011 W2.3), or nil when the
                            // night could not be read. Persisted as the `posture_*` series so the
                            // per-night numbers outlive the 28-day gravity retention.
                            posture: PostureEngine.Summary?,
                            // Waking-window capture coverage in [0,1], or nil for "not graded yet".
                            // Persisted as `effort_coverage` so the UI can flag an Effort score built on
                            // partial capture; never used to rescale `strain`.
                            dayCoverage: Double?,
                            // Staged ASLEEP minutes sitting over worn silence (030 Track A), or nil when
                            // the night was not graded for it. Persisted as `sleep_unmeasured_min`;
                            // like `dayCoverage` it never rescales a score.
                            unmeasuredStagedMin: Double?)] = []
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        // Device-registry snapshot for per-day owner resolution (invariant I2 — a day's scores come from
        // exactly ONE source). With only the seeded "my-whoop" row paired (every single-WHOOP install)
        // `resolveDayOwner` returns `deviceId` for every day, byte-identical to a single-source read.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let regDevices = (try? registry.all()) ?? []
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        // Floor `now` to LOCAL midnight (#277) so the day keys are LOCAL calendar days.
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)

        // Learned habitual midsleep (#547): computed once per run from the trailing sleep history so the
        // main-night scored pick aligns to the user's REAL bedtime. nil under 14 days → cold-start band.
        let habitualMidsleepSec = await Self.computeHabitualMidsleep(
            store: store, importedId: deviceId, computedId: deviceId + "-computed",
            windowStart: nowLocalMidnight - scanDays * 86_400 - 30 * 3_600,
            windowEnd: now, offsetSec: tzOffset)

        // The MERGED daily history the two sleep inputs below read — the SAME two-lane store read +
        // pure `mergeDaily` the Repository publishes, over the SAME 120-day window `Repository.refresh`
        // builds. Read from the STORE, not `repo.days`: taking the repository cache as scoring INPUT
        // made the engine depend on its own published output (refresh → analyze → refresh), the very
        // cycle the imported-only `hist` read above documents avoiding. Byte-identical when the cache
        // is fresh, and strictly better when it is stale.
        // NOT `hist` — that is the IMPORTED LANE ONLY, so a pure on-device user (no WHOOP export ever
        // imported) would see an empty history and a permanent 8 h default `personalNeedHours`.
        let nowDate = Date(timeIntervalSince1970: TimeInterval(now))
        let from120 = DayKey.local(nowDate.addingTimeInterval(-120 * 86_400))
        let to120 = DayKey.local(nowDate.addingTimeInterval(86_400))
        let mergedDays = Repository.mergeDaily(
            imported: (try? await store.dailyMetrics(deviceId: deviceId, from: from120, to: to120)) ?? [],
            computed: (try? await store.dailyMetrics(deviceId: computedId, from: from120, to: to120)) ?? [])

        // Personal sleep need: trailing mean of nightly asleep hours, floored at 7.5 h; under 7 nights
        // fall back to Rest.defaultNeedHours (8 h). Drives the Rest composite's 0.50 duration term.
        let personalNeedHours = Self.personalNeedHours(days: mergedDays)
        // Sleep/wake regularity in [0,1] over the merged history; nil under 3 nights keeps the Rest
        // composite's consistency term neutral (0.5).
        let sleepConsistency = VitalityEngine.sleepConsistency(
            nightlyHours: mergedDays.compactMap { $0.totalSleepMin }.map { $0 / 60.0 })
        let ageYears: Double? = profile.age > 0 ? Double(profile.age) : nil

        // ── Run the ENTIRE per-day enumeration OFF the main actor (FIX 1): the loop touches no
        // @Published state — only captured immutable inputs, the StrapStore actor, the nonisolated
        // registry, and pure statics — so its ~thousands of read-resumes never block SwiftUI.
        let ownerFallbackId = deviceId
        // Snapshot on the MainActor (diagnosticSink is MainActor-isolated; the scan runs detached): the RHR
        // floor-vs-mean diagnostic below is a log line with no consumer unless a sink is wired, but building
        // its `inBedBpms` is O(hr.count × sessions) per day over up to ~200k HR rows × maxDays. Skip the whole
        // build in the common (no-sink) config.
        let wantsRhrDiag = (diagnosticSink != nil)
        let scanned: [DayScan] = await Task.detached(priority: .utility) {
            var out: [DayScan] = []
            // Step scan days by CALENDAR, not fixed 86_400 s: a spring-forward local day is only 23 h, so
            // fixed 24 h stepping jumps clean OVER it (its key is never emitted → that night is never scored,
            // showing no Charge/Effort/Rest for ~21 days); fall-back's 25 h day collapses two offsets to one
            // key. Mirrors the StrapHealthModel fix. `baseDayStart` is today's local midnight.
            let baseDayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(nowLocalMidnight)))
            for offset in 0..<scanDays {
                guard let dayDate = Calendar.current.date(byAdding: .day, value: -offset, to: baseDayStart),
                      let nextDayDate = Calendar.current.date(byAdding: .day, value: 1, to: dayDate)
                else { continue }
                let dayStart = Int(dayDate.timeIntervalSince1970)
                let nextMidnight = Int(nextDayDate.timeIntervalSince1970)   // next LOCAL midnight (DST-aware)
                // TZ-PER-DAY (DST): resolve THIS day's own wall-clock offset from its instant.
                let dayTzOffset = TimeZone.current.secondsFromGMT(for: dayDate)
                let day = DayEngine.dayString(dayStart, offsetSec: dayTzOffset)
                // Read a generous window around the night that ends on `day`; the stager finds the span.
                let from = dayStart - 30 * 3_600
                // For a PAST day read through to the next local midnight so a late wake isn't truncated
                // (#500); TODAY keeps the 18:00 cap (the store clamps to `now` anyway).
                let to = (dayStart < nowLocalMidnight) ? nextMidnight : dayStart + 18 * 3_600

                // I2: pick the single device that owns this day, and read ITS streams below.
                let owner = await Self.resolveDayOwner(day: day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId)

                let hr = (try? await store.hrSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                guard hr.count >= 200 else { continue }   // need real raw data, not a stray sample
                let rr = (try? await store.rrIntervals(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                // Raw respiration, gated: a store banked BEFORE `RespChannelGate` landed still holds up to
                // ~200k mode-register rows a day (2 distinct values — see `RespChannelGate`). Dropping them
                // here spares the stager fingerprinting + epoch-binning them for a feature that is finite on
                // 0% of epochs. NOT hardcoded to `[]`: a genuine waveform passes the distinctness test and
                // reaches `SleepStaging.respRateAndRRV` exactly as before.
                var resp = (try? await store.respSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                if RespChannelGate.isDegenerate(resp) { resp = [] }
                let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                // Raw red/IR PPG for the nightly SpO2 ESTIMATE below (type-47 historical, raw ADC).
                // Empty on a strap that banks no spo2 stream — the estimate stays nil, absent stays absent.
                let spo2Raw = (try? await store.spo2Samples(deviceId: owner, from: from, to: to, limit: 200_000)) ?? []
                // #938: the strap family that WROTE this owner's skin-temp rows, so analyzeDay converts
                // the raw register on the right scale (a WHOOP 4.0 banks a raw ADC, a 5/MG centidegrees).
                let skinFamily = Self.skinTempFamily(forOwner: owner, devices: regDevices)
                // Wrist-wear events paired into off-wrist [start, end) intervals for the off-wrist sleep
                // backstop (#500/#504).
                // …read over whichever window is WIDER, the night read or the graded coverage window.
                // `to` caps TODAY's read at 18:00, but the coverage grader runs to min(22:00, now), and
                // GapScan explains HR silence away ONLY with an off-wrist interval. An evening spent off
                // the wrist was therefore invisible to it and its silence was booked as a genuine capture
                // gap — while the same seconds still counted toward the worn denominator, so today's
                // `effort_coverage` came out false-low. That is persisted and read everywhere: Today dims
                // the Effort column and captions "partial capture", and the Data tab WITHHOLDS the day's
                // Effort and Calories entirely, so its tile silently shows yesterday's number instead. It
                // self-corrects only once the day rolls over and is rescanned as a past day.
                //
                // Widening the EVENT read, not `to` itself: `to` also bounds the night/stream reads and
                // resolveDayOwner, and the 18:00 cap there is the deliberate #500 sleep-window guard.
                // Past days are unchanged (`to` is already nextMidnight).
                let wearTo = (dayStart >= nowLocalMidnight) ? Swift.max(to, now) : to
                let wristEvents = (try? await store.events(deviceId: owner, from: from, to: wearTo, limit: 50_000)) ?? []
                let wristOff = DayEngine.offWristIntervals(events: wristEvents, windowEnd: wearTo)

                // Calendar-day window for the ADDITIVE daily totals (steps + calories) (#277). `dayStart` is
                // already this day's local midnight and `nextMidnight` the next (both DST-aware), so the
                // window is exactly [dayStart, nextMidnight) — 23 h / 25 h on a DST day, not a hard 24 h.
                let dayMid = dayStart
                let dayEnd = nextMidnight - 1
                // #997: for a PAST day the calendar day is a strict subset of the night window already in
                // memory — slice instead of re-reading. TODAY / a limit-hit read declines and reads direct.
                let dayHr: [HRSample]
                if let slice = DayEngine.daySliceFromNight(hr, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayHr = slice
                } else {
                    dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }
                let daySteps: [StepSample]
                if let slice = DayEngine.daySliceFromNight(steps, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    daySteps = slice
                } else {
                    daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }
                let dayGrav: [GravitySample]
                if let slice = DayEngine.daySliceFromNight(grav, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayGrav = slice
                } else {
                    dayGrav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)) ?? []
                }

                // #531/#175: the strap's OWN band sleep_state for the night window, so the H7 morning-
                // stillness guard can confirm a borderline re-onset. Empty on a WHOOP 4.0 → HR-bar fallback.
                var bandSleepState = (try? await store.sleepStateSamples(deviceId: owner, from: from, to: to))?
                    .map { (ts: $0.ts, state: $0.state) } ?? []
                if bandSleepState.isEmpty {
                    bandSleepState = await Self.bandSleepStateSamples(computedId: computedId,
                                                                     from: from, to: to, store: store)
                }

                // #690: the experimental-V2 staging toggle threads into the normal detected-night path.
                let useSleepStagingV2 = PuffinExperiment.experimentalSleepV2Enabled

                // ── Waking-window CAPTURE COVERAGE for this day ────────────────────────────────────
                // Both inputs (`dayHr`, `wristOff`) are already in memory, so this is one pure call and
                // zero extra store reads. Effort ACCUMULATES over whatever HR exists — `edwardsTRIMP` is a
                // plain `Σ zoneWeight × minutes` with no coverage or rate term — and `trimpToStrain` then
                // log-compresses hard, so a half-missing day does not look half-missing. On the real
                // 2026-07-15 (one 753-min hole, no WRIST_OFF covering it, so genuine capture loss) Effort
                // scored 27.01: inside the 26.31–64.18 band of the 17 full days and indistinguishable from
                // 07-22's 26.31 at 99.8% coverage. The honest range was 27.01…65.28.
                //
                // The coverage number NEVER touches `strain`. It rides the confidence tier and the
                // `effort_coverage` series so the UI can say "partial capture", and it keeps low-coverage
                // days out of the Effort BASELINE. `windowNotStarted` guards TODAY before 08:00 local so an
                // early-morning today reads "not graded" (nil) rather than a false 0% — which is what stops
                // this from blanking the live accumulating gauge every morning.
                let coverageClamp = (dayStart >= nowLocalMidnight) ? now : nil
                let dayCoverage: Double? = {
                    if let clamp = coverageClamp,
                       GapScan.windowNotStarted(dayKey: day, offsetSec: dayTzOffset, clampEnd: clamp) {
                        return nil
                    }
                    // Floored at the first sample this store holds, symmetric to `coverageClamp` at the
                    // other end. Otherwise the PAIRING day is graded from 08:00 over hours that predate
                    // the install: a strap paired at 15:00 scores ~0.70, under the 0.80 bar, so the
                    // user's first day is badged "partial capture" and dropped from the Effort baseline
                    // for having been set up in the afternoon.
                    return GapScan.dayCoverage(dayKey: day, hrTimestamps: dayHr.map(\.ts),
                                               offWrist: wristOff, offsetSec: dayTzOffset,
                                               clampEnd: coverageClamp,
                                               clampStart: firstEverHrTs).coverage
                }()

                let res = DayEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                                     steps: steps, dayHr: dayHr, daySteps: daySteps,
                                                     dayGravity: dayGrav,
                                                     skinTemp: skin,
                                                     skinTempFamily: skinFamily,   // #938
                                                     profile: up, baselines: baselines1, maxHROverride: maxHR,
                                                     tzOffsetSeconds: dayTzOffset, wristOff: wristOff,
                                                     sleepNeedHours: personalNeedHours,
                                                     sleepConsistency: sleepConsistency,
                                                     habitualMidsleepSec: habitualMidsleepSec,
                                                     bandSleepState: bandSleepState,
                                                     method: useSleepStagingV2 ? .path : .bands,
                                                     dayCoverage: dayCoverage,
                                                     restingHRFallbackBpm: restingHRFallbackBpm)
                // ── RHR floor-vs-mean diagnostic (#691), computed here from pure inputs. Only when a
                // diagnostic sink is wired — the O(hr × sessions) in-bed filter is pure waste otherwise. ──
                var rhrLine: String?
                if wantsRhrDiag, let floor = res.daily.restingHr {
                    let inBedBpms = hr.filter { s in
                        res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
                    }.map { $0.bpm }
                    rhrLine = Self.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms)
                }
                // ── Nightly SpO2 (UNCALIBRATED ESTIMATE) ── ratio-of-ratios over the raw red/IR PPG
                // restricted to the night's matched sleep sessions (the SAME in-sleep population the
                // other overnight vitals read). analyzeDay always nils spo2Pct (it never sees the raw
                // spo2 stream), so the estimate is folded onto the daily at the merge below.
                let spo2 = Spo2Estimator.nightlyPct(
                    samples: spo2Raw,
                    sessions: res.cachedSleep.map { (start: $0.startTs, end: $0.endTs) })
                // ── Wrist-orientation summary (011 W2.3) ── the four numbers that OUTLIVE the tape.
                // Raw gravity is pruned at 28 days (`SampleRetention.swift:92-95`), so the BANDS on Rest
                // are a 28-day artifact (the rule `NightTape` already lives with) while these ride
                // `metricSeries` and are never pruned. Read over the night's LONGEST session — the main
                // night, the same span the hypnogram draws — with `grav` already in memory for the
                // window. READ-ONLY (011 decision 2): nothing here reaches AnalyticsEngine, and no
                // Charge/Effort/Rest score moves because of it.
                let posture = res.cachedSleep
                    .max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
                    .flatMap {
                        PostureEngine.analyze(gravity: grav, start: $0.effectiveStartTs,
                                              end: $0.endTs)?.summary
                    }
                // ── NIGHT WORN-SILENCE (030 Track A) ────────────────────────────────────────────
                // The waking-window grader above asks "was the strap capturing between 08:00 and
                // 22:00"; nothing asked the same question of the NIGHT, and the stager answers a
                // zero-data epoch by stretching the PRECEDING label across it
                // (`SleepStagingV2.swift:286` skips uncovered epochs, the tiling at :118-131 fills the
                // skipped span). On the real record, 2026-08-02 banks a single 176.0-min `deep`
                // segment (09:37:30→12:33:30) inside an otherwise 30-second hypnogram, while strictly
                // inside 09:47:23→12:33:55 the store holds ZERO rows in hrSample, gravitySample,
                // skinTempSample, spo2Sample, rrInterval, ppgHrSample, stepSample and sleepStateSample
                // and ZERO events of any kind — no WRIST_OFF, nothing. 166.1 of those minutes flow
                // unmodified into `deepMin` 254.5 (the record's max), `totalSleepMin` 610.33 (also the
                // max) and `sleep_performance` 96.24 (the max Rest score the user has ever seen).
                //
                // The contradiction is INTERNAL, which is why this belongs here and not in a UI: the
                // very same minutes are ALREADY booked as a capture failure by the sibling lane —
                // `effort_coverage[2026-08-02]` = 0.8017, under `ScoreConfidence.effortSolidCoverage`
                // (0.85) — so the Data tab withholds that day's Effort while the Rest lane celebrates
                // its best night ever, off the same silence.
                //
                // WHAT THIS DOES AND DELIBERATELY DOES NOT DO. It reuses the SAME bar the waking scan
                // uses (`GapScan.gapThresholdS`, 15 min) over the SESSION SPAN instead of 08:00–22:00,
                // subtracts off-wrist time (an explained absence is honest, and only UNEXPLAINED
                // silence is the defect), and intersects what survives with the session's staged ASLEEP
                // segments. It then does exactly two things: raises the EXISTING
                // `CachedSleepSession.lowConfidence` flag on the affected session, and totals the
                // minutes for the `sleep_unmeasured_min` series below. It does NOT touch `stagesJSON`
                // (`HealthExport.writeSleepStages` prefix-DELETES every Apple Health sample it
                // previously wrote for a session whose stages fingerprint changed — one scoring pass
                // would destroy health data living outside this app), and it does NOT subtract the
                // unmeasured minutes from `totalSleepMin` / `deepMin` / `remMin` / `lightMin`.
                // Quietly replacing a wrong number with a smaller one is still asserting a number
                // nobody measured, and it would feed that second fabrication into the Rest composite,
                // the debt ledger and the baselines. Flag and absence are the honest tools; the
                // arithmetic is not.
                //
                // Both inputs are already in memory (`hr` for the night read, `wristOff` for the
                // off-wrist pairing), so this costs no additional store read.
                //
                // TRUNCATION GUARD: `hrSamples` is read with `limit: 200_000`. A read that HIT the
                // limit is a truncated prefix, and its missing tail would scan as a multi-hour phantom
                // silence — the app asserting a capture failure it never observed, which is the same
                // sin in the other direction. A truncated day is therefore NOT graded at all (nil, no
                // flag, no series point), the same shape `daySliceFromNight` already uses for its own
                // limit guard.
                let silenceScanUsable = hr.count < 200_000
                let hrTs: [Int] = (silenceScanUsable && !res.cachedSleep.isEmpty) ? hr.map(\.ts) : []
                var flaggedSleep: [CachedSleepSession] = []
                var unmeasuredS = 0.0
                for s in res.cachedSleep {
                    guard silenceScanUsable else { flaggedSleep.append(s); continue }
                    let u = Self.unmeasuredStagedSeconds(session: s, hrTimestamps: hrTs,
                                                         offWrist: wristOff)
                    unmeasuredS += u
                    // OR, never overwrite: the stager raises the same flag for its own reason (a run
                    // longer than `SleepDetection.maxMainSleepSpanS`), and clearing that would delete a
                    // caveat the user is already being shown.
                    flaggedSleep.append(u > 0 ? Self.flaggedLowConfidence(s) : s)
                }
                let unmeasuredStagedMin: Double? =
                    (silenceScanUsable && !res.cachedSleep.isEmpty) ? unmeasuredS / 60.0 : nil
                out.append(DayScan(result: res, rhrLine: rhrLine,
                                   readOwner: owner, hrRows: hr.count, spo2: spo2, posture: posture,
                                   dayStart: dayStart, flaggedSleep: flaggedSleep,
                                   unmeasuredStagedMin: unmeasuredStagedMin))
            }
            return out
        }.value

        // Back on the main actor: fold the off-actor results in the SAME order the loop produced them.
        for scan in scanned {
            let res = scan.result
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            if let line = scan.rhrLine { diagnosticSink?(line, nil) }
            // Fold the scan's nightly SpO2 estimate onto the daily HERE, so pass 2's `with(recovery:
            // skinTempDevC:)` rebuild (which carries spo2Pct through) persists it. nil-on-nil is identity.
            // `scan.flaggedSleep`, NOT `res.cachedSleep`: same rows, with the night-silence
            // `lowConfidence` flag folded in (030 Track A). Everything else, `stagesJSON` included, is
            // the scan's own output verbatim.
            scoredNights.append((daily: res.daily.with(spo2Pct: scan.spo2), strain: res.strain, cachedSleep: scan.flaggedSleep,
                                 nightlySkin: res.nightlySkinTempC,
                                 sessionMotion: res.sessionMotionByStart,
                                 sessionSleepState: res.sessionSleepStateByStart,
                                 workouts: res.workouts,
                                 posture: scan.posture,
                                 dayCoverage: res.dayCoverage,
                                 unmeasuredStagedMin: scan.unmeasuredStagedMin))
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // This is the BLE-only recovery fix: the "-computed" nightly avgHrv/restingHr feed the baseline so a
        // strap-only user crosses Baselines.minNightsSeed and recovery lights up. IMPORTED values win per
        // day (`dict[day] == nil` is true only when the KEY is absent).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        for (day, v) in nightlyHrvByDay where histHrvByDay[day] == nil { histHrvByDay[day] = v }
        for (day, v) in nightlyRhrByDay where histRhrByDay[day] == nil { histRhrByDay[day] = v }
        for (day, v) in nightlyRespByDay where histRespByDay[day] == nil { histRespByDay[day] = v }
        // (`recoveryEpoch` — rhr/resp/skin honour the Charge-wide recalibration epoch, HRV its own — is
        // read once above pass 1, because pass 1's Effort resting-HR fallback needs it too.)
        let hrvDayKeys = histHrvByDay.keys.sorted()
        let hrvSeq = hrvDayKeys.map { histHrvByDay[$0]! }
        let rhrDayKeys = histRhrByDay.keys.sorted()
        let rhrSeq = rhrDayKeys.map { histRhrByDay[$0]! }
        let respDayKeys = histRespByDay.keys.sorted()
        let respSeq = respDayKeys.map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only, folded purely over the pass-1 nightly means.
        let skinDayKeys = nightlySkinByDay.keys.sorted()
        let skinSeq = skinDayKeys.map { nightlySkinByDay[$0]! }
        // Resp/skin gated on `usable` so a calibrating (<4-night) baseline can't move recovery.
        let respFold = Baselines.foldHistory(respSeq, dayKeys: respDayKeys, cfg: respCfg, baselineEpoch: recoveryEpoch,
                                             offsetSec: tzOffset)
        let skinFold = Baselines.foldHistory(skinSeq, dayKeys: skinDayKeys, cfg: skinCfg, baselineEpoch: recoveryEpoch,
                                             offsetSec: tzOffset)
        let baselines2 = DayEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(hrvSeq, dayKeys: hrvDayKeys, cfg: hrvCfg, offsetSec: tzOffset),
            restingHR: Baselines.foldHistory(rhrSeq, dayKeys: rhrDayKeys, cfg: rhrCfg, baselineEpoch: recoveryEpoch,
                                             offsetSec: tzOffset),
            resp: respFold.usable ? respFold : nil,
            skinTemp: skinFold.usable ? skinFold : nil)
        // AS-OF-DAY Charge gate. `baselines2` is ONE state folded over the whole history, and every day in
        // the window is then scored against it — so `RecoveryScorer`'s own `hrvBaselineUsable` gate (nValid
        // ≥ `Baselines.minNightsSeed`) sees the END-OF-HISTORY nValid for every day and can never fire for
        // the early days it exists to protect. On the real 18-day store the HRV fold reaches nValid 1/2/3 on
        // 07-09/07-10/07-11, so `recovery()` would have returned nil for all three on a live device — yet
        // they carry persisted Charge values of 86.7 / 15.6 / 12.1, because each pass re-persists every day
        // and retroactively overwrites the correctly-nil ones the moment nValid crosses the seed. The 86.7 →
        // 15.6 cliff, the window's most jarring transition, is entirely inside that calibration period.
        //
        // Same inputs, same cfg, same epoch handling as the HRV fold above, so the two cannot disagree about
        // which nights count. Gating on this while still SCORING from the global baseline is the minimum
        // correct change.
        //
        // CRITICAL — the gate must fold over the user's WHOLE RECORD, not over this pass's scan window.
        // `histHrvByDay` is `hist` (the IMPORTED lane, which is EMPTY for the app's core strap-only user —
        // see the note at the `hist` read) ∪ `nightlyHrvByDay` (only the days THIS pass scanned, i.e. at
        // most the trailing `maxDays` = 21). Folding the prefix over that set restarts the seed count from
        // zero at the WINDOW's oldest day, so it marks the first `minNightsSeed − 1` days of the WINDOW
        // unusable no matter how much real history precedes them. Because a day's LAST scoring pass is the
        // one where it sits at offset 20 — i.e. where it is the OLDEST key and therefore suppressed — and
        // `MetricsCache.upsertDailyMetrics` substitutes (`recovery = excluded.recovery`) rather than
        // coalescing, EVERY day's final write would be a NULL. A strap-only user's entire Charge history
        // would die at ~3 weeks, one day at a time.
        //
        // So extend the prefix backwards with the COMPUTED lane's own persisted `avgHrv`, which is
        // baseline-independent and written for every day ever scored — the record is reconstructible from
        // it even for days whose raw samples the retention sweep has since pruned. Priority per day:
        // imported > this pass's freshly computed value > previously persisted computed value, so no day
        // already known to `histHrvByDay` changes and the fold's verdict for the recent days is unchanged.
        //
        // NOTE the deliberate asymmetry: `baselines2.hrv` still folds over `histHrvByDay` only. That fold
        // produces the baseline VALUE (a recency-weighted EWMA the window is the right scope for); this
        // one answers a different, purely historical question — "has this user ever banked
        // `minNightsSeed` nights before day D?" — which only the whole record can answer.
        // (`persistedComputed` is read once above pass 1 — pass 1's Effort resting-HR fallback reads the
        // same rows, and a second full-history query for them would be pure waste.)
        let prefix = Self.chargeSeedSequence(histHrvByDay: histHrvByDay, persistedComputed: persistedComputed)
        let chargeUsableFromDay = Baselines.foldPrefixUsable(prefix.values, dayKeys: prefix.dayKeys, cfg: hrvCfg,
                                                            offsetSec: tzOffset)
        // The computed lane's already-persisted Charge, for the write guard in pass 2 below.
        var storedRecoveryByDay: [String: Double] = [:]
        for d in persistedComputed { if let r = d.recovery { storedRecoveryByDay[d.day] = r } }

        let windowStart = now - scanDays * 86_400 - 30 * 3_600

        // ── Detected-workout dedup (W7, port of the original IntelligenceEngine 731-742): the real (non-detected)
        // logged sessions in the scored window under the strap id AND the apple-health id. A detected bout
        // that time-overlaps ANY of them is skipped below (a wear+import/manual user never sees the same
        // session twice — the per-day merge doesn't cover the workout table). Bare time overlap on purpose
        // so a detected bout collapses against a manual session even though their SPORTS differ.
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                      to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: WorkoutSource.appleHealthSource,
                                                   from: windowStart, to: now, limit: 100_000)) ?? []

        // The scored window's canonical local-day keys — CALENDAR-stepped (DST-aware) so they match exactly
        // the day set the scan loop above emits; a fixed-86_400 derivation would disagree with the scan
        // about which days exist near a DST boundary and let the eviction backstop reason over a wrong set.
        // Shared by the health-monitor journal read below and the #277/#521 stale-row eviction after the loop.
        let baseMidnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(nowLocalMidnight)))
        let canonicalDayKeys: [String] = (0..<scanDays).compactMap { off in
            guard let d = Calendar.current.date(byAdding: .day, value: -off, to: baseMidnight) else { return nil }
            return DayEngine.dayString(Int(d.timeIntervalSince1970),
                                             offsetSec: TimeZone.current.secondsFromGMT(for: d))
        }
        let newestDay = canonicalDayKeys.first ?? DayEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)
        let oldestDay = canonicalDayKeys.last ?? newestDay

        // ── Health monitor (007 F2): the scored window's journal tags, one merged-lane read
        // (WHOOP-CSV rows a restored imported backup carries under the strap id fill lowest, imported
        // "imported-journal" over them, native "wm-journal" wins per (day, question) — the SAME merge
        // the Journal chips render, so the confounders here can never disagree with the UI).
        // The read starts one day EARLY: the night keyed D reads day D-1's behavior tags (see
        // `nightContextTags`), so the oldest scored night still finds its context.
        let jFrom = Self.shiftDay(oldestDay, by: -1) ?? oldestDay
        let jStrap = (try? await store.journalEntries(deviceId: deviceId,
                                                      from: jFrom, to: newestDay)) ?? []
        let jImported = (try? await store.journalEntries(deviceId: JournalStore.importedSourceId,
                                                         from: jFrom, to: newestDay)) ?? []
        let jNative = (try? await store.journalEntries(deviceId: JournalStore.nativeSourceId,
                                                       from: jFrom, to: newestDay)) ?? []
        var journalTagsByDay: [String: Set<String>] = [:]
        for e in JournalStore.merged(strap: jStrap, imported: jImported,
                                     native: jNative) where e.answeredYes {
            journalTagsByDay[e.day, default: []].insert(e.question)
        }

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent).
        // Recovery stays nil until the HRV baseline is usable — honest cold-start.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        // Detected exercise bouts to persist under the computed id (sport = "detected"), overlap-skipped.
        var workoutRows: [WorkoutRow] = []
        // Rest composite (0–100) per computed night, persisted as the `sleep_performance` metric series.
        var restPoints: [MetricPoint] = []
        // Health-monitor composite + level per computed night (007 F2), persisted as the
        // `strain_score` / `strain_level` metric series.
        var strainPoints: [MetricPoint] = []

        // Provenance set for the honest By-Day badge + the per-day diagnostic source token.
        let importedWhoopDays = Set(hist.map { $0.day })

        for night in scoredNights {
            let daily = night.daily
            // P4: the personalized Rest composite is identical across its three consumers this iteration
            // (the recovery re-score, the Charge drivers, and the persisted `sleep_performance` point) —
            // compute it ONCE and thread it into all three, instead of three identical `composite` calls.
            let restComposite = Rest.composite(daily: daily, needHours: personalNeedHours,
                                                               consistency: sleepConsistency, ageYears: ageYears)
            // Was the HRV baseline usable AS OF THIS DAY? Below the seed the scorer's own contract is to
            // refuse — "more honest than a fabricated value" — so all THREE Charge outputs are suppressed
            // together: the number, the driver list behind it (the Charge detail screen must not explain a
            // score that does not exist), and the confidence stamp. A missing key means the day never
            // entered the fold (no HRV, or dropped by a recalibration epoch) — also not usable.
            // `ScoreColumn` already renders a nil score as a hollow track + dashed tick + em-dash with the
            // VoiceOver string "…, calibrating", so no UI work is needed to show this honestly.
            let asOfUsable = chargeUsableFromDay[daily.day] ?? false
            // HOISTED above the recovery re-score. It depends only on `night.nightlySkin` + `baselines2`,
            // neither of which the block below touches, and computing it here is what makes the skin-temp
            // term reach the score at all — see `recomputeRecovery` for why `daily.skinTempDevC` is always
            // nil at this point.
            let skinDev = Self.recomputeSkinTempDev(night.nightlySkin, baselines2.skinTemp)
            let scored = asOfUsable
                ? Self.recomputeRecovery(daily, baselines2, restComposite: restComposite,
                                    skinTempDev: skinDev) : nil
            // WRITE GUARD (data-loss, not scoring). `upsertDailyMetrics` SUBSTITUTES recovery, so any nil
            // this pass produces DELETES whatever the day already had. That is correct for the seed gate
            // above — those early scores are exactly the fabricated ones it exists to retract — but it is
            // never correct when the baseline WAS usable for this day and the scorer simply could not
            // score it this time (a night that banked no usable HRV, a partially-pruned day). That day was
            // legitimately scored before, the user has already seen the number, and it cannot be
            // re-derived once the raw is gone. Carry it forward instead of erasing it.
            //
            // Deliberately NARROWER than "never nil over a stored value": that broader form would also
            // preserve the cold-start scores the seed gate is meant to remove, undoing the round-2 fix.
            let recovery = Self.recoveryToPersist(scored: scored, asOfUsable: asOfUsable,
                                                  stored: storedRecoveryByDay[daily.day])
            let source = DaySource.classify(day: daily.day, importedWhoopDays: importedWhoopDays)
            // SHARED CONTRACT enrichment: the ordered Charge driver list + the relative skin-temp marker,
            // built from the SAME inputs `recomputeRecovery` reads so the rows can never disagree. A
            // CARRIED-FORWARD score (write guard above) gets NO drivers: it was computed by an earlier
            // pass from inputs this pass could not reproduce, so explaining it from today's inputs would
            // be the exact "detail screen disagrees with the number" failure the gate below avoids.
            let drivers = (asOfUsable && scored != nil)
                ? Self.recomputeChargeDrivers(daily, baselines2, restComposite: restComposite,
                                         skinTempDev: skinDev) : []
            let skinRel = RecoveryScorer.skinTempRelative(deviationC: skinDev)
            // No extra gate needed here: `charge(recovery:hrvBaseline:)` already returns `.calibrating`
            // for a nil recovery, so suppressing the number above also downgrades the stamp. Without the
            // gate above this line stamped 07-09 `.solid` — a fabricated score labelled fully trusted.
            let chargeConf = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines2.hrv)
            out.append(Computed(day: daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr, source: source, confidence: chargeConf,
                                effortCoverage: night.dayCoverage,
                                drivers: drivers, skinTempRel: skinRel))
            // One concise, privacy-safe line per scored day into the shareable strap log (§2.5).
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            diagnosticSink?("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                            + "matched=\(night.cachedSleep.count) source=\(source.logToken)", nil)
            dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev))
            // The AUTHORITATIVE personalized Rest score: persisted with the per-run personal need /
            // consistency / age so the `sleep_performance` series reflects them (P4: the single
            // `restComposite` computed above).
            if let rest = restComposite {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            // ── Health monitor (007 F2): evaluate the night's multi-signal illness-ward anomaly
            // against the pass-2 personal baselines (HRV z NEGATED inside — a drop is illness-ward)
            // with the night's CONTEXT tags as confounders (behaviors from D-1, `sick` from either
            // day — see `nightContextTags`), and bank the composite + level + per-signal fired
            // bitmask. Persisted for EVERY scored night — a stored quiet row is how the UI tells
            // "evaluated, nothing notable" from "never evaluated"; the fired bitmask is what the
            // detail screen's per-vital "Flagged" markers read, so they can never disagree with
            // the persisted level (they used to re-derive over a different baseline population).
            let monitorInputs = Self.healthMonitorInputs(hrv: nightlyHrvByDay[daily.day] ?? nil,
                                                         rhr: nightlyRhrByDay[daily.day] ?? nil,
                                                         resp: nightlyRespByDay[daily.day] ?? nil,
                                                         skin: nightlySkinByDay[daily.day] ?? nil,
                                                         baselines: baselines2)
            let monitor = Self.healthMonitorResult(
                inputs: monitorInputs, baselines: baselines2,
                journalTags: Self.nightContextTags(day: daily.day, tagsByDay: journalTagsByDay))
            strainPoints.append(MetricPoint(day: daily.day, key: "strain_score", value: monitor.score))
            strainPoints.append(MetricPoint(day: daily.day, key: "strain_level",
                                            value: Double(StrainLevel(monitor.level).rawValue)))
            strainPoints.append(MetricPoint(day: daily.day, key: "strain_fired",
                                            value: Double(StrainFiredMask.mask(of: monitorInputs))))
            // The day's waking-window capture coverage, riding the generic `metricSeries` (deviceId, day,
            // key, value) table the way `nap_min` / `strain_*` already do — so no schema change is needed
            // for a `dailyMetric` that has no coverage column and whose package is frozen. Written only
            // when the day was actually graded; an ungraded day (today before its window opens) simply has
            // no point, which reads downstream as "unknown", never as 0%.
            if let cov = night.dayCoverage {
                strainPoints.append(MetricPoint(day: daily.day, key: "effort_coverage", value: cov))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded in W1).
            // Skip any bout overlapping a real imported/manual workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for s in night.workouts {
                if realWorkouts.contains(where: { s.start < $0.endTs && $0.startTs < s.end }) { continue }
                workoutRows.append(WorkoutRow(startTs: s.start, endTs: s.end,
                                              sport: "detected", source: computedId,
                                              durationS: s.durationS, energyKcal: s.caloriesKcal,
                                              avgHr: Int(s.avgHR), maxHr: s.peakHR,
                                              strain: s.strain, distanceM: nil,
                                              zonesJSON: nil, notes: nil))
            }
        }

        // ── Nap credit (007 F3): credited nap minutes per scored day, persisted as the `nap_min`
        // metric series. Classified over the SAME merged session population the UI reads (imported
        // wins per end-day — Repository.mergeSleep over the window's imported rows + this pass's
        // fresh computed sessions), with the learned habitual midsleep threaded so the main-night
        // group matches the scored dailyMetric's pick. ADDITIVE only — `totalSleepMin` / the night
        // numbers are never touched (#525). Every SCORED night gets a row — an EXPLICIT 0 when the
        // day has no credited naps — so a day whose classification later flips back to zero naps
        // reconciles instead of freezing its stale value forever (metricSeries has no delete API;
        // the upsert IS the eviction). The read side filters the zeros, keeping the published
        // `napSeries` on its absent-means-none contract.
        let importedSleepWindow = (try? await store.sleepSessions(deviceId: deviceId, from: windowStart,
                                                                  to: now, limit: 4000)) ?? []
        let napByDay = NapCredit.creditedMinByDay(
            sleeps: Repository.mergeSleep(imported: importedSleepWindow, computed: cachedSleep),
            habitualMidsleepSec: habitualMidsleepSec)
        var napPoints: [MetricPoint] = []
        for night in scoredNights {
            let credited = napByDay[night.daily.day] ?? 0
            napPoints.append(MetricPoint(day: night.daily.day, key: "nap_min",
                                         value: (credited * 10).rounded() / 10))
        }

        // ── Sleep regularity (011 W2.1): the true 24 h-lag Sleep Regularity Index over the trailing
        // `SleepRegularity.defaultWindowDays` nights, persisted as the `sleep_regularity` series.
        //
        // READ-ONLY (011 decision 2): nothing below reaches `AnalyticsEngine`. The Rest composite's
        // consistency term above is still `VitalityEngine.sleepConsistency`'s duration CV, so no
        // Charge/Effort/Rest score and no historical value moves because of this block.
        //
        // Population. Timing, not staging — `sleepStateSample` has 0 rows and `sleepStateJSON` is NULL,
        // so only `sleepSession(startTs, endTs)` can carry this. It reads over the SAME 120-day merged
        // shape the Repository publishes so the Data tab's tile and Rest's own recomputed hero cannot
        // disagree: `mergedDays` for the `totalSleepMin` usability gate (with THIS pass's fresher rows
        // folded in the way `Repository.mergeDaily` folds a computed lane under an imported one), and
        // both sleep lanes over the same window. Two reads rather than a widening of
        // `importedSleepWindow`, which belongs to nap credit and must keep its own bounds.
        //
        // The lead-in matters: a point for the OLDEST scored day needs the 13 nights BEFORE it, which
        // sit outside `windowStart`. Reading the 120-day window gives every scored day a full window
        // instead of leaving the older half of each pass computed over a truncated one.
        let sriLo = now - 121 * 86_400, sriHi = now + 86_400
        let sriImportedSleep = (try? await store.sleepSessions(deviceId: deviceId, from: sriLo,
                                                               to: sriHi, limit: 4000)) ?? []
        let sriStoredComputedSleep = (try? await store.sleepSessions(deviceId: computedId, from: sriLo,
                                                                     to: sriHi, limit: 4000)) ?? []
        // `mergedDays` already encodes imported-wins-per-field, so it goes in on the imported side and
        // this pass's fresh computed rows only FILL what it lacks — the day that just gained its first
        // `totalSleepMin` becomes usable, and no imported value is overwritten.
        let sriDays = Repository.mergeDaily(imported: mergedDays, computed: dailies)
        let sriComputedSleep = Self.sriSleepPopulation(stored: sriStoredComputedSleep,
                                                       rederived: cachedSleep)
        let sriByDay = SleepRegularity.series(
            days: sriDays,
            sleeps: Repository.mergeSleep(imported: sriImportedSleep, computed: sriComputedSleep),
            dayKeys: scoredNights.map { $0.daily.day })
        // Only days whose window cleared `SleepRegularity.minimumPairs` are in the map at all, so this
        // writes a reading or nothing — never a placeholder zero (011 decision 4).
        let regularityPoints = sriByDay
            .map { MetricPoint(day: $0.key, key: "sleep_regularity", value: ($0.value * 10).rounded() / 10) }
            .sorted { $0.day < $1.day }

        // ── Wrist orientation (011 W2.3): the per-night summary numbers, persisted as the `posture_*`
        // series. THE POINT of persisting them is retention — raw gravity is pruned at 28 days
        // (`SampleRetention.swift:92-95`), so the tape on Rest ages out while these do not, and a night
        // that is never summarized HERE can never be summarized again.
        //
        // No explicit-zero reconcile row, unlike `nap_min`: a night with no reading has no reading, and
        // 0 switches / 0.0 stable fraction are all REAL values a real night can hold. Writing one for an
        // unread night would be the exact fabrication 011 decision 4 forbids, so an unread night simply
        // leaves its keys absent and the read side keeps its absent-means-no-reading contract.
        //
        // READ-ONLY (011 decision 2): nothing here feeds AnalyticsEngine, moves a Charge/Effort/Rest
        // score, or alters a historical value.
        var posturePoints: [MetricPoint] = []
        for night in scoredNights {
            guard let p = night.posture else { continue }
            let day = night.daily.day
            posturePoints.append(MetricPoint(day: day, key: "posture_switches",
                                             value: Double(p.switches)))
            posturePoints.append(MetricPoint(day: day, key: "posture_stable_frac",
                                             value: (p.stableFraction * 1000).rounded() / 1000))
            posturePoints.append(MetricPoint(day: day, key: "posture_dominant_frac",
                                             value: (p.dominantFraction * 1000).rounded() / 1000))
            posturePoints.append(MetricPoint(day: day, key: "posture_entropy",
                                             value: (p.entropyBits * 1000).rounded() / 1000))
        }

        // ── Unmeasured staged sleep (030 Track A): the day's staged ASLEEP minutes that sit over WORN
        // SILENCE, persisted as the `sleep_unmeasured_min` series. Summed over EVERY session the day
        // owns, naps included — `analyzeDay` attributes a session to the day its END falls on, so each
        // session is counted exactly once and under exactly one day, and a nap staged across a hole
        // over-claims the same way a night does (it feeds `nap_min`, which feeds the debt ledger's
        // credit). On the real record this writes 166.1 for 2026-08-02 and 0.0 for the other ten days
        // that own a session; the 166.1 is one 176.0-min `deep` segment intersected with one 166.5-min
        // worn silence, verified by replay over the corpus.
        //
        // ADDITIVE ONLY, like `nap_min` and `posture_*`: `totalSleepMin` / `deepMin` / `remMin` /
        // `lightMin` / the Rest composite / the debt ledger / the baselines are all untouched. The
        // night's numbers still say what the stager said; this says how much of that claim rests on
        // minutes nothing was recorded for, and `CachedSleepSession.lowConfidence` (raised in the scan
        // above) is what the Rest surfaces already read to caveat the night.
        //
        // AN EXPLICIT 0 IS WRITTEN for a graded night with nothing unmeasured, and this is the
        // `nap_min` discipline rather than the `posture_*` one — a deliberate choice, because here the
        // two lanes MUST agree. `metricSeries` has no delete API (the upsert IS the eviction), but
        // `upsertSleepSessions` DOES reconcile the flag (`lowConfidence = excluded.lowConfidence`,
        // `MetricsCache.swift:132`). Publishing nothing on a clean night would therefore let a stale
        // non-zero outlive the flag that justified it: a night flagged on the pass that scored it from
        // a partial offload, then cleared on the next pass once the backfill filled the hole, would
        // keep its minutes-unmeasured number forever with no flag on the session — the app asserting a
        // capture failure it no longer believes in. A 0 here is not a fabricated measurement: it is
        // the honest answer to a question that WAS asked ("does any staged sleep sit over worn
        // silence" — no).
        //
        // Absence still means something distinct, and the read side must honour it: no point at all is
        // written for a day that banked no sleep session, or whose HR read hit its row limit (see the
        // truncation guard in the scan). Those days were never graded, and 0 would claim they were.
        var unmeasuredPoints: [MetricPoint] = []
        for night in scoredNights {
            guard let unmeasured = night.unmeasuredStagedMin else { continue }
            unmeasuredPoints.append(MetricPoint(day: night.daily.day, key: "sleep_unmeasured_min",
                                                value: (unmeasured * 10).rounded() / 10))
        }

        // #277/#521 reconcile window (bounds computed above the pass-2 loop): UPSERT the freshly
        // local-keyed rows FIRST (row count stays monotonic during a recompute), then evict only the
        // STALE computed rows the new run no longer produces. Scoped to the computed source only —
        // imported rows are never touched.

        // Persist the computed scores under the dedicated "-computed" source so the whole dashboard reads
        // them. The Repository merges these UNDER any imported "my-whoop" rows (imports win).
        if !dailies.isEmpty { _ = try? await store.upsertDailyMetrics(dailies, deviceId: computedId) }

        // Evict stale computed rows in the window (e.g. UTC-keyed leftovers a prior run produced).
        // C1 (data-loss guard): a forced pass that scored NOTHING — a transient store-read failure, or no
        // day cleared the 200-sample floor — must never evict, or it wipes the whole computed dashboard.
        // And even a partial pass removes only genuine WRONG-KEY leftovers (keys OUTSIDE this window's
        // canonical local-day set — e.g. a prior UTC-keyed run), NOT a canonical day that merely lacked
        // data this run: that day's previously-computed Charge/Effort/Rest is still valid and must stand
        // (its raw may since have been pruned, so re-deriving it is impossible). Both reads swallow errors,
        // so a dropped day is indistinguishable from a genuinely-empty one — hence keep, never delete.
        if !dailies.isEmpty {
            let freshKeys = Set(dailies.map { $0.day })
            let canonicalKeys = Set(canonicalDayKeys)   // calendar-stepped, matches the scan loop (DST-safe)
            let existingWindow = (try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? []
            for stale in existingWindow where !freshKeys.contains(stale.day) && !canonicalKeys.contains(stale.day) {
                _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: stale.day, to: stale.day)
            }
        }
        if !restPoints.isEmpty { _ = try? await store.upsertMetricSeries(restPoints, deviceId: computedId) }
        if !strainPoints.isEmpty { _ = try? await store.upsertMetricSeries(strainPoints, deviceId: computedId) }
        if !napPoints.isEmpty { _ = try? await store.upsertMetricSeries(napPoints, deviceId: computedId) }
        if !regularityPoints.isEmpty { _ = try? await store.upsertMetricSeries(regularityPoints, deviceId: computedId) }
        if !posturePoints.isEmpty { _ = try? await store.upsertMetricSeries(posturePoints, deviceId: computedId) }
        if !unmeasuredPoints.isEmpty { _ = try? await store.upsertMetricSeries(unmeasuredPoints, deviceId: computedId) }

        // Persist the detected sleep sessions (no user-edit / dismissal guards in W1 — no editing UI yet).
        //
        // `userEdited` / `startTsAdjusted` are inert columns, not ignored user intent: they have NO
        // producer in this app. whoopmaxx deliberately pruned the original user-edited-sleep substitution (see
        // the PRUNED list at the top of this file); `applySleepEdit` / `insertManualSleepSession` /
        // `updateSleepStages` have zero callers outside tests; there is no sleep-edit screen; and on the
        // real store `SELECT deviceId, COUNT(*), SUM(userEdited), SUM(startTsAdjusted IS NOT NULL) FROM
        // sleepSession` returns `my-whoop-computed|21|0|0`. The rows written here are built with the defaults.
        //
        // CONTRACT for whoever wires an edit UI: the day's sleep AGGREGATES (totalSleepMin / deep / rem /
        // light / efficiency / the Rest composite) come from the FRESH detection inside `analyzeDay`, not
        // from these stored rows — `analyzeDay` never reads a `sleepSession` row. The read-side surfaces
        // that already resolve `effectiveStartTs` (Repository, NapCredit, habitual midsleep, Today, Rest)
        // would move on their own, so an edit that only writes `startTsAdjusted` would show a corrected
        // bed time above uncorrected totals. Route the edited bounds back into the detection.
        // Packages/StrapStore is frozen and needs no change for either half.
        if !cachedSleep.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleep, deviceId: computedId) }
        let keptStarts = Set(cachedSleep.map { $0.startTs })
        // ── Persist per-epoch motion (H8) beside each session's stagesJSON. A session whose gravity
        // wouldn't grid was omitted from the map — an absent motion series stays absent.
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        // ── Persist per-epoch BAND sleep_state (#175) beside each session's stagesJSON — the source the
        // NEXT pass's `bandSleepStateSamples` read (the H7 confirm) consumes.
        var sleepStateByStart: [Int: [Int]] = [:]
        for night in scoredNights {
            for (start, states) in night.sessionSleepState where keptStarts.contains(start) {
                sleepStateByStart[start] = states
            }
        }
        for (start, states) in sleepStateByStart {
            _ = try? await store.persistSessionSleepState(deviceId: computedId, sessionStart: start, states: states)
        }
        // ── Overlap-aware banked-sleep heal (#899): an unstable strap clock re-banks the SAME night
        // under a shifted timebase; collapse the window's stored sessions with the overlap rule (the
        // rows THIS pass banked are the bank-recency witness) and delete the stale copies.
        let storedSessions = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                             to: now, limit: 4000)) ?? []
        let healable = storedSessions.filter {
            (oldestDay...newestDay).contains(DayEngine.dayString($0.endTs, offsetSec: tzOffset))
        }
        let healDropped = SleepSessionDedup.dedupe(healable, freshStarts: keptStarts).dropped
        for stale in healDropped {
            _ = try? await store.deleteSleepSession(deviceId: computedId, startTs: stale.startTs)
        }
        if !healDropped.isEmpty {
            diagnosticSink?("Dedup(#899): removed \(healDropped.count) overlapping duplicate sleep "
                + "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.", nil)
            // One forced re-pass reconciles the read-side view with the heal's survivor. HARD-BOUNDED to
            // a single re-arm per cycle; the budget restores once a pass heals nothing.
            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                // This re-arm has no width of its own — it reconciles the days THIS pass just healed, so
                // the holder's own `maxDays` is the right reach. max() keeps a wider pending request.
                pendingForcedRescoreDays = Swift.max(pendingForcedRescoreDays ?? 0, maxDays)
            }
        } else {
            healRearmedThisCycle = false
        }

        // ── Detected-workout persistence (W7, port of the original IntelligenceEngine 1248-1253). Make
        // re-detection idempotent across runs: clear the prior computed detected workouts in the scored
        // window (a bout's startTs drifts as more HR arrives, which would otherwise orphan stale rows
        // under the (deviceId, startTs, sport) PK), then re-insert this pass's set.
        // C1 (data-loss guard), workout arm: evict only across the span this pass actually RE-DERIVED,
        // never the span it INTENDED to scan. `windowStart` keys off `scanDays`, which a widened one-shot
        // pushes to `SampleRetention.hardCapDays` (56) — but retention prunes raw at 28d, so every day in
        // the 29–56d band fails `guard hr.count >= 200` above, contributes no `workoutRows`, and its
        // detected bouts would be deleted with nothing to re-insert. That loss is PERMANENT: the raw HR
        // those bouts were derived from is already gone, so no later pass can recreate them.
        // The `if let … .min()` also supplies the empty-pass guard for free — a pass where every store read
        // failed scans nothing and now evicts nothing, matching the daily-metric eviction discipline above.
        // The 30h lead-in matches the scan's own read floor (`let from = dayStart - 30 * 3_600`), so no
        // re-derived bout can start below `evictFrom` and duplicate against a surviving row.
        if let oldestScannedStart = scanned.map(\.dayStart).min() {
            let evictFrom = Swift.max(windowStart, oldestScannedStart - 30 * 3_600)
            _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected",
                                                from: evictFrom, to: now)
        }
        if !workoutRows.isEmpty { _ = try? await store.upsertWorkouts(workoutRows, deviceId: computedId) }

        // #137: a manually-started workout is scored from sparse live HR at save time — near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser strap data.
        await rescoreManualWorkouts(store: store, profile: up)

        // Mirror the store-write guard (the `if !dailies.isEmpty` upserts at 523/533): a pass that scored
        // NOTHING is usually a transient store-read failure (every `store.hrSamples` in the detached scan
        // returned nil/threw, so each day hit the 200-sample floor), NOT genuinely no data. The store rows
        // are preserved on such a pass, so the in-memory publish must be too — otherwise the Charge driver
        // breakdown (Today + Charge detail read `scores.results`) vanishes until the next non-empty pass.
        if !out.isEmpty {
            results = out
            note = nil
        } else if results.isEmpty {
            // Genuine cold-start — nothing has ever scored. Surface the onboarding empty-state.
            note = "No scored nights yet. Wear the strap with whoopmaxx connected overnight and the engine will score your Charge, Effort and Rest itself — no WHOOP cloud required."
        }
        // else: a transient/aged all-empty pass while prior results are still valid — preserve both
        // `results` and `note` rather than blanking a still-good breakdown.

        // Did this pass write anything the dashboard caches are now behind? A heal-only pass (or one that
        // only (re)persisted detected workouts) counts too, so stale duplicates disappear and the workouts
        // cache reflects the new rows right away. The CALLER reloads on a true (see the doc above) — the
        // engine no longer refreshes the Repository itself.
        let wroteRows = !dailies.isEmpty || !healDropped.isEmpty || !workoutRows.isEmpty

        // #836: record the raw-HR fingerprint this run scored against. Advance ONLY when the pass actually
        // scored a day (mirrors the store-write guards at 523/533 and the publish guard above): an all-empty
        // pass is usually a transient per-day store-read failure while the cheap `hrFingerprint` still
        // succeeded — stamping the watermark then would gate every future idle tick off never-scored data,
        // so that night would stay unscored until a forced (post-sync) pass. (out.isEmpty == dailies.isEmpty.)
        if !out.isEmpty, !wmKey.isEmpty { UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey) }
        // Consume the round-4 one-shot only on a pass that actually SCORED something. A pass that scored
        // nothing is usually a transient store-read failure, and burning the one-shot there would strand
        // every out-of-window day on its pre-round-4 staging/spread forever — the same failure discipline
        // `Spo2Heal` / `SleepHrvHeal` use for their flags.
        if round4Rescore, !out.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.round4RescoreDoneKey)
            NSLog("ScoreEngine: round-4 one-shot rescore complete over \(scanDays) days (\(out.count) scored)")
        }
        // 009's weed one-shot burns on the same condition and for the same reason — a pass that scored
        // nothing would otherwise strand every out-of-window night on its pre-weed evaluation forever.
        if weedRescore, !out.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.weedConfounderRescoreDoneKey)
            NSLog("ScoreEngine: weed-confounder one-shot rescore complete over \(scanDays) days (\(out.count) scored)")
        }
        return wroteRows
    }

    /// UserDefaults key for the #836 idle-tick gate: the `(count:maxTs)` HR fingerprint the last
    /// completed `analyzeRecent` scored against. Internal rather than private so the
    /// score-orchestration tests can ARM the gate (there is no other way to make a pass short-circuit).
    static let analyzeWatermarkKey = "whoopmaxx.analyzeWatermark"

    /// One-shot flag for the round-4 widened re-score (see the block in `analyzeRecent`). Unset ⇒ the
    /// next pass scans out to `SampleRetention.hardCapDays` instead of the caller's window, so every day
    /// whose raw samples still exist is re-derived by the corrected stager and the corrected baseline
    /// spread rather than left half-corrected.
    ///
    /// BUMPED v1 ⇒ v2 when `PuffinExperiment.experimentalSleepV2Default` flipped to true. Every persisted
    /// hypnogram on an existing install was staged by V1; without a fresh key, an install that had already
    /// consumed the v1 one-shot would keep those V1 nights forever while newly-scored nights came from V2 —
    /// a store with two incompatible stagers in it. Bumping re-arms the widened pass for everyone exactly
    /// once, so the whole retained window is re-staged under the new default.
    ///
    /// Deliberately NOT in either settings whitelist (`BackupSettings` / `WmBackup.settingsWhitelist` are
    /// strict allowlists), so it never rides into a `.wmbak` and a restore onto a FRESH install re-runs
    /// the widened pass against the restored rows — which is right, because a restored store carries
    /// pre-round-4 values. The restore-onto-an-ALREADY-HEALED-install gap is now closed too: this key is
    /// registered in `BackupImport`'s `RestoreHealReset`, which re-arms it on every landed restore.
    ///
    /// Safe to re-run by construction — the pass only re-derives days from raw samples that are still
    /// present and upserts the result. It deletes nothing and reads no state it also writes.
    static let round4RescoreDoneKey = "wm.heal.round4StagingAndSpread.v2"

    /// One-shot flag for 009's weed-confounder re-score (see the block in `analyzeRecent`). Unset ⇒ the
    /// next pass scans out to `SampleRetention.hardCapDays` so every night whose D-1 carries the weed tag
    /// is re-evaluated against the confounder the engine only learned in 009, instead of keeping the
    /// `strain_level` it was banked with before weed existed as a `Context` field.
    ///
    /// Like `round4RescoreDoneKey` it is deliberately outside both settings whitelists, so it never rides
    /// into a `.wmbak`, and it IS in `BackupImport`'s `RestoreHealReset` so a restore onto an already-run
    /// install re-evaluates the restored rows. Safe to re-run by construction: the pass re-derives from raw
    /// samples still present and upserts, deleting nothing.
    static let weedConfounderRescoreDoneKey = "wm.heal.weedConfounder.v1"

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync — once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories) or are missing strain, and only when the recompute is a genuine improvement,
    /// so a well-scored workout is never touched and a still-sparse window is a no-op. (Port of the original
    /// IntelligenceEngine 1368-1396, minus the Test Centre trace.)
    private func rescoreManualWorkouts(store: StrapStore, profile up: UserProfile) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        // Nothing manual in the window ⇒ leave BEFORE paying for the computed lane's whole persisted
        // history below. The eligibility loop at the bottom is the only consumer of `restingHR` and
        // `firstMeasuredRhrDay`, and the common tick has no `manual` row in the trailing 14 days at all —
        // so on that path this function was decoding (and sorting) every day the install has ever scored
        // to answer a question nothing went on to ask. `rows` is already in hand and capped at 200, so
        // the test itself is free. Same discipline the `persistedComputed` note above pass 1 records: a
        // full-history query nobody consumes is pure waste.
        guard rows.contains(where: { $0.source == "manual" }) else { return }
        let hrMax = Double(profile.hrMax)
        // The computed lane's whole persisted history, read ONCE — both values below are derived from it.
        // It used to be read TWICE (once inside `latestMeasuredRestingHR`, once again for the first
        // measured day), each with its own full sort, for byte-identical rows.
        //
        // Deliberately NOT `analyzeRecent`'s `persistedComputed`: this pass upserts its freshly scored
        // days before it calls us, so that snapshot is a pass stale and reusing it would rescore manual
        // workouts against yesterday's resting HR.
        let computedRows = ((try? await store.dailyMetrics(deviceId: deviceId + "-computed",
                                                           from: "0000-01-01", to: "9999-12-31")) ?? [])
        // The user's MEASURED resting HR, not `StrainScorer.defaultRestingHR`. The auto-detector always
        // scores against a real value (`WorkoutDetector` derives one from the whole day when the caller
        // gives none), so leaving this at the 60 constant made the same bout score differently depending
        // on which scorer produced the row — and dropped a light session a whole Edwards zone for anyone
        // whose resting HR is well under 60 (this user's is 47). Distinct from `restingHRFallback`, which
        // folds a smoothed BASELINE for Effort's day path: a workout is scored against what the user's
        // resting HR actually IS, so this wants the plain last observed value. nil ⇒ nothing has ever
        // been measured (a cold install) and only then does the 60 constant apply.
        //
        // `last(where: restingHr != nil)` and NOT the obvious `max(by: day)?.restingHr`: `dailyMetrics`
        // is `ORDER BY day ASC` (MetricsCache), so this walks BACKWARDS past days that never banked a
        // resting HR — exactly what the old `.sorted { $0.day > $1.day }.compactMap { $0.restingHr }
        // .first` did. That backwards walk is load-bearing, not incidental: today's row was upserted
        // earlier in this same pass and carries a nil `restingHr` on any day with no scored night, so
        // taking the newest row unconditionally would fall through the `??` to 60 bpm — a number the
        // user never measured, and precisely the failure the paragraph above exists to prevent.
        let restingHR = (computedRows.last(where: { $0.restingHr != nil })?.restingHr)
            .map(Double.init) ?? StrainScorer.defaultRestingHR
        // The first day that carries a measured resting HR. A manual workout logged BEFORE it was scored
        // against `StrainScorer.defaultRestingHR` (60) because nothing better existed; once a real night
        // lands, that row is correctable and otherwise never would be — the ordinary "never lower a
        // stored value" rule would freeze the user's first sessions at a stranger's number. ASC order
        // again, so the oldest such day is `first(where:)` with no sort and no intermediate array.
        let firstMeasuredRhrDay = computedRows.first(where: { $0.restingHr != nil })?.day
        var updated: [WorkoutRow] = []
        let tzOffsetForRows = TimeZone.current.secondsFromGMT()

        // Eligible when it looks under-scored (negligible kcal) OR is missing strain (the merged-workout
        // case, where kcal is the SUM of inputs so it never looks under-scored yet Effort stays blank).
        for row in rows where row.source == "manual"
            && (ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) || row.strain == nil
                || Self.predatesMeasuredRestingHR(startTs: row.startTs, firstMeasuredDay: firstMeasuredRhrDay,
                                                  offsetSec: tzOffsetForRows)) {
            // 200_000, not 20_000: `hrSamples` reads `ORDER BY ts ASC LIMIT ?` over a 1-row-per-second
            // stream (both source tables are PK'd on (deviceId, ts)), so 20_000 capped the window at
            // 5 h 33 m and TRUNCATED the tail of any longer session. This pass exists to repair a
            // manually-logged workout scored from sparse live HR, and the `looksUnderScored` eligibility
            // means the truncated recompute still beat the stored near-zero value — so it persisted a
            // kcal/Effort roughly (5.56 h / duration) low, and the row then no longer qualified, making
            // the wrong number sticky. A manual row is capped at 24 h (86,400 rows), so 200_000 cannot
            // truncate any legal window. Matches the day-scale reads elsewhere in this file.
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 200_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax,
                                                      restingHR: restingHR),
                  ManualWorkoutRescore.improves(
                      s, over: row.energyKcal, currentStrain: row.strain, allowStrainOnlyFill: true,
                      allowStrainRewrite: Self.predatesMeasuredRestingHR(
                          startTs: row.startTs, firstMeasuredDay: firstMeasuredRhrDay,
                          offsetSec: tzOffsetForRows))
            else { continue }
            // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
            // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
            let kcalBeatsStored = (s.kcal ?? 0) > (row.energyKcal ?? 0) + ManualWorkoutRescore.improvementMarginKcal
            let energyKcal = kcalBeatsStored ? s.kcal : row.energyKcal
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: energyKcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source. With one paired device that is the fallback id this returns it without any probe reads.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: StrapStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String) async -> String {
        // A locked override wins outright and skips the presence checks entirely.
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        guard !devices.isEmpty else { return fallbackDeviceId }

        let liveDevices = devices.filter { $0.status != .archived }
        // #970: the default single-WHOOP install has exactly one live device that IS the fallback id —
        // skip the per-day LIMIT-1 HR probe (byte-identical outcome).
        if liveDevices.count == 1, liveDevices[0].id == fallbackDeviceId {
            return fallbackDeviceId
        }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in liveDevices {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority = d.id == activeId ? 0 : (isImport ? 2 : 1)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates) ?? fallbackDeviceId
    }

    /// The strap family that wrote `owner`'s skin-temp rows (#938): the raw skin-temp register is a RAW
    /// ADC on a WHOOP 4.0 (v24 layout) but centidegrees on a 5/MG, so the raw→°C conversion MUST know
    /// the family or it produces garbage °C — a deviation that never validates → skin temp reads "—".
    ///
    /// A registry `model` that positively names a WHOOP family wins. But whoopmaxx registers its single
    /// strap as just "WHOOP" (no model string), so that lookup normally misses — and the old fallback
    /// hardcoded `.whoop5`, silently breaking skin temp for every WHOOP 4.0 wearer. Fall back instead to
    /// the family the user PAIRED as (`WhoopModel.persisted`, the same source BLEManager decodes with),
    /// so a 4.0's raw ADC is scored on the 4.0 map.
    nonisolated static func skinTempFamily(forOwner owner: String, devices: [PairedDevice]) -> DeviceFamily {
        if let model = devices.first(where: { $0.id == owner })?.model,
           let family = WhoopModel(rawValue: model)?.deviceFamily {
            return family
        }
        return WhoopModel.persisted.deviceFamily
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Returns nil until
    /// the HRV baseline is usable (≥ minNightsSeed valid nights) — honest cold-start.
    nonisolated static func recomputeRecovery(_ daily: DailyMetric, _ baselines: DayEngine.ProfileBaselines,
                                   restComposite: Double?, skinTempDev: Double?) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw efficiency, and fold
        // in the night's skin-temp deviation. The composite is computed ONCE by the caller (P4) and
        // passed in, so the Charge "Rest quality" term stays byte-aligned with the persisted series.
        //
        // `skinTempDev` is PASSED IN, never read off `daily.skinTempDevC`. That field is always nil here:
        // pass 1 builds its `ProfileBaselines` with `skinTemp` defaulting to nil, so
        // `AnalyticsEngine`'s `guard let b = baselines.skinTemp, b.usable` returns nil for every day and
        // `daily.skinTempDevC` carries that nil into pass 2. Only `recomputeSkinTempDev` against the
        // re-seeded `baselines2` produces a real deviation — and it used to be computed AFTER this call,
        // so the term was dead for every user on every day and `RecoveryScorer`'s skin-temp branch was
        // unreachable from the app.
        let restQuality = restComposite.map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: skinTempDev)
    }

    /// The ordered "what shaped it" Charge driver list for one day. Feeds the SAME inputs
    /// `recomputeRecovery` reads into `RecoveryScorer.chargeDrivers`, so the rows can never diverge from
    /// the Charge number written for the day. Empty when a hard input is missing (cold-start).
    nonisolated static func recomputeChargeDrivers(_ daily: DailyMetric,
                                        _ baselines: DayEngine.ProfileBaselines,
                                        restComposite: Double?, skinTempDev: Double?) -> [ChargeDriver] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return []
        }
        let restQuality = restComposite.map { $0 / 100.0 } ?? daily.efficiency
        // Same passed-in deviation the score above used — that is what "the rows can never diverge from
        // the Charge number" requires. Reading `daily.skinTempDevC` here would reintroduce the nil.
        return RecoveryScorer.chargeDrivers(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                            respBaseline: baselines.resp, sleepPerf: restQuality,
                                            skinTempDev: skinTempDev)
    }

    /// True when this workout happened before the user had ANY measured resting HR — i.e. it was scored
    /// against the 60 bpm default. nil `firstMeasuredDay` means none exists yet, so every row qualifies.
    nonisolated static func predatesMeasuredRestingHR(startTs: Int, firstMeasuredDay: String?,
                                                      offsetSec: Int) -> Bool {
        guard let firstMeasuredDay else { return true }
        return DayEngine.dayString(startTs, offsetSec: offsetSec) < firstMeasuredDay
    }

    // `latestMeasuredRestingHR(store:deviceId:)` lived here. It had exactly one caller —
    // `rescoreManualWorkouts` — and its body was a second, byte-identical whole-history `dailyMetrics`
    // read of the computed lane plus a full descending sort, duplicating the read that same caller
    // already made for `firstMeasuredRhrDay`. It is now a `last(where:)` over the caller's single read;
    // the "plain last observed value, not `restingHRFallback`'s smoothed baseline" rule it documented,
    // and the reason the lookup must walk backwards past nil-`restingHr` days, are recorded there.

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline. Nil when the night had no wear-gated mean or the baseline isn't usable yet. APPROXIMATE.
    nonisolated static func recomputeSkinTempDev(_ nightly: Double?, _ base: Baselines.BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// Health monitor (007 F2): assemble one night's `IllnessSignalEngine` evaluation from the pass-2
    /// nightly values + baselines. Per-signal z comes from `Baselines.deviation` (σ = 1.253 × spread
    /// lives inside it — never divide by raw spread); the HRV z is NEGATED so a drop reads
    /// illness-ward, RHR / respiration / skin temp pass their raw z. A signal only participates when
    /// its OWN baseline is trusted (≥ `Baselines.minNightsTrust` valid nights, not stale) — a z
    /// against a cold-start baseline is noise, not corroboration — and the engine's own
    /// `baselineTrusted` gate additionally requires the two primary lanes (HRV + resting HR, the
    /// baselines every install folds) to be trusted before anything can surface. Journal question
    /// keys map 1:1 onto the engine's confounders by design (see `JournalTag`); `sick` routes to the
    /// alreadyUnwell "rest up" path instead of a scare. Pure + nonisolated so tests can drive the
    /// Inputs/Context assembly without a store.
    nonisolated static func healthMonitorResult(
        hrv: Double?, rhr: Double?, resp: Double?, skin: Double?,
        baselines: DayEngine.ProfileBaselines,
        journalTags: Set<String>
    ) -> IllnessSignalEngine.Result {
        healthMonitorResult(inputs: healthMonitorInputs(hrv: hrv, rhr: rhr, resp: resp, skin: skin,
                                                        baselines: baselines),
                            baselines: baselines, journalTags: journalTags)
    }

    /// The per-signal z readings for one night (the shared assembly behind `healthMonitorResult`
    /// and the persisted `strain_fired` bitmask, so the two can never diverge). A signal only
    /// participates when its OWN baseline is trusted; the HRV z is NEGATED (drop = illness-ward).
    nonisolated static func healthMonitorInputs(
        hrv: Double?, rhr: Double?, resp: Double?, skin: Double?,
        baselines: DayEngine.ProfileBaselines
    ) -> IllnessSignalEngine.Inputs {
        func reading(_ value: Double?, _ state: Baselines.BaselineState?,
                     negate: Bool = false) -> IllnessSignalEngine.SignalReading? {
            guard let value, let state, state.trusted else { return nil }
            let z = Baselines.deviation(value, state: state).z
            return IllnessSignalEngine.SignalReading(zIllnessward: negate ? -z : z)
        }
        return IllnessSignalEngine.Inputs(
            restingHR: reading(rhr, baselines.restingHR),
            skinTemp: reading(skin, baselines.skinTemp),
            hrv: reading(hrv, baselines.hrv, negate: true),
            respiration: reading(resp, baselines.resp))
    }

    /// `healthMonitorResult` over pre-assembled inputs (the loop builds them once and shares them
    /// with the `strain_fired` mask write).
    nonisolated static func healthMonitorResult(
        inputs: IllnessSignalEngine.Inputs,
        baselines: DayEngine.ProfileBaselines,
        journalTags: Set<String>
    ) -> IllnessSignalEngine.Result {
        let context = IllnessSignalEngine.Context(
            alcohol: journalTags.contains(JournalTag.alcohol.rawValue),
            stress: journalTags.contains(JournalTag.stress.rawValue),
            sauna: journalTags.contains(JournalTag.sauna.rawValue),
            // 009: weed rides the same D-1 evening convention as alcohol — `nightContextTags` already
            // hands the previous day's set and `jFrom` already reads a day early, so this is the whole
            // wiring. No new store read in the scoring loop.
            weed: journalTags.contains(JournalTag.weed.rawValue),
            // hardOrLateWorkout defaults to false — the "hard late workout" journal tag was removed.
            travelPhaseJump: journalTags.contains(JournalTag.travel.rawValue),
            alreadyUnwell: journalTags.contains(JournalTag.sick.rawValue),
            baselineTrusted: (baselines.hrv?.trusted ?? false)
                && (baselines.restingHR?.trusted ?? false))
        return IllnessSignalEngine.evaluate(inputs, context: context)
    }

    /// The journal tags that give a night keyed `day` its confounder CONTEXT (007 F2).
    ///
    /// CONVENTION (shared with `HealthMonitorScreen` — apply identically in both places): tags are
    /// logged on the BEHAVIOR day, and the night keyed D is the night FOLLOWING day D-1's evening
    /// (the same lag-1 convention `JournalInsightsTests` pins — "the baked effect lands the NEXT
    /// morning"). So the behavior confounders (alcohol / stress / sauna / hard-late-workout /
    /// travel) read D-1's tags: Friday-night alcohol logged Friday dampens the Saturday-keyed
    /// night, and a Saturday-afternoon sauna can't suppress Saturday's already-completed morning.
    /// `sick` is a STATE, not an evening behavior — feeling unwell logged on either day should
    /// route the gentle alreadyUnwell path — so it joins from D-1 ∪ D.
    nonisolated static func nightContextTags(day: String,
                                             tagsByDay: [String: Set<String>]) -> Set<String> {
        var tags = Self.shiftDay(day, by: -1).flatMap { tagsByDay[$0] } ?? []
        if tagsByDay[day]?.contains(JournalTag.sick.rawValue) == true {
            tags.insert(JournalTag.sick.rawValue)
        }
        return tags
    }

    /// Shift a "yyyy-MM-dd" day key by `delta` days. Fixed UTC calendar so it is deterministic and
    /// timezone-free (twin of `CorrelationEngine.shiftDay`, which is package-internal). Nil for an
    /// unparseable key.
    nonisolated static func shiftDay(_ day: String, by delta: Int) -> String? {
        if delta == 0 { return day }
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: comps),
              let shifted = cal.date(byAdding: .day, value: delta, to: date) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        guard let sy = c.year, let sm = c.month, let sd = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", sy, sm, sd)
    }

    /// The prior pass's persisted v18 BAND sleep_state for sessions overlapping `[from, to]`, expanded to
    /// timestamped `(ts, state)` samples on the 30 s epoch grid — the H7 re-onset confirm fallback for a
    /// DB whose raw sleep-state stream is absent. #899-deduped read-side so a stale re-banked copy can't
    /// keep confirming itself.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: StrapStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        let sessions = SleepSessionDedup.dedupe(
            (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                            limit: 4000)) ?? []).kept
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = try? await store.sessionSleepState(deviceId: computedId,
                                                                  sessionStart: s.startTs),
                  !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of
    /// history (cold-start). One `HistoryBlock` per stored session (imported + computed, #899-deduped),
    /// keyed by the LOCAL calendar day of its midpoint; the learner keeps the longest block per day. (#547)
    private static func computeHabitualMidsleep(
        store: StrapStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, offsetSec: Int
    ) async -> Int? {
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let merged = SleepSessionDedup.dedupe(imported + computed).kept
        let blocks = merged.compactMap { s -> SleepGrouping.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = DayEngine.dayString(mid, offsetSec: offsetSec)
            return SleepGrouping.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        return SleepGrouping.habitualMidsleepSec(blocks, offsetSec: offsetSec)
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is
    // MARK: - Sleep-regularity population (pure seam)

    /// The computed-lane sleep population the SRI is derived from: this pass's freshly derived sessions
    /// replace the stored rows for the days they cover, and every other stored row is KEPT.
    ///
    /// Scoping the replacement by TIME instead — dropping every stored row newer than the scan's
    /// `windowStart` — was a data-corrupting bug, and this seam exists so it cannot come back.
    /// A day inside the window can be skipped by the scan: `guard hr.count >= 200` drops any day whose
    /// raw samples were pruned (28 days) or were never dense enough, and a skipped day contributes
    /// nothing to `cachedSleep`. Its `totalSleepMin` still lives in the 120-day merged dailies, so
    /// `SleepRegularity`'s usability gate calls it usable — and a usable day carrying no sleep intervals
    /// grids as AWAKE FOR ALL 1440 MINUTES. Both of its pairs then score as a night spent awake, the
    /// precise failure that gate exists to prevent.
    ///
    /// It persists, too: `metricSeries` has no delete API, and a day is written for the LAST time on the
    /// pass where it is the oldest scanned day. On a restore — which re-arms the rescore keys and widens
    /// the scan to 56 days while raw samples only ever reach 28 — every day in the 29…56 range went this
    /// way at once.
    ///
    /// Keyed on the END day, the same key `Repository.mergeSleep` resolves on, so the two never disagree
    /// about which night a session belongs to.
    nonisolated static func sriSleepPopulation(stored: [CachedSleepSession],
                                               rederived: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return DayEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        let covered = Set(rederived.map(endDay))
        return stored.filter { !covered.contains(endDay($0)) } + rederived
    }

    // MARK: - Night worn-silence (030 Track A, pure seams)

    /// The same session row with `lowConfidence` raised, and EVERY other field copied verbatim.
    ///
    /// `stagesJSON` in particular is passed through untouched by construction. That is not tidiness:
    /// `HealthExport.writeSleepStages` reacts to a changed stages fingerprint by prefix-DELETING every
    /// Apple Health sample it previously wrote for that session, so re-writing a hypnogram from a
    /// scoring pass would irreversibly destroy health data that lives OUTSIDE this app. The flag is the
    /// only thing this lane is allowed to move.
    ///
    /// Idempotent, and it never CLEARS the flag: the stager raises the same bit for its own reason (a
    /// detected run longer than `SleepDetection.maxMainSleepSpanS`), and an already-flagged session is
    /// returned unchanged rather than rebuilt.
    nonisolated static func flaggedLowConfidence(_ s: CachedSleepSession) -> CachedSleepSession {
        guard !s.lowConfidence else { return s }
        return CachedSleepSession(startTs: s.startTs, endTs: s.endTs, efficiency: s.efficiency,
                                  restingHr: s.restingHr, avgHrv: s.avgHrv, stagesJSON: s.stagesJSON,
                                  userEdited: s.userEdited, startTsAdjusted: s.startTsAdjusted,
                                  lowConfidence: true)
    }

    /// Seconds of this session's staged ASLEEP time that sit over WORN SILENCE — time the strap banked
    /// no heart rate for and no off-wrist event explains. 0 on a clean night.
    ///
    /// ONLY the asleep lanes (`deep` / `rem` / `light`) count. A staged `wake` / `awake` span over
    /// silence is a mis-stated absence too, but it asserts no SLEEP: it inflates nothing in
    /// `totalSleepMin` / `deepMin` / `remMin` / `lightMin` and nothing in the Rest composite, so folding
    /// it in here would inflate the very number that exists to size the over-claim. On the real
    /// 2026-08-02 this returns 9967 s = 166.1 min, all of it `deep` — the 176.0-min `deep` segment
    /// 09:37:30→12:33:30 intersected with the 166.5-min silence 09:47:23→12:33:55.
    ///
    /// The span scanned is `[min(startTs, effectiveStartTs), endTs)`, not `[effectiveStartTs, endTs)`:
    /// the staged segments are keyed to the DETECTED run, so a hand-corrected onset that moved LATER
    /// must not hide the segments before it from the scan. (No producer sets `startTsAdjusted` in this
    /// app today — see the write-back contract at the `upsertSleepSessions` call site — so the two
    /// forms are identical on every row that currently exists; the min is what keeps them identical
    /// once an edit UI lands.)
    nonisolated static func unmeasuredStagedSeconds(session: CachedSleepSession,
                                                    hrTimestamps: [Int],
                                                    offWrist: [(start: Int, end: Int)]) -> Double {
        let lo = Swift.min(session.startTs, session.effectiveStartTs)
        let hi = session.endTs
        guard hi > lo else { return 0 }
        let segments = SleepStage.decode(session.stagesJSON).filter {
            switch $0.stage {
            case .deep, .rem, .light: return true
            case .wake, .awake:       return false
            }
        }
        guard !segments.isEmpty else { return 0 }
        let silences = wornSilences(from: lo, to: hi, hrTimestamps: hrTimestamps, offWrist: offWrist)
        guard !silences.isEmpty else { return 0 }
        var total = 0
        for seg in segments {
            for s in silences {
                total += Swift.max(0, Swift.min(seg.end, s.end) - Swift.max(seg.start, s.start))
            }
        }
        return Double(total)
    }

    /// The WORN-SILENCE intervals inside `[lo, hi)`: HR silences longer than `GapScan.gapThresholdS`
    /// with off-wrist time subtracted out, and only the remainders still over the threshold kept.
    ///
    /// This is `GapScan.dayCoverage`'s silence rule applied to an arbitrary span instead of the
    /// 08:00–22:00 waking window — same 15-minute bar, same "a mark within the threshold BEFORE the
    /// window still satisfies the leading edge" allowance, same off-wrist subtraction. It is written
    /// here rather than added to `GapScan` because that file belongs to another lane this iteration;
    /// if the two ever need to share, `GapScan` is the right home and this is the caller to move.
    ///
    /// Off-wrist is subtracted for the reason the flag exists at all: a strap on the nightstand is a
    /// KNOWN, honest absence that the user themself created, while silence with no event to explain it
    /// is the unexplained kind this lane is about. Subtracting it can only ever produce FEWER flags.
    nonisolated static func wornSilences(from lo: Int, to hi: Int, hrTimestamps: [Int],
                                         offWrist: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        let threshold = GapScan.gapThresholdS
        let marks = hrTimestamps.filter { $0 >= lo - threshold && $0 <= hi }.sorted()
        var silences: [(start: Int, end: Int)] = []
        var prev = lo
        for t in marks {
            if t - prev > threshold { silences.append((start: prev, end: t)) }
            prev = Swift.max(prev, t)
        }
        if hi - prev > threshold { silences.append((start: prev, end: hi)) }
        var worn: [(start: Int, end: Int)] = []
        for s in silences {
            for r in subtractIntervals((Swift.max(s.start, lo), Swift.min(s.end, hi)), offWrist)
            where r.1 - r.0 > threshold {
                worn.append((start: r.0, end: r.1))
            }
        }
        return worn
    }

    /// Subtract a set of `[start, end)` intervals from one interval, returning the ordered remainders.
    /// The inputs need be neither sorted nor disjoint. (A local twin of `GapScan`'s private helper —
    /// see `wornSilences` for why it is not shared.)
    nonisolated private static func subtractIntervals(_ interval: (Int, Int),
                                                      _ minus: [(start: Int, end: Int)]) -> [(Int, Int)] {
        var remainders: [(Int, Int)] = [interval]
        for m in minus.sorted(by: { $0.start < $1.start }) {
            var next: [(Int, Int)] = []
            for r in remainders {
                if m.end <= r.0 || m.start >= r.1 {           // no overlap
                    next.append(r)
                } else {
                    if m.start > r.0 { next.append((r.0, m.start)) }
                    if m.end < r.1 { next.append((m.end, r.1)) }
                }
            }
            remainders = next
        }
        return remainders.filter { $0.1 > $0.0 }
    }

    // MARK: - Causal Charge seed gate (pure seams)

    /// The day-ordered HRV sequence the CAUSAL Charge seed gate folds its prefix over — the user's whole
    /// record, not this pass's scan window.
    ///
    /// Per day, best knowledge wins: an IMPORTED value, else this pass's freshly computed one (both
    /// already merged into `histHrvByDay`), else the value a previous pass persisted on the computed
    /// lane. Only that last tier is new, and it can only ADD days — no day already present changes value —
    /// so the gate's verdict for the recent days is exactly what folding `histHrvByDay` alone gave.
    ///
    /// WHY IT MATTERS. `histHrvByDay` spans the IMPORTED lane (empty for a strap-only user, which is the
    /// app's stated core user) ∪ the days this pass scanned (`maxDays` = 21). Folding the seed prefix over
    /// that set restarts the count from zero at the WINDOW's oldest day, so it marks the first
    /// `Baselines.minNightsSeed − 1` days of the WINDOW unusable however much real history precedes them.
    /// A day's LAST scoring pass is the one where it sits at the oldest offset — i.e. the pass that
    /// suppresses it — and `MetricsCache.upsertDailyMetrics` substitutes rather than coalesces
    /// (`recovery = excluded.recovery`), so every day's final write would be a NULL and a strap-only
    /// user's whole Charge history would die at ~3 weeks, one day at a time. Reading the persisted
    /// `avgHrv` (baseline-independent, written for every day ever scored, and still present after the raw
    /// samples are pruned) is what makes the prefix reconstructible over the real record.
    nonisolated static func chargeSeedSequence(histHrvByDay: [String: Double?],
                                               persistedComputed: [DailyMetric])
        -> (dayKeys: [String], values: [Double?]) {
        var merged = histHrvByDay
        // `merged[day] == nil` is true only when the KEY is absent — a present-but-nil value is knowledge
        // ("this day was scored and banked no HRV") and must not be overwritten by an older row.
        for d in persistedComputed where merged[d.day] == nil { merged[d.day] = d.avgHrv }
        let keys = merged.keys.sorted()
        return (dayKeys: keys, values: keys.map { merged[$0]! })
    }

    /// Effort's PERSONAL resting-HR fallback (bpm) for days that banked no sleep session, or nil when
    /// the user has no usable resting-HR history yet.
    ///
    /// WHY IT IS BUILT HERE AND NOT INSIDE `analyzeDay`. `analyzeDay` used to reach for
    /// `baselines.restingHR`, but `strain` is produced in PASS 1, which is handed the IMPORTED-ONLY fold,
    /// and pass 2 only substitutes recovery/skinTempDev (the day's HR stream is dropped each iteration for
    /// memory). For the app's stated strap-only user the imported lane has ZERO rows — verified on the real
    /// store, `SELECT deviceId, COUNT(*) FROM dailyMetric` returns only `my-whoop-computed|18` — so that fold
    /// is `foldHistory([])`: nValid 0, `.calibrating`, `usable == false`. The term could never fire.
    ///
    /// The lane that DOES exist is the union of the imported rows and the computed lane's own persisted
    /// `restingHr`, which is exactly the precedence `chargeSeedSequence` uses for `avgHrv`: imported wins
    /// per day, and a present-but-nil value is knowledge ("this day was scored and banked no resting HR")
    /// rather than an absent key. `restingHr` is baseline-INDEPENDENT — it is the night's HR floor — so
    /// seeding a baseline from it and feeding that baseline back into Effort closes no loop.
    ///
    /// GATED ON `usable`, and that guard is load-bearing rather than defensive: an unusable fold returns
    /// the config's (30 + 120)/2 = 75.0 midpoint SEED, and 75 bpm NARROWS the reserve, scoring the day
    /// LOWER than the generic 60. Measured on the real 2026-07-15 (a 753-min capture hole, no sleep
    /// session): 75.0 → Effort 17.93, generic 60 → 27.01, this user's real 46.15 → 37.44.
    ///
    /// Measured over the real 17-day record: `foldHistory` = 46.15 bpm, spread 2.10, nValid 17,
    /// `.trusted`. A causal as-of-day fold reaches 46.23 by 2026-07-15 and gives the same 37.44, so the
    /// simpler global union is used. 17 of 18 days are byte-identical; only the no-session day moves.
    nonisolated static func restingHRFallback(hist: [DailyMetric], persistedComputed: [DailyMetric],
                                              recoveryEpoch: Double, offsetSec: Int) -> Double? {
        var byDay: [String: Double?] = [:]
        for d in persistedComputed { byDay[d.day] = d.restingHr.map(Double.init) }
        for d in hist { byDay[d.day] = d.restingHr.map(Double.init) }   // imported wins per day
        let keys = byDay.keys.sorted()
        let fold = Baselines.foldHistory(keys.map { byDay[$0]! }, dayKeys: keys,
                                         cfg: Baselines.metricCfg["resting_hr"]!,
                                         baselineEpoch: recoveryEpoch, offsetSec: offsetSec)
        return fold.usable ? fold.baseline : nil
    }

    /// The recovery value to PERSIST for one day, given what this pass scored, whether the seed gate
    /// cleared, and what is already stored.
    ///
    /// `upsertDailyMetrics` SUBSTITUTES recovery, so any nil this pass produces DELETES whatever the day
    /// already had. Two different things produce a nil and they need opposite handling:
    ///
    ///  • `asOfUsable == false` — the causal seed gate refused. Those early scores are exactly the
    ///    fabricated ones the gate exists to retract, so the nil MUST be written.
    ///  • `asOfUsable == true` but the scorer returned nil — the baseline was fine and this particular
    ///    day simply could not be scored this time (a night that banked no usable HRV, a partially
    ///    pruned day). That day was legitimately scored before, the user has already seen the number,
    ///    and it cannot be re-derived once the raw is gone. Carry it forward.
    ///
    /// Deliberately narrower than "never nil over a stored value": that broader rule would also preserve
    /// the cold-start scores the seed gate is meant to remove.
    nonisolated static func recoveryToPersist(scored: Double?, asOfUsable: Bool, stored: Double?) -> Double? {
        (asOfUsable && scored == nil) ? stored : scored
    }

    /// seconds EAST of UTC. floorMod keeps the floor correct for negative offsets and timestamps.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (result has the sign of the divisor) — Swift's `%` is a remainder and would
    /// mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

private extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted nightly SpO2 estimate. analyzeDay always
    /// produces spo2Pct = nil (the raw spo2 stream never rides into it), so substituting nil is identity.
    func with(spo2Pct v: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: v, skinTempDevC: skinTempDevC, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    solMin: solMin, remLatencyMin: remLatencyMin, wasoMin: wasoMin)
    }

    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation.
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    // Carry the v23 sleep-latency fields through the rebuild — this is the row that gets
                    // PERSISTED, so dropping them would nil out solMin/remLatencyMin/wasoMin every pass.
                    solMin: solMin, remLatencyMin: remLatencyMin, wasoMin: wasoMin)
    }
}
