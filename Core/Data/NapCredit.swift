import Foundation
import StrapStore
import StrapAnalytics

/// Nap classification + credit (007 F3, pure). SleepStager already detects daytime naps and keeps
/// them as their OWN `sleepSession` rows, so "nap detection" is done upstream. This helper answers
/// the remaining read-side questions: WHICH of a day's sessions are naps (vs the main night), and
/// how many minutes they credit toward sleep need/debt. Credit is ADDITIVE — it feeds the
/// `SleepDebt.ledger` / need inputs, never the night totals.
///
/// Classification uses `SleepGrouping.mainNightGroupIndices` — the SAME bridged-group selector
/// `analyzeDay` uses for the day's dailyMetric. A fragmented main sleep (short mid-night wake, or
/// an overnight-band re-doze inside the #861 night-tail bridge) is bridged into ONE main-night
/// group whose stages `analyzeDay` already SUMS into `totalSleepMin` — so a fragment of it must
/// never be handed back out as a "nap", or the same sleep counts twice in the debt ledger and the
/// persisted `nap_min` series. Only sessions OUTSIDE the winning group are naps.
enum NapCredit {

    /// Ceiling on the nap minutes one day may credit toward need. Letting an unbounded "nap" wipe a
    /// whole night of debt would overstate its restorative value (naps are lighter sleep — little
    /// deep/REM architecture).
    ///
    /// The "past ~2 h a nap is really a SPLIT NIGHT" case this ceiling used to absorb is now handled
    /// UPSTREAM, where it belongs: `SleepGrouping.splitNightMinFragmentMin` (deliberately the SAME
    /// 120 min — keep the two in step) reclassifies a long overnight-band fragment INTO the main-night
    /// group, so `analyzeDay` sums its minutes into `totalSleepMin` and it never reaches this function
    /// as a nap at all. Truncating here was lossy: on 2026-07-25 the real store's 229.5-min second half
    /// of a split night was capped to 120, silently discarding 68.5 min that were also missing from
    /// `totalSleepMin`. What remains for this ceiling is what it is actually good for — a genuinely
    /// DAYTIME nap (onset outside the overnight band, so never bridgeable) and chains of several naps
    /// in one day, where the "lighter sleep, diminishing returns" argument really does hold.
    static let maxCreditedMinPerDay: Double = 120

    /// The sessions ENDING on `dayKey` that are NOT part of the day's main-night group, sorted by
    /// start.
    ///
    /// Sessions key to the local calendar day their `endTs` lands on — each by its OWN end-instant
    /// offset (mirroring `Repository.mergeSleep`'s per-instant keyer, so a DST transition inside
    /// the window can't shift a session onto the wrong day). Pass a fixed `offsetSec` (tests) to
    /// key and select on that offset instead. Thread the learned `habitualMidsleepSec` where the
    /// caller has it (ScoreEngine) so the pick aligns with the scored dailyMetric; nil falls back
    /// to the cold-start overnight band. A day with a single session has no naps by construction
    /// (its one session IS the main night).
    static func naps(for dayKey: String, sleeps: [CachedSleepSession],
                     offsetSec: Int? = nil, habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        let onDay = sleeps
            .filter { endDayKey($0, offsetSec: offsetSec) == dayKey }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        guard onDay.count > 1 else { return [] }
        let blocks = onDay.map { SleepGrouping.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        // The selector's local-clock offset: the fixed one when supplied, else the newest end's own.
        let selOffset = offsetSec ?? instantOffset(onDay[onDay.count - 1].endTs)
        guard let mainGroup = SleepGrouping.mainNightGroupIndices(
            blocks, offsetSec: selOffset, habitualMidsleepSec: habitualMidsleepSec) else {
            return []
        }
        let main = Set(mainGroup)
        return onDay.indices.filter { !main.contains($0) }.map { onDay[$0] }
    }

    /// The exact complement of `naps(for:)` — the sessions that ARE the day's main night, which the
    /// split-night bridge may span across several fragments.
    ///
    /// Sharing one selector is the point: a session lands in exactly one lane, so the Rest screen can
    /// never disagree with the scored `dailyMetric` about which blocks are the night. The Rest screen
    /// used to pick with a bare longest-span `max`, which can only ever return ONE fragment and ignores
    /// the alignment bonus `mainNightIndex` applies — so on a bridged night the hero showed the whole
    /// group's Asleep total while the stage rows, hypnogram, bed/wake and arousal forensics described a
    /// single fragment, contradicting each other by hours.
    static func mainNightSessions(for dayKey: String, sleeps: [CachedSleepSession],
                                  offsetSec: Int? = nil,
                                  habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        let onDay = sleeps
            .filter { endDayKey($0, offsetSec: offsetSec) == dayKey }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        // A day with one session IS the main night by construction (mirrors the nap side's early-out).
        guard onDay.count > 1 else { return onDay }
        let blocks = onDay.map { SleepGrouping.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let selOffset = offsetSec ?? instantOffset(onDay[onDay.count - 1].endTs)
        guard let mainGroup = SleepGrouping.mainNightGroupIndices(
            blocks, offsetSec: selOffset, habitualMidsleepSec: habitualMidsleepSec) else {
            // Same fallback shape as the nap side: an unresolvable day yields no naps, so every session
            // is the night.
            return onDay
        }
        let main = Set(mainGroup)
        return onDay.indices.filter { main.contains($0) }.map { onDay[$0] }
    }

    /// Every session across ALL days that classifies as a nap (i.e. NOT part of its day's main-night
    /// group), keyed as `"effectiveStartTs:endTs"` for O(1) membership. The complement of this set over
    /// a session list is the "true nights" — the split BodyClockEngine needs so daytime naps don't
    /// pollute the circadian temperature minimum / habitual sleep-wake hours. Grouping by end-day first
    /// is behaviour-identical to per-day `naps(for:)` calls (each only looks at its own end-day).
    static func napSessionKeys(sleeps: [CachedSleepSession], offsetSec: Int? = nil,
                               habitualMidsleepSec: Int? = nil) -> Set<String> {
        let byDay = Dictionary(grouping: sleeps) { endDayKey($0, offsetSec: offsetSec) }
        var keys = Set<String>()
        for (day, group) in byDay {
            for nap in naps(for: day, sleeps: group, offsetSec: offsetSec,
                            habitualMidsleepSec: habitualMidsleepSec) {
                keys.insert("\(nap.effectiveStartTs):\(nap.endTs)")
            }
        }
        return keys
    }

    /// A single session's clock-span minutes (the same span `NightBlock.durationS` ranks by).
    static func minutes(of session: CachedSleepSession) -> Double {
        Double(max(0, session.endTs - session.effectiveStartTs)) / 60.0
    }

    /// The day's credited nap minutes: the summed nap spans, capped at `maxCreditedMinPerDay`.
    /// 0 when the day has no naps.
    static func creditedMin(for dayKey: String, sleeps: [CachedSleepSession],
                            offsetSec: Int? = nil, habitualMidsleepSec: Int? = nil) -> Double {
        let total = naps(for: dayKey, sleeps: sleeps, offsetSec: offsetSec,
                         habitualMidsleepSec: habitualMidsleepSec)
            .reduce(0.0) { $0 + minutes(of: $1) }
        return Swift.min(total, maxCreditedMinPerDay)
    }

    /// Credited nap minutes for EVERY day in one grouped pass (O(sessions)), instead of one
    /// whole-array `creditedMin` scan per day — the shape the ScoreEngine `nap_min` write and the
    /// Rest debt ledger consume. Days with no naps are ABSENT (callers decide whether an absent
    /// day persists as an explicit 0 — ScoreEngine does, so a stale row can be reconciled);
    /// grouping by end-day key first is behavior-identical to per-day calls because `naps(for:)`
    /// only ever looks at sessions ending on its own day.
    static func creditedMinByDay(sleeps: [CachedSleepSession],
                                 offsetSec: Int? = nil,
                                 habitualMidsleepSec: Int? = nil) -> [String: Double] {
        let byDay = Dictionary(grouping: sleeps) { endDayKey($0, offsetSec: offsetSec) }
        var out: [String: Double] = [:]
        for (day, group) in byDay {
            let credited = creditedMin(for: day, sleeps: group, offsetSec: offsetSec,
                                       habitualMidsleepSec: habitualMidsleepSec)
            if credited > 0 { out[day] = credited }
        }
        return out
    }

    /// Per-nap credited minutes for a day's nap list (same order as `naps`), distributing
    /// `maxCreditedMinPerDay` chronologically: each nap credits its full span until the day's cap
    /// runs out, then partially, then 0. Σ(result) == `creditedMin` for the same naps by
    /// construction, so a row-by-row "+N toward need" readout can never disagree with the day total.
    static func credits(forNaps naps: [CachedSleepSession]) -> [Double] {
        var remaining = maxCreditedMinPerDay
        return naps.map { nap in
            let credit = Swift.min(minutes(of: nap), Swift.max(remaining, 0))
            remaining -= credit
            return credit
        }
    }

    // MARK: - Day keying

    /// A session's local end-day key: the fixed `offsetSec` when supplied, else the end instant's
    /// OWN local offset — the same per-instant keyer `Repository.mergeSleep` uses, so the two can
    /// never disagree across a DST transition.
    private static func endDayKey(_ s: CachedSleepSession, offsetSec: Int?) -> String {
        DayEngine.dayString(s.endTs, offsetSec: offsetSec ?? instantOffset(s.endTs))
    }

    /// Seconds east of UTC at a specific instant (DST-correct, unlike "now"'s offset).
    private static func instantOffset(_ ts: Int) -> Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
