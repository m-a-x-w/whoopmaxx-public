import Foundation
import UIKit
import StrapProtocol
import StrapStore
import StrapAnalytics

/// The manually-tracked workout recorder (W7, port of the original AppModel — no GPS): start / capture / end,
/// the durable crash-recovery snapshot (#529), and the live-strain + persist throttles.
///
/// Its OWN `ObservableObject` (a nested one is NOT observed through its parent), so the Live screens take
/// `@EnvironmentObject var workout: WorkoutSessionController` — injected by `WhoopmaxxApp` next to `repo`.
///
/// Realtime HR is a REF-COUNT owned by `AppRoot` (it is composition wiring, shared with the Live tab's
/// appear/disappear), so this controller only says WHEN it wants the stream, through the two injected
/// closures. They are settable `var`s rather than init-only because the root can't reference `self`
/// while its stored properties are still being assigned (the `journal.onChanged` idiom).
@MainActor
final class WorkoutSessionController: ObservableObject {
    private let repo: Repository
    /// The workout write layer — the one cache a just-saved manual row has to reach.
    private let workoutRepo: WorkoutRepository
    private let profile: ProfileStore

    /// Take a PERSISTENT realtime-HR wanter for the whole session so capture survives leaving the Live
    /// tab (device-only bug otherwise), and release it on end. `AppRoot` supplies the ref-counted pair.
    var armRealtime: () -> Void
    var disarmRealtime: () -> Void

    /// An in-progress manually-tracked workout (W7). Holds the start time + the live HR collected since;
    /// on End the window is scored via `StrainScorer` and saved as a `WorkoutRow` (source "manual"). The
    /// day's Effort already counts this HR (same live stream the store persists), so a session is a
    /// per-session ANNOTATION, not a double-count. Port of the original AppModel's activeWorkout path (no GPS).
    @Published var activeWorkout: ActiveWorkout?
    /// The just-ended workout, for a brief inline confirmation on Live (cleared on the next start).
    @Published var justEndedWorkout: WorkoutRow?

    /// A manual workout in progress — LIGHTWEIGHT aggregates only. The growing per-second HR samples live
    /// OUT of this @Published struct in `workoutSamples`, so appending a sample never COW-deep-copies
    /// an array embedded in the struct and republishing the struct each second stays O(1). `liveStrain` is
    /// recomputed as the window grows so the active card can show strain building in real time.
    struct ActiveWorkout: Equatable {
        let start: Date
        /// The named sport chosen at start (e.g. "Tennis"), persisted as the saved row's `sport`.
        var sport: String = WorkoutCatalog.defaultSportName
        var liveStrain: Double = 0
        var avgHr: Int = 0
        var peakHr: Int = 0
    }

    /// The user's MEASURED resting HR (newest scored day that has one), for the Effort denominator.
    ///
    /// WHY THIS AND NOT `StrainScorer.defaultRestingHR`. Both scorers can see the same bout: the manual
    /// session saved here, and `WorkoutDetector`'s auto-detected copy — which ALWAYS scores against a real
    /// resting HR. Leaving this path on the 60 constant made one bout carry two different Effort numbers,
    /// and the error is worst where the score is smallest: at this user's measured 47, a light 120 bpm
    /// session is Edwards zone 1, but against 60 it is zone 0, i.e. it displayed zero Effort.
    ///
    /// Deliberately NOT derived from the workout window itself. The 10th-percentile estimate is only valid
    /// over a whole day (the only way `WorkoutDetector` uses it); a bout that starts already-warm has a
    /// 10th percentile of ~140, which would collapse the same session's Effort from the other direction.
    /// nil-safe: a cold install with nothing measured yet falls back to the constant.
    private var measuredRestingHR: Double {
        repo.days.sorted { $0.day > $1.day }
            .compactMap(\.restingHr).first.map(Double.init) ?? StrainScorer.defaultRestingHR
    }

    /// The growing per-second HR samples for the in-flight manual workout, held OUTSIDE the @Published
    /// `ActiveWorkout` struct so `append` writes in place on this uniquely-referenced buffer
    /// (amortized O(1)) rather than COW-deep-copying a struct-embedded array every ~1 Hz sample — and so
    /// republishing `activeWorkout` no longer re-emits the whole growing window each second. Reset on start,
    /// scored on end, persisted into the durable Snapshot, and restored on rehydrate. (P1)
    private var workoutSamples: [HRSample] = []
    /// True when the active session was rehydrated across a real app-kill gap, so it exists only to be
    /// finalized honestly — it must not capture. Set in `rehydrateActiveWorkout`, cleared on a new start.
    private(set) var revivedIdle = false
    /// Running Σ of every sample's bpm, kept in step with `workoutSamples` so `avgHr` is an O(1) update.
    /// Not persisted (the durable Snapshot stores `avgHr` directly); rebuilt on rehydrate by replaying the
    /// restored samples through `append`, the ONE place either half moves.
    private var bpmSum = 0

    /// Throttle for the per-sample durable snapshot: re-encoding the whole growing HR window per ~1 Hz
    /// sample is O(n²) blob churn, so the per-sample persist is spaced. A mid-session kill still recovers
    /// everything up to at most the last interval (#529). Reset on Start so the first sample persists.
    private var lastWorkoutPersistAt: Date = .distantPast
    private static let workoutPersistInterval: TimeInterval = 15
    /// Throttle for the live-strain recompute. `StrainScorer.strain` is O(samples), so recomputing it on
    /// every ~1 Hz sample is O(n²) main-actor work over a long workout (and churns the shared strain memo).
    /// Recompute every few seconds instead; the final saved strain still runs once over the full window.
    private var lastLiveStrainAt: Date = .distantPast
    private static let liveStrainInterval: TimeInterval = 3

    init(repo: Repository,
         workoutRepo: WorkoutRepository,
         profile: ProfileStore,
         armRealtime: @escaping () -> Void = {},
         disarmRealtime: @escaping () -> Void = {}) {
        self.repo = repo
        self.workoutRepo = workoutRepo
        self.profile = profile
        self.armRealtime = armRealtime
        self.disarmRealtime = disarmRealtime
    }

    // MARK: - Launch

    /// Launch hook, called from `AppRoot.start()` (never from `init` — a `#Preview` that builds an object
    /// graph must not revive a session or write a snapshot).
    ///
    /// #529: if a manual workout was in flight when iOS killed the app, rebuild it from the durable
    /// snapshot so reopening doesn't lose it — the session can still be ended + saved.
    func start() {
        rehydrateActiveWorkout()

        #if DEBUG
        // `--demo-active-workout` (sim has no BLE): inject a synthetic in-workout session so the Live
        // session block (elapsed / building strain / HR stream / Stop) renders for screenshots. The
        // caller seeds a live link + HR alongside this so the reused stream fills too.
        if DebugFlags.demoActiveWorkout {
            var w = ActiveWorkout(start: Date().addingTimeInterval(-22 * 60), sport: "Tennis")
            w.avgHr = 138
            w.peakHr = 164
            w.liveStrain = 11.4
            activeWorkout = w
        }
        #endif
    }

    // MARK: - Session

    /// Start a manual workout under the chosen sport (catalogue default "Other" when none). The Live
    /// session block then shows elapsed time, building strain and the live HR-zone stream; End scores +
    /// saves it under this sport. On start we take a PERSISTENT realtime-HR wanter so `ingest(bpm:)`
    /// keeps getting bpm even if the user leaves the Live tab mid-session (device-only bug otherwise).
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        justEndedWorkout = nil
        revivedIdle = false   // a fresh session always captures
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        activeWorkout = ActiveWorkout(start: Date(), sport: resolved)
        workoutSamples = []   // fresh HR buffer for this session
        bpmSum = 0
        // Keep the realtime stream armed for the whole session so capture survives leaving Live.
        armRealtime()
        // Make the session durable from the first instant (#529); arm the throttle so the first sample
        // persists immediately, then settles into the throttled cadence.
        lastWorkoutPersistAt = .distantPast
        lastLiveStrainAt = .distantPast   // first sample computes strain immediately, then throttles
        persistActiveWorkout()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Finish the active workout: score the captured HR window and save it as a `WorkoutRow` (source
    /// "manual") under the strap id, then refresh. A session with fewer than 2 samples is discarded
    /// quietly. Releases the persistent realtime wanter taken on start.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        disarmRealtime()
        let samples = workoutSamples
        workoutSamples = []
        bpmSum = 0
        // Too few samples to score → discard quietly. Nothing will be persisted, so there's no upsert to
        // protect: drop the durable snapshot now.
        guard samples.count >= 2 else { ActiveWorkoutPersistence.clear(); justEndedWorkout = nil; return }
        // Clamp the finish to the newest captured sample: a session revived by `rehydrateActiveWorkout`
        // after an idle kill/reopen gap (the staleness cap only rejects snapshots > 24 h old) must record
        // only its real coverage, not the wall-clock hours it sat idle — otherwise duration/span dwarf the
        // sample-derived strain/HR, and the inflated span lets `dedupCrossSource` swallow real same-sport
        // sessions logged inside it. For a live session the newest sample is ~now, so this is a no-op.
        let lastSample = samples.map(\.ts).max().map { Date(timeIntervalSince1970: Double($0)) }
        let end = min(Date(), lastSample ?? Date())
        let avg = Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max()
        let strain = StrainScorer.strain(samples, maxHR: Double(profile.hrMax),
                                         restingHR: measuredRestingHR, sex: profile.sex)
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the detector
        // uses) so a manual session shows energy too, not just duration/strain.
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = Calories.estimateBoutCalories(samples, profile: up,
                                                 hrmax: Double(profile.hrMax),
                                                 restingHR: measuredRestingHR).0
        let startTs = Int(w.start.timeIntervalSince1970)
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            distanceM: nil, zonesJSON: nil, notes: nil)
        justEndedWorkout = row
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { [weak self, workoutRepo] in
            // Commit the finished workout to the DB FIRST, then drop the durable in-flight snapshot. If we
            // cleared before the upsert (the old order) a crash mid-upsert lost the session with no recovery
            // record (#529). On an upsert failure we deliberately KEEP the snapshot so a relaunch can
            // rehydrate and re-save the session rather than silently lose it — which is why this goes
            // through the RESULT-RETURNING `saveManualWorkout` rather than a fire-and-forget write.
            // That call also refreshes the workout cache: only that cache can have moved — the daily /
            // sleep lanes are untouched by a workout upsert.
            guard await workoutRepo.saveManualWorkout(row) else { return }
            // Drop the durable snapshot ONLY if no NEW workout started during the await — a
            // Start-after-Stop would have written the fresh session's crash-recovery snapshot
            // (startWorkout → persistActiveWorkout), and clearing here would wipe it, losing that
            // session on an iOS kill (#529). The new session owns the snapshot now; this one's row
            // is already committed to the DB.
            if self?.activeWorkout == nil { ActiveWorkoutPersistence.clear() }
        }
    }

    /// Append the smoothed live `bpm` to the active workout and recompute its running strain. Called from
    /// `AppRoot`'s HR ingest on every fresh smoothed sample; a no-op when no workout is running.
    func ingest(bpm hr: Int) {
        // The guard belongs HERE, not at `armRealtime`: opening the Live tab takes its own realtime
        // wanter, so a revived-idle session would be fed anyway. See `rehydrateActiveWorkout`.
        guard !revivedIdle, var w = activeWorkout else { return }
        let ts = Int(Date().timeIntervalSince1970)
        // Keep ONE sample per whole second so the workout window isn't double-dense (ingestHR is coalesced
        // per packet — P2 — but a slow second could still surface two): a double-dense window would double
        // the strain-recompute cost and bias the avg. (P3)
        if workoutSamples.last?.ts == ts { return }
        append(bpm: hr, at: ts)
        w.peakHr = max(w.peakHr, hr)
        // O(1) running mean off the Σ `append` folded, rather than re-summing the whole window.
        w.avgHr = Int((Double(bpmSum) / Double(workoutSamples.count)).rounded())
        let now = Date()
        // Live strain recompute throttled to ~every few seconds (P1): StrainScorer.strain is O(samples),
        // so a per-sample recompute is O(n²) on the main actor over a long workout. Display strain lags by
        // at most the interval and converges; endWorkout() computes the final strain once over the full window.
        if now.timeIntervalSince(lastLiveStrainAt) >= Self.liveStrainInterval {
            lastLiveStrainAt = now
            w.liveStrain = StrainScorer.strain(workoutSamples, maxHR: Double(profile.hrMax),
                                               restingHR: measuredRestingHR,
                                               sex: profile.sex) ?? w.liveStrain
        }
        // Republish only the lightweight aggregates — no samples array — so this per-second emit is cheap.
        activeWorkout = w
        // Re-snapshot the durable session so a kill keeps the latest window (#529), throttled — the encode
        // re-serializes the whole growing window, so a per-sample write is O(n²) blob churn.
        if now.timeIntervalSince(lastWorkoutPersistAt) >= Self.workoutPersistInterval {
            lastWorkoutPersistAt = now
            persistActiveWorkout()
        }
    }

    /// The ONE place the sample buffer grows: append in place on the uniquely-referenced buffer (amortized
    /// O(1); the samples no longer live in the @Published struct, so this never COW-deep-copies a growing
    /// array — P1) AND fold the bpm into the running Σ. Single mutation point, so `workoutSamples` and
    /// `bpmSum` cannot drift apart — the live capture and the rehydrate replay both come through here.
    private func append(bpm: Int, at ts: Int) {
        workoutSamples.append(HRSample(ts: ts, bpm: bpm))
        bpmSum += bpm
    }

    // MARK: - Durable snapshot (#529)

    /// Persist the in-flight manual workout to `UserDefaults` so it survives an app kill mid-session
    /// (#529). Called on start + each captured sample. A no-op when nothing is running.
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport, samples: workoutSamples, avgHr: w.avgHr,
                peakHr: w.peakHr, liveStrain: w.liveStrain))
    }

    /// Rebuild `activeWorkout` from the durable snapshot on launch (#529). No-op when a workout is already
    /// live or nothing is stored. Re-takes the realtime wanter so a restored session keeps capturing.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        // #529 staleness cap: a snapshot whose start is in the future or older than the longest plausible
        // manual session (24h, matching buildManualRow's durationMin cap) is not a recoverable in-flight
        // session — reviving it would show a multi-day "Recording" card and, on Stop, save a giant WorkoutRow
        // that dedupCrossSource then collapses real same-sport sessions under. Drop + clear it instead (clear
        // so it can't re-trigger every launch). The staleness check lives here (not in the pure, clock-free
        // codec) so encode/decode stay time-independent for unit tests.
        let start = TimeInterval(snap.startSec)
        let now = Date().timeIntervalSince1970
        guard start <= now, now - start <= 24 * 3600 else {
            ActiveWorkoutPersistence.clear()
            return
        }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: start), sport: snap.sport)
        workoutSamples = []
        bpmSum = 0
        for s in snap.samples { append(bpm: s.bpm, at: s.ts) }
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        activeWorkout = w

        // A session revived across a REAL gap is revived for FINALIZATION ONLY, never for resumed
        // capture. `endWorkout`'s clamp to the newest sample is the intended defence, but it only works
        // while no new sample arrives: re-arming realtime here fed fresh ~now samples straight in, so the
        // clamp became a no-op and Stop saved a row spanning the entire dead-app gap — 14 h of "workout"
        // for 40 min of activity, with strain/kcal computed from the real samples only, so duration and
        // load disagreed. Worse, ScoreEngine drops any auto-detected bout that merely OVERLAPS a real
        // workout, so every detected bout inside the gap was silently discarded too.
        //
        // The threshold is well above the 15 s persist throttle, so relaunching straight after a crash
        // still resumes capture normally. Nothing is discarded either way — every restored sample is
        // still scored and saved on Stop.
        let lastTs = snap.samples.map(\.ts).max() ?? snap.startSec
        revivedIdle = (now - TimeInterval(lastTs)) > Self.revivedIdleGapSec
        // Arm UNCONDITIONALLY, even when revived-idle. `armRealtime`/`disarmRealtime` are a strict
        // ref-count in AppRoot, and `endWorkout` releases one on every Stop — so skipping the arm here
        // would make that Stop consume the LIVE TAB's wanter instead, dropping the count to zero and
        // killing the live stream on a visible Live tab, with the imbalance persisting into the next
        // session. The arm is not what makes this fix work: the load-bearing guard is `!revivedIdle` in
        // `ingest(bpm:)`, so a revived-idle session still captures nothing and the clamp still yields the
        // honest end.
        armRealtime()
    }

    /// Gap after which a rehydrated session stops capturing (see `rehydrateActiveWorkout`).
    private static let revivedIdleGapSec: TimeInterval = 300
}
