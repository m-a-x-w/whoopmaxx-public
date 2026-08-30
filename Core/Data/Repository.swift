import Foundation
import Combine
import StrapProtocol
import StrapStore
import StrapAnalytics

/// Slim read cache over the on-device store — the ONLY thing the UI observes for daily history.
///
/// Slimmed rewrite of the original Repository (which had grown Apple-Health / Xiaomi / workout / journal /
/// hydration lanes): whoopmaxx W1 keeps just the core loop — merged daily metrics, merged sleep
/// sessions, and the `sleep_performance` (Rest) series — read as the union of the imported strap lane
/// (`deviceId`, what a WHOOP-export import / backup restore writes) and the computed lane
/// (`computedDeviceId`, what ScoreEngine writes). Merge rule carried from the original: IMPORTED values win
/// field-by-field per day; computed rows fill only the fields the import lacks (recovery / strain /
/// skin-temp deviation / activity totals on a raw-only export) and whole days no import covers.
@MainActor
final class Repository: ObservableObject {
    /// Canonical strap id — every subsystem (BLE writes, imports, engine reads) shares it.
    let deviceId = "my-whoop"
    /// The sibling id ScoreEngine persists computed scores under.
    var computedDeviceId: String { deviceId + "-computed" }

    /// Merged daily rows, oldest → newest (imported-over-computed, per `mergeDaily`).
    @Published private(set) var days: [DailyMetric] = []
    /// The day key `days` was READ FROM — the trailing window's own lower bound, not the oldest row in
    /// it. nil until the first refresh lands.
    ///
    /// The difference is the whole point: when `days.first` is NEWER than this, nothing was clipped and
    /// the record genuinely starts there; when it sits at or below this, the cache is saturated and the
    /// user's history may run further back than anything published here. Any window that reaches the
    /// oldest cached day has to know which of those it hit, or it will describe the CACHE's edge as a
    /// fact about the user (see `SleepRegularity.analyze`'s `recordFloor`).
    @Published private(set) var daysWindowFloor: String?
    /// Merged sleep sessions, sorted by start (imported wins per end-day; every session kept, #715).
    @Published private(set) var sleeps: [CachedSleepSession] = []
    /// Rest score (the `sleep_performance` series, 0–100) per day key — imported wins, computed fills.
    @Published private(set) var restSeries: [String: Double] = [:]
    /// Health monitor (007 F2): the `strain_score` composite (0–100) per day key. Computed lane only —
    /// ScoreEngine is the sole writer of these keys, so there is no imported lane to merge.
    @Published private(set) var strainScore: [String: Double] = [:]
    /// Health monitor (007 F2): the decoded `strain_level` per day key. An absent key means the day was
    /// never evaluated (vs a stored `.quiet` row: evaluated, nothing notable).
    @Published private(set) var strainLevel: [String: StrainLevel] = [:]
    /// Health monitor (007 F2): the persisted `strain_fired` per-signal bitmask per day key (see
    /// `StrainFiredMask`) — which vitals cleared the firing bar the night ScoreEngine scored it.
    /// The detail screen's "Flagged" markers read THIS so they can never disagree with the level.
    @Published private(set) var strainFired: [String: Int] = [:]
    /// Nap credit (007 F3): credited nap minutes (the `nap_min` series) per day key. Computed lane
    /// only — ScoreEngine is the sole writer. Absent key = no naps credited that day (ScoreEngine
    /// writes an explicit 0 for a scored zero-nap day so stale rows reconcile; the zeros are
    /// filtered HERE on read). ADDITIVE to sleep need/debt; never folded into `totalSleepMin` (#525).
    @Published private(set) var napSeries: [String: Double] = [:]
    /// Sleep Regularity Index (011 W2.1) per day key (the `sleep_regularity` series): the trailing
    /// 14-night 24 h-lag agreement between consecutive days' sleep/wake timing. Computed lane only —
    /// ScoreEngine is the sole writer, and it writes a point ONLY for a day whose window cleared
    /// `SleepRegularity.minimumPairs`, so an absent key means "not enough comparable nights", never 0
    /// (which on this scale would read as coin-flip irregularity rather than as no reading).
    /// READ-ONLY: no score consumes it (011 decision 2).
    @Published private(set) var regularitySeries: [String: Double] = [:]
    /// Unmeasured staged minutes (030 Track A) per day key — the `sleep_unmeasured_min` series: minutes
    /// inside the day's sleep sessions that the hypnogram stages as ASLEEP but the strap banked no heart
    /// rate for, with off-wrist time already subtracted out. Computed lane only; ScoreEngine is the sole
    /// writer, and it flags the same sessions with `CachedSleepSession.lowConfidence`.
    ///
    /// Absent key = nothing to report — either the day was scanned and clean, or it was never scanned at
    /// all (no sleep session, or an HR read that hit its row limit and so could not be graded honestly).
    /// ScoreEngine writes an EXPLICIT 0 for a scanned-clean day so a stale non-zero can never outlive the
    /// flag that justified it, and the zeros are filtered HERE on read exactly as `napSeries` filters its
    /// own — a rendered "0" reads as a measured "no gap tonight", which is a claim, and it would be
    /// indistinguishable from the reconciling rows. The distinction the filter collapses is the absence
    /// of a defect, so nothing a surface could say is lost.
    ///
    /// ADDITIVE/READ-ONLY: no score consumes it. It never rescales `totalSleepMin` or any stage total —
    /// subtracting these minutes would replace one unmeasured number with another, smaller invented one.
    @Published private(set) var unmeasuredSeries: [String: Double] = [:]
    /// Waking-window capture coverage in [0,1] per day key (the `effort_coverage` series). Computed lane
    /// only — ScoreEngine is the sole writer, and it writes a point ONLY for a day it actually graded, so
    /// an absent key means "not graded", never 0%.
    ///
    /// Effort is an ACCUMULATED score: `StrainScorer.edwardsTRIMP` is a plain sum with no coverage or rate
    /// term, and `trimpToStrain` log-compresses hard, so a half-captured day looks exactly like a genuine
    /// rest day. On the real 2026-07-15 (66.8% coverage, a 12.5 h hole) Effort scored 27.01 — inside the
    /// 26.31–64.18 band of the 17 full days. This series is what lets the UI mark it and what keeps such a
    /// day out of the Effort baseline; it never rescales `strain` itself.
    @Published private(set) var effortCoverage: [String: Double] = [:]
    /// The user's learned habitual midsleep (local time-of-day seconds), computed over the merged sleep
    /// history the SAME way `ScoreEngine.computeHabitualMidsleep` does (longest-block-per-day circular mean,
    /// `SleepGrouping.habitualMidsleepSec`) — nil under 14 nights (cold-start). Published so the Rest
    /// screen's nap ROW split (`NapCredit.naps`) uses the SAME main-night pick that produced the credited
    /// `napSeries` minutes; without it the rows fall back to the cold-start overnight band and can disagree
    /// with the credit for a day-sleeper / shift worker — crediting nap minutes the screen never renders.
    @Published private(set) var habitualMidsleepSec: Int?
    /// True once the first refresh has published (screens can tell "empty" from "not loaded yet").
    @Published private(set) var loaded = false
    /// Bumped once per refresh THAT ACTUALLY CHANGED something (diff-guarded), so heavy screens can
    /// reload exactly when there is a real change and never for a byte-identical refresh.
    @Published private(set) var refreshSeq = 0
    /// Cheap whole-history HR change stamp — `(count, maxTs)` from an indexed COUNT/MAX with no rows
    /// materialized (P5), republished each refresh only when it moves. Heavy RAW-HR consumers (the
    /// AutoWorkoutDetector) key their reloads on THIS instead of `refreshSeq`, so the detector re-runs only
    /// when raw HR actually grew — not on every daily-score / sleep change. Same fingerprint ScoreEngine's
    /// #836 idle gate uses.
    @Published private(set) var hrWatermark = HRWatermark(count: 0, maxTs: 0)

    /// The value of `hrWatermark` — a raw-HR-stream change stamp (see above).
    struct HRWatermark: Equatable { let count: Int; let maxTs: Int }

    private var store: StrapStore?
    /// In-flight open, so concurrent first-callers share ONE open instead of each opening their own.
    /// One logical flight (`storeOpenKey`) — there is exactly one store.
    private let storeOpen = SingleFlight<String, StrapStore?>()
    private static let storeOpenKey = "store"
    /// Generation stamp so an older refresh that finished late can't clobber a newer one's caches.
    private var refreshGen = Generation()

    // MARK: - Store handle

    /// The shared store handle (single lazy opener at `StorePaths.defaultDatabasePath()`).
    ///
    /// SANCTIONED CALLERS, by convention only — App/, Core/ and Shared/ compile into ONE module, so there
    /// is no access-control seam to enforce this with: (a) the Core facades layered over this store
    /// (`WorkoutRepository`, `JournalStore`, `HabitsStore`, `ScoreEngine`, `StrapHealthModel`,
    /// `BodyClockEngine`, `WorkoutSessionController`); (b) maintenance one-liners that only checkpoint or
    /// seed (`AppRoot.backupNow`, `WhoopmaxxApp`'s demo seed); (c) screens that hand the handle STRAIGHT to
    /// a nonisolated loader without reading rows themselves (`RestScreen` → `ArousalForensicsLoader`
    /// and → `PostureLoader`, `SignalLabScreen` / `SignalLabHRVView` → `ScopeHistoryLoader`,
    /// `NightMovementScreen` →
    /// `NightTape.load`). A View that reads rows off this handle itself is NOT on the list — add a facade
    /// here, or a loader beside the screen.
    func storeHandle() async -> StrapStore? { await ensureStore() }

    /// Test seam: adopt an ALREADY-OPEN store so `refresh()` reads a throwaway fixture DB instead of the
    /// fixed default path. Nothing in the app calls this — `ensureStore` stays the only production opener.
    /// Needed because the unit bundle is HOSTED: the live app is running its own engine against the
    /// default store, so a test that drove `refresh()` through it would race real writes.
    func adoptStore(_ opened: StrapStore) { store = opened }

    private func ensureStore() async -> StrapStore? {
        if let store { return store }
        // SINGLE-FLIGHT: several callers ask for the store at once on launch; they all join one
        // in-flight open instead of racing `StrapStore(path:)`. The handle is cached from INSIDE the
        // flight (before its slot frees) so a caller arriving right as it completes sees `store` rather
        // than starting a second open.
        return await storeOpen.run(Self.storeOpenKey) { [weak self, deviceId] () -> StrapStore? in
            let path: String
            do {
                path = try StorePaths.defaultDatabasePath()
            } catch {
                NSLog("StrapStore: ensureStore FAILED resolving DB path: \(error)")
                return nil
            }
            // Run-once file-level housekeeping, BEFORE the store handle exists so the purge isn't
            // competing with our own connection for the writer lock (a `VACUUM` needs exclusive access,
            // which is precisely why this is not fire-and-forget alongside the open). Detached because it
            // is blocking SQLite work and `ensureStore` runs on the main actor.
            //
            // AWAITED deliberately: on the ONE launch that finds a store banked by a pre-gate build this
            // delays the first read by the DELETE + VACUUM (seconds, on the order of the file's size) in
            // exchange for ~70 MB back. Every launch after that — and every fresh install — short-circuits
            // on the run-once flag before opening anything. See `StoreMaintenance`.
            // The freelist reclaim rides the SAME detached hop, immediately after the purge, so the two
            // file-exclusive jobs share one connection window and the purge's freed pages are counted by
            // the reclaim's gate. It self-gates on `freelist_count`, so on a normal install (and on every
            // launch once the file has been rewritten) it is two PRAGMA reads and returns. It exists for
            // the ONE launch after `SampleRetention` first ages out a large backlog: SQLite would otherwise
            // hold that space as freelist forever. See `StoreMaintenance.reclaimFreelistIfNeeded`.
            _ = await Task.detached(priority: .utility) {
                StoreMaintenance.purgeDegenerateRespSamplesIfNeeded(databaseAt: path)
                StoreMaintenance.reclaimFreelistIfNeeded(databaseAt: path)
            }.value
            let s: StrapStore
            do {
                s = try await StrapStore(path: path)
            } catch {
                let ns = error as NSError
                NSLog("StrapStore: ensureStore FAILED opening store: \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
                return nil
            }
            try? await s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
            self?.store = s
            return s
        }
    }

    // MARK: - Single-flight reads

    /// Coalescer behind `load`. `AnyHashable` / `Any?` because the key and the result type vary per call
    /// site; `load` re-types the result on the way out.
    private let reads = SingleFlight<AnyHashable, Any?>()

    /// Single-flight READ seam: run `read` against the shared store handle, or JOIN the read already in
    /// flight under the same `key`. nil only when the store can't be opened.
    ///
    /// The point is `.task(id:)`: SwiftUI restarts the body on every id bump WITHOUT waiting for the
    /// prior one to finish, so a screen keyed to `refreshSeq` can have two identical multi-second reads
    /// in flight at once, racing to publish (which is why each such screen also carries its own
    /// stale-drop stamp). Routed through here, the restart joins the in-flight read instead of racing it.
    ///
    /// `key` must identify the read AND its inputs (e.g. an enum case carrying the window bounds) — two
    /// different reads sharing one key would join each other. It must also always be read at the SAME
    /// `T`: a joiner asking for a different type gets nil, never a wrong-typed value.
    func load<T>(_ key: some Hashable & Sendable, _ read: @escaping (StrapStore) async -> T) async -> T? {
        let boxed = await reads.run(AnyHashable(key)) { [weak self] () -> Any? in
            guard let store = await self?.ensureStore() else { return nil }
            return await read(store) as Any
        }
        return boxed as? T
    }

    // MARK: - Refresh

    /// Re-read the dashboard caches for the trailing `nDays` window. Diff-guarded: a refresh that
    /// produces byte-identical caches publishes nothing (no objectWillChange, no `refreshSeq` bump).
    func refresh(days nDays: Int = 120) async {
        guard let store = await ensureStore() else { return }
        let myGen = refreshGen.claim()
        let now = Date()
        let fromDay = Self.localDayKey(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.localDayKey(now.addingTimeInterval(86_400))
        let nowTs = Int(now.timeIntervalSince1970)
        // The sleep window must START WHERE THE DAY WINDOW STARTS, and a day earlier again.
        //
        // `fromDay` is a local day KEY, so the daily rows begin at that day's midnight; `lo` was
        // `now − nDays × 86400`, a mid-afternoon instant on the same date. The oldest cached day
        // therefore had a `DailyMetric` — so `SleepRegularity`'s `totalSleepMin != nil` gate called it
        // usable — while its night, which began the previous evening hours before `lo`, was absent from
        // `sleeps` entirely. A usable day carrying no sleep interval grids as AWAKE for all 1440
        // minutes, so the oldest night scored as a night spent awake. Harmless while Rest only ever
        // showed the newest night; 014 made that day reachable with the back chevron.
        //
        // The extra day is the straddle: a night starting the evening BEFORE `fromDay` and ending on it
        // belongs to `fromDay`, so the read has to reach past the boundary to hold it whole.
        let dayWindowStart = DayKey.date(from: fromDay).map { Int($0.timeIntervalSince1970) }
            ?? (nowTs - nDays * 86_400)
        let lo = dayWindowStart - 86_400, hi = nowTs + 86_400

        let imported = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        let computed = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? []
        let impSleep = (try? await store.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: 4000)) ?? []
        let compSleep = (try? await store.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: 4000)) ?? []
        let impPerf = (try? await store.metricSeries(deviceId: deviceId, key: "sleep_performance",
                                                     from: fromDay, to: toDay)) ?? []
        let compPerf = (try? await store.metricSeries(deviceId: computedDeviceId, key: "sleep_performance",
                                                      from: fromDay, to: toDay)) ?? []
        // Health monitor (007 F2): computed lane only — ScoreEngine is the sole writer of these keys.
        let strainScoreRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "strain_score",
                                                             from: fromDay, to: toDay)) ?? []
        let strainLevelRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "strain_level",
                                                             from: fromDay, to: toDay)) ?? []
        let strainFiredRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "strain_fired",
                                                             from: fromDay, to: toDay)) ?? []
        // Nap credit (007 F3): computed lane only — ScoreEngine is the sole writer of this key.
        let napRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "nap_min",
                                                     from: fromDay, to: toDay)) ?? []
        // Effort capture coverage: computed lane only — ScoreEngine is the sole writer of this key.
        let coverageRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "effort_coverage",
                                                          from: fromDay, to: toDay)) ?? []
        // Sleep regularity (011 W2.1): computed lane only — ScoreEngine is the sole writer of this key.
        let regularityRows = (try? await store.metricSeries(deviceId: computedDeviceId, key: "sleep_regularity",
                                                             from: fromDay, to: toDay)) ?? []
        // Unmeasured staged minutes (030 Track A): computed lane only — ScoreEngine is the sole writer.
        let unmeasuredRows = (try? await store.metricSeries(deviceId: computedDeviceId,
                                                            key: "sleep_unmeasured_min",
                                                            from: fromDay, to: toDay)) ?? []
        // P5: cheap whole-history HR watermark (indexed COUNT/MAX, no rows) so raw-HR consumers re-run only
        // when the stream actually grew — decoupled from the daily-score `refreshSeq`. Same fingerprint the
        // ScoreEngine #836 idle gate reads.
        let hrFp = try? await store.hrFingerprint(deviceId: deviceId, from: 0, to: 9_999_999_999)

        // Snapshot the currently-published caches (cheap COW) so the equality DIFF runs OFF the main actor
        // inside the merge (P4) — comparing up to ~4000 multi-KB `CachedSleepSession` on the UI thread every
        // idle tick was the cost. The detached block returns `changed`; the main actor only assigns when it's
        // true. (Assigning an equal value to an @Published prop still fires objectWillChange, so the skip has
        // to cover the assignments too.)
        let curDays = days, curSleeps = sleeps, curRest = restSeries
        let curStrainScore = strainScore, curStrainLevel = strainLevel
        let curStrainFired = strainFired
        let curNap = napSeries, curCoverage = effortCoverage
        let curRegularity = regularitySeries
        let curUnmeasured = unmeasuredSeries
        let wasLoaded = loaded

        // Merge + sort + diff OFF the main actor: pure over the rows just read, so the main actor stays free
        // for SwiftUI during a deep refresh (FIX 3).
        let merged: (days: [DailyMetric], sleeps: [CachedSleepSession], rest: [String: Double],
                     strainScore: [String: Double], strainLevel: [String: StrainLevel],
                     strainFired: [String: Int],
                     nap: [String: Double], coverage: [String: Double],
                     regularity: [String: Double], unmeasured: [String: Double], habitual: Int?,
                     changed: Bool) =
            await Task.detached(priority: .utility) {
                var rest: [String: Double] = [:]
                for p in compPerf { rest[p.day] = p.value }            // computed fills…
                for p in impPerf { rest[p.day] = p.value }             // …imported wins per day
                var sScore: [String: Double] = [:]
                for p in strainScoreRows { sScore[p.day] = p.value }
                var sLevel: [String: StrainLevel] = [:]
                // An unknown stored code (a NEWER app wrote a level this build doesn't know) decodes
                // conservatively to .quiet rather than dropping the day.
                for p in strainLevelRows { sLevel[p.day] = StrainLevel(rawValue: Int(p.value)) ?? .quiet }
                var sFired: [String: Int] = [:]
                for p in strainFiredRows { sFired[p.day] = Int(p.value) }
                // Filter the explicit zero rows ScoreEngine writes for scored zero-nap days (the
                // reconcile that lets a stale nap retract) — the published cache keeps its
                // absent-means-none contract.
                var nap: [String: Double] = [:]
                for p in napRows where p.value > 0 { nap[p.day] = p.value }
                // NO zero filter here, unlike `nap`: 0.0 coverage is a MEANINGFUL value (a day the strap
                // never captured during waking hours), and dropping it would make the worst days read as
                // "not graded" — the one state that suppresses the partial-capture flag.
                var coverage: [String: Double] = [:]
                for p in coverageRows { coverage[p.day] = p.value }
                // NO zero filter here either: an SRI of 0 is a real reading (the two nights agreed on
                // exactly half the day's minutes), and ScoreEngine only writes a day whose window
                // cleared the pair floor — so absence already carries the "no reading" meaning.
                var regularity: [String: Double] = [:]
                for p in regularityRows { regularity[p.day] = p.value }
                // `where p.value > 0`, on the `nap` filter's reasoning rather than coverage's: ScoreEngine
                // writes an explicit 0 for every scanned-clean day purely so a stale non-zero cannot
                // outlive the flag, and a rendered 0 here would read as the measured claim "no gap
                // tonight". See `unmeasuredSeries`.
                var unmeasured: [String: Double] = [:]
                for p in unmeasuredRows where p.value > 0 { unmeasured[p.day] = p.value }
                let days = Self.mergeDaily(imported: imported, computed: computed)
                let sleeps = Self.mergeSleep(imported: impSleep, computed: compSleep)
                // Learned habitual midsleep over the merged history — the SAME longest-block-per-day circular
                // mean ScoreEngine feeds its nap classifier (computeHabitualMidsleep), keyed by each session's
                // midpoint local day. Lets the Rest nap-ROW split align to the credited `nap_min`. nil under
                // 14 nights → cold-start, exactly as ScoreEngine falls back.
                let tzOff = TimeZone.current.secondsFromGMT()
                let habitualBlocks = sleeps.compactMap { s -> SleepGrouping.HistoryBlock? in
                    guard s.endTs > s.effectiveStartTs else { return nil }
                    let mid = s.effectiveStartTs + (s.endTs - s.effectiveStartTs) / 2
                    return SleepGrouping.HistoryBlock(start: s.effectiveStartTs, end: s.endTs,
                                                         dayKey: DayEngine.dayString(mid, offsetSec: tzOff))
                }
                let habitual = SleepGrouping.habitualMidsleepSec(habitualBlocks, offsetSec: tzOff)
                let changed = !(wasLoaded && days == curDays && sleeps == curSleeps
                                && rest == curRest
                                && sScore == curStrainScore && sLevel == curStrainLevel
                                && sFired == curStrainFired
                                && nap == curNap && coverage == curCoverage
                                && regularity == curRegularity && unmeasured == curUnmeasured)
                return (days: days, sleeps: sleeps, rest: rest,
                        strainScore: sScore, strainLevel: sLevel, strainFired: sFired, nap: nap,
                        coverage: coverage, regularity: regularity, unmeasured: unmeasured,
                        habitual: habitual, changed: changed)
            }.value

        // Generation guard: if a newer refresh() started while this one merged off-actor, drop this
        // now-stale result so it can't clobber the newer caches.
        guard refreshGen.isCurrent(myGen) else { return }

        // Republish the raw-HR watermark even when the daily caches are unchanged (raw HR can grow without
        // moving a score this tick), so the AutoWorkoutDetector re-runs on real HR growth. Guarded so an
        // unchanged stamp fires no objectWillChange. (P5)
        if let hrFp {
            let wm = HRWatermark(count: hrFp.count, maxTs: hrFp.maxTs)
            if hrWatermark != wm { hrWatermark = wm }
        }

        // Outside the diff guard: the floor moves with the wall clock even on a refresh that produced
        // byte-identical caches, and a stale floor would let a saturated cache read as the record start.
        self.daysWindowFloor = fromDay

        guard merged.changed else { return }

        self.days = merged.days
        self.sleeps = merged.sleeps
        self.restSeries = merged.rest
        self.strainScore = merged.strainScore
        self.strainLevel = merged.strainLevel
        self.strainFired = merged.strainFired
        self.napSeries = merged.nap
        self.effortCoverage = merged.coverage
        self.regularitySeries = merged.regularity
        self.unmeasuredSeries = merged.unmeasured
        self.habitualMidsleepSec = merged.habitual
        self.loaded = true
        self.refreshSeq += 1
    }

    // MARK: - Merge rules (carried from the original)

    /// Imported daily values win field-by-field; computed rows fill only nil imported fields. This
    /// preserves official export/import values while letting fresh local analysis populate Charge,
    /// skin-temp deviation, activity totals, or other fields missing from that row — and fully supply
    /// the days no import covers.
    /// A DEEP, read-only window for the Data tab's detail screen — the dashboard caches stop at the
    /// `refresh(days:)` window (120), so the "1Y" range charted and computed Mean/Min/Max/Slope over
    /// four months while labelling them a year. Min and Max simply could not see a genuine annual
    /// extreme, and the least-squares Slope — whose sign the detail screen calls "the finding" — could
    /// carry the opposite sign to the real annual trend on any seasonal metric.
    ///
    /// Deliberately NOT a wider `refresh(days:)`. `days` also feeds the journal/weed effect-size tiering,
    /// which is specced against the 120-day window; widening it globally would silently move those
    /// numbers. This is additive, reads nothing the caches don't already read, writes nothing, and
    /// publishes nothing — a caller that gets nil just keeps using the ordinary caches.
    ///
    /// `dailyMetric` and `metricSeries` are the durable record and are never pruned by SampleRetention,
    /// so the deeper history genuinely exists. Merge rules are byte-identical to `refresh`: computed
    /// fills, imported wins per day.
    func deepDailyWindow(days nDays: Int) async -> (days: [DailyMetric], series: MetricSeriesSet)? {
        let now = Date()
        let fromDay = Self.localDayKey(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.localDayKey(now.addingTimeInterval(86_400))
        let imp = deviceId, comp = computedDeviceId
        return await load(DeepWindowKey(from: fromDay, to: toDay)) { store in
            let imported = (try? await store.dailyMetrics(deviceId: imp, from: fromDay, to: toDay)) ?? []
            let computed = (try? await store.dailyMetrics(deviceId: comp, from: fromDay, to: toDay)) ?? []
            let impPerf = (try? await store.metricSeries(deviceId: imp, key: "sleep_performance",
                                                        from: fromDay, to: toDay)) ?? []
            let compPerf = (try? await store.metricSeries(deviceId: comp, key: "sleep_performance",
                                                         from: fromDay, to: toDay)) ?? []
            let napRows = (try? await store.metricSeries(deviceId: comp, key: "nap_min",
                                                        from: fromDay, to: toDay)) ?? []
            let coverageRows = (try? await store.metricSeries(deviceId: comp, key: "effort_coverage",
                                                             from: fromDay, to: toDay)) ?? []
            let regularityRows = (try? await store.metricSeries(deviceId: comp, key: "sleep_regularity",
                                                               from: fromDay, to: toDay)) ?? []
            let unmeasuredRows = (try? await store.metricSeries(deviceId: comp, key: "sleep_unmeasured_min",
                                                               from: fromDay, to: toDay)) ?? []
            var rest: [String: Double] = [:]
            for p in compPerf { rest[p.day] = p.value }   // computed fills…
            for p in impPerf { rest[p.day] = p.value }    // …imported wins per day
            var nap: [String: Double] = [:]
            // `where p.value > 0`, exactly as `refresh` does: ScoreEngine writes an EXPLICIT 0 row for
            // every scored night with no credited nap, and `MetricSeriesSet` documents napMin on an
            // absent-means-none contract. Without the filter the deep window turns every no-nap night
            // into a real 0:00 point — and because the deep source, once loaded, backs EVERY range, one
            // tap on 1Y would silently rewrite the 7D/30D/90D Naps stats too.
            for p in napRows where p.value > 0 { nap[p.day] = p.value }
            var coverage: [String: Double] = [:]
            for p in coverageRows { coverage[p.day] = p.value }
            var regularity: [String: Double] = [:]
            for p in regularityRows { regularity[p.day] = p.value }
            // `where p.value > 0`, for the same reason spelled out on `nap` above and NOT merely for
            // symmetry: the deep source, once loaded, backs EVERY range, so admitting ScoreEngine's
            // reconciling zeros here would turn one tap on 1Y into a wall of measured-looking "0 min"
            // points on every clean night across 7D/30D/90D too.
            var unmeasured: [String: Double] = [:]
            for p in unmeasuredRows where p.value > 0 { unmeasured[p.day] = p.value }
            return (days: Repository.mergeDaily(imported: imported, computed: computed),
                    series: MetricSeriesSet(rest: rest, napMin: nap, effortCoverage: coverage,
                                            regularity: regularity, unmeasuredMin: unmeasured))
        }
    }

    /// Identifies a `deepDailyWindow` read AND its inputs, so two different windows never join.
    private struct DeepWindowKey: Hashable, Sendable { let from: String; let to: String }

    nonisolated static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in computed { byDay[d.day] = d }
        for d in imported {
            if let existing = byDay[d.day] {
                byDay[d.day] = d.fillingNilFields(from: existing)
            } else {
                byDay[d.day] = d
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Same precedence for sleep sessions, keyed by the LOCAL day the night ends on (the engine's
    /// cached-offset keyer, #406) — every session per day survives (#715), imported wins per end-day.
    /// Internal (not private) so ScoreEngine's `nap_min` write classifies naps over the SAME merged
    /// population this cache publishes (007 F3) — a second merge rule would let the two drift.
    nonisolated static func mergeSleep(imported: [CachedSleepSession],
                                       computed: [CachedSleepSession]) -> [CachedSleepSession] {
        func endDay(_ s: CachedSleepSession) -> String {
            let offsetSec = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            return DayEngine.dayString(s.endTs, offsetSec: offsetSec)
        }
        return SleepMerge.merge(imported: imported, computed: computed, endDay: endDay)
    }

    // MARK: - Today / anchor resolution (ported verbatim from the original)

    /// The row "today" resolves to (#304 pre-04:00 carve-out + #144 anti-blank guard).
    var today: DailyMetric? {
        let now = Date()
        return Repository.resolveToday(days: days,
                                       logicalKey: Repository.logicalDayKey(now),
                                       localKey: Repository.localDayKey(now))
    }

    /// Pure resolver behind `today`: prefer the LOCAL-calendar-day row when it differs from the logical
    /// day AND has a banked night (`totalSleepMin != nil`); otherwise the logical-day row (preserving
    /// the #144 anti-blank guard).
    nonisolated static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }

    /// #911: the SINGLE anchor every off-dashboard surface (widget, watch snapshot, Live Activity)
    /// resolves the row it describes through. Resolve today's row; when it's scored use it, else carry
    /// over the freshest STRICTLY-PRIOR scored day. The `$0.day < carriedKey` bound keeps a stale or
    /// stray future-dated scored row from re-surfacing AS today (#547 future-day guard).
    nonisolated static func widgetAnchor(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        let todayRow = resolveToday(days: days, logicalKey: logicalKey, localKey: localKey)
        if todayRow?.recovery != nil { return todayRow }
        let carriedKey = todayRow?.day ?? logicalKey
        return days.last(where: { $0.recovery != nil && $0.day < carriedKey })
    }

    /// Live-clock convenience over the pure `widgetAnchor`: resolves the anchor for `now` so every call
    /// site reads as one line and can never partially re-derive the keys and drift.
    nonisolated static func widgetAnchor(days: [DailyMetric], now: Date = Date()) -> DailyMetric? {
        widgetAnchor(days: days, logicalKey: logicalDayKey(now), localKey: localDayKey(now))
    }

    /// The resolved "today" DAY KEY every on-screen surface clamps its derivations to: the resolved-today
    /// row's day, falling back to the logical key when no row exists yet. The `<= anchorKey` bound this
    /// feeds is the #547 future-day guard — the daily read window admits rows keyed up to TOMORROW (a
    /// tz-ahead backup import / transient clock skew), and without the clamp a future-dated row would
    /// describe itself AS today. One definition so Today, its Signals and Charge detail can never drift.
    nonisolated static func anchorKey(days: [DailyMetric], now: Date = Date()) -> String {
        resolveToday(days: days, logicalKey: logicalDayKey(now), localKey: localDayKey(now))?.day
            ?? logicalDayKey(now)
    }

    // MARK: - Day keys
    //
    // The rule itself lives in `DayKey` (nonisolated, so the off-actor surfaces share ONE formatter
    // instead of each hand-rolling a twin). These stay as the names the call sites + tests already
    // spell, and are `nonisolated` so forwarding costs no actor hop.

    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    nonisolated static func localDayKey(_ date: Date) -> String { DayKey.local(date) }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    nonisolated static let logicalDayRolloverHour = DayKey.rolloverHour

    /// The LOGICAL local day for `now` — the calendar date of `now − rolloverHour hours` (#144).
    /// Presentation-only: used solely to pick which stored row is Today; row keys are never rewritten.
    nonisolated static func logicalDay(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> Date {
        DayKey.logical(now, rolloverHour: rolloverHour)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logicalDay`).
    nonisolated static func logicalDayKey(_ now: Date, rolloverHour: Int = logicalDayRolloverHour) -> String {
        DayKey.logicalKey(now, rolloverHour: rolloverHour)
    }

    // MARK: - HR reads
    //
    // Generic reads over the strap's raw HR stream, NOT workout state — every workout-shaped read/write
    // lives on `WorkoutRepository`. Single-device install → one lane (`deviceId`) per read.

    /// Raw HR samples over `[from, to]` under the strap id. Single-device install → one read.
    func hrSamples(from: Int, to: Int, limit: Int = 8000) async -> [HRSample] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// HR coverage fingerprint over `[from, to]` under the strap id: `(sample count, max ts)` from an
    /// indexed COUNT/MAX with no rows materialized. The Rest "This morning's wake" panel reads this to
    /// report how much of the wake window the strap actually streamed. Single-device install → one read.
    func hrFingerprint(from: Int, to: Int) async -> (count: Int, maxTs: Int) {
        guard let store = await ensureStore() else { return (count: 0, maxTs: 0) }
        return (try? await store.hrFingerprint(deviceId: deviceId, from: from, to: to)) ?? (count: 0, maxTs: 0)
    }

    /// The strap lane's data FRONTIER — MAX(ts) over the persisted HR samples, a cheap indexed query with
    /// no rows materialized. nil when the lane is empty or the read fails. Read by the Live tab's
    /// sync-progress row (via `AppRoot`) and by Signal Lab, which ends its default window at real data
    /// rather than at the wall clock. Single-device install → one read.
    func latestHRSampleTs() async -> Int? {
        guard let store = await ensureStore() else { return nil }
        return try? await store.latestHRSampleTs(deviceId: deviceId)
    }

    /// Downsampled HR (mean bpm per `bucketSeconds`) over `[from, to]` for a trend chart.
    func hrBuckets(from: Int, to: Int, bucketSeconds: Int = 300) async -> [HRBucket] {
        guard let store = await ensureStore() else { return [] }
        return (try? await store.hrBuckets(deviceId: deviceId, from: from, to: to,
                                           bucketSeconds: bucketSeconds)) ?? []
    }

    /// Downsampled HR over a workout window for the detail HR-curve. The bucket scales with duration
    /// (~120 buckets across the window, floored at 15 s, capped at 300 s) so a short session isn't
    /// flattened. (Port of the original Repository.workoutHrBuckets.)
    func workoutHrBuckets(from: Int, to: Int) async -> [HRBucket] {
        guard to > from else { return [] }
        let span = to - from
        let bucket = max(15, min(300, span / 120))
        return await hrBuckets(from: from, to: to, bucketSeconds: bucket)
    }

    /// Raw HR samples binned into per-zone MINUTES for a workout window, using the age-derived (Tanaka)
    /// 6-edge %HRmax zone model (`ZoneModel` → the vendored `StrapAnalytics.HRZones`). Returns nil when
    /// the window carries no HR. `age <= 0` → a 30 y default.
    func workoutZoneMinutes(from: Int, to: Int, age: Int, hrMax: Int) async -> [Double]? {
        guard to > from else { return nil }
        // C2: the default 8000-sample cap truncates a long workout's ~1 Hz HR, undercounting
        // zone-minutes. Size the read to the window's seconds plus an hour of margin so the whole
        // span's HR is credited.
        let samples = await hrSamples(from: from, to: to, limit: max(8000, (to - from) + 3600))
        guard !samples.isEmpty else { return nil }
        // `hrSamples` reads `ORDER BY ts ASC`, so these rows already arrive in order; the engine still
        // sorts defensively, which is a cheap single run-detection pass on an already-ordered array.
        // Bucket against the override-aware HRmax the live stream + Effort scoring use, not raw Tanaka(age).
        let minutes = ZoneModel.minutes(samples, age: age > 0 ? Double(age) : 30,
                                        hrMax: hrMax > 0 ? Double(hrMax) : nil)
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }
}

private extension DailyMetric {
    /// A copy of self where every nil field is backfilled from `fallback`. Used by the field-by-field
    /// daily merge so an imported export keeps its own values while a computed row fills the gaps it
    /// doesn't carry. (Carries the v23 latency fields too, unlike the original, so a computed
    /// night's SOL/REM-latency/WASO survive the merge when the import lacks them.)
    func fillingNilFields(from fallback: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin ?? fallback.totalSleepMin,
            efficiency: efficiency ?? fallback.efficiency,
            deepMin: deepMin ?? fallback.deepMin,
            remMin: remMin ?? fallback.remMin,
            lightMin: lightMin ?? fallback.lightMin,
            disturbances: disturbances ?? fallback.disturbances,
            restingHr: restingHr ?? fallback.restingHr,
            avgHrv: avgHrv ?? fallback.avgHrv,
            recovery: recovery ?? fallback.recovery,
            strain: strain ?? fallback.strain,
            exerciseCount: exerciseCount ?? fallback.exerciseCount,
            spo2Pct: spo2Pct ?? fallback.spo2Pct,
            skinTempDevC: skinTempDevC ?? fallback.skinTempDevC,
            respRateBpm: respRateBpm ?? fallback.respRateBpm,
            steps: steps ?? fallback.steps,
            activeKcalEst: activeKcalEst ?? fallback.activeKcalEst,
            solMin: solMin ?? fallback.solMin,
            remLatencyMin: remLatencyMin ?? fallback.remLatencyMin,
            wasoMin: wasoMin ?? fallback.wasoMin
        )
    }
}
