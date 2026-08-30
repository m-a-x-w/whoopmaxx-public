import Foundation
import Combine
import StrapProtocol
import StrapStore
import StrapAnalytics

/// The Strap Health screen's read model (007 F4): battery now + runtime estimate + 7-day trend
/// from the PERSISTED battery table (the live ring is cleared on disconnect, so only the store
/// survives reconnects), last-7-day capture coverage + gap list via `GapScan`, the session
/// signal-quality grade, and a session reconnect counter.
///
/// Constructed once in `AppRoot` (so the reconnect counter spans the whole session, not just
/// while the screen is open) and injected as an environment object; the screen calls `refresh()`
/// from its `.task`. Store reads are async and diff-guarded, so an unchanged pass publishes
/// nothing.
@MainActor
final class StrapHealthModel: ObservableObject {

    /// One day of the capture strip: worn-waking coverage + its reported gaps.
    struct DayCapture: Equatable, Identifiable {
        /// "yyyy-MM-dd" local day key.
        let day: String
        /// Short localized weekday label ("Tue").
        let weekday: String
        /// True when this day ENTIRELY predates the first sample this store holds — the app was not
        /// installed (or the strap not paired) yet. Distinct from `coverage == nil` meaning "today's
        /// window hasn't opened", because the honest copy differs: one is "not yet", the other is "never".
        let preHistory: Bool
        /// 0–1 worn-waking coverage fraction (see `GapScan.dayCoverage`), or nil when today's
        /// waking window hasn't started yet (pre-08:00 — "not graded yet", never a false 0 %).
        let coverage: Double?
        let gaps: [GapScan.Gap]
        var id: String { day }
    }

    /// One battery trend point: the day's last persisted reading.
    struct BatteryPoint: Equatable {
        let date: Date
        let soc: Double
    }

    /// Trailing window both the battery trend and the capture strip cover.
    static let windowDays = 7
    /// HR-presence marks are read as 1-minute buckets (a cheap indexed GROUP BY), not raw ~1 Hz
    /// rows — GapScan's 15-min threshold only needs marks, and the ±59 s bucket snap is invisible
    /// at that scale. 7 days ≈ 10k rows worst case instead of ~600k.
    static let hrMarkBucketS = 60

    /// Battery % for the hero: the live reading when a link is up, else the last persisted sample
    /// (so the sim / a disconnected launch still shows the last known charge).
    @Published private(set) var batteryNowPct: Double?
    /// "~4.5 days" / "~14h" runtime estimate label (BatteryEstimator over the persisted series),
    /// nil before any reading. The view appends the "left" copy.
    @Published private(set) var estimateLabel: String?
    /// Last persisted SoC per local day, oldest → newest — the 7-day trend chart.
    @Published private(set) var trend: [BatteryPoint] = []
    /// Last 7 local days, oldest → newest (today clamped to "now" so the un-lived remainder never
    /// reads as a gap).
    @Published private(set) var capture: [DayCapture] = []
    /// Times the link re-established after the session's first connect. Counted here (not in
    /// LiveState) so the frozen BLE layer stays untouched.
    @Published private(set) var reconnects = 0

    private let repo: Repository
    private let live: LiveState
    private var everConnected = false
    private var cancellables = Set<AnyCancellable>()
    /// Stale-drop generation stamp (mirrors Repository.refresh). `.task(id: repo.refreshSeq)` starts a new
    /// refresh on every bump WITHOUT waiting for the prior one to finish, and refresh does several sequential
    /// store awaits — so without this an older-started call finishing AFTER a newer one would clobber the
    /// fresher trend/capture with stale reads. Claimed synchronously at entry; only the newest publishes.
    private var refreshGen = Generation()

    init(repo: Repository, live: LiveState) {
        self.repo = repo
        self.live = live
        // Count reconnects as rising `connected` edges past the first. `removeDuplicates()` keeps
        // repeated same-state publishes from inflating the count; the EMITTED value is used, never
        // a read-back (the willSet rule).
        live.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self, connected else { return }
                if self.everConnected {
                    self.reconnects += 1
                } else {
                    self.everConnected = true
                }
            }
            .store(in: &cancellables)
        // Keep the battery hero live while the cover stays open: mirror each EMITTED pct into the
        // published value (the refresh()-time snapshot went stale until the cover was reopened —
        // "panel says connected, battery says —"). The store-backed fallback and the runtime
        // estimate still come from refresh().
        live.$batteryPct
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] pct in
                guard let self, self.batteryNowPct != pct else { return }
                self.batteryNowPct = pct
            }
            .store(in: &cancellables)
    }

    /// Re-read the store-backed surfaces (battery trend + capture coverage). Diff-guarded + stale-dropped.
    func refresh(now: Date = Date()) async {
        // Claim synchronously at entry: the last-invoked refresh holds the highest gen and reads the
        // freshest data; older bodies bail at the guard below.
        let myGen = refreshGen.claim()
        guard let store = await repo.storeHandle() else { return }
        let nowTs = Int(now.timeIntervalSince1970)
        let windowLo = nowTs - Self.windowDays * 86_400

        // ── Battery: the persisted table, NOT the live ring (cleared on disconnect). The read-back
        // drops the charging flag (Reads.swift maps ts/soc/mv only), which is fine here: the
        // estimator infers charge cycles from SoC rises, so (ts, soc) is all it needs.
        let battery = (try? await store.batterySamples(deviceId: repo.deviceId,
                                                       from: windowLo, to: nowTs + 60,
                                                       limit: 5_000)) ?? []
        let socSeries: [(ts: Int, soc: Double)] = battery.compactMap { s in
            s.soc.map { (ts: s.ts, soc: $0) }
        }
        let pct = live.batteryPct ?? socSeries.last?.soc
        let estimate = BatteryEstimator.estimate(samples: socSeries,
                                                 ratedHours: live.batteryRatedHours)
        let estLabel = estimate.map { BatteryEstimator.label(hours: $0.remainingHours) }

        // One trend point per local day: the day's LAST reading (shows the discharge trend and any
        // charge bump; the store read is ts-ascending, so "last write wins" is the day's newest).
        var lastByDay: [String: (ts: Int, soc: Double)] = [:]
        for s in socSeries {
            lastByDay[Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.ts)))] = s
        }
        let trendPoints = lastByDay.values
            .sorted { $0.ts < $1.ts }
            .map { BatteryPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), soc: $0.soc) }

        // ── Capture: HR-presence marks (1-min buckets) + paired off-wrist intervals, graded per
        // local day by the pure GapScan. Today is clamped to "now".
        let marks = (await repo.hrBuckets(from: windowLo, to: nowTs,
                                          bucketSeconds: Self.hrMarkBucketS)).map(\.ts)
        // Events read starts a day early so an off-wrist span already open at the window edge
        // still pairs up.
        let events = (try? await store.events(deviceId: repo.deviceId,
                                              from: windowLo - 86_400, to: nowTs,
                                              limit: 20_000)) ?? []
        let offWrist = DayEngine.offWristIntervals(events: events, windowEnd: nowTs)

        // The earliest instant this store holds anything — the floor for every window graded below.
        let firstEverTs = try? await store.earliestHRSampleTs(deviceId: repo.deviceId)

        var days: [DayCapture] = []
        // Step by CALENDAR days off local midnight, not fixed 86_400-s intervals: across a DST
        // transition two adjacent `back` values could otherwise map to the same local-day key (fall-back)
        // or skip one (spring-forward). DayCapture is Identifiable by `day`, so a collision produces
        // duplicate ForEach ids (dropped/mis-rendered bar) and a missing day. Calendar stepping guarantees
        // `windowDays` distinct, contiguous local-day keys.
        let day0 = Calendar.current.startOfDay(for: now)
        for back in stride(from: Self.windowDays - 1, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: day0) else { continue }
            let key = Repository.localDayKey(date)
            // Grade with the day's OWN local UTC offset, not GapScan's default (now's offset). GapScan derives
            // each day's local midnight as `utcMidnight(key) - offsetSec`, which is only correct when offsetSec
            // is THAT day's offset — otherwise a day on the far side of a DST transition from `now` gets its
            // 08:00–22:00 window shifted by the DST delta, mis-grading coverage + gap clock times.
            let offsetSec = TimeZone.current.secondsFromGMT(for: date)
            // FLOOR THE WINDOW AT THE FIRST SAMPLE THIS STORE HOLDS. Without it every day before the
            // install grades 0 % and reports one 08:00–22:00 "gap while worn", under copy telling the user
            // the recording is permanently lost — for days the app did not exist. It also punished the
            // install day itself: paired at 15:00, the day was graded from 08:00 and scored ~0.70, under
            // the 0.80 bar that marks Effort "partial capture".
            let cov = GapScan.dayCoverage(dayKey: key, hrTimestamps: marks, offWrist: offWrist,
                                          offsetSec: offsetSec, clampEnd: back == 0 ? nowTs : nil,
                                          clampStart: firstEverTs)
            // Pre-08:00, today's graded window hasn't begun — that's "not graded yet" (nil), not
            // a 0 % capture failure.
            let notStarted = back == 0 && GapScan.windowNotStarted(dayKey: key, offsetSec: offsetSec, clampEnd: nowTs)
            // Wholly before the first sample: nothing to grade, and nothing was lost.
            let dayEnd = Int(date.timeIntervalSince1970) + GapScan.wakingEndHour * 3_600
            let preHistory = firstEverTs.map { dayEnd <= $0 } ?? true
            days.append(DayCapture(day: key, weekday: Self.weekdayLabel(date), preHistory: preHistory,
                                   coverage: (notStarted || preHistory) ? nil : cov.coverage,
                                   gaps: preHistory ? [] : cov.gaps))
        }

        // Drop a stale in-flight result: if a newer refresh started during our awaits, it holds a higher gen
        // and reads fresher data — publishing our older reads here would clobber it (each assign is only
        // value-diff-guarded, so older != newer passes and overwrites).
        guard refreshGen.isCurrent(myGen) else { return }
        if batteryNowPct != pct { batteryNowPct = pct }
        if estimateLabel != estLabel { estimateLabel = estLabel }
        if trend != trendPoints { trend = trendPoints }
        if capture != days { capture = days }
    }

    // MARK: - Formatting

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    static func weekdayLabel(_ date: Date) -> String { weekdayFormatter.string(from: date) }
}
