import Foundation
import Combine
import StrapProtocol
import StrapStore
import StrapAnalytics

/// The workout WRITE layer + suggestion pipeline — split out of `Repository`, which stays the slim read
/// cache the UI observes for daily history.
///
/// Owns everything workout-shaped: the published `workouts` cache across the three lanes, the
/// manual / relabel / dismiss / delete CRUD, BOTH durable dismissed-span lists (the detected-bout read
/// filter and the auto-detect suggestion filter) with their shared token parser + prune policy, and the
/// opt-in "Looks like a workout?" candidate pipeline. It holds a `Repository` reference for the shared
/// store handle, the lane ids, the HR reads, and `days` (the resting HR the detectors need).
///
/// It carries its OWN `refreshSeq`: `workouts` no longer takes part in `Repository`'s diff, so that
/// counter stops moving for a workout-only change and anything keyed to it would never fire. Both
/// repositories are refreshed together from `AppRoot.dataDidChange`.
@MainActor
final class WorkoutRepository: ObservableObject {
    /// The read cache this layer reads through — the shared store handle, the lane ids, the HR reads,
    /// and `days` for the resting HR the detectors take.
    private let repo: Repository

    /// Workouts across every lane (strap, computed-detected, apple-health), dismissed-filtered +
    /// cross-source-deduped, NEWEST first — the single cache Today + the Live workouts list read (W7).
    @Published private(set) var workouts: [WorkoutRow] = []
    /// Bumped once per refresh THAT ACTUALLY CHANGED `workouts` (diff-guarded), so heavy screens can
    /// reload exactly when there is a real change and never for a byte-identical refresh. SEPARATE from
    /// `Repository.refreshSeq` by design — see the type doc.
    @Published private(set) var refreshSeq = 0

    /// The most recent PERSISTED workout, for Today's last-workout row. Derived from the newest-first
    /// `workouts` cache.
    var lastWorkout: WorkoutRow? { workouts.first }

    /// Generation stamp so an older refresh that finished late can't clobber a newer one's cache.
    private var refreshGen = Generation()

    init(repo: Repository) {
        self.repo = repo
    }

    // MARK: - Refresh

    /// C1: workouts are sparse and routinely outlive the 120-day dashboard window, so `refresh` reads
    /// the workout lanes over THIS wide window (bounded only by the per-lane row cap) rather than the
    /// dashboard's daily window — otherwise a workout older than that window silently vanishes from the
    /// list/history. Matches `workoutRows`' default multi-year read.
    private static let workoutReadWindowDays = 4000

    /// Re-read the three workout lanes and republish `workouts`. Diff-guarded: a refresh that produces a
    /// byte-identical cache publishes nothing (no objectWillChange, no `refreshSeq` bump).
    func refresh() async {
        guard let store = await repo.storeHandle() else { return }
        let myGen = refreshGen.claim()
        let nowTs = Int(Date().timeIntervalSince1970)
        let hi = nowTs + 86_400
        // Workouts across every lane (strap, computed-detected, apple-health). Deduped by natural key
        // (a row banked under two ids), dismissed-filtered, then cross-source-deduped off-actor below.
        // C1: read the workout lanes over a WIDE window (workouts are sparse and outlive the 120-day
        // daily window) so older sessions never fall out of the list/history.
        let workoutLo = nowTs - Self.workoutReadWindowDays * 86_400
        var rawWorkouts = (try? await store.workouts(deviceId: repo.deviceId,
                                                     from: workoutLo, to: hi, limit: 5000)) ?? []
        rawWorkouts += (try? await store.workouts(deviceId: repo.computedDeviceId,
                                                  from: workoutLo, to: hi, limit: 5000)) ?? []
        rawWorkouts += (try? await store.workouts(deviceId: WorkoutSource.appleHealthSource,
                                                  from: workoutLo, to: hi, limit: 5000)) ?? []
        let dismissedSpans = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)

        // Snapshot the currently-published cache (cheap COW) so the equality DIFF runs OFF the main actor
        // next to the O(n²) resolve (P4/P5); the main actor only assigns when `changed` is true.
        // (Assigning an equal value to an @Published prop still fires objectWillChange, so the skip has
        // to cover the assignment too.)
        let curWorkouts = workouts

        let merged: (workouts: [WorkoutRow], changed: Bool) =
            await Task.detached(priority: .utility) {
                let workouts = Self.resolveWorkouts(rawWorkouts, dismissedSpans: dismissedSpans)
                return (workouts: workouts, changed: workouts != curWorkouts)
            }.value

        // Generation guard: if a newer refresh() started while this one resolved off-actor, drop this
        // now-stale result so it can't clobber the newer cache.
        guard refreshGen.isCurrent(myGen) else { return }
        guard merged.changed else { return }

        self.workouts = merged.workouts
        self.refreshSeq += 1
    }

    /// Pure workout resolution over the raw multi-lane read: de-dup identical same-source rows banked
    /// under two ids (natural key), drop dismissed detected spans, cross-source-dedup (collapse a strap
    /// session and its Apple import; drop a detected shadow of a real session), NEWEST first. Static +
    /// pure so it's testable and can run off-actor. (Slimmed from the original `Repository.workoutRows`.)
    nonisolated static func resolveWorkouts(_ rows: [WorkoutRow],
                                            dismissedSpans: [(start: Int, end: Int)]) -> [WorkoutRow] {
        var byKey: [String: WorkoutRow] = [:]
        for r in rows { byKey["\(r.source)|\(r.startTs)|\(r.sport)"] = r }
        let unique = Array(byKey.values)
        let filtered = unique.filter { !WorkoutSource.isDismissed($0, spans: dismissedSpans) }
        return WorkoutSource.dedupCrossSource(filtered).sorted { $0.startTs > $1.startTs }
    }

    // MARK: - Workouts (W7 facade, slimmed from the original Repository)
    //
    // The single-device whoopmaxx store carries three workout lanes: the strap id `deviceId` (imports +
    // manual/relabelled rows), the computed sibling `computedDeviceId` (detected bouts the engine
    // re-derives), and "apple-health" (Apple imports). No RouteStore / GPS lane (spec cut line).

    /// The persisted dismissed detected spans ("startTs:endTs"). Read straight off UserDefaults so the
    /// read filter and the mutators share one source of truth (the engine never sees this — it always
    /// re-derives; only the read filter and these mutators consult it). (#107)
    private var dismissedDetectedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: WorkoutSource.dismissedDefaultsKey) }
    }

    /// All workouts across the three lanes for the last `days`, dismissed-filtered + cross-source-deduped,
    /// NEWEST first. `refresh()` publishes the same computation into `workouts`; this is the on-demand read
    /// the auto-detector uses to exclude already-saved windows.
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] {
        guard let store = await repo.storeHandle() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let lo = now - days * 86_400, hi = now + 86_400
        var rows: [WorkoutRow] = []
        for id in [repo.deviceId, repo.computedDeviceId, WorkoutSource.appleHealthSource] {
            rows += (try? await store.workouts(deviceId: id, from: lo, to: hi, limit: 5000)) ?? []
        }
        // P5: resolveWorkouts is pure but O(n²), so run it OFF the main actor (mirror `refresh()`) — on the
        // Today path this used to O(n²)-resolve a multi-year read on the UI actor. Callers bound the read
        // window (see `autoDetectCandidate`), so `rows` is small in practice; off-actor keeps it off the UI.
        let dismissed = WorkoutSource.parseDismissedSpans(dismissedDetectedSpans)
        return await Task.detached(priority: .utility) {
            Self.resolveWorkouts(rows, dismissedSpans: dismissed)
        }.value
    }

    /// Persist a retroactive / edited manual workout under the strap source. `replacing` is the row the
    /// edit started from: editing a DETECTED bout dismisses the detected original durably (so the
    /// re-detector doesn't bring it back); editing a MANUAL row whose natural key changed deletes the
    /// stale strap row first (the PK upsert would otherwise orphan it). (Port of the original, minus RouteStore.)
    ///
    /// Returns whether the upsert actually COMMITTED. `WorkoutSessionController.endWorkout` decides on
    /// this whether to drop its durable crash-recovery snapshot (#529) — a failed write must keep the
    /// snapshot so a relaunch can re-save the session instead of losing it. Every other caller ignores it.
    @discardableResult
    func saveManualWorkout(_ row: WorkoutRow, replacing old: WorkoutRow? = nil) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        if let old, WorkoutSource.classify(old.source) == .detected {
            await dismissDetected(old)
        } else if let old, WorkoutSource.classify(old.source) == .apple
                      || old.startTs != row.startTs || old.sport != row.sport {
            // Delete the stale original from its ACTUAL storage lane, mirroring `deleteWorkout`. Two cases
            // need it: (a) the natural key changed, so a plain upsert would orphan the old strap row; or
            // (b) the original is an Apple-Health import — it lives under `appleHealthSource`, a DIFFERENT
            // lane from the strap id the new "manual" copy lands under, so WITHOUT this delete BOTH rows
            // persist (the display de-dups them, but deleting the visible manual copy later resurfaces the
            // orphaned Apple one). A strap-lane edit with an unchanged key needs no delete: same PK, the
            // upsert overwrites it in place.
            let storageId = WorkoutSource.classify(old.source) == .apple
                ? WorkoutSource.appleHealthSource : repo.deviceId
            _ = try? await store.deleteWorkouts(deviceId: storageId, sport: old.sport,
                                                from: old.startTs, to: old.startTs)
        }
        // Thread the throw/no-throw result out rather than swallowing it with `try?`: the #529 caller
        // must be able to tell a committed row from a failed write.
        var saved = true
        do {
            _ = try await store.upsertWorkouts([row], deviceId: repo.deviceId)
        } catch {
            saved = false
        }
        await refresh()
        return saved
    }

    /// Re-label a detected bout: copy it to a manual strap row with the chosen sport, then delete the
    /// detected original. This survives analyzeRecent — the engine skips a re-derived bout overlapping a
    /// real strap workout, which this copy now is — so the same session is never re-created. (#107)
    func relabelDetected(_ row: WorkoutRow, sport: String) async {
        guard let store = await repo.storeHandle() else { return }
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let manual = WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: trimmed, source: "manual",
                                durationS: row.durationS, energyKcal: row.energyKcal,
                                avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain,
                                distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes)
        _ = try? await store.upsertWorkouts([manual], deviceId: repo.deviceId)
        _ = try? await store.deleteWorkouts(deviceId: repo.computedDeviceId, sport: "detected",
                                            from: row.startTs, to: row.startTs)
        await refresh()
    }

    /// Dismiss a DETECTED bout the user says isn't a workout: record its span durably (so a re-detect
    /// that recreates the same span stays hidden) AND delete the current row so it disappears now.
    /// Idempotent. (#107)
    func dismissDetected(_ row: WorkoutRow) async {
        guard WorkoutSource.classify(row.source) == .detected else { return }
        let token = WorkoutSource.dismissedToken(for: row)
        var spans = dismissedDetectedSpans
        if !spans.contains(token) {
            spans.append(token)
            // Prune on append (mirrors the sibling auto-detect list): age out spans whose end is past
            // the detected-bout re-derivation window + hard-cap. Without this the list grows unbounded
            // in UserDefaults and is re-parsed + overlap-checked against every detected row each refresh.
            // The `startTs:endTs` token shape matches `prunedAutoDetectSpans`'s last-colon END parser, and
            // its ~30-day age-out safely covers ScoreEngine's ~21-day re-derivation window (a span older
            // than that can never resurface, and `dismissDetected` already deletes the current row).
            dismissedDetectedSpans = prunedAutoDetectSpans(spans, now: Int(Date().timeIntervalSince1970))
        }
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteWorkouts(deviceId: repo.computedDeviceId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
    }

    /// Delete ONE workout by natural key. The read model has no deviceId, so reconstruct it from the
    /// source: a detected row is dismissed durably (else the re-detector resurrects it); every other row
    /// is deleted under the SAME lane id the read attributed it to.
    func deleteWorkout(_ row: WorkoutRow) async {
        if WorkoutSource.classify(row.source) == .detected {
            await dismissDetected(row)
            await refresh()
            return
        }
        guard let store = await repo.storeHandle() else { return }
        // C2: delete under the row's ACTUAL storage id — the lane `refresh`/`workoutRows` read it from —
        // not always the strap id. An Apple-Health import lives under `appleHealthSource`, so deleting it
        // under the strap id silently no-ops and the row reappears on the next refresh. Strap-native rows
        // (imported "whoop" + "manual"/"lifting"/"activity-file") stay under the strap `deviceId`, exactly
        // as `saveManualWorkout` banks them. (Mirrors how `relabelDetected`/`dismissDetected` target the
        // computed id for detected rows.)
        let storageId = WorkoutSource.classify(row.source) == .apple
            ? WorkoutSource.appleHealthSource : repo.deviceId
        _ = try? await store.deleteWorkouts(deviceId: storageId, sport: row.sport,
                                            from: row.startTs, to: row.startTs)
        await refresh()
    }

    // MARK: - Auto-detect workouts (opt-in) — the "Looks like a workout?" suggestion
    //
    // Pure read + suggestion path for the opt-in `AutoWorkoutDetector`. SEPARATE from the gravity-gated
    // detected-bouts pipeline (which writes "detected" rows under the computed id): nothing here is ever
    // persisted until the user taps Save, and a dismissed suggestion is remembered in its OWN durable
    // span list so it never re-prompts.

    private static let autoDetectDismissedKey = "workouts.autoDetectDismissed"
    private var autoDetectDismissedSpans: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.autoDetectDismissedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoDetectDismissedKey) }
    }
    private func autoDetectToken(_ w: DetectedWorkout) -> String { "\(w.startSec):\(w.endSec)" }
    private static let autoDetectDismissedMax = 200
    private static let autoDetectDismissedMaxAgeSec = 30 * 86_400

    private func autoDetectTokenEnd(_ token: String) -> Int? {
        guard let colon = token.lastIndex(of: ":") else { return nil }
        return Int(token[token.index(after: colon)...])
    }

    /// Prune the dismissed-span list: drop spans whose END aged out (~30 days — they can never be
    /// re-suggested), then hard-cap to the most-recent 200 as a backstop.
    private func prunedAutoDetectSpans(_ spans: [String], now: Int) -> [String] {
        let cutoff = now - Self.autoDetectDismissedMaxAgeSec
        let fresh = spans.filter { token in
            guard let end = autoDetectTokenEnd(token) else { return true }
            return end >= cutoff
        }
        guard fresh.count > Self.autoDetectDismissedMax else { return fresh }
        let keepIdx = Set(fresh.indices
            .sorted { (autoDetectTokenEnd(fresh[$0]) ?? .max) > (autoDetectTokenEnd(fresh[$1]) ?? .max) }
            .prefix(Self.autoDetectDismissedMax))
        return fresh.indices.filter { keepIdx.contains($0) }.map { fresh[$0] }
    }

    /// The bucket width the auto-detect HR read downsamples to (see `autoDetectHR`). 5 s sits far below
    /// every detector timescale (30 s min set, 90 s dip tolerance, 240 s rest gap, 12/20 min sessions),
    /// so detection is unaffected while a 7-day read stays bounded.
    static let autoDetectBucketSeconds = 5

    /// The detectors' shared HR read over the last `daysBack` days ending at `now` (unix seconds):
    /// 5-s bucket MEANS mapped into the detectors' `(ts, bpm)` shape. WHY buckets, not raw samples: a
    /// fully-worn day banks HR at ~1 Hz (~86k rows — see `StrapStore.hrSamples`), so 7 days of RAW
    /// samples is ~605k rows — 3× the old 200k cap — and `hrSamples` is `ORDER BY ts ASC LIMIT`, so an
    /// overflowing cap silently drops the NEWEST days, exactly the ones a suggestion should come from.
    /// 5-s buckets keep the whole 7-day window ≤ 120,960 points (7 × 86_400 / 5) with the same
    /// measured+PPG COALESCE population as the raw read; only the reported avg/peak bpm smooth slightly
    /// (a ≤5-sample mean). Shared by `autoDetectCandidate` and the Signal Lab detection panel so the
    /// diagnostic sees EXACTLY the production input.
    ///
    /// ORDER IS PART OF THE CONTRACT: `StrapStore.hrBuckets` is `GROUP BY ts / bucket ORDER BY bucket
    /// ASC`, so the series comes back with strictly increasing, distinct timestamps, and `map` keeps
    /// that. This used to be an incidental property nobody depended on — every consumer re-sorted
    /// defensively — but `zone3PlusMinutes` now binary-searches the series instead of re-filtering it
    /// per candidate, so the ordering is load-bearing. Anything that reshapes this read must preserve
    /// it (or restore it with a single sort here, not per consumer).
    func autoDetectHR(daysBack: Int, now: Int) async -> [(ts: Int, bpm: Int)] {
        let from = now - daysBack * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now,
                                           bucketSeconds: Self.autoDetectBucketSeconds)
        return buckets.map { (ts: $0.ts, bpm: Int($0.bpm.rounded())) }
    }

    /// Run the opt-in detectors over the last `daysBack` days of HR (default 7 — wide enough that a
    /// workout from earlier in the week still surfaces after a few days without syncing) and return
    /// EVERY surviving candidate — both detectors, trimmed, saved+dismissed filtered — sorted
    /// NEWEST-FIRST. This is the suggestion QUEUE: the Today row shows `.first` and advances to the
    /// next entry as suggestions are saved/dismissed. Empty when the toggle is off, there's nothing
    /// to suggest, or detection finds nothing. PURE READ.
    func autoDetectCandidates(daysBack: Int = 7) async -> [DetectedWorkout] {
        guard PuffinExperiment.autoDetectWorkoutsEnabled else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let hr = await autoDetectHR(daysBack: daysBack, now: now)
        guard hr.count >= 2 else { return [] }
        let restingBpm = repo.days.last(where: { $0.restingHr != nil })?.restingHr
        // P5: candidates only ever come from the last `daysBack` (default 7) days of HR, so the
        // saved-workout exclusion set only needs a recent window — bound the read to 30 days rather
        // than ~11 years (still ≥ 4× the scan window).
        let saved = await workoutRows(days: 30)
            .map { (start: $0.startTs, end: $0.endTs) }
        let dismissed = WorkoutSource.parseDismissedSpans(autoDetectDismissedSpans)
        // `hrmaxBpm` used to be left to its default (`profileHRmaxBpm()`), which Swift evaluates at
        // the CALL SITE — so detaching the call below would have carried that evaluation into the
        // detached task with it. Bind it HERE instead and pass it explicitly: the resolved value is
        // the same one the Signal Lab panel gets from the default, but it no longer depends on where
        // the pure pass happens to run. Cheap insurance rather than a correctness precondition —
        // `profileHRmaxBpm()` only reads `UserDefaults.standard`.
        let hrmax = Self.profileHRmaxBpm()
        // P5, mirroring `workoutRows` and `refresh`: `autoDetectQueue` is pure CPU — two detectors, a
        // per-candidate trim and three overlap filters over up to 120,960 bucket points — and it ran
        // INLINE on the main actor, so an HR-growing sync could stall the Today scroll for the whole
        // pass while the suggestion row reloaded. Everything that touches STORE STATE is already
        // awaited above (`autoDetectHR`, `workoutRows`) and both durable span lists are read on this
        // actor; what detaches is a fold over value types only, so this moves CPU off the UI without
        // making any store access concurrent.
        return await Task.detached(priority: .utility) {
            Self.autoDetectQueue(hr: hr, restingBpm: restingBpm,
                                 savedSpans: saved, dismissedSpans: dismissed,
                                 hrmaxBpm: hrmax)
        }.value
    }

    /// The single best candidate to suggest — the head of `autoDetectCandidates()` (newest first).
    /// Kept as the simple accessor for call sites that only ever show one suggestion. PURE READ.
    func autoDetectCandidate(daysBack: Int = 7) async -> DetectedWorkout? {
        await autoDetectCandidates(daysBack: daysBack).first
    }

    // MARK: Reserve-anchored suggestion gates
    //
    // `AutoWorkoutDetector.elevatedMarginBPM` (30) and `IntervalWorkoutDetector`'s reuse of it are
    // frozen at Kotlin byte-parity, so the APP LAYER anchors around them instead of editing them.

    /// The fraction of HR RESERVE that defines "this is exercise, not merely being awake" for the
    /// suggestion path's elevated floor — the Edwards zone-1 cut, the same notion (and the same
    /// number) `WorkoutDetector.bridgeHRRFraction` uses one layer down.
    ///
    /// WHY the absolute `restingBpm + 30` cannot stand on its own. For the real strap user
    /// (resting 44–52, Tanaka HRmax 194.7) that floor lands at 74–81 bpm = 20.2 %HRR, a level he
    /// holds for 620,367 of 1,433,775 recorded seconds — 43.3 % of the stream, 601 minutes a DAY.
    /// It is the same category error round 1 diagnosed for the bridge floor, one notch up: resting
    /// + 30 is the bar for "HR is off baseline", not for "the athlete is still working". Replaying
    /// the exact production pipeline over the 17 days at restingBpm 46 yields **91 candidates
    /// totalling 153.2 hours** (median 36.7 min, MAX 767.7 min); the rolling 7-day queue holds
    /// 35–45 entries once the window fills. Worst offers include 07-25 12:03→00:51 (767 min, avg
    /// 112), 07-11 16:26→01:04 (517 min with 0.0 minutes above 70 %HRR) and 07-17 17:56→22:45
    /// (288 min, peak 117, 0.0 minutes above 60 %HRR). `WorkoutTailTrimmer` does not rescue it
    /// (85 raw base candidates → 84 trimmed). Precision ≈ 8/91 = 9 %.
    ///
    /// Anchoring the floor to reserve puts it at ~120 bpm for this user (49.8 %HRR, 4.7 % of the
    /// stream) and drops the queue to 31 candidates.
    nonisolated static let suggestionFloorHRRFraction = 0.50
    /// Absolute DOSE filter on a surviving candidate: minutes it must hold at or above
    /// `WorkoutDetector.zone3HRRPct` (70 %HRR).
    ///
    /// BOTH halves are required. Raising `elevatedMarginBPM` alone was measured and rejected — and
    /// is initially COUNTER-productive, because a higher floor fragments one long span into several
    /// ≥ 12-minute ones: queue size by margin runs 30 → 91, 35 → 108, 40 → 100, 45 → 91, 50 → 76,
    /// 55 → 60, 60 → 47. The reserve-anchored floor alone still leaves 31 candidates with a
    /// 224-minute maximum. Floor + this filter gives **6 candidates** (median 50.4 min, max
    /// 74.8 min) covering 6 of the 8 bouts the retroactive detector finds — it misses 2026-07-23
    /// (6.5 zone-3+ minutes) and 2026-07-24 (4.0), both genuinely low-dose, which is the right
    /// trade for a suggestion the user has to be interrupted for.
    ///
    /// 5 minutes, not the retroactive detector's `minZone3PlusMinutes` (10): these candidates are
    /// already trimmed back to their own work band, so the same 10-minute bar drops the yield to
    /// 3 of 8 (measured). See `WorkoutDetector.minZone3PlusMinutes` for the retroactive rationale.
    nonisolated static let suggestionMinZone3PlusMinutes = 5.0

    /// Effective HRmax (bpm), resolved EXACTLY the way `ProfileStore.hrMax` resolves it: the user's
    /// explicit override when set, else Tanaka (208 − 0.7 × age). `ProfileStore` owns the rule and
    /// the `profile.*` UserDefaults keys; this reads the same keys because `autoDetectQueue` is
    /// `nonisolated` (and its Signal Lab caller runs off-actor) while `ProfileStore` is `@MainActor`.
    /// Keep in sync with `ProfileStore.hrMax`.
    ///
    /// AMENDED (P5 actor move): this is still the DEFAULT ARGUMENT of `autoDetectQueue`, which Swift
    /// evaluates at the call site — that is how the Signal Lab panel resolves the same value without
    /// threading a profile through, and how a test passes an explicit value (or nil) to stay
    /// hermetic. It is no longer how PRODUCTION reaches it. `autoDetectCandidates` now runs the queue
    /// in a detached task, so "the call site" would sit inside that task; it binds this on the main
    /// actor and passes the result explicitly. Same number either way — the point of the amendment is
    /// that the resolution no longer depends on where the pure pass runs.
    /// nil when age is non-positive and no override is set.
    nonisolated static func profileHRmaxBpm() -> Int? {
        let d = UserDefaults.standard
        let override = d.object(forKey: "profile.hrMaxOverride") as? Int ?? 0
        if override > 0 { return override }
        let age = d.object(forKey: "profile.age") as? Int ?? 30
        guard age > 0 else { return nil }
        return Int(208.0 - 0.7 * Double(age))
    }

    /// HR reserve (bpm) for the suggestion gates, or nil when there is none to anchor against
    /// (no profile HRmax, or an HRmax at/below resting) — in which case every gate below falls back
    /// to the shipped absolute behaviour. `restingBpm` nil mirrors the detectors' own fallback
    /// (`AutoWorkoutDetector.defaultRestingHR`) so anchor and detector share one baseline.
    nonisolated static func suggestionReserve(restingBpm: Int?, hrmaxBpm: Int?) -> Double? {
        let effResting = Double(restingBpm ?? AutoWorkoutDetector.defaultRestingHR)
        guard let hrmax = hrmaxBpm.map({ Double($0) }), hrmax > effResting else { return nil }
        return hrmax - effResting
    }

    /// The resting value to hand the FROZEN detectors so their fixed `+ elevatedMarginBPM` lands on
    /// a reserve-anchored floor (`restingBpm + suggestionFloorHRRFraction × reserve`). Returns
    /// `restingBpm` unchanged when there is no reserve, and the shift is clamped at 0 so anchoring
    /// can only ever RAISE the floor — never loosen the detector.
    ///
    /// Every stage downstream takes THIS value, `WorkoutTailTrimmer` included: the trimmer re-checks
    /// its candidate against its detector's own gates (`IntervalWorkoutDetector.sessions`, the base
    /// minimum-sustained bound), so feeding it the raw resting HR would have it judge candidates
    /// against a floor no detector used. The side effect is a proportionally higher work mark, i.e.
    /// slightly tighter tail trimming — which is what the 17-day measurement behind
    /// `suggestionFloorHRRFraction` was taken with.
    nonisolated static func anchoredRestingBpm(restingBpm: Int?, hrmaxBpm: Int?) -> Int? {
        guard let reserve = suggestionReserve(restingBpm: restingBpm, hrmaxBpm: hrmaxBpm) else {
            return restingBpm
        }
        let floorBpm = Int((suggestionFloorHRRFraction * reserve).rounded())
        return (restingBpm ?? AutoWorkoutDetector.defaultRestingHR)
            + max(0, floorBpm - AutoWorkoutDetector.elevatedMarginBPM)
    }

    /// THE candidate-pipeline core, pure and shared: given the detectors' HR read, the resting HR,
    /// the saved-workout spans and the durable dismissed spans, produce the suggestion queue —
    /// newest first. `autoDetectCandidates()` (production) and the Signal Lab detection panel BOTH
    /// call this, so the panel's "next suggestion / queued" labels can never drift from what the
    /// Today row actually shows.
    ///
    /// Pipeline, in production order (anchor → detect → trim → filter):
    ///  0. Reserve-anchor the elevated floor. `AutoWorkoutDetector` is frozen at Kotlin parity and
    ///     computes its floor internally as `restingBpm + elevatedMarginBPM`, so the anchoring is
    ///     applied by passing the detectors the resting value that makes that fixed +30 LAND on
    ///     `restingBpm + suggestionFloorHRRFraction × HR reserve`. Never lowers the floor (the
    ///     shift is clamped at 0), and is skipped entirely when `hrmaxBpm` is nil / ≤ resting —
    ///     which leaves today's behaviour exactly. See `suggestionFloorHRRFraction`.
    ///  1. Two detectors over the SAME input: the base sustained-elevation detector plus the
    ///     app-layer interval/strength detector (set/rest cadence the base one can't see — its
    ///     ≤90 s dip tolerance splits on every 2–3 min rest).
    ///  2. EPOC / low-floor trim (pure post-pass, BOTH detectors, before merge): a low overnight
    ///     resting HR puts the elevated floor (resting + 30) below normal post-workout daytime HR,
    ///     so cooldown / EPOC drift never exits the elevated state and a ~50 min bout can surface
    ///     as a ~4 h candidate. Trim each candidate back to its own work band; a candidate that no
    ///     longer passes its detector's gates afterwards is dropped. See `WorkoutTailTrimmer`.
    ///  3. Merge: base wins any overlap (steadier signal) — `IntervalWorkoutDetector.merged`.
    ///  4. Intensity post-filter: drop a survivor holding under `suggestionMinZone3PlusMinutes` at
    ///     ≥ 70 %HRR. Skipped with the anchoring when there is no reserve to score against.
    ///  5. Exclusion filters run on the TRIMMED span (the survivor is what would be suggested, so
    ///     it is what must be checked): drop a candidate overlapping any saved workout (touching
    ///     endpoints count — the detectors' rule) or any dismissed span (strict overlap, by
    ///     TIME-OVERLAP not exact "startSec:endSec" token: a later sync that extends the bout's
    ///     end yields a different token, so an exact-match filter would re-prompt an
    ///     already-dismissed suggestion — mirroring `WorkoutSource.isDismissed`).
    ///  6. Sort newest-first (startSec descending) — the queue order the Today row consumes.
    ///
    /// PURE READ — nothing here is ever persisted, so no history can be damaged by a change to
    /// these gates; a candidate that stops surfacing simply stops being suggested.
    nonisolated static func autoDetectQueue(hr: [(ts: Int, bpm: Int)],
                                            restingBpm: Int?,
                                            savedSpans: [(start: Int, end: Int)],
                                            dismissedSpans: [(start: Int, end: Int)],
                                            hrmaxBpm: Int? = profileHRmaxBpm()) -> [DetectedWorkout] {
        // 0: reserve-anchored floor (see `anchoredRestingBpm`). NOTE for whoever next touches the
        // Signal Lab detection panel: it re-runs `AutoWorkoutDetector` / `IntervalWorkoutDetector` /
        // `WorkoutTailTrimmer` itself for its per-candidate rows and still passes them the RAW
        // resting HR, so those rows list candidates this queue now drops (mislabelled `.mergedAway`).
        // Its authoritative queue comes from here and is correct; threading `anchoredRestingBpm`
        // through that view's three direct detector calls is the one-line follow-up.
        let effResting = Double(restingBpm ?? AutoWorkoutDetector.defaultRestingHR)
        let reserve = suggestionReserve(restingBpm: restingBpm, hrmaxBpm: hrmaxBpm)
        let anchoredResting = anchoredRestingBpm(restingBpm: restingBpm, hrmaxBpm: hrmaxBpm)

        // Detectors run UNFILTERED (savedSpans: []) so the saved-overlap check below can run on the
        // TRIMMED span — a raw span whose cooldown drift merely brushes a saved workout is still a
        // valid suggestion once the trim cuts the drift off.
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: anchoredResting,
                                              motion: nil, savedSpans: [])
        let interval = IntervalWorkoutDetector.detect(hr: hr, restingBpm: anchoredResting,
                                                      savedSpans: [])
        let trimmedBase = base.compactMap {
            WorkoutTailTrimmer.trim($0, kind: .base, hr: hr, restingBpm: anchoredResting).survivor
        }
        let trimmedInterval = interval.compactMap {
            WorkoutTailTrimmer.trim($0, kind: .interval, hr: hr, restingBpm: anchoredResting).survivor
        }
        return IntervalWorkoutDetector.merged(base: trimmedBase, interval: trimmedInterval)
            .filter { cand in
                // Intensity dose (see `suggestionMinZone3PlusMinutes`). No reserve → no filter.
                guard let r = reserve else { return true }
                return zone3PlusMinutes(cand, hr: hr, restingBpm: effResting, hrReserve: r)
                    >= suggestionMinZone3PlusMinutes
            }
            .filter { cand in
                // Saved: touching endpoints count (the detectors' overlap rule).
                !savedSpans.contains { cand.startSec <= $0.end && $0.start <= cand.endSec }
            }
            .filter { cand in
                // Dismissed: strict overlap (`WorkoutSource.isDismissed`'s rule).
                !dismissedSpans.contains { cand.startSec < $0.end && $0.start < cand.endSec }
            }
            .sorted { $0.startSec > $1.startSec }
    }

    /// Minutes a candidate holds at or above `WorkoutDetector.zone3HRRPct` (70 %HRR), measured on
    /// the series the detectors actually saw.
    ///
    /// The series is NOT 1 Hz — `autoDetectHR` hands the pipeline 5-second bucket means — so a
    /// sample is worth the series' own MEDIAN inter-sample step, not one second. Median rather than
    /// mean-of-elapsed so an unworn gap inside the span can't inflate the dose (the failure mode
    /// that makes an elapsed-time weighting unsafe on a non-gap-filled read); clamped to [1, 60] s
    /// so a pathological cadence can't either. On the production 5-s stream this is exactly
    /// `count × 5 s`, which is what the 17-day measurements behind
    /// `suggestionMinZone3PlusMinutes` were taken with.
    ///
    /// P5 — WHAT CHANGED AND WHY. This used to open with
    /// `hr.filter { … }.sorted { … }`: a full scan of the 7-day series (up to 120,960 points) plus
    /// TWO freshly allocated tuple arrays, ONCE PER surviving candidate, every time the queue was
    /// rebuilt. The scan and both copies are gone — `hr` arrives strictly ascending by ts (see
    /// `autoDetectHR`), so the window is now an index RANGE found by binary search and walked with a
    /// single cursor. The arithmetic is untouched: the same inclusive `[startSec, endSec]` bounds,
    /// the same inter-sample steps, the same `steps[count / 2]` median (upper median on an even
    /// count — deliberately kept, not "fixed"), and the same `>= cut` tally. The dose, and therefore
    /// the queue, is byte-identical.
    ///
    /// PRECONDITION, now load-bearing: `hr` must be sorted ascending by ts. That was already true of
    /// every caller — the store's `hrBuckets` is `GROUP BY … ORDER BY bucket ASC`, and the test
    /// fixtures build the same shape — and the old `.sorted` merely re-established it defensively at
    /// the cost of the copy. A caller that hands this an unordered series now gets a wrong window
    /// instead of a slow right one, which is why the ordering guarantee is written down at
    /// `autoDetectHR` too rather than left as an incidental property of the SQL.
    nonisolated static func zone3PlusMinutes(_ cand: DetectedWorkout,
                                             hr: [(ts: Int, bpm: Int)],
                                             restingBpm: Double,
                                             hrReserve: Double) -> Double {
        let win = spanRange(hr, from: cand.startSec, to: cand.endSec)
        guard win.count > 1 else { return 0 }
        let cut = restingBpm + WorkoutDetector.zone3HRRPct / 100.0 * hrReserve
        // One cursor over the range collects both things the old code made two passes and two arrays
        // for: the inter-sample steps (for the median) and the above-cut count. `steps` is the only
        // allocation left and it is sized to the CANDIDATE, not to the 7-day series.
        var steps: [Int] = []
        steps.reserveCapacity(win.count - 1)
        var above = Double(hr[win.lowerBound].bpm) >= cut ? 1 : 0
        var prevTs = hr[win.lowerBound].ts
        for i in (win.lowerBound + 1)..<win.upperBound {
            let s = hr[i]
            steps.append(s.ts - prevTs)
            prevTs = s.ts
            if Double(s.bpm) >= cut { above += 1 }
        }
        steps.sort()
        let stepS = max(1, min(60, steps[steps.count / 2]))
        return Double(above) * Double(stepS) / 60.0
    }

    /// The index range of `hr` whose timestamps fall inside the INCLUSIVE `[from, to]` window, found
    /// by binary search. `hr` MUST be sorted ascending by ts (see `autoDetectHR`). An out-of-order
    /// or reversed window yields an empty range, so callers can read `.count` exactly the way they
    /// read the old filtered array's.
    ///
    /// Exists so the candidate post-pass stops re-scanning the whole 7-day series once per candidate.
    /// `WorkoutTailTrimmer.trim` used to open with the IDENTICAL `filter { … }.sorted { … }` shape over
    /// the same series, and it runs over the un-merged candidate sets, so it paid that cost more times
    /// than this does. That follow-up has LANDED (P5's second half): `trim` now takes its span, its
    /// work anchors and its in-trim recompute off this function. Both callers therefore share ONE
    /// window definition — which is why the inclusive upper bound below is spelled out here rather
    /// than left for each caller to re-derive.
    nonisolated static func spanRange(_ hr: [(ts: Int, bpm: Int)], from: Int, to: Int) -> Range<Int> {
        // First index whose ts is >= `from`.
        var lo = 0, hi = hr.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if hr[mid].ts < from { lo = mid + 1 } else { hi = mid }
        }
        let start = lo
        // First index whose ts is > `to` — an INCLUSIVE upper bound, matching the `$0.ts <= endSec`
        // the filter used. Resumes from `start`, so `to < from` collapses to an empty range.
        hi = hr.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if hr[mid].ts <= to { lo = mid + 1 } else { hi = mid }
        }
        return start..<lo
    }

    /// SAVE a suggested window as a manual-style "Workout" (generic sport — we don't claim a sport we
    /// didn't classify), through the same `buildManualRow` the manual sheet uses.
    @discardableResult
    func saveDetectedWorkout(_ w: DetectedWorkout) async -> Bool {
        let durationMin = max(1, w.durationMin)
        let start = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        guard let row = WorkoutSource.buildManualRow(start: start, durationMin: durationMin,
                                                     sport: "Workout", avgHr: w.avgBpm,
                                                     energyKcal: nil) else { return false }
        await saveManualWorkout(row)
        return true
    }

    /// The durable auto-detect dismissed spans, parsed into the same `(start, end)` tuples the candidate
    /// filter overlap-checks against. Read by the Signal Lab detection panel so the diagnostic consults
    /// the SAME source the suggestion path filters on, never a re-derivation.
    var autoDetectDismissedSpanList: [(start: Int, end: Int)] {
        WorkoutSource.parseDismissedSpans(autoDetectDismissedSpans)
    }

    /// DISMISS a suggested window: record its span durably so it never re-prompts. Idempotent; prunes on
    /// every add so the stored list can never grow unbounded.
    func dismissDetectedSuggestion(_ w: DetectedWorkout) {
        let token = autoDetectToken(w)
        var spans = autoDetectDismissedSpans
        guard !spans.contains(token) else { return }
        spans.append(token)
        autoDetectDismissedSpans = prunedAutoDetectSpans(spans, now: Int(Date().timeIntervalSince1970))
    }
}
