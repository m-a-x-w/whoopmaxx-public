import Foundation
import StrapStore

/// Pure derivations behind the Today screen: day-key stepping, trailing 30-day baselines, semantic
/// signal deltas, and the sleep spans that land on a given local day. All nonisolated + value-in /
/// value-out so previews and (later) tests can drive them without a Repository.
enum TodayModel {

    // MARK: - Day keys

    static func date(fromKey key: String) -> Date? { DayKey.date(from: key) }
    static func key(from date: Date) -> String { DayKey.local(date) }

    /// `key` stepped by `days` calendar days (negative = back), or nil for an unparseable key.
    static func shiftKey(_ key: String, by days: Int) -> String? {
        guard let date = date(fromKey: key),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return self.key(from: shifted)
    }

    /// Header title for a selected day: plain "Today" for the anchor day, the spelled-out date
    /// otherwise ("Tuesday, July 8").
    static func headerTitle(key: String, isToday: Bool) -> String {
        if isToday { return "Today" }
        guard let date = date(fromKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    // MARK: - Baselines (trailing 30-day means, STRICTLY before the selected day)

    /// Mean of `value` over the last `window` rows strictly before `key` that carry the field,
    /// or nil when none do (calibrating — hides ticks / deltas instead of faking a typical).
    static func priorMean(days: [DailyMetric], before key: String, window: Int = 30,
                          value: (DailyMetric) -> Double?) -> Double? {
        let prior = days.filter { $0.day < key }.compactMap(value).suffix(window)
        guard prior.count >= minBaselineSamples else { return nil }
        return mean(Array(prior))
    }

    /// Fewest prior days that may be called a "typical". Below this the honest answer is no tick and no
    /// delta, not a mean.
    ///
    /// WITHOUT THIS, ONE DAY WAS A TREND. On day 3 of a fresh install the Today hero drew a "30-day
    /// typical" baseline tick and a coloured up/down verdict against a single prior night, and the Charge
    /// detail said "above your typical" on the same evidence — while the Data tab, reading the identical
    /// series, correctly showed nothing, because `MetricSeriesSet` already requires 3. The two surfaces
    /// contradicted each other and a code comment claimed they agreed. 3 matches the Data tab so they
    /// finally do.
    static let minBaselineSamples = 3

    /// Same trailing mean over the Rest (`sleep_performance`) series, which is keyed independently
    /// of the daily rows.
    static func priorRestMean(restSeries: [String: Double], before key: String,
                              window: Int = 30) -> Double? {
        let prior = restSeries.keys.filter { $0 < key }.sorted().suffix(window)
            .compactMap { restSeries[$0] }
        guard prior.count >= minBaselineSamples else { return nil }   // same floor as `priorMean`
        return mean(prior)
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Trailing mean that HONOURS `minBaselineSamples` — the only mean a surface may present as a
    /// "typical". `priorMean`/`priorRestMean` above build their own window and apply the floor inline;
    /// this is for the surfaces that assemble the window themselves and then need the same floor.
    ///
    /// The floor was originally added only inside `priorMean`/`priorRestMean`, so three read-side
    /// surfaces that call bare `mean` kept turning ONE prior night into a 30-day "typical": the Today
    /// Signals deltas (HRV/RHR/Resp/Skin), the Charge detail's "above your typical" caption, and the
    /// Rest hero verdict. Today then contradicted both the score trio above it and the Data tab, which
    /// is the exact disagreement `minBaselineSamples` exists to end. Route new surfaces through here.
    static func typicalMean(_ values: [Double]) -> Double? {
        guard values.count >= minBaselineSamples else { return nil }
        return mean(values)
    }

    // MARK: - Anchor-day carry (#911 / v8 rollover-blank fix)

    /// Carry freshness cap (#977, extended to Charge): a carried Charge OR Rest older than this
    /// many days is stale — a wearer who stopped syncing must see "—", not last week's value pinned as
    /// today's. Both scores share the one cap so they can't disagree about what "too old to carry" means.
    static let carryFreshnessDays = 2

    /// Back-compat alias (older call sites / docs used the rest-specific name).
    static let restCarryFreshnessDays = carryFreshnessDays

    /// The freshest recovery-scored row STRICTLY before `key` — what Charge carries on the anchor
    /// day while today's row is still forming (last night not yet synced/scored). The `< key` bound
    /// is the #547 future-day guard; `carryFreshnessDays` refuses a stale score (a source more than
    /// two days back reads "—", matching Rest). Anchor day ONLY — browsing history shows each day
    /// honestly, carry-free.
    static func carriedChargeRow(days: [DailyMetric], before key: String) -> DailyMetric? {
        guard let row = days.last(where: { $0.recovery != nil && $0.day < key }),
              let age = daysBetween(row.day, key), age <= carryFreshnessDays
        else { return nil }
        return row
    }

    /// The freshest Rest score strictly before `key` (same carry, over the independently-keyed
    /// `sleep_performance` series), with its source day — capped at `carryFreshnessDays`
    /// (the original #977 fix; without the cap a stale Rest pins forever as today's).
    static func carriedRest(restSeries: [String: Double],
                            before key: String) -> (day: String, value: Double)? {
        guard let day = restSeries.keys.filter({ $0 < key }).max(),
              let value = restSeries[day],
              let age = daysBetween(day, key), age <= carryFreshnessDays
        else { return nil }
        return (day, value)
    }

    /// A compact source-day label for a carried value's caption ("Tue") — the abbreviated weekday of
    /// the key, so "Today" honestly reads "carried · Tue" instead of silently borrowing yesterday.
    static func shortDayLabel(_ key: String) -> String {
        guard let date = date(fromKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Whole calendar days from `earlierKey` to `laterKey`, nil for unparseable keys.
    static func daysBetween(_ earlierKey: String, _ laterKey: String) -> Int? {
        guard let a = date(fromKey: earlierKey), let b = date(fromKey: laterKey) else { return nil }
        // Count CALENDAR DAYS, not elapsed time. `DayKey.date(from:)` returns a day's first instant,
        // which is 00:00 on all but a handful of dates a year — in the zones whose DST springs forward AT
        // midnight the day begins at 01:00. A span starting on such a date is then only 23 h per day, and
        // `dateComponents([.day])` truncates, so it came back one short. (Normalising through
        // `startOfDay` does NOT help: 01:00 already IS that day's start.) At the carry gate
        // (`age <= carryFreshnessDays`) that silently extended how long a stale Charge/Rest could be
        // presented as today's. `ordinality(of: .day, in: .era)` is an index, so the difference is exact
        // regardless of how long either civil day happened to be.
        let cal = Calendar.current
        guard let da = cal.ordinality(of: .day, in: .era, for: a),
              let db = cal.ordinality(of: .day, in: .era, for: b) else { return nil }
        return db - da
    }

    /// The freshest strictly-prior row carrying ANY overnight vital (HRV / RHR / resp) — the
    /// recovery-INDEPENDENT vitals fallback (the original `lastVitalsDay`): a night with real HRV but null
    /// recovery is a valid source here. Skin temp is deliberately NOT carried (parity with the original — it
    /// reads today-only). Call sites read each vital today-first (`row?.field ?? vitalsRow?.field`),
    /// so today's own value always wins.
    ///
    /// Capped at `carryFreshnessDays`, exactly like the Charge and Rest carries above. Without the cap
    /// this returned the freshest vitals-bearing row anywhere in the 120-day refresh window, so after a
    /// sync gap Today showed an all-em-dash score trio ("no data for this day") directly above three
    /// precise present-tense vitals with coloured "vs typical" deltas and no source-day caption — sourced
    /// from a night that could be months old, and written into the widget snapshot too. The doc on
    /// `carryFreshnessDays` states the rule this now follows: a wearer who stopped syncing must see "—",
    /// not last week's value pinned as today's.
    static func vitalsFallbackRow(days: [DailyMetric], before key: String) -> DailyMetric? {
        guard let row = days.last(where: {
                  $0.day < key && ($0.avgHrv != nil || $0.restingHr != nil || $0.respRateBpm != nil)
              }),
              let age = daysBetween(row.day, key), age <= carryFreshnessDays
        else { return nil }
        return row
    }

    // MARK: - Signal deltas

    /// What a signal's move away from its 30-day mean MEANS for this vital.
    enum DeltaRule {
        /// Higher is better (HRV).
        case upGood
        /// Lower is better (resting HR).
        case downGood
        /// Staying near the typical is the good state (respiratory rate, skin temp): |Δ| under
        /// `warn` is good, under `bad` is warn, beyond is bad — direction doesn't matter.
        case nearZeroGood(warn: Double, bad: Double)
    }

    /// The ▲/▼ delta vs the 30-day mean, or nil when either side is missing (no fake zeros).
    /// A delta whose magnitude rounds to zero at `decimals` renders neutral — "unchanged" isn't
    /// good or bad news.
    static func signalDelta(current: Double?, mean: Double?, rule: DeltaRule,
                            decimals: Int, suffix: String = "") -> WMDelta? {
        guard let current, let mean else { return nil }
        let diff = current - mean
        let magnitude = abs(diff)
        // Tie "unchanged" to what the formatter will actually PRINT — a magnitude that rounds to zero at
        // this precision (e.g. exactly 0.5 → "%.0f" → "0", round-half-to-even) must read neutral, not a
        // colored ▲0/▼0. A raw threshold (`magnitude < 0.5·10^-decimals`) disagrees with printf at the
        // exact-half boundary; deriving it from the formatted string can't.
        let magText = String(format: "%.\(decimals)f", magnitude)
        let text = magText + suffix
        let roundsToZero = (Double(magText) ?? 0) == 0

        let sentiment: WMDelta.Sentiment
        if roundsToZero {
            sentiment = .neutral
        } else {
            switch rule {
            case .upGood: sentiment = diff > 0 ? .good : .bad
            case .downGood: sentiment = diff < 0 ? .good : .bad
            case let .nearZeroGood(warn, bad):
                sentiment = magnitude < warn ? .good : (magnitude < bad ? .warn : .bad)
            }
        }
        return WMDelta(up: diff >= 0, text: text, sentiment: sentiment)
    }

    // MARK: - Sleep spans

    /// The sessions that END on `dayKey` (the same local-end-day bucketing Repository merges by),
    /// clipped to the day's bounds for the TimelineStrip. Uses `effectiveStartTs` so a
    /// hand-corrected onset draws where the user put it.
    static func sleepSpans(_ sleeps: [CachedSleepSession], dayKey: String,
                           dayStart: Date, dayEnd: Date) -> [(start: Date, end: Date)] {
        sleeps.compactMap { s in
            let end = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            guard key(from: end) == dayKey else { return nil }
            let start = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let clippedStart = max(start, dayStart)
            let clippedEnd = min(end, dayEnd)
            guard clippedEnd > clippedStart else { return nil }
            return (start: clippedStart, end: clippedEnd)
        }
    }
}
