import Foundation
import Combine
import StrapProtocol
import StrapStore
import StrapAnalytics

/// BodyClockEngine — the compute-on-read loader that turns ALREADY-STORED strap data into a body-clock
/// readout: the CircadianEngine phase estimate (thermal midnight + owl/lark lean) and the TwoProcessModel
/// optimal-bedtime recommendation. No store schema change; nothing persisted. Runs ONCE per day (or when
/// the wake target changes), cached across the two surfaces that read it (the Rest "Tonight's bedtime"
/// section + the More → Body Clock screen), never per SwiftUI frame.
///
/// Inputs are built from the store's richest reliably-available 24-hour signal:
///   • ActivityBin profile: hourly HEART-RATE means over the trailing ~14 days (`hrBuckets`, aggregated
///     in SQL so a fortnight costs ~336 rows). Persisted per-epoch sleep motion is night-only, so it
///     can't feed a 24-h cosinor; the HR rhythm is a genuine circadian activity proxy (higher across the
///     active day, lower overnight). CircadianEngine down-confidences thin data on its own.
///   • habitualWakeHour / habitualSleepHour: circular means of recent sleep-session wake / onset hours.
///   • observedTempMinHour: the family-aware nightly skin-temperature minimum's clock hour, circular-mean
///     over recent nights; nil when there is no worn skin-temp stream. The per-night minimum is
///     `ThermalSleepSignature`'s ROBUST nadir (bin medians + a rolling median), not a raw argmin — see
///     that type for why the argmin was reading a dropout spike and steering bedtime advice by hours.
///   • Two-process inputs: the recent sleep sessions as intervals + the personal sleep need + the
///     SmartAlarmSettings wake target (passed in when the alarm is enabled).
@MainActor
final class BodyClockEngine: ObservableObject {

    /// The computed body-clock readout for a day. Pure value — safe to cache + diff.
    struct Readout: Equatable {
        let phase: CircadianEngine.PhaseEstimate?
        let bedtime: TwoProcessModel.BedtimeRecommendation?
        /// Circular-mean habitual sleep-onset clock hour (for the jet-lag planner), or nil (cold-start).
        let habitualSleepHour: Double?
        /// Circular-mean habitual wake clock hour (for the jet-lag planner), or nil (cold-start).
        let habitualWakeHour: Double?
        /// Distinct days of activity data backing the phase fit (confidence driver / honest empty state).
        let daysObserved: Int
        /// Last night's onset heat dump (011 W2.2): how long the skin trace took to settle, and where
        /// that drop sits against the user's own recent nights. Never a °C — the 4.0 raw→°C slope is
        /// provisional, so only the calibration-free duration and the within-user ranking leave the
        /// engine. Carries its own refusals (`.unreadable` / a nil ranking), so it is not optional here.
        let heatDump: ThermalSleepSignature.HeatDump
        /// The local day key the readout was generated for.
        let dayKey: String
    }

    @Published private(set) var readout: Readout?
    @Published private(set) var computing = false

    /// Trailing window for the activity profile + sleep-schedule medians.
    private static let windowDays = 14
    /// Recent nights scanned for the skin-temperature minimum (bounded per-night reads).
    private static let tempMinNights = 10
    /// Fewest nights inside `windowDays` before the habitual anchor trusts the window alone. Below this
    /// it widens to the most recent nights, so a sporadic wearer still gets a real anchor — a nil anchor
    /// is strictly worse, since `wakeForPhase` then collapses to the 7.0 default and the jet-lag planner
    /// cells blank out.
    private static let minAnchorNights = 5
    /// Plausible worn skin-temperature range (°C) — off-wrist/charging drift is excluded before the min.
    private static let skinWornMinC = 28.0
    private static let skinWornMaxC = 42.0
    /// Cold-start floor for the personal sleep-need mean (mirrors ScoreEngine.personalNeedMinNights).
    private static let personalNeedMinNights = 7

    /// Cache shared across every BodyClockEngine instance so the Rest section and the Body Clock screen
    /// compute the readout ONCE per (day, wake-target) rather than once each. Keyed by day + wake target.
    private static var sharedCache: [String: Readout] = [:]

    /// In-flight compute per cacheKey, shared across BOTH engine instances AND a superseding `.task(id:)`
    /// restart, so the ~11-query read pass runs at most ONCE per (day, wake-target, data-version). Replaces
    /// the old per-instance `computing` boolean guard, which (a) dropped a superseding call entirely —
    /// freezing the readout at pre-sync data (#14) — and (b) being per-instance and set only AFTER the first
    /// await, let the two surfaces both run the full read pass on a cold cache (#15).
    private static let inFlight = SingleFlight<String, Readout?>()

    /// Compute (or reuse) today's readout. `wakeTargetHour` is the SmartAlarmSettings latest-edge wake
    /// clock hour when the alarm is enabled, else nil. A no-op when a matching readout is already cached
    /// unless `force` is set.
    func refresh(repo: Repository, wakeTargetHour: Double?, force: Bool = false) async {
        let now = Date()
        let dayKey = Repository.localDayKey(now)
        // Key on the data version too, so a same-day sync (refreshSeq bump) recomputes rather than
        // serving a stale readout, while the two surfaces at the same version still share ONE compute.
        let cacheKey = Self.cacheKey(dayKey: dayKey, wakeTargetHour: wakeTargetHour, dataSeq: repo.refreshSeq)

        if !force, let cached = Self.sharedCache[cacheKey] {
            if readout != cached { readout = cached }
            return
        }

        // Coalesce onto a single in-flight compute for this key (join an existing one unless forced).
        computing = true
        defer { computing = false }
        let result = await Self.inFlight.run(cacheKey, restart: force) {
            await Self.computeReadout(repo: repo, cacheKey: cacheKey,
                                      dayKey: dayKey, wakeTargetHour: wakeTargetHour)
        }
        // If a newer `.task(id:)` superseded this call while we awaited, SwiftUI cancelled THIS task —
        // don't publish a stale readout over the newer one (the newer refresh awaits its own compute and
        // publishes the fresh result).
        if Task.isCancelled { return }
        if let result, readout != result { readout = result }
    }

    /// The heavy readout compute, coalesced via `inFlight` (see `refresh`), which frees its own slot when
    /// this returns. Static so the shared Task isn't tied to one engine instance; writes `sharedCache` and
    /// returns the readout (or nil if the store is unavailable). Runs on the main actor (reads `repo`
    /// @Published state), awaits yield it.
    private static func computeReadout(repo: Repository, cacheKey: String, dayKey: String,
                                       wakeTargetHour: Double?) async -> Readout? {
        guard let store = await repo.storeHandle() else { return nil }
        let now = Date()

        // Snapshot the merged, deduped sleep sessions as Sendable (start, end) tuples on the main actor.
        let sessions: [(start: Int, end: Int)] = repo.sleeps
            .map { (start: $0.effectiveStartTs, end: $0.endTs) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        // Nights-only subset: daytime naps are stored as ordinary sleep sessions, but a 14:00 nap's worn
        // skin-temp minimum reports a ~14:00 "nightly temp min" and its onset/wake skew the habitual
        // clock hours — corrupting the circadian nadir fed to CircadianEngine/TwoProcessModel. Exclude
        // the sessions NapCredit classifies as naps (same split the Rest screen / scored dailyMetric use)
        // so the circadian inputs see only true nights. The FULL `sessions` list still feeds the
        // two-process spans below (naps legitimately contribute to sleep pressure discharge).
        // Pass the LEARNED midsleep, as the comment above promises ("the same split the Rest screen /
        // scored dailyMetric use"). Omitting it defaulted `habitualMidsleepSec` to nil, which falls back
        // to the cold-start 03:30 anchor — and the alignment bonus that anchor drives is worth up to 90
        // minutes of score, so it decides the main-night pick whenever two same-day blocks are close in
        // duration. A night misclassified as a nap is then dropped from the very circadian inputs this
        // function exists to compute. The Rest screen and ScoreEngine both already pass their own.
        let napKeys = NapCredit.napSessionKeys(sleeps: repo.sleeps,
                                               habitualMidsleepSec: repo.habitualMidsleepSec)
        let nightSessions = sessions.filter { !napKeys.contains("\($0.start):\($0.end)") }
        let needHours = Self.personalNeedHours(days: repo.days)
        let deviceId = repo.deviceId
        let family = WhoopModel.persisted.deviceFamily

        let nowTs = Int(now.timeIntervalSince1970)
        let windowStart = nowTs - Self.windowDays * 86_400

        // ── Reads (store actor; awaits yield the main actor) ──────────────────────────────────────────
        // Hourly HR means over the fortnight — the 24-h activity proxy.
        let buckets = (try? await store.hrBuckets(deviceId: deviceId, from: windowStart, to: nowTs,
                                                  bucketSeconds: 3600)) ?? []
        // Nightly skin-temp minimum clock hours over the most recent nights (naps excluded).
        let recentNights = nightSessions.suffix(Self.tempMinNights)
        var tempMinHours: [Double] = []
        // Onset-limb amplitudes, oldest → newest, ONE entry per scanned night — nil where that night's
        // start didn't read. Positional, because `heatDump` ranks last night against the ones before it
        // and a compacted array would silently promote an older night into last night's slot.
        var dumpAmplitudes: [Double?] = []
        var lastOnset: ThermalSleepSignature.Onset? = nil
        for night in recentNights {
            // Size the read to the WINDOW, not a flat cap. skinTempSample is a 1 Hz stream and the store
            // reads `ORDER BY ts ASC LIMIT ?`, so a flat 20_000 covered only 5 h 33 m and truncated the
            // TAIL of essentially every real night — exactly where the circadian nadir sits.
            // The nadir statistic had no coverage check, so it reported the minimum of the first 5.5 h
            // as the night's, and `CircadianEngine.estimatePhase` OVERRIDES its activity-derived
            // estimate with that value, which then drives "Tonight's bedtime".
            // Same shape as the C2 workout fix in Repository. The upper clamp keeps this read no larger
            // than the day-scale reads ScoreEngine already issues against this table.
            let span = Swift.max(0, night.end - night.start)
            let samples = (try? await store.skinTempSamples(
                deviceId: deviceId, from: night.start, to: night.end,
                limit: Swift.min(200_000, Swift.max(20_000, span + 3_600)))) ?? []
            // The nadir is the ROBUST one, not the raw argmin `nightlyTempMinClockHour` returns (011
            // W2.2). Measured on the real backup, every long night carries 16–110 isolated dropout
            // samples that clear the 28 °C worn gate by a hair, and the surviving single-sample minimum
            // was one of them on 6 of 7 nights — off by +0.5…+3.3 h. That value FULLY OVERRIDES the
            // cosinor fit inside `CircadianEngine.estimatePhase`, so the spike was steering "Tonight's
            // bedtime" by hours. Same read, same loop; only the statistic changed.
            let signature = ThermalSleepSignature.analyze(samples, family: family,
                                                          start: night.start, end: night.end)
            if let ts = signature?.nadirTs { tempMinHours.append(Self.localClockHour(ts)) }
            dumpAmplitudes.append(signature?.onset?.amplitudeC)
            lastOnset = signature?.onset      // `recentNights` ascends, so this settles on last night
        }

        // ── Pure derivation (cheap) ───────────────────────────────────────────────────────────────────
        let profile = Self.activityProfile(buckets: buckets)
        // The habitual anchors follow the SAME trailing window as the activity profile. `windowDays` is
        // documented as covering "the activity profile + sleep-schedule medians", but it was only ever
        // applied to the HR buckets: `nightSessions` comes from `repo.sleeps`, which Repository fills
        // over ~120 nights, so these circular means averaged four months of onsets and wakes. A user
        // whose schedule changed two months ago (new job, term start, a move) got an anchor sitting
        // between the old and new rhythm, and `wakeForPhase` drives BOTH the recommended bedtime and the
        // phase estimate — so "Tonight's bedtime" could be over an hour off their actual rhythm.
        // `sessions` is sorted ascending and the nap filter preserves order, so `suffix` is the most
        // RECENT nights (the same property the temp-min read above already relies on).
        let windowedNights = nightSessions.filter { $0.start >= windowStart }
        let anchorNights = windowedNights.count >= Self.minAnchorNights
            ? windowedNights
            : Array(nightSessions.suffix(Self.windowDays))
        let habitualWakeHour = Self.circularMeanHour(anchorNights.map { Self.localClockHour($0.end) })
        let habitualSleepHour = Self.circularMeanHour(anchorNights.map { Self.localClockHour($0.start) })
        let observedTempMin = Self.circularMeanHour(tempMinHours)

        let wakeForPhase = habitualWakeHour ?? 7.0
        let phase = CircadianEngine.estimatePhase(bins: profile.bins,
                                                  daysObserved: profile.days,
                                                  habitualWakeHour: wakeForPhase,
                                                  observedTempMinHour: observedTempMin)

        let spans = sessions.map { TwoProcessModel.SleepSpan(start: $0.start, end: $0.end) }
        let bedtime = TwoProcessModel.recommendBedtime(
            spans: spans,
            habitualWakeHour: wakeForPhase,
            tempMinHour: phase?.tempMinHour,
            phaseConfidence: phase?.confidence,
            needHours: needHours,
            wakeTargetHour: wakeTargetHour)

        // Last night's drop ranked against the readable nights BEFORE it — `dropLast()` keeps last night
        // out of its own baseline, so "steeper than your recent nights" compares it to something else.
        let heatDump = ThermalSleepSignature.heatDump(latest: lastOnset,
                                                      history: Array(dumpAmplitudes.dropLast()))

        let result = Readout(phase: phase, bedtime: bedtime,
                             habitualSleepHour: habitualSleepHour, habitualWakeHour: habitualWakeHour,
                             daysObserved: profile.days, heatDump: heatDump, dayKey: dayKey)
        sharedCache[cacheKey] = result
        // Bound the cache — only ever a couple of live keys (today × wake-target variants).
        if sharedCache.count > 8 {
            sharedCache = [cacheKey: result]
        }
        return result
    }

    private static func cacheKey(dayKey: String, wakeTargetHour: Double?, dataSeq: Int) -> String {
        "\(dayKey)|\(wakeTargetHour.map { String(format: "%.3f", $0) } ?? "-")|\(dataSeq)"
    }

    // MARK: - Pure builders (static, unit-testable)

    /// Pool hourly HR means into a 24-point per-hour-of-day activity profile for the cosinor. Each
    /// bucket's local hour-of-day is averaged across the window; `days` is the count of distinct local
    /// days the buckets span (drives CircadianEngine confidence).
    static func activityProfile(buckets: [HRBucket]) -> (bins: [CircadianEngine.ActivityBin], days: Int) {
        guard !buckets.isEmpty else { return ([], 0) }
        var sum = [Double](repeating: 0, count: 24)
        var count = [Int](repeating: 0, count: 24)
        var dayKeys = Set<Int>()
        for b in buckets {
            let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(b.ts)))
            let local = b.ts + offset
            let hour = (local / 3600) % 24
            let h = hour < 0 ? hour + 24 : hour
            sum[h] += b.bpm
            count[h] += 1
            dayKeys.insert(Int(floor(Double(local) / 86_400.0)))
        }
        var bins: [CircadianEngine.ActivityBin] = []
        for h in 0..<24 where count[h] > 0 {
            bins.append(CircadianEngine.ActivityBin(hour: Double(h), activity: sum[h] / Double(count[h])))
        }
        return (bins, dayKeys.count)
    }

    /// The clock hour of a night's MINIMUM worn skin temperature, or nil when no worn sample survives.
    /// The raw→°C map is monotonic per family, so the minimum raw IS the minimum °C; we still convert to
    /// gate out off-wrist/charging drift (outside the 28–42 °C worn band). Family-aware (#938).
    ///
    /// OFF THE READOUT PATH since 011 W2.2 — `ThermalSleepSignature.analyze` supplies the nadir now. This
    /// single-sample argmin is kept as the pre-011 comparator `ThermalSleepSignatureTests` pins the
    /// dropout-spike regression against: the test is only worth anything if it moves the code that
    /// actually shipped, not a re-typed sketch of it.
    static func nightlyTempMinClockHour(_ samples: [SkinTempSample], family: DeviceFamily) -> Double? {
        var minC = Double.greatestFiniteMagnitude
        var minTs: Int? = nil
        for s in samples {
            let c = skinTempCelsius(raw: s.raw, family: family)
            guard c >= skinWornMinC, c <= skinWornMaxC else { continue }
            if c < minC { minC = c; minTs = s.ts }
        }
        return minTs.map { localClockHour($0) }
    }

    /// Personal sleep need (hours): trailing mean of nightly asleep hours floored at 7.5 h; under
    /// `personalNeedMinNights` nights falls back to `Rest.defaultNeedHours`. Mirrors
    /// ScoreEngine.personalNeedHours / RestScreen.personalNeedMin so the surfaces agree.
    static func personalNeedHours(days: [DailyMetric]) -> Double {
        let perNight: [Double] = days.compactMap { d in
            if let tst = d.totalSleepMin, tst > 0 { return tst / 60.0 }
            return nil
        }
        guard perNight.count >= personalNeedMinNights else { return Rest.defaultNeedHours }
        return max(7.5, perNight.reduce(0, +) / Double(perNight.count))
    }

    /// The device-local clock hour ([0, 24)) of a unix-seconds timestamp, DST-correct per instant.
    static func localClockHour(_ ts: Int) -> Double {
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        let local = Double(ts + offset)
        var h = (local / 3600.0).truncatingRemainder(dividingBy: 24.0)
        if h < 0 { h += 24.0 }
        return h
    }

    /// Circular (wrap-aware) mean of a set of clock hours in [0, 24), robust to the midnight wrap so a
    /// cluster of onsets like 23:00 / 00:30 averages near midnight, not near noon. Returns nil for empty
    /// input or a degenerate (antipodal) set with no defined mean direction.
    static func circularMeanHour(_ hours: [Double]) -> Double? {
        guard !hours.isEmpty else { return nil }
        var sx = 0.0, sy = 0.0
        for h in hours {
            let a = 2.0 * Double.pi * h / 24.0
            sx += cos(a); sy += sin(a)
        }
        guard abs(sx) > 1e-9 || abs(sy) > 1e-9 else { return nil }
        var ang = atan2(sy, sx)
        if ang < 0 { ang += 2.0 * Double.pi }
        return ang * 24.0 / (2.0 * Double.pi)
    }
}
