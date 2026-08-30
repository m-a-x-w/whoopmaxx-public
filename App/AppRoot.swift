import Foundation
import Combine
import SwiftUI

/// Composition root — the pruned whoopmaxx twin of the original AppModel. Builds the core loop
/// (LiveState → BLEManager → Repository → ScoreEngine), smooths the live HR centrally, and drives the
/// two score-refresh paths: the post-sync debounce (a completed backfill rescoring right away) and the
/// 15-minute steady-state backstop tick.
@MainActor
final class AppRoot: ObservableObject {
    let live: LiveState
    let ble: BLEManager
    let repo: Repository
    /// The workout write layer + suggestion pipeline over the same store handle. Its `workouts` cache is
    /// its OWN `@Published` (a nested ObservableObject is not observed through its parent), so every
    /// workout screen takes `@EnvironmentObject var workoutRepo: WorkoutRepository` — injected by
    /// `WhoopmaxxApp` next to `repo`.
    let workoutRepo: WorkoutRepository
    /// The manual workout recorder (W7): start/capture/end + the #529 crash-recovery snapshot. Its
    /// `activeWorkout` / `justEndedWorkout` are its OWN `@Published`s (a nested ObservableObject is not
    /// observed through its parent), so the Live screens take
    /// `@EnvironmentObject var workout: WorkoutSessionController` — injected by `WhoopmaxxApp`.
    let workout: WorkoutSessionController
    let profile: ProfileStore
    let scores: ScoreEngine
    /// Rest wake-window smart alarm (W9): arms the strap firmware backstop at the latest edge, schedules a
    /// notification backup, and advances the wake early on detected light sleep. Wired below off the same
    /// live sinks; injected into the environment by `WhoopmaxxApp`.
    let alarm: SmartAlarmCoordinator
    /// Persisted "why did the band buzz" history — appended at each app-sent buzz (habit, smart alarm,
    /// inactivity nudge).
    let buzzLog = BuzzLog()

    /// True once a restore has swapped the database file in THIS process.
    ///
    /// `BackupImport` Gate 6 unlinks the live DB and its WAL/SHM before copying the backup into place,
    /// but nothing tears down the open `DatabasePool`s (Repository caches its handle forever, and
    /// BLEManager — verbatim by decision — offers no coordination seam; that is exactly why the importer
    /// returns `.needsRelaunch`). From the swap onward the writer's fds point at a deleted inode while
    /// any newly-opened connection sees the restored file, so continued use silently discards every
    /// journal tag, weed session, manual workout, habit log and decoded sample.
    ///
    /// PROCESS-LIFETIME ONLY — deliberately not persisted and never defaulted true. A persisted version
    /// would brick the app into needing a reinstall, which is strictly worse than the bug it closes.
    @Published private(set) var relaunchRequired = false

    /// What landed, so `RelaunchWall` can say it. nil when the caller has no summary to hand over —
    /// First Run's restore route, and any legacy call site — where the wall reads exactly as before.
    ///
    /// The receipt has to travel WITH the flag. Setting `relaunchRequired` swaps the whole window for
    /// `RelaunchWall`, tearing down `AppShell` → `MoreScreen` → `DataSection` and the import runner that
    /// holds the summary. So a receipt rendered on the Data screen is unreachable BY CONSTRUCTION: the
    /// screen it lives on stops existing in the same update that would have shown it.
    @Published private(set) var restoreReceipt: BackupImport.Inspection.Summary?

    /// Called on the `.needsRelaunch` edge from every import call site.
    func markStoreSwapped(receipt: BackupImport.Inspection.Summary? = nil) {
        restoreReceipt = receipt
        relaunchRequired = true
    }
    /// Live-HR Live Activity (Lock Screen + Dynamic Island). Driven from the live-HR / connection sinks
    /// below (auto path) and the Live tab's Pin button (manual path). `isRunning` is @Published for the
    /// button; injected into the environment by `WhoopmaxxApp` so screens observe it.
    let liveActivity = LiveActivityController()
    /// Write-only Apple Health export (W8). Pushes the Repository's merged vitals + sleep stages to
    /// Apple Health on the analyze seam + toggle-enable. A cheap no-op when the toggle is off. Injected
    /// into the environment by `WhoopmaxxApp` so the More toggle observes its auth state.
    let healthExport: HealthExport
    /// Journal facade (007 F1): merged-lane reads over the store's `journal` table, native tag writes
    /// under "wm-journal" — each write re-runs the FORCED rescore (journal tags feed the health-monitor
    /// confounders) and refreshes the dashboard. Injected into the environment by `WhoopmaxxApp`.
    let journal: JournalStore
    /// Weed facade (009): the v26 `weedSession` table, the additive DETAIL behind the journal's
    /// per-day weed boolean. It has no `onChanged` seam of its own and needs none — every boolean
    /// write goes through `journal.set`, so a weed tap already rides the journal hook below into
    /// `dataDidChange(.derivedRows)`. Injected by `WhoopmaxxApp`, which also loads its cache in the
    /// launch `.task` AFTER `journal.refresh()` (the repair reads the tag cache).
    let weed: WeedStore
    /// Intake facade (024): the v27 `ingestionEvent` table — meal / caffeine / alcohol / water, with
    /// a timestamp. Like `WeedStore` it needs no `onChanged` seam, because the only boolean it ever
    /// writes goes through `journal.set` and rides the journal hook below. Unlike `WeedStore` its
    /// projection RAISES ONLY: `alcohol` and `caffeine_late` are chips the user taps directly, and
    /// nothing tells an app-raised tag from a user-tapped one, so this feature must never lower one.
    /// Injected by `WhoopmaxxApp`, which loads its cache in the launch `.task` AFTER
    /// `journal.refresh()` (the repair reads the tag cache).
    let intake: IntakeStore
    /// Strap health center read model (007 F4): battery now/trend/estimate from the persisted battery
    /// table, capture coverage + gaps via GapScan, session signal-quality grade. Constructed here (not
    /// in the screen) so its reconnect counter spans the whole session. Injected by `WhoopmaxxApp`.
    let strapHealth: StrapHealthModel
    /// Habits facade (008): the v25 `habit` / `habitLog` tables, current-period adherence derived
    /// from the sleep / workout / nap lanes. Injected by `WhoopmaxxApp`; its buzz windows drive the
    /// live-loop wrist-buzz hook below.
    let habits: HabitsStore
    /// The app's app-sent-buzz center (008 / #460): the windowed habit reminder, the Haptic Clock time
    /// check, the buzz-history recording for the smart-alarm + inactivity buzzes, and the low-battery
    /// notification. Publishes nothing, so it is a plain `let` — this root just calls `tick()` from the
    /// live-HR sink and the 15-minute backstop.
    let buzz: HabitBuzzScheduler

    /// UserDefaults key holding the paired strap's peripheral UUID (survives relaunch; cleared by
    /// Forget device). The pin that makes reconnects targeted instead of blind-scan.
    static let pairedPeripheralKey = "wm.pairedPeripheralUUID"

    /// Smoothed, display-ready live heart rate — median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?

    /// Ref-count of screens currently wanting the realtime HR stream (the original AppModel port). The
    /// strap only emits realtime frames after TOGGLE_REALTIME_HR — and the WHOOP 4 connect
    /// handshake turns the stream OFF — so the live tab must arm it explicitly.
    private var realtimeWanters = 0
    /// Bounded re-arm loop for a lost arm command (see `kickRealtimeWatchdog`).
    private var realtimeWatchdog: Task<Void, Never>?
    /// The live-HR window + median (clamp, rr-fallback, ~10 s/40-sample bounds, the #39 blank rule).
    /// Plain value state — this root only decides what to REPUBLISH from it (see `ingestHR`).
    private var smoother = HRSmoother()
    /// Coalescing gate for the two live-HR sinks: set when the first of a packet's `$heartRate`/`$rr` fires
    /// and cleared when the scheduled ingest runs, so `ingestHR` (a full-window re-sort) executes ONCE per
    /// packet instead of twice. (P2)
    private var hrIngestScheduled = false
    /// P1: cached (charge, effort) for the Live Activity, refreshed only when the repository republishes
    /// a score change (see the `CombineLatest(repo.$days, repo.$restSeries)` sink) — NOT recomputed on
    /// every ~1 Hz bpm tick, since `WidgetDayResolver.fields` is 6–8 O(days) passes.
    private var liveActivityCache: (charge: Int?, effort: Int?) = (nil, nil)
    private var cancellables = Set<AnyCancellable>()
    /// The app's scheduled jobs, in ONE register (see `PeriodicWork`): the 15-minute steady-state analyze
    /// tick and the deferred launch backup catch-up. Both are owned + cancellable here rather than being
    /// loose Tasks; neither is ever cancelled in the shipping app, since AppRoot is the `@StateObject`
    /// composition root and lives for the whole process.
    private let periodic = PeriodicWork()
    /// Job ids for `periodic` — one constant per schedule, so the register reads as a list.
    private enum Job {
        static let analyzeTick = "analyze-tick"
        static let backupCatchUp = "backup-catch-up"
        static let liveSessionSweep = "live-session-sweep"
        static let retentionSweep = "retention-sweep"
    }
    /// Daily 00:01 re-arm timer for the smart alarm (the firmware alarm is a single instant, so a
    /// continuously-bonded strap needs a nightly re-arm). Invalidated only when it re-schedules itself.
    /// Stays a wall-clock `Timer` rather than a `PeriodicWork` interval job: it is anchored with
    /// `Calendar.nextDate(matching:)` to local 00:01, which an interval can't express across DST.
    private var smartAlarmRearmTimer: Timer?
    /// One-shot guard for `start()` — the launch side effects arm exactly once per process.
    private var started = false

    init() {
        // One-time launch migration: fold a retired `units.temperature` override into `units.system`
        // (Fahrenheit → Imperial) and drop the key, so Units alone drives temperature. Runs before any
        // temperature surface reads the pref. Mirrors the launch-apply spot used for the HRV pref below.
        TempUnit.migrateTemperatureOverride()

        let live = LiveState()
        self.live = live
        let repo = Repository()
        self.repo = repo
        let workoutRepo = WorkoutRepository(repo: repo)
        self.workoutRepo = workoutRepo
        let profile = ProfileStore()
        self.profile = profile
        // Manual workout recorder (W7). Its realtime-HR closures are wired below, once every stored
        // property is assigned and `self` is usable (the `journal.onChanged` idiom).
        self.workout = WorkoutSessionController(repo: repo, workoutRepo: workoutRepo, profile: profile)
        // BLEManager opens its own store handle in bootstrapStore() once CoreBluetooth reaches
        // poweredOn — same shared sqlite file the Repository reads (WAL handles the two handles).
        self.ble = BLEManager(state: live, deviceId: repo.deviceId)
        let scores = ScoreEngine(repo: repo, profile: profile, deviceId: repo.deviceId)
        self.scores = scores
        // Write-only Health bridge over the same merged caches. (The silent resume of a prior grant
        // runs in `start()`.)
        let healthExport = HealthExport(repo: repo)
        self.healthExport = healthExport
        // Journal facade over the same store handle (007 F1). Constructed after the engine so a tag
        // write can force the rescore that re-reads the tags. The initial chip-cache load runs from
        // WhoopmaxxApp's launch `.task` (after any demo seed, so seeded tags surface too).
        self.journal = JournalStore(repo: repo, scores: scores)
        // Weed facade (009) — constructed after the journal it writes THROUGH: sessions are detail,
        // the journal boolean stays the single truth for whether a day is a weed day. Its session
        // cache is loaded from WhoopmaxxApp's launch `.task`, after the journal's.
        self.weed = WeedStore(repo: repo, journal: self.journal)
        // Intake facade (024) — same construction order and for the same reason: it writes booleans
        // only through `journal.set`. Its event cache is loaded from WhoopmaxxApp's launch `.task`,
        // after the journal's, because its repair compares owed tags against the tag cache.
        self.intake = IntakeStore(repo: repo, journal: self.journal)
        // Habits facade (008) — no rescore coupling (habits don't feed scores); derives adherence
        // from the same repo lanes the dashboard reads. Its cache is loaded from WhoopmaxxApp's
        // launch `.task` alongside the journal cache.
        self.habits = HabitsStore(repo: repo)
        // Strap health center (007 F4) — constructed with the session-long live/repo pair so its
        // reconnect counter starts at launch, not when the screen first opens.
        self.strapHealth = StrapHealthModel(repo: repo, live: live)
        // The buzz center (008 / #460). Wires its own strap-facing hooks (the DOUBLE_TAP time check,
        // the low-battery notifier) in its initializer; the two LAUNCH hooks are attached from `start()`.
        self.buzz = HabitBuzzScheduler(habits: self.habits, ble: self.ble, live: live, buzzLog: buzzLog)

        // Rest wake-window smart alarm (W9). Constructed here so AppRoot stays the composition root; the
        // coordinator owns the arm/advance/notification logic (unit-testable with a fake ble + clock).
        let alarm = SmartAlarmCoordinator(ble: self.ble, live: live, settings: SmartAlarmSettings())
        self.alarm = alarm
        // The alarm's notifier calls this sink from UNUserNotificationCenter completion handlers (a
        // background queue), but LiveState.append is @MainActor — hop to the main actor so the @Published
        // `log` array is never mutated off-main (would race the BLE writers). Harmless for the coordinator's
        // own main-actor log calls (just deferred).
        alarm.attachLog { [weak live] line in
            Task { @MainActor in live?.append(log: line) }
        }

        // Re-apply the paired strap's peripheral pin BEFORE CoreBluetooth's first poweredOn
        // callback (init runs synchronously ahead of it), so connectCore takes the TARGETED
        // retrievePeripherals path. Without the pin every relaunch falls back to a blind scan —
        // and a bonded strap that is connected elsewhere (or just not advertising) is never
        // found: dead live screen. This is the original registry.setPeripheralId loop, keyed to
        // UserDefaults because the registry store opens async after poweredOn.
        if let pid = UserDefaults.standard.string(forKey: Self.pairedPeripheralKey) {
            ble.setPreferredPeripheral(pid)
        }
        ble.$connectedPeripheralUUID
            .compactMap { $0 }
            .removeDuplicates()
            .sink { UserDefaults.standard.set($0, forKey: Self.pairedPeripheralKey) }
            .store(in: &cancellables)

        // Apply the "Continuous HRV capture" preference on launch (default ON, overnight-only ON): arm the
        // reconciler's continuous-capture want now so the dense R-R stream is held open the moment the strap
        // bonds, with no Live screen needed. setKeepRealtimeForData only sets intent + reconciles here — the
        // toggle reaches the strap once it's a WHOOP4 or a bonded 5/MG (the post-bond arm handles the rest),
        // and the #927 overnight-only window gate is re-derived at every arm site. Nothing to reach yet at
        // init, so this is the "remember the want" call the More toggle re-issues when either pref changes.
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)

        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log every other
        // subsystem writes to (PII-scrubbed by `live.append(log:)`), so a bug report ships proof of
        // what was computed per day. `live` is captured strongly — both live for the whole process.
        scores.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }

        // A journal tag write runs its own FORCED rescore (tags feed the health-monitor confounders),
        // which can move Charge / Rest — so route its completion through the ONE data-change seam
        // instead of the facade refreshing the repository alone: `.derivedRows` also republishes the
        // glance snapshot, which the write path never did. Wired here (not in the initializer at the
        // top) because `self` isn't usable until every stored property is assigned.
        journal.onChanged = { [weak self] in await self?.dataDidChange(.derivedRows) }

        // Same seam for the engine's ONE self-driven pass: the `#899-A` re-arm re-invokes
        // `analyzeRecent` detached, so nothing is awaiting its result to republish. It can write
        // detected workout rows, which live in `workoutRepo`'s cache — refreshing `repo` alone (what
        // the engine falls back to without this hook) would leave a detected bout invisible until the
        // next sync or 15-minute tick.
        scores.onWroteRows = { [weak self] in await self?.dataDidChange(.derivedRows) }

        // The realtime-HR ref-count stays HERE (it is composition wiring, shared with the Live tab's
        // appear/disappear); the recorder only says when it wants the stream. Weak so the root ↔ recorder
        // pair doesn't retain itself — same "self isn't usable until every stored property is assigned"
        // reason as the journal hook above.
        workout.armRealtime = { [weak self] in self?.startRealtimeHR() }
        workout.disarmRealtime = { [weak self] in self?.stopRealtimeHR() }

        // Smooth HR centrally so it's solid everywhere it's shown. Both sinks funnel through
        // `scheduleIngestHR`, which coalesces the pair of @Published fires the standard 0x2A37 handler emits
        // per packet (`rr` then `heartRate`) into ONE ingest per packet — ingestHR's full-window re-sort ran
        // 2×/packet otherwise. (P2)
        live.$heartRate.sink { [weak self] _ in self?.scheduleIngestHR() }.store(in: &cancellables)
        live.$rr.sink { [weak self] _ in self?.scheduleIngestHR() }.store(in: &cancellables)

        // P1: Charge / Effort for the Live Activity only move on a score refresh, so resolve them ONCE
        // when the repository republishes (days / restSeries change) and cache the pair — the ~1 Hz
        // bpm-driven syncLiveActivity then reads the cache instead of re-running the O(days)
        // WidgetDayResolver.fields on every tick. Uses the EMITTED values: both are @Published (fire in
        // `willSet`), so reading `repo.days` back inside the sink would see the pre-assignment stale value.
        Publishers.CombineLatest(repo.$days, repo.$restSeries)
            .sink { [weak self] days, rest in
                guard let self else { return }
                let f = WidgetDayResolver.fields(days: days, restSeries: rest, now: Date())
                self.liveActivityCache = (f.charge, f.effort)
            }
            .store(in: &cancellables)

        // ONE smoothed-HR sink for the three consumers of a fresh bpm. All three self-gate and none
        // reads the others' state, so their order here is free — a single subscription instead of three
        // parallel ones over the same ~1 Hz publisher:
        //  • Live Activity — drive the Lock-Screen / Dynamic-Island surface off the smoothed bpm (the
        //    connection flag drives it too, in the SEPARATE sink below, so a dropped link ends the
        //    activity even when HR stops arriving). The controller throttles its own ActivityKit pushes
        //    to ~2 s and only auto-starts when the user's toggle is on, so reacting per tick is cheap.
        //  • Smart alarm (W9) — feed the light-sleep watcher. `feedHR` self-gates on inside-window &&
        //    connected && worn, so an unconditional feed is cheap.
        //  • Habit wrist-buzz (008) — on each smoothed-HR tick (responsive while streaming), check
        //    whether a pinned habit's buzz window is open and fire ONE gentle buzz. Self-gates on
        //    connected + worn + in-window + not-yet-done + not-yet-buzzed-today; the 15-min steady-state
        //    tick is the backstop when HR isn't streaming (the buzz is a command write, independent of
        //    the HR stream). No notifications — the strap or nothing (008 decision).
        //
        // `$bpm` is @Published, which fires in `willSet` — so thread the EMITTED value into
        // `syncLiveActivity` / `feedHR` rather than reading `self.bpm` back inside the sink (which would
        // see the pre-assignment, stale value). `live.connected` is a DIFFERENT property (it did not emit
        // this event), so reading its current value here is correct.
        $bpm.sink { [weak self] newBpm in
            guard let self else { return }
            self.syncLiveActivity(bpm: newBpm, connected: self.live.connected)
            self.alarm.feedHR(newBpm)
            self.buzz.tick()
        }.store(in: &cancellables)
        // KEPT SEPARATE from the sink above: this one is the CONNECTION edge, and it must reset the
        // smoother before it syncs. `live.$connected` is @Published too, so thread the EMITTED flag into
        // `syncLiveActivity` rather than reading `live.connected` back — on the true→false disconnect
        // edge a read-back would still see `true` and UPDATE the activity (connected) instead of ENDING
        // it, freezing a dead "live" HR on the Lock Screen.
        live.$connected.sink { [weak self] connected in
            guard let self else { return }
            // #39/C1: a dropped link must deterministically blank the smoothed bpm. clearBiometrics()
            // nils `heartRate` THEN empties `rr` in sequence, so ingestHR's both-nil guard never sees
            // both true across the transition and the stale median lingers on every screen. Reset on
            // the connection edge instead, so `bpm` → nil the instant the strap drops.
            if !connected { self.resetSmoothing() }
            self.syncLiveActivity(bpm: self.bpm, connected: connected)
        }.store(in: &cancellables)

        // Smart-alarm wiring (W9), mirroring the existing sink/timer idioms. All paths funnel through the
        // coordinator, which self-gates on `settings.enabled`.
        //  • The strap reported it fired its firmware alarm → mirror to a notification + re-arm tomorrow.
        live.onSmartAlarmFired = { [weak self] in self?.alarm.onStrapFired() }
        //  • Re-arm on the genuine encrypted-bond edge: a window changed while the strap was away never
        //    reached it (the SET_ALARM_TIME write needs the encrypted channel). removeDuplicates() fires
        //    once per bond; `apply()` no-ops when the alarm is off.
        live.$encryptedBond.removeDuplicates().sink { [weak self] bond in
            if bond { self?.alarm.apply() }
        }.store(in: &cancellables)
        //  • The smoothed-HR feed into the light-sleep watcher rides the ONE `$bpm` sink above.

        // A completed backfill has just written strap history → refresh + rescore right away, so a
        // just-synced night's Charge / Effort / Rest doesn't wait for the 15-minute tick. `.debounce`
        // collapses the per-slice `lastSyncedAt` stamp storm a segmented offload produces (#755): it
        // fires ONCE, 2 s after the stream goes quiet, and always delivers the trailing edge.
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in await self?.refreshAfterCompletedBackfill() }
            }
            .store(in: &cancellables)

        // Sync-progress frontier (Live tab's "BEHIND" row): keep `live.persistedFrontierUnix` — the
        // newest persisted sample ts — fresh while an offload runs, WITHOUT touching the frozen
        // BLEManager/Backfiller. Two feeds:
        //  • The backfill-start edge seeds one read so the row has a number the instant it appears.
        //    Filter on the EMITTED flag (@Published fires in willSet — reading `live.backfilling`
        //    back here would see the stale pre-assignment value).
        live.$backfilling
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.refreshPersistedFrontier() }
            .store(in: &cancellables)
        //  • Each decoded chunk may have advanced the frontier — re-read, throttled to ≤1/s so a
        //    fast offload (many chunks/sec) can't turn the cheap indexed MAX into a query storm.
        //    `backfilling` is a DIFFERENT property (it did not emit this event), so reading its
        //    current value inside the sink is correct — same rule as `live.connected` in the `$bpm`
        //    sink above (and `charging` in `HabitBuzzScheduler`'s battery sink).
        live.$decodedChunksThisSession
            .dropFirst()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.live.backfilling else { return }
                self.refreshPersistedFrontier()
            }
            .store(in: &cancellables)
    }

    // MARK: - Launch side effects

    /// Every PROCESS-GLOBAL side effect of composing the app — notification delegate registration, the
    /// midnight re-arm timer, the periodic jobs, the crash-recovery rehydrate. Deliberately NOT in
    /// `init`: eight `#Preview` specimens build an `AppRoot()` to hand screens an environment object, and
    /// rendering one in Xcode must not register a delegate, arm a RunLoop timer, start the scoring loop,
    /// re-arm realtime HR, or write a `.wmbak`. `WhoopmaxxApp`'s launch `.task` calls this first, before
    /// the demo seed.
    ///
    /// What stays in `init` is everything that must be live before the first frame or the first
    /// CoreBluetooth `poweredOn` callback: object construction, all the Combine sinks, the
    /// paired-peripheral pin, and the continuous-HRV want.
    ///
    /// Idempotent — a second call is a no-op, so a re-entered `.task` can't double-arm anything.
    func start() {
        guard !started else { return }
        started = true

        // Resume a prior Health grant silently (no sheet) so a returning enabled user's exports pick up
        // where they left off.
        healthExport.refreshAuthIfPreviouslyGranted()

        // The buzz center's two LAUNCH hooks: the smart-alarm early-wake recording and the
        // process-global `AppModel.onInactivity` seam (see `HabitBuzzScheduler.attachLaunchHooks`).
        buzz.attachLaunchHooks(alarm: alarm)
        // Present the wake notification even while the app is foreground — iOS suppresses a trigger:nil
        // notification posted while active unless a delegate returns presentation options (the early-fire
        // wake fires while the app is alive, so without this the in-foreground wake alert is swallowed).
        WakeNotificationPresenter.register()

        // Re-arm once per day just after local midnight so a continuously-bonded strap keeps waking the
        // user (the firmware alarm is a single instant with no recurrence). iOS additionally re-arms on
        // foreground (WhoopmaxxApp), since it can't run timers while suspended.
        scheduleDailySmartAlarmRearm()

        // Daily autobackup catch-up (WmFolderBackup): if a backup folder is chosen and >= 24 h have
        // passed, write one .wmbak snapshot. Delayed 10 s so it stays off the launch-critical path
        // (first refresh + analyze land first); no-ops instantly when no folder is set. Shares the ONE
        // checkpoint closure with the manual `backupNow()` below.
        periodic.once(id: Job.backupCatchUp, after: 10, priority: .utility) { [weak self] in
            await WmFolderBackup.catchUpIfDue(
                checkpoint: { await self?.checkpointForBackup() ?? false },
                drain: { await self?.drainForBackup() ?? true })
        }

        // Close out `liveSession` rows a crash / link-drop left open (the repair the v22 migration
        // already assumes the app performs on next launch, and never did — see `LiveSessionRecovery`).
        // Delayed 12 s so it sits behind the backup catch-up and well off the launch-critical path; it
        // is a no-op on every normal launch, and nothing reads the table yet, so nothing waits on it.
        periodic.once(id: Job.liveSessionSweep, after: 12, priority: .utility) { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            await LiveSessionRecovery.sweepStaleOpenSessions(store: store, deviceId: self.repo.deviceId)
        }

        // Steady-state backstop: turn the strap's offloaded raw data into dashboard scores every 15
        // minutes (matches the offload cadence). `.utility` keeps the heavy pass off the UI's QoS, and
        // `force: false` lets the #836 fingerprint gate skip the rescore when nothing new landed —
        // every real update path (the sync debounce above, an import, launch) rescores with force: true.
        periodic.add(id: Job.analyzeTick, interval: 15 * 60, priority: .utility) { [weak self] in
            guard let self else { return }
            await self.dataDidChange(.idleTick)
            // Habit buzz backstop (008): the reliable driver when HR isn't streaming — the buzz is a
            // command write, not HR-dependent, so a 15-min granularity still catches an open window.
            self.buzz.tick()
        }

        // Age out decoded 1 Hz samples past `SampleRetention.retentionDays` — the only bound on a store
        // measured to grow 24.4 MB per calendar day forever (419.7 MB of a 422 MB file after 17 days).
        // Six-hourly because the policy is day-granular: anything more frequent re-checks the same days.
        //
        // ORDERING MATTERS. The prune runs FIRST and the rescore SECOND. `ScoreEngine` stores a whole-history
        // "COUNT(*):MAX(ts)" HR fingerprint as its idle-tick watermark, so removing rows invalidates it;
        // rescoring immediately AFTER the prune rewrites the watermark against the post-prune database, which
        // means the next `.idleTick` can still short-circuit. Scoring first (or leaving the rescore to the
        // next 15-minute tick) would instead burn one full 21-day pass per prune. The rescore is skipped
        // entirely when nothing was deleted, so the steady-state cost is one bool.
        periodic.add(id: Job.retentionSweep, interval: 6 * 3_600, priority: .utility) { [weak self] in
            await self?.sweepRetentionIfDue()
        }

        #if DEBUG
        // `--demo-active-workout` (sim has no BLE): seed a live link + HR so the reused HR stream fills
        // too. The synthetic session itself is built by `WorkoutSessionController.start()` below, which
        // owns `ActiveWorkout`.
        if DebugFlags.demoActiveWorkout {
            live.connected = true
            live.heartRate = 150
        }
        #endif

        // The recorder's launch hook: the #529 crash-recovery rehydrate, plus the DEBUG demo session.
        workout.start()
    }

    /// Re-arm the single-instant firmware alarm once per day (just after local midnight) so a
    /// continuously-bonded strap keeps waking the user past the first fire. `alarm.apply()` self-gates on
    /// the alarm being enabled, so this is a no-op when it's off. (Ported from the original
    /// AppModel.scheduleDailySmartAlarmRearm.)
    private func scheduleDailySmartAlarmRearm() {
        smartAlarmRearmTimer?.invalidate()
        let cal = Calendar.current
        guard let firstFire = cal.nextDate(after: Date(),
                                           matching: DateComponents(hour: 0, minute: 1, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: firstFire, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.alarm.apply() }
        }
        RunLoop.main.add(timer, forMode: .common)
        smartAlarmRearmTimer = timer
    }

    // MARK: - Realtime HR (ref-counted, the original AppModel port)

    /// A screen that shows live HR entered — first wanter arms the strap's realtime stream.
    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            ble.startRealtime()
            kickRealtimeWatchdog()
        }
        realtimeWanters += 1
    }

    /// That screen left — last wanter out stops the stream (saves strap battery).
    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 {
            realtimeWatchdog?.cancel()
            ble.stopRealtime()
        }
    }

    /// Re-arm after a (re)connect while a live screen is open: the WHOOP 4 connect handshake
    /// resets the realtime stream OFF, so the standing want must be re-asserted.
    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        ble.startRealtime()
        kickRealtimeWatchdog()
    }

    /// Fast time-to-first-reading: the arm commands are fire-and-forget, and a write that lands
    /// mid-handshake is silently lost — BLEManager's own re-arm is the 30 s keep-alive tick, which
    /// reads as "live screen takes forever to start". While a live screen wants the stream and the
    /// strap is bonded but no HR has arrived, re-send the arm every 2 s (bounded; disconnect blanks
    /// `heartRate`, so a nil here really means "no live flow yet").
    private func kickRealtimeWatchdog() {
        realtimeWatchdog?.cancel()
        realtimeWatchdog = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.realtimeWanters > 0, self.live.heartRate == nil else { return }
                guard self.live.bonded else { continue }   // keep waiting through a slow connect
                self.live.append(log: "Realtime: bonded but no HR yet — re-arming stream")
                self.ble.startRealtime()
            }
        }
    }

    /// Re-read the store's data frontier — MAX(ts) over the persisted HR samples for the strap, a
    /// cheap indexed query (`Repository.latestHRSampleTs`) — and publish it into
    /// `live.persistedFrontierUnix` for the Live tab's sync-progress row. The read suspends off the main
    /// actor inside the repository facade; the publish lands back on @MainActor.
    /// An empty-or-failed read keeps the frontier where it was (guard-return; it starts nil, which
    /// honestly reads "first sync"), so a transient DB error can't flash a known frontier away.
    ///
    /// Internal rather than private for ONE outside caller: `WhoopmaxxApp`'s `scenePhase == .active`
    /// foreground hook. The two sinks that drive it above are BOTH conditioned on an offload already
    /// running, so without that hook the frontier is only ever read while data is arriving — a process
    /// that never syncs never reads it at all (it stays nil, which reads as "first sync" for a strap
    /// that has years of history), and one that synced an hour ago carries that number unchanged for the
    /// rest of its lifetime. Anything reporting how far behind the store is would then measure its gap
    /// from a stale frontier, which is precisely the staleness it exists to report. Returning to the
    /// foreground is the other honest moment to re-read.
    func refreshPersistedFrontier() {
        Task { [weak self, repo] in
            // Banked UNCONDITIONALLY, nil included. An empty store is a real answer — "we looked, and
            // nothing has ever landed" — and returning early on it would leave `frontierLoaded` false
            // forever, so every frontier-derived surface would stay silent on precisely the install
            // that most needs to say "paired, but no data has arrived yet".
            let ts = await repo.latestHRSampleTs()
            self?.live.setPersistedFrontier(ts.map { TimeInterval($0) })
        }
    }

    // MARK: - Backup

    /// Write ONE `.wmbak` snapshot into the chosen backup folder now, returning whether it landed. THE
    /// backup entry point: the More screen's "Back up now" row and the launch catch-up job above both go
    /// through this object, so the WAL-checkpoint step below exists once instead of being re-spelled at
    /// each call site (it was duplicated verbatim between here and `MoreScreen`). Returns false when no
    /// folder is chosen, the store won't open, or the write fails.
    func backupNow() async -> Bool {
        await WmFolderBackup.backupNow(checkpoint: { await self.checkpointForBackup() },
                                       drain: { await self.drainForBackup() })
    }

    /// Push the Collector's in-RAM sample buffers into the store BEFORE the WAL checkpoint below — the
    /// checkpoint only moves what SQLite already holds, so without this a snapshot silently misses up
    /// to a flush window of just-recorded HR/R-R. False when a write failed and rows are still
    /// buffered, which aborts the snapshot rather than shipping it short.
    private func drainForBackup() async -> Bool {
        await ble.drainForBackup()
    }

    /// Checkpoint the WAL so the sqlite file the backup COPIES carries every committed page — a snapshot
    /// taken without this misses everything still sitting in `-wal`. False when the store can't be opened
    /// or frames remain outside the main file, which aborts the snapshot rather than writing a short one.
    ///
    /// Uses `checkpointWALComplete()`, not `checkpointWAL()`: the latter only reports that the PRAGMA
    /// didn't throw, and SQLite does not throw on a blocked checkpoint. Two `DatabasePool`s share this
    /// file (Repository + BLEManager), so a reader snapshot at checkpoint time is routine — the old
    /// predicate answered "WAL is empty" while it wasn't, and the archive shipped short in silence.
    /// Retried a few times because contention here is transient (a refresh/analyze/backfill read finishing).
    private func checkpointForBackup() async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        for attempt in 0..<3 {
            if (try? await store.checkpointWALComplete()) == true { return true }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return false
    }

    // MARK: - Data-change seam

    /// WHAT changed, so the one seam below runs exactly the steps that kind of change needs. The three
    /// scopes are the only refresh→rescore→publish→export sequences in the app; adding a fourth step set
    /// at a call site is what let six sites drift apart.
    enum ChangeScope {
        /// New RAW strap history landed — a completed backfill, an import, or launch. The widest pass:
        /// re-read the 120-day window, FORCE a rescore past the #836 idle gate, then publish + export.
        case rawHistory
        /// DERIVED rows moved under the caches without new raw history (a journal tag write, which runs
        /// its own forced rescore first). Re-read the dashboard and republish the glance — no rescore.
        case derivedRows
        /// The 15-minute steady-state backstop: a NON-forced rescore (the #836 fingerprint gate
        /// short-circuits it when the raw stream is unchanged), then publish + export.
        case idleTick
    }

    /// THE one place the refresh → rescore → publish → export sequence lives. Every caller says WHAT
    /// changed and this decides which steps run, so the post-sync path, the launch path, the idle tick
    /// and the journal write can no longer disagree about the order or skip a step.
    ///
    /// `analyzeRecent` returns whether it actually wrote rows; only then is a second `refreshCaches()`
    /// worth its cost (both are diff-guarded anyway, so a no-op pass publishes nothing). The FIRST refresh
    /// on `.rawHistory` is the one that puts the just-synced data on screen ahead of the multi-second
    /// analyze — keep it.
    func dataDidChange(_ scope: ChangeScope) async {
        // After a restore this process reads and writes a deleted inode. Every branch below either
        // consumes a heal one-shot, writes derived rows, publishes a widget snapshot, or pushes to Apple
        // Health — all of it against pre-restore data. Refusing here is what stops Gate 9's re-armed
        // heals being spent on the orphaned store before the relaunch can apply them.
        guard !relaunchRequired else { return }
        switch scope {
        case .rawHistory:
            // One-shot, BEFORE the caches are read: clear the fabricated 85.0 % SpO2 rows the pre-fix
            // estimator persisted (see `Spo2Heal`). It has to run ahead of the refresh or the dashboard
            // flashes a severe-hypoxemia number, and ahead of the Health push below or that number is
            // re-written to Apple Health; and it has to be its own sweep because the rescore that
            // follows only reaches the trailing 21 days. Self-gated on a UserDefaults flag, so every
            // launch after the first is one bool read.
            //
            // `.rawHistory` is also the post-import seam — an import returns `.needsRelaunch` and the
            // next launch lands here — but the SEAM being right was never the whole story, and reading
            // it as coverage is what let this ship. The heals below gate on UserDefaults flags that a
            // restore does not touch, so on an install that had ALREADY healed they short-circuited on
            // their first line and the restored rows kept the fabricated 85.0 % SpO2 (measured: all 17
            // on the real backup, for the `.wmbak` container). The coverage comes
            // from the RESTORE side re-arming those flags — `BackupImport` Gate 9 / `RestoreHealReset` —
            // which is what makes this seam do what the sentence above claims.
            if let store = await repo.storeHandle() {
                await Spo2Heal.runIfNeeded(store: store, deviceId: repo.deviceId)
                // One-shot, on the SAME seam and for the same reason: the round-3 analytics fixes
                // (splice-safe + gated nightly HRV, cleaned per-epoch RMSSD, `solMin` retired) rewrite
                // values that are already persisted, and the ordinary rescore below only reaches the
                // trailing 21 days. Run ONE widened forced pass out to the raw-retention horizon so every
                // day that is recomputable at all is genuinely re-derived, then let the heal mop up the
                // days it could not reach. Self-gated on a UserDefaults flag, so every launch after the
                // first is one bool read. See `SleepHrvHeal` for why old rows are NOT blanked.
                if SleepHrvHeal.isPending {
                    _ = await scores.analyzeRecent(maxDays: SleepHrvHeal.rescoreDays, force: true)
                    await SleepHrvHeal.finish(store: store, deviceId: repo.deviceId)
                }
            }
            await refreshCaches(days: 120)
            if await scores.analyzeRecent(force: true) { await refreshCaches() }
            // A just-synced / just-imported night's Charge / Effort / Rest just landed.
            publishWidget()
            // Push the freshly-merged vitals + sleep stages to Apple Health (no-op unless enabled + granted).
            await healthExport.exportRecentIfEnabled()
        case .derivedRows:
            await refreshCaches()
            publishWidget()
        case .idleTick:
            if await scores.analyzeRecent(force: false) { await refreshCaches() }
            // The steady-state tick also refreshes the home widget (battery / bpm move while
            // backgrounded, and a fresh score may have landed).
            publishWidget()
            // …and re-reads the store frontier. Live HR is persisted continuously while connected
            // (`Collector.ingestStandardHR`), but the published frontier only moved during an offload
            // — so a reader dividing `now` by that snapshot watched a healthy pipeline drift further
            // and further "behind" between syncs. One indexed MAX(ts) per tick keeps the number the
            // sync status is derived from no more than one tick old.
            refreshPersistedFrontier()
            // Steady-state Health push: a fresh score / vital may have landed. No-op when disabled.
            await healthExport.exportRecentIfEnabled()
        }
    }

    /// Re-read BOTH read caches. The workout cache lives on its own object with its own diff + its own
    /// `refreshSeq` (workouts left `Repository`'s diff, so `repo.refreshSeq` no longer moves for a
    /// workout-only change) — so every scope that refreshes the dashboard must refresh workouts too, or a
    /// newly detected / imported bout would never reach the list. Both are diff-guarded: an unchanged
    /// pass publishes nothing.
    private func refreshCaches(days nDays: Int? = nil) async {
        if let nDays { await repo.refresh(days: nDays) } else { await repo.refresh() }
        await workoutRepo.refresh()
    }

    /// Refresh the dashboard cache and rescore after a completed strap sync (the debounced
    /// `lastSyncedAt` path above). analyzeRecent no-ops (re-arming) if a pass is already running.
    private func refreshAfterCompletedBackfill() async {
        live.append(log: "Backfill: refreshing dashboard cache from completed sync")
        await dataDidChange(.rawHistory)
    }

    /// Re-score after the user edits their profile.
    ///
    /// Age / sex / weight / height / max-HR feed `hrMax` (the HRR denominator behind every Effort score
    /// and zone boundary) and the Keytel calorie estimate, and `ScoreEngine` derives all of those from the
    /// stored raw samples on each pass — so a forced pass retroactively corrects every day whose signal is
    /// still on the phone. Without it the corrected profile would only reach TODAY, leaving the user's
    /// existing history scored against a stranger's body.
    func rescoreAfterProfileChange() {
        Task { await dataDidChange(.rawHistory) }
    }

    // MARK: - Retention

    /// Wall-clock instant of the last completed retention sweep. Persisted because the schedule has to
    /// survive process death — that is the whole point of the foreground catch-up below.
    private static let lastRetentionSweepKey = "wm.maintenance.retentionSweep.lastRunAt"

    /// How stale the last sweep must be before another one is worth doing. Matches the interval of
    /// `Job.retentionSweep`, so the timer and the foreground catch-up can share one due-check and never
    /// double-sweep: whichever path arrives first does the work and the other finds it not due.
    private static let retentionSweepInterval: TimeInterval = 6 * 3_600

    /// True while a sweep is between its due-check and its stamp. See `sweepRetentionIfDue`.
    private var retentionSweepInFlight = false

    /// Run the decoded-sample retention sweep if it has not run in `retentionSweepInterval`.
    ///
    /// WHY A DUE-GATE AND A FOREGROUND CALLER. `Job.retentionSweep` was the ONLY trigger, and
    /// `PeriodicWork.add` deliberately fires its first pass one full interval after registration — so a
    /// process that never lives six uninterrupted hours never swept even once. That is the normal iPhone
    /// case: iOS suspends and recycles the app, and `bluetooth-central` buys BLE wake-ups, not scheduling.
    /// `BLEManager.pruneRaw()` documents itself as the background-entry backstop but has NO callers, and
    /// `WhoopmaxxApp`'s scenePhase hook only handles `.active`, so nothing covered the gap. The result was
    /// that the app's one bound on a store measured to grow ~24 MB/day effectively never ran.
    ///
    /// Foreground is the right catch-up point rather than `.background`: `.active` is guaranteed on every
    /// launch (so this doubles as the launch-time pass the interval job intentionally skips), while a
    /// `.background` transition grants only seconds — too little for a sweep bounded at `maxDaysPerSweep`
    /// days of DELETEs. The persisted stamp is what makes calling it on every foreground free.
    func sweepRetentionIfDue(defaults: UserDefaults = .standard) async {
        // RE-ENTRANCY. @MainActor gives mutual exclusion between suspension points, not across them — the
        // due-check and the stamp straddle an `await`, so the timer job and a foreground transition
        // arriving together would both pass the guard and run two sweeps against one SQLite file. They
        // would not corrupt anything (each DELETE is its own statement and the second finds the rows
        // gone), but they would contend for the write lock and double the launch cost. One flag, set and
        // cleared on the main actor, closes the window.
        guard !retentionSweepInFlight else { return }

        let now = Date().timeIntervalSince1970
        let last = defaults.double(forKey: Self.lastRetentionSweepKey)   // 0 when never run
        // A stamp in the FUTURE is impossible and must be repaired, not merely tolerated: the device clock
        // moved forward, got stamped, and moved back. `now - last` is then negative and only grows more so,
        // which would disable retention permanently. CLAMP rather than just treating it as due — a
        // due-disjunct would leave the impossible value in place until a sweep actually SUCCEEDS, so a
        // store that also fails its sweep stays wedged. Clamping to one full interval ago repairs the stamp
        // immediately and keeps the sweep due until one succeeds. (Clock changes are routine in this app's
        // domain — the smart alarm and habit windows are wall-clock anchored, and users travel.)
        if last > now {
            defaults.set(now - Self.retentionSweepInterval, forKey: Self.lastRetentionSweepKey)
        } else if now - last < Self.retentionSweepInterval {
            return
        }
        guard let path = try? StorePaths.defaultDatabasePath() else { return }

        retentionSweepInFlight = true
        defer { retentionSweepInFlight = false }

        let deviceId = repo.deviceId
        let outcome = await Task.detached(priority: .utility) {
            SampleRetention.sweep(databaseAt: path, deviceId: deviceId)
        }.value
        // Stamp only on a sweep that reached a verdict on BOTH halves. A sweep that stopped mid-way (a
        // failed DELETE) must be retried at the next opportunity rather than sitting out a full interval.
        // A sweep that found NO DATABASE is likewise not a sweep: on a fresh install the first `.active`
        // fires before `Repository` has created the store, and recording that as a success sat the real
        // first sweep out for a full interval on the strength of having done nothing.
        let ranAgainstAStore = FileManager.default.fileExists(atPath: path)
        if ranAgainstAStore && outcome.failure == nil && outcome.chatterFailure == nil {
            defaults.set(now, forKey: Self.lastRetentionSweepKey)
        }
        if outcome.rowsDeleted > 0 { await dataDidChange(.idleTick) }
    }

    // MARK: - Widget + Live Activity

    /// Publish the glance snapshot to the App Group and refresh WidgetKit. Called from exactly two
    /// places: every `dataDidChange` scope above (launch / post-sync / journal write / 15-min tick), and
    /// `WhoopmaxxApp`'s scenePhase `.active` hook. Still a deliberately SMALL budget — never off the
    /// live-HR stream (see `WidgetSnapshot.publish`).
    func publishWidget() { WidgetSnapshot.publish(from: self) }

    /// Feed the Live Activity the current live values (auto path). BOTH `bpm` and `connected` are passed
    /// in — the emitting sink's fresh value — rather than read back off `self.bpm` / `live.connected`,
    /// which would be the stale pre-assignment value inside a @Published `willSet`. Threading
    /// `connected` is what lets a true→false disconnect edge actually END the activity. Charge / Effort
    /// come from `liveActivityCache` (P1), refreshed only on a score republish — not per bpm tick.
    private func syncLiveActivity(bpm: Int?, connected: Bool) {
        let s = liveActivityCache
        liveActivity.sync(bpm: bpm ?? live.heartRate, charge: s.charge, effort: s.effort,
                          connected: connected)
    }

    /// The Live tab's "Pin to Lock Screen" button — force-start the Live Activity regardless of the
    /// auto-start toggle (still needs the system switch on, a live link, and a bpm).
    func pinLiveActivity() {
        let s = liveActivityCache
        liveActivity.startManually(bpm: bpm ?? live.heartRate, charge: s.charge, effort: s.effort,
                                   connected: live.connected)
    }

    /// The Live tab's "Stop" — end the pinned Live Activity now.
    func stopLiveActivity() { liveActivity.stop() }

    // MARK: - Pairing

    /// More → Strap → "Forget device": release the strap fully so it can enter pairing mode elsewhere.
    /// `BLEManager.forgetDevice` stops auto-reconnect, drops the link and clears targeting — but it
    /// clears only the IN-MEMORY pin, so the persisted one has to go too or the next launch re-seeds it
    /// from `pairedPeripheralKey` (the `setPreferredPeripheral` restore in `init`) and resurrects the
    /// strap the user just released. Both halves live here, beside the key's only writer.
    func forgetStrap() {
        ble.forgetDevice(nil)
        UserDefaults.standard.removeObject(forKey: Self.pairedPeripheralKey)
    }

    // MARK: - Health export

    /// The More screen's "Write to Apple Health" toggle-enable: request write-only permission and run
    /// one immediate export. Disabling the toggle is one-way (no teardown — prior samples stay in Health).
    func enableHealthExport() async { await healthExport.requestAuthorizationAndExport() }

    // MARK: - Continuous HRV capture

    /// Re-apply the "Continuous HRV capture" preference to the BLE reconciler after either the base toggle
    /// OR the "overnight only" refinement changes in More → Preferences. Reads the CURRENT base pref (both
    /// toggles persist via `@AppStorage` before this runs) and hands it to `setKeepRealtimeForData`, which
    /// reconciles the realtime want. #927 idiom: when only the overnight-only pref flipped, we still call
    /// this with the UNCHANGED base value purely so the reconciler re-runs with the fresh window gate (the
    /// gate is re-derived from `continuousHrvOvernightOnlyEnabled` at arm time).
    func applyContinuousHrvPreference() {
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
    }

    /// Coalesce the paired per-packet `$heartRate` + `$rr` emits into a single `ingestHR`. The first sink of
    /// a runloop tick schedules the ingest on the main queue and gates the second; the scheduled block clears
    /// the gate and reads the FINAL live values (both fully assigned by then), preserving the rr-fallback (HR
    /// from 60000/rr when `heartRate` is absent). (P2)
    private func scheduleIngestHR() {
        guard !hrIngestScheduled else { return }
        hrIngestScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hrIngestScheduled = false
            self.ingestHR()
        }
    }

    /// Fold the packet's live values into the smoother and republish what changed. The clamp, the
    /// 60000/R-R fallback, both window bounds and the #39 blank-on-disconnect rule all live in
    /// `HRSmoother`; what stays here is the PUBLISHING policy.
    private func ingestHR() {
        let smoothed = smoother.ingest(heartRate: live.heartRate, rr: live.rr)
        // Only republish when the SMOOTHED value actually changes — ingestHR fires ~1–3 Hz but the
        // median is stable across most of them; an unconditional assign re-renders every bpm observer.
        // (A rejected sample returns the unchanged median, so it publishes nothing.)
        if bpm != smoothed { bpm = smoothed }
        // W7: feed the smoothed sample into an in-flight manual workout (no-op when none is running).
        if let s = smoothed { workout.ingest(bpm: s) }
    }

    private func resetSmoothing() {
        smoother.reset()
        if bpm != nil { bpm = nil }
    }

    /// Median of the live HR window over just the trailing `seconds` — the live tab's optional
    /// short-smooth display (the published `bpm` keeps its full window for calmer surfaces).
    func smoothedBpm(over seconds: TimeInterval) -> Int? { smoother.smoothedBpm(over: seconds) }
}
