#if os(iOS)
import Foundation
import HealthKit
import StrapStore

/// Write-only Apple Health bridge (iOS). One-way export of whoopmaxx's already-merged `Repository`
/// caches — DailyMetric vitals + CachedSleepSession stages — into Apple Health as native HK samples.
///
/// Deliberately NOT the two-way `HealthKitBridge`: no reads, no import, no observers, no
/// background delivery, no raw-HR / workout write. The 15-min analyze tick (plus post-sync + launch +
/// toggle-enable) is the cadence. Scores (Charge / Effort / Rest) are NOT written — HealthKit has a
/// fixed type catalog with no honest recovery/strain/readiness type; the genuinely-mappable vitals and
/// sleep stages are all that go to Health (this is also what the real WHOOP app writes).
///
/// Idempotency: each sample carries a deterministic `HKMetadataKeyExternalUUID`; before saving a day /
/// session the bridge deletes OUR prior matching samples (scoped to `HKSource.default()`) then saves.
/// A per-day vitals fingerprint and per-session stages fingerprint in `UserDefaults` skip the
/// delete/save entirely when nothing changed, and only advance AFTER a successful save.
@MainActor
final class HealthExport: ObservableObject {

    /// Authorization / reachability state, driving the More screen caption.
    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// SideStore) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework links
        /// and `isHealthDataAvailable()` is true but `requestAuthorization` is a dead-end and the app
        /// can never appear under Settings › Health. Distinct from `.denied` (entitled build, user said
        /// no) so the UI shows an honest caption instead of impossible Settings guidance (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    /// When the last export attempt ran. Advanced whether or not every day/session succeeded.
    @Published private(set) var lastExport: Date?
    /// True while an export is in flight (re-entrancy guard for overlapping ticks).
    @Published private(set) var exporting = false
    /// The most recent save failure (locked device, quota, invalid sample). Cleared at the start of a
    /// clean export; a day/session whose save threw does NOT advance its fingerprint, so it retries.
    @Published private(set) var lastError: String?

    private let store = HKHealthStore()
    private let repo: Repository
    /// Strap source id the external UUIDs are namespaced under ("my-whoop").
    private var deviceId: String { repo.deviceId }

    /// The `@AppStorage` key the More toggle writes; the bridge reads it as user intent.
    /// `nonisolated` so the (nonisolated) `.wmbak` settings whitelist can name it — an immutable
    /// `String`, so sharing it across isolation is trivially safe.
    nonisolated static let exportEnabledKey = "wm.health.exportEnabled"
    /// Trailing window (days) each export reconsiders.
    private static let windowDays = 14
    /// One-shot flag: the fabricated-SpO2 purge below has completed cleanly (see
    /// `purgeFabricatedSpo2IfNeeded`). Deliberately NOT in the `.wmbak` settings whitelist, so a restore
    /// onto a fresh install re-runs the purge.
    private static let spo2PurgeKey = "wm.health.spo2PurgeV1"
    /// One-shot flag: the inflated-HRV purge below has completed cleanly (see `purgeStaleHrvIfNeeded`).
    /// Same non-whitelisted discipline as `spo2PurgeKey`, so a restore onto a fresh install re-runs it.
    private static let hrvPurgeKey = "wm.health.hrvSplicePurgeV1"

    /// DECISION, recorded here so nobody "completes the registry" later: these two keys are deliberately
    /// NOT in `RestoreHealReset.storeScopedOneShots`, even though a restored store does carry pre-fix
    /// values and these purges are the only thing that removes our bad samples from Health.
    ///
    ///  (a) Re-arming them buys nothing. Inside `AppRoot.dataDidChange(.rawHistory)` the STORE heals run
    ///      strictly before `exportRecentIfEnabled()`, so once `RestoreHealReset` re-arms those, the
    ///      store is already corrected by the time anything is exported.
    ///  (b) Days inside the export window self-correct without a purge: `writeVitals` reconciles per
    ///      (type, day) by fingerprint, deletes before it saves, and evicts a present→nil vital.
    ///  (c) Decisively, both purges are `deleteObjects` over ALL TIME with no date predicate — every
    ///      whoopmaxx-sourced HRV / SpO2 sample we ever wrote — while the re-export that follows reaches
    ///      only `windowDays` (14). Re-arming them would therefore make EVERY restore silently destroy
    ///      the user's Health history from 15 days back, with nothing able to rewrite it.
    ///
    /// These flags are install-scoped in the way that matters (they describe what we deleted from THIS
    /// device's Health store, which a restore does not touch), so the flag and the fact stay in sync.
    ///
    /// CORRECTION — the last sentence was wrong, and reason (c) above is exactly why it mattered. The FLAG
    /// is install-scoped; the FACT is DEVICE-scoped. Deleting the app clears `UserDefaults` but not the
    /// Health store, so on a plain REINSTALL (no restore involved) both flags reset while the samples
    /// remain — and the purges re-arm and do the all-time delete described in (c), truncating the user's
    /// Health history to the trailing 14 days that `exportRecent` can rewrite. The raw samples behind the
    /// older days are themselves gone by then (`SampleRetention`, 28 days), so nothing can recreate them.
    /// The two are only in sync until the app is deleted once.
    ///
    /// Closed by requiring evidence that THIS install has actually exported before either purge may
    /// delete — see `hasEverExportedVitals`. The restore intent in (a)-(c) is unaffected: a restore
    /// replays exports, so an install with real export history still purges.

    init(repo: Repository) {
        self.repo = repo
        // Surface an unusable environment up front, most-specific first. `.unavailable` (no HealthKit)
        // wins where it applies; otherwise a free-signed build with the entitlement stripped routes to
        // `.entitlementMissing` so the caption is honest rather than "you denied it".
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthExport.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
    }

    // MARK: - Types

    private static let writeQuantityIds: [HKQuantityTypeIdentifier] = [
        .heartRateVariabilitySDNN, .restingHeartRate, .respiratoryRate, .oxygenSaturation,
    ]

    /// The share set requested on enable and checked on launch-resume: the 4 vitals + sleep analysis.
    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthExport.writeQuantityIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // MARK: - Authorization

    /// Toggle-enable path: request write-only permission (`read: []`) then run one immediate export.
    /// Requested ONLY on an explicit enable — never on launch.
    func requestAuthorizationAndExport() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build with no entitlement can never reach Health: `requestAuthorization` either
        // throws or returns leaving every type `.notDetermined`. The honest answer is "this build can't
        // use Apple Health", not "you denied it" — detect via the embedded profile up front (#348).
        guard HealthExport.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            // Empty read set = write-only: the share sheet lists the 5 write scopes and asks for NO
            // read access.
            try await store.requestAuthorization(toShare: writeTypes, read: [])
            // HealthKit does NOT throw when the user DENIES write access — the request resolves
            // successfully with the types left `.sharingDenied`. So don't infer `.authorized` from a
            // non-throw; treat it as granted only when every write type is actually shareable (mirrors
            // refreshAuthIfPreviouslyGranted), else `.denied` — otherwise the `.denied` caption is dead.
            auth = writeTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
                ? .authorized : .denied
        } catch {
            // The entitlement is present (guarded above), so a throw here is a genuine request failure —
            // the normal `.denied` "enable in Settings" path, never the entitlement reroute.
            auth = .denied
        }
        if auth == .authorized {
            await purgeFabricatedSpo2IfNeeded()
            await purgeStaleHrvIfNeeded()
            await exportRecent()
        }
    }

    /// Launch-resume without re-prompting: if the user already granted our write types, mark authorized
    /// so export resumes silently. Status-only — shows no permission sheet.
    func refreshAuthIfPreviouslyGranted() {
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        let granted = writeTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
        if granted { auth = .authorized }
    }

    /// C5: revalidate write-auth on foreground and DOWNGRADE `.authorized → .denied` the moment the user
    /// revokes whoopmaxx's Health write access in Settings — otherwise `auth` stays `.authorized`, the More
    /// caption keeps claiming we're writing, and every `store.save` silently fails. Two-way (unlike the
    /// one-way launch resume): a fresh grant made in Settings also upgrades so export resumes without a
    /// relaunch. Status-only, shows no sheet. Called from the app's `.active` scene-phase seam.
    ///
    /// A never-asked user is deliberately LEFT at `.unknown` (all types read `.notDetermined` → not
    /// granted), never flipped to `.denied` — that would show a bogus "enable in Settings" caption to
    /// someone who simply never turned export on. The terminal environment states (`.unavailable`,
    /// `.entitlementMissing`) describe a build that can never reach Health, so they are never revisited.
    func refreshAuth() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let granted = writeTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
        switch auth {
        case .authorized:
            if !granted { auth = .denied }          // revoked in Settings → stop claiming we write
        case .unknown, .denied:
            if granted { auth = .authorized }       // (re)granted in Settings → resume silently
        case .unavailable, .entitlementMissing:
            break                                   // terminal environment states — never revocable
        }
    }

    // MARK: - Export entry points

    /// The gated entry the loop calls (post-sync, 15-min tick, launch). A no-op that returns in well
    /// under a millisecond when the toggle is off or auth isn't granted.
    func exportRecentIfEnabled() async {
        // The one-shot fabricated-SpO2 purge runs AHEAD of the toggle gate on purpose: a user who has
        // since turned export OFF still has our bogus 85 % samples sitting in their permanent Health
        // record, and disabling the toggle is deliberately a no-teardown operation. The purge self-gates
        // on its own flag and on write authorization, so this stays a sub-millisecond no-op afterwards.
        await purgeFabricatedSpo2IfNeeded()
        await purgeStaleHrvIfNeeded()
        guard UserDefaults.standard.bool(forKey: HealthExport.exportEnabledKey),
              auth == .authorized else { return }
        await exportRecent()
    }

    /// One-shot purge of the INFLATED `heartRateVariabilitySDNN` samples this app wrote before the
    /// splice/window fixes landed (see `SleepHrvHeal` for the store-side half and the full measurement).
    ///
    /// `HealthExportMapping` writes `dailyMetric.avgHrv` straight through as an SDNN-unit HRV sample, and
    /// that number was inflated by a night-DEPENDENT 5–37 % — RMSSD differenced across beats the ectopic
    /// filter had just removed, averaged in with 5-minute windows that had discarded most of their own
    /// beats. Unlike the fabricated SpO2 this is not a dangerous reading, but it is still a number this
    /// app partly manufactured, and other Health-reading apps consume it quantitatively.
    ///
    /// Why the normal present→nil eviction in `writeVitals` is NOT enough: `windowDays = 14`, and that
    /// loop only walks days newer than the cutoff, so every day 15+ back keeps its inflated sample
    /// permanently. Deleting them lets the corrected values re-export for the days still in range, and
    /// leaves an honest gap for the days whose raw is gone and which therefore have no correct value to
    /// write.
    ///
    /// Scoped to `HKSource.default()` — ONLY samples whoopmaxx itself wrote. An Apple Watch's or the WHOOP
    /// app's own HRV samples are a different source and are never touched. The per-(type, day)
    /// fingerprints for the type are cleared too, so the corrected value re-writes cleanly instead of
    /// being skipped as "already at this fingerprint".
    ///
    /// Sleep-stage samples are deliberately NOT purged even though the hypnograms moved (deep 1.55 % →
    /// 4.21 % of TST). Total sleep and in-bed span are unchanged — only the stage SPLIT of a correct
    /// total shifted — and wholesale deletion of a user's sleep history from Apple Health is a larger
    /// harm than a slightly mis-attributed breakdown. The days inside the export window rewrite
    /// themselves on the next pass anyway.
    ///
    /// The flag advances ONLY on a clean delete: a delete that failed while the phone was locked
    /// post-reboot must retry, not be recorded as done.
    /// Has THIS install ever written vitals to Apple Health?
    ///
    /// True iff any per-(type, day) export fingerprint exists. Fingerprints live in `UserDefaults`, so a
    /// fresh install has none — which is exactly the signal wanted here.
    ///
    /// WHY BOTH PURGES NEED THIS. They are one-shot corrections of samples THIS APP wrote badly, gated on
    /// a `UserDefaults` flag. Deleting the app clears that flag, and their delete predicate
    /// (`predicateForObjects(from: HKSource.default())`) carries NO date bound — so on a reinstall they
    /// re-arm and delete every HRV and SpO2 sample whoopmaxx ever wrote, over all time, while
    /// `exportRecent` only rewrites the trailing `windowDays` (14). Net effect: every reinstall
    /// permanently truncates the user's Apple Health history to two weeks. Apple Health data outlives app
    /// deletion, so this destroys data the app cannot recreate — the store's raw samples are themselves
    /// aged out by `SampleRetention` at 28 days.
    ///
    /// Re-running on a fresh install was DELIBERATE (see `hrvPurgeKey`) so that restoring a backup onto a
    /// clean install re-corrects the restored store. That intent is preserved: a restore replays exports,
    /// which write fingerprints, so an install that has actually exported still purges. What is now
    /// excluded is the install that has written NOTHING — where the purge can only destroy, never correct.
    ///
    /// Fails SAFE. If fingerprint pruning ever leaves an affected install looking untouched, the outcome
    /// is stale samples left in place rather than good history deleted.
    nonisolated static func hasEverExportedVitals(defaults: UserDefaults = .standard) -> Bool {
        defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("wm.health.vitalsFp.") }
    }

    private func purgeStaleHrvIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: HealthExport.hrvPurgeKey),
              auth == .authorized, HKHealthStore.isHealthDataAvailable(),
              let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }
        // A purge is a CORRECTION of writes THIS install made. An install that has never exported has
        // nothing of its own to correct, so deleting would be pure destruction — see `hasEverExportedVitals`.
        guard HealthExport.hasEverExportedVitals() else {
            UserDefaults.standard.set(true, forKey: HealthExport.hrvPurgeKey)
            return
        }
        do {
            try await store.deleteObjects(of: type,
                                          predicate: HKQuery.predicateForObjects(from: HKSource.default()))
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing of ours to delete (a user who only ever enabled export after the fix). That is a
            // CLEAN outcome, not a failure — fall through and set the flag so this never runs again.
        } catch {
            lastError = "Apple Health HRV purge failed: \(error.localizedDescription)"
            return                                    // leave the flag clear so the next export retries
        }
        let suffix = ".\(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue)"
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys
        where key.hasPrefix("wm.health.vitalsFp.") && key.hasSuffix(suffix) {
            d.removeObject(forKey: key)
        }
        d.set(true, forKey: HealthExport.hrvPurgeKey)
    }

    /// One-shot purge of the FABRICATED `oxygenSaturation` samples this app wrote before `Spo2Estimator`
    /// stopped clamping (see `Spo2Heal` for the store-side half and the measurement).
    ///
    /// Why the normal present→nil eviction in `writeVitals` is NOT enough: `windowDays = 14`, and that
    /// loop only walks days newer than the cutoff — it can never reach a day 15+ back. Every such day
    /// keeps a `0.85` oxygenSaturation sample, and a sustained 85 % SpO2 reads as severe hypoxemia
    /// (below the <88 % supplemental-oxygen threshold), readable by every app the user has granted Health
    /// access to. Those have to be deleted explicitly, once.
    ///
    /// Scoped to `HKSource.default()` — ONLY samples whoopmaxx itself wrote. A real pulse oximeter's or
    /// the WHOOP app's own SpO2 samples are a different source and are never touched. The per-(type,day)
    /// fingerprints for the type are cleared too, so a legitimate value that ever returns re-writes
    /// cleanly instead of being skipped as "already at this fingerprint". The flag advances ONLY on a
    /// clean delete (the same failure discipline as the eviction path below): a delete that failed while
    /// the phone was locked post-reboot must retry, not be recorded as done.
    private func purgeFabricatedSpo2IfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: HealthExport.spo2PurgeKey),
              auth == .authorized, HKHealthStore.isHealthDataAvailable(),
              let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return }
        // Same reasoning as the HRV purge — see `hasEverExportedVitals`.
        guard HealthExport.hasEverExportedVitals() else {
            UserDefaults.standard.set(true, forKey: HealthExport.spo2PurgeKey)
            return
        }
        do {
            try await store.deleteObjects(of: type,
                                          predicate: HKQuery.predicateForObjects(from: HKSource.default()))
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing of ours to delete (a user who only ever enabled export after the fix). That is a
            // CLEAN outcome, not a failure — fall through and set the flag so this never runs again.
        } catch {
            lastError = "Apple Health SpO2 purge failed: \(error.localizedDescription)"
            return                                    // leave the flag clear so the next export retries
        }
        let suffix = ".\(HKQuantityTypeIdentifier.oxygenSaturation.rawValue)"
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys
        where key.hasPrefix("wm.health.vitalsFp.") && key.hasSuffix(suffix) {
            d.removeObject(forKey: key)
        }
        d.set(true, forKey: HealthExport.spo2PurgeKey)
    }

    /// Push the trailing `windowDays` of vitals + sleep stages. Re-entrancy-guarded; sets `lastExport`.
    private func exportRecent() async {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable(), !exporting else { return }
        exporting = true
        defer { exporting = false }
        lastError = nil
        await writeVitals(days: HealthExport.windowDays)
        await writeSleepStages(days: HealthExport.windowDays)
        pruneStaleFingerprints()
        lastExport = Date()
    }

    /// Perf1: drop the per-(device,day,vital) and per-(device,session) fingerprint keys once a day/session
    /// ages past the export window, so `standard` UserDefaults can't grow without bound over years. Only OUR
    /// two prefixes are touched, and only keys whose embedded day/startTs predates the window cutoff — an
    /// in-window key is always kept, so a settled export never re-writes. The sleep cutoff is one day more
    /// lenient than the export window (the key embeds the session's START but the export keeps it by its
    /// END) so a boundary night's key is never pruned while it can still be exported.
    private func pruneStaleFingerprints() {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -HealthExport.windowDays, to: cal.startOfDay(for: Date())) ?? Date()
        let cutoffKey = Repository.localDayKey(cutoff)                                    // yyyy-MM-dd
        let sleepCutoffTs = Int(Date().timeIntervalSince1970) - (HealthExport.windowDays + 1) * 86_400
        let d = UserDefaults.standard
        let vitalsPrefix = "wm.health.vitalsFp.", sleepPrefix = "wm.health.sleepFp."
        for key in d.dictionaryRepresentation().keys {
            if key.hasPrefix(vitalsPrefix) {
                // {deviceId}.{yyyy-MM-dd}.{typeId} — the day is the middle component (device id + HK type
                // id carry no dots). Lexicographic compare == chronological for zero-padded day keys.
                let parts = key.dropFirst(vitalsPrefix.count).split(separator: ".")
                guard parts.count >= 3 else { continue }
                if String(parts[parts.count - 2]) < cutoffKey { d.removeObject(forKey: key) }
            } else if key.hasPrefix(sleepPrefix) {
                // {deviceId}.{startTs} — the trailing component is the session start epoch.
                guard let last = key.split(separator: ".").last, let ts = Int(last) else { continue }
                if ts < sleepCutoffTs { d.removeObject(forKey: key) }
            }
        }
    }

    // MARK: - Vitals write

    /// Write each in-window merged `DailyMetric`'s vitals, tracking the saved state PER vital type (P9).
    /// For each known vital type on the day: skip when its per-(type,day) fingerprint already matches and
    /// it's still present, or when nothing of ours was ever written for it; otherwise delete OUR prior
    /// sample (so a changed value replaces and a present→nil vital is removed rather than orphaned), save
    /// the present vital, and advance THAT type's fingerprint only on its own clean save. A single denied
    /// scope (a partial grant, or a scope revoked between ticks) therefore lets the granted types settle
    /// while only the denied type retries — the old whole-day fingerprint never advanced under a partial
    /// grant, re-writing every granted vital on every export forever.
    private func writeVitals(days: Int) async {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date())) ?? Date()
        let cutoffKey = Repository.localDayKey(cutoff)
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())

        for row in repo.days where row.day >= cutoffKey {
            let candidates = HealthExportMapping.vitalCandidates(from: row, deviceId: deviceId)
            // A day whose vitals ALL went nil must STILL run the reconcile loop below — that loop is the
            // only path that EVICTS what we previously wrote. The old `guard !candidates.isEmpty else
            // { continue }` skipped it wholesale, orphaning our samples in Health forever and
            // contradicting the app (the same bug the sleep-stage writer already fixes for an emptied
            // stage timeline). The SpO2 fix makes this the common case, not a corner: every day's
            // spo2Pct goes present→nil at once, and a day carrying nothing BUT SpO2 would otherwise
            // keep its fabricated sample. Skip only when nothing of ours was ever written for the day.
            guard !candidates.isEmpty || hasStoredVitalFingerprint(day: row.day) else { continue }

            // One sample per PRESENT vital type on this day, plus a PER-TYPE fingerprint of ONLY that
            // vital's own value — so a changed HRV doesn't force RHR/resp/SpO2 to needlessly re-write.
            // (Storing the whole-day fingerprint under each type key made every present vital re-write
            // whenever any single one changed.)
            //
            // An unparseable day key must SKIP the day, never fall through into the loop below with no
            // samples — that is pure-eviction mode, which deletes what we already wrote. The old comment
            // here claimed we "could never have written such a day in the first place", but the zone is
            // re-read per call, so parseability depends on where the phone is NOW, not where it was at
            // export time. With the noon-direct parse above this guard is unreachable; it stays so any
            // future parse failure fails SAFE (skip and retry) instead of destroying Health history.
            guard let at = HealthExport.noon(ofDay: row.day) else { continue }
            var samplesByType: [HKQuantityType: HKQuantitySample] = [:]
            var fpByType: [HKQuantityType: String] = [:]
            for c in candidates {
                guard let type = HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: c.typeId))
                else { continue }
                samplesByType[type] = HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: HealthExport.hkUnit(c.unit), doubleValue: c.value),
                    start: at, end: at,
                    metadata: [HKMetadataKeyExternalUUID: c.externalUUID])
                fpByType[type] = String(format: "%.4f", c.value)
            }

            // Reconcile each KNOWN vital type independently, keyed by a per-(type,day) fingerprint, so a
            // single denied scope advances the GRANTED types on their own successful saves while the
            // denied one simply retries (P9). A present→nil vital clears its fingerprint after its stale
            // sample is deleted, so it re-writes if it later returns.
            for id in HealthExport.writeQuantityIds {
                guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
                let fpKey = vitalsFpKey(day: row.day, typeId: id.rawValue)
                let stored = UserDefaults.standard.string(forKey: fpKey)
                let sample = samplesByType[type]
                let typeFp = fpByType[type]
                // Skip a fully-settled type: present & already at THIS vital's own fingerprint, or absent
                // with nothing of ours ever written for it on this day.
                if sample != nil, stored == typeFp { continue }
                if sample == nil, stored == nil { continue }

                // (Re)write or evict this ONE type. Delete OUR prior sample first — keyed by the
                // deterministic per-(device,type,day) external UUID, scoped to our source — so a changed
                // value replaces cleanly and a present→nil vital is removed rather than orphaned.
                let uuid = HealthExportMapping.vitalExternalUUID(typeId: id.rawValue, deviceId: deviceId, day: row.day)
                let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                        allowedValues: [uuid])
                let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])

                guard let sample else {
                    // present→nil eviction: clear the fingerprint ONLY after a CLEAN delete. A try?-swallowed
                    // failed delete (e.g. HKError.errorDatabaseInaccessible while the phone is locked post-reboot,
                    // #222) that still cleared the fp would make the next tick see stored==nil, skip, and orphan
                    // the stale sample in Health forever. Leaving the fp on failure means the next tick retries.
                    do {
                        try await store.deleteObjects(of: type, predicate: pred)
                        UserDefaults.standard.removeObject(forKey: fpKey)
                    } catch let error as HKError where error.code == .errorNoData {
                        // Already gone — the user deleted it by hand in the Health app. Nothing of ours
                        // is orphaned, so this IS the clean outcome and the fingerprint must clear.
                        // Treating it as a failure left the fp set forever and re-reported this error
                        // on every tick. Same rule the HRV/SpO2 purges above already apply.
                        UserDefaults.standard.removeObject(forKey: fpKey)
                    } catch {
                        lastError = "Apple Health vitals evict failed: \(error.localizedDescription)"
                    }
                    continue
                }
                do {
                    // Delete-before-save, both gated. `deleteObjects` THROWS `.errorNoData` when the
                    // predicate matches nothing — which is the NORMAL case for the first-ever write of
                    // any (type, day), since the predicate keys on our own deterministic external UUID.
                    // Letting that throw skip the save meant no vital was ever written: the fingerprint
                    // never advanced, so `hasEverExportedVitals()` stayed false forever and both one-shot
                    // purges disarmed themselves too. Sleep already avoids this by using `try?`.
                    do { try await store.deleteObjects(of: type, predicate: pred) }
                    catch let error as HKError where error.code == .errorNoData {}
                    try await store.save([sample])
                    UserDefaults.standard.set(typeFp, forKey: fpKey)    // advance THIS type's own value, on success
                } catch {
                    lastError = "Apple Health vitals write failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// The per-(device, day, vital type) fingerprint key. One speller, because `pruneStaleFingerprints`
    /// parses this exact shape (`{prefix}{deviceId}.{yyyy-MM-dd}.{typeId}`) back apart.
    private func vitalsFpKey(day: String, typeId: String) -> String {
        "wm.health.vitalsFp.\(deviceId).\(day).\(typeId)"
    }

    /// True when ANY of our per-(type, day) vitals fingerprints exists for `day` — i.e. we wrote at
    /// least one vital sample for it, so an eviction pass still has work to do even with no candidates.
    private func hasStoredVitalFingerprint(day: String) -> Bool {
        HealthExport.writeQuantityIds.contains {
            UserDefaults.standard.string(forKey: vitalsFpKey(day: day, typeId: $0.rawValue)) != nil
        }
    }

    // MARK: - Sleep-stage write

    /// Write each in-window session's stage timeline as `sleepAnalysis` category samples. Per session:
    /// skip when the stages fingerprint is unchanged; otherwise delete OUR prior sleep samples over the
    /// night's span (window-delete, gap-free even if segment boundaries moved) then save the fresh
    /// segments, advancing the fingerprint ONLY on a clean save.
    private func writeSleepStages(days: Int) async {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let cutoffTs = Int(Date().timeIntervalSince1970) - days * 86_400
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())

        for session in repo.sleeps where session.endTs >= cutoffTs {
            let fpKey = "wm.health.sleepFp.\(deviceId).\(session.startTs)"
            let candidates = HealthExportMapping.sleepCandidates(from: session, deviceId: deviceId)
            if candidates.isEmpty {
                // The session is in-window but its stage timeline is now empty / all-unknown (e.g. it was
                // re-processed and cleared). The old early-return left any samples we HAD written orphaned
                // in Health, contradicting the app. Evict them — but only when a stored fingerprint proves
                // we wrote some; with nothing ever written, a delete every tick would be pointless churn.
                if UserDefaults.standard.string(forKey: fpKey) != nil {
                    do {
                        try await store.deleteObjects(of: sleepType,
                                                      predicate: sessionDeletePredicate(startTs: session.startTs,
                                                                                        bySource: bySource))
                        UserDefaults.standard.removeObject(forKey: fpKey)   // clear only on a clean delete
                    } catch {
                        lastError = "Apple Health sleep evict failed: \(error.localizedDescription)"
                    }
                }
                continue
            }

            let fp = HealthExportMapping.sessionStagesFingerprint(session)
            if UserDefaults.standard.string(forKey: fpKey) == fp { continue }   // unchanged → skip

            let samples = candidates.map { c in
                HKCategorySample(
                    type: sleepType, value: c.categoryValue,
                    start: Date(timeIntervalSince1970: TimeInterval(c.startTs)),
                    end: Date(timeIntervalSince1970: TimeInterval(c.endTs)),
                    metadata: [HKMetadataKeyExternalUUID: c.externalUUID])
            }
            // Delete ONLY our samples for THIS session (see `sessionDeletePredicate`), then save fresh.
            do {
                _ = try? await store.deleteObjects(of: sleepType,
                                                   predicate: sessionDeletePredicate(startTs: session.startTs,
                                                                                     bySource: bySource))
                try await store.save(samples)
                UserDefaults.standard.set(fp, forKey: fpKey)   // advance ONLY on success
            } catch {
                lastError = "Apple Health sleep write failed: \(error.localizedDescription)"
            }
        }

        // Reconcile FULLY-DELETED sessions: a session dropped from repo.sleeps is never visited by the loop
        // above, so its previously-written sleepAnalysis samples would orphan in Health forever (the ADD/
        // UPDATE-only design never sees a deletion). Enumerate OUR sleep fingerprints and, for any whose
        // session start is in-window but no longer present in repo.sleeps, delete its samples + clear the
        // fingerprint — mirroring the present→nil vitals eviction.
        let presentStarts = Set(repo.sleeps.map { $0.startTs })
        let fpPrefix = "wm.health.sleepFp.\(deviceId)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(fpPrefix) {
            guard let startTs = Int(key.dropFirst(fpPrefix.count)),
                  startTs >= cutoffTs, !presentStarts.contains(startTs) else { continue }
            do {
                try await store.deleteObjects(of: sleepType,
                                              predicate: sessionDeletePredicate(startTs: startTs, bySource: bySource))
                UserDefaults.standard.removeObject(forKey: key)   // clear only on a clean delete, else retry next tick
            } catch {
                lastError = "Apple Health sleep reconcile failed: \(error.localizedDescription)"
            }
        }
    }

    /// The predicate that matches ONLY our sleepAnalysis samples for the session starting at `startTs`:
    /// the external-UUID component embedding that session's own start (`wm:health:sleep:<deviceId>:
    /// <startTs>:…`, per HealthExportMapping), scoped to our source. Prefix-keyed so it is gap-free across
    /// re-stages (matches EVERY segment of the night whatever its boundaries moved to) yet never touches a
    /// neighbor — a different session start ⇒ a different prefix, and the trailing ':' blocks a numeric
    /// run-on. (A ±time-window delete, the old C4 fix, ate an adjacent nap whose samples fell in the span.)
    private func sessionDeletePredicate(startTs: Int, bySource: NSPredicate) -> NSPredicate {
        let byOurSession = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID, operatorType: .beginsWith,
            value: HealthExportMapping.sleepSessionUUIDPrefix(deviceId: deviceId, sessionStartTs: startTs))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byOurSession])
    }

    // MARK: - Unit + date helpers

    /// Map a store-free unit descriptor to a real `HKUnit`.
    private static func hkUnit(_ u: HealthExportMapping.VitalUnit) -> HKUnit {
        switch u {
        case .millisecondsSDNN: return .secondUnit(with: .milli)
        case .countPerMinute:   return HKUnit.count().unitDivided(by: .minute())
        case .fraction:         return .percent()
        }
    }

    /// Noon (local) of a `yyyy-MM-dd` day key — the instant a per-day vital sample is stamped, matching
    /// the original write-back (a mid-day point so the sample lands squarely on the civil day).
    private static func noon(ofDay day: String) -> Date? {
        // C5: refresh the shared formatter's zone per call. As a `static let` it otherwise froze
        // `TimeZone.current` at first access, so a timezone change mid-process yielded a wrong instant.
        //
        // Parse NOON DIRECTLY rather than midnight-then-bySettingHour. In America/Havana,
        // America/Santiago, Asia/Beirut and Atlantic/Azores, DST starts AT 00:00, so local midnight does
        // not exist on the transition date and a non-lenient `yyyy-MM-dd` parse returns nil. That nil
        // left `writeVitals` with no samples for the day, which dropped every vital into the EVICTION
        // branch — and because the zone is re-read per call, a day exported from a normal zone carries a
        // live fingerprint, so a traveller arriving in one of those zones had that day's HRV, resting HR,
        // respiratory rate and SpO2 DELETED from Apple Health and never rewritten. 12:00 local is never
        // skipped in tzdata, so this always resolves. Byte-identical on every non-skip day.
        noonFormatter.timeZone = TimeZone.current
        return noonFormatter.date(from: day + " 12:00")
    }

    private static let noonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / SideStore
    /// re-sign that strips the capability (framework still links, `isHealthDataAvailable()` still true,
    /// but `requestAuthorization` is a dead-end). Same embedded-profile slice `IOSDiagnostics` uses.
    ///
    /// Resolution: if an `embedded.mobileprovision` is present, slice its wrapped XML plist and look for
    /// the key in `Entitlements`; a free re-sign omits it. No embedded profile → an App Store install
    /// (App Store strips the profile), which is properly signed — assume PRESENT so a user who merely
    /// denied permission keeps normal Settings guidance rather than the honest-dead-end caption. On the
    /// Simulator there is no embedded profile, so this is `true` and the entitlement path isn't
    /// exercised — that's device-only.
    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return true   // no profile = App Store build = properly signed; assume present
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            return true   // present but unparseable — don't down-route off a parse failure
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        return entitlements["com.apple.developer.healthkit"] != nil
    }()
}
#endif
