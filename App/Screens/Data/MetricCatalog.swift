import Foundation
import StrapStore
import StrapAnalytics

/// The keyed per-day series the catalog reads BESIDE the merged daily rows — the values Repository
/// publishes off the `metricSeries` table (`sleep_performance` → `rest`, `nap_min` → `napMin`).
/// A tiny named bundle instead of a bare dictionary so adding a series is one field, not a new
/// parameter threaded through every read closure.
struct MetricSeriesSet {
    /// Rest score (0–100) per day key (`Repository.restSeries`).
    var rest: [String: Double] = [:]
    /// Credited nap minutes per day key (`Repository.napSeries`); absent day = no naps credited.
    var napMin: [String: Double] = [:]
    /// Waking-window capture coverage per day key (`Repository.effortCoverage`); absent day = not graded.
    var effortCoverage: [String: Double] = [:]
    /// Sleep Regularity Index per day key (`Repository.regularitySeries`); absent day = the trailing
    /// window held too few comparable nights to have a reading, NOT a reading of 0.
    var regularity: [String: Double] = [:]
    /// Minutes inside a night's staged span that were never measured — the `sleep_unmeasured_min`
    /// series ScoreEngine writes on the computed lane beside the session's `CachedSleepSession
    /// .lowConfidence` flag, keyed by the night's day. Absent day = no reading, NEVER a measured 0;
    /// the `sleep_unmeasured_min` catalog entry below drops a zero-rendering point for the same reason.
    ///
    /// Populated from `Repository.unmeasuredSeries` (both the 120-day refresh and the deep-window read),
    /// which already filters ScoreEngine's reconciling zeros out on read — so every day present here
    /// really did have unmeasured minutes. Defaulted empty like its neighbours, which keeps every
    /// preview and test construction site that predates this field compiling and correctly showing the
    /// metric as absent (`DataScreen.rebuildSeries` drops a metric with no points, so no tile appears at
    /// all rather than a wall of zeros).
    var unmeasuredMin: [String: Double] = [:]

    /// True when this day's Effort was accumulated over materially incomplete capture. ADDITIVE metrics
    /// (strain, active calories) are under-reported on such a day by an unknowable amount, so they are
    /// withheld from the Data tab's series rather than shown as ordinary points — otherwise the 30-day
    /// delta, mean, min/max and slope all quietly absorb a number that is only a floor. Absent ⇒ not
    /// graded ⇒ not low, so today's still-accumulating totals are never withheld.
    func isLowCoverage(_ day: String) -> Bool {
        guard let c = effortCoverage[day] else { return false }
        return c < ScoreConfidence.effortSolidCoverage
    }
}

/// The data-tab metric catalog: every browsable metric with its label, unit, domain color, delta
/// semantics, display format, and the accessor that reads it off a merged daily row (or the keyed
/// series). Pure model — `DataScreen` builds the wall from it, `MetricDetailScreen` charts it.
struct MetricDef: Identifiable {

    /// What a MOVE in this metric means, so the delta arrow can be colored by meaning (the 001
    /// semantic colors are deltas/statuses, never an accent): HRV up is good, RHR up is bad, and a
    /// strain or skin-temp move is just information (neutral ink).
    enum Sense {
        case higherBetter, lowerBetter, neutral
    }

    /// How values render: whole number, thousands-grouped whole number (step counts), fixed decimals,
    /// always-signed decimals (skin-temp deviation), or decimal HOURS shown as h:mm (sleep durations).
    enum Format {
        case integer
        case groupedInteger
        case decimal(Int)
        case signedDecimal(Int)
        case hoursMinutes

        /// The smallest difference this format can SHOW — a delta below it would render as "0", so
        /// the tile omits the arrow instead of printing a zero-magnitude change.
        var minimumVisible: Double {
            switch self {
            case .integer, .groupedInteger:                   return 0.5
            case .decimal(let p), .signedDecimal(let p):      return 0.5 * pow(10, -Double(p))
            case .hoursMinutes:                               return 0.5 / 60
            }
        }
    }

    let key: String
    let label: String
    let unit: String?
    let domain: WM.Domain
    let sense: Sense
    let format: Format
    /// Honest-labeling caption for the detail screen (nil = none): the approximate/estimated metrics
    /// (steps, calories) say plainly what the number is and is not — an estimate is surfaced AS an
    /// estimate, never dressed as a measurement — and SpO2 goes one step further, stating that no
    /// percentage can be read from the strap's raw channel at all rather than promising one. `var`
    /// with a default so the memberwise init leaves every unannotated entry untouched.
    var note: String? = nil
    /// Reads this metric off one merged daily row; series-backed entries (Rest, Naps) read the
    /// `MetricSeriesSet` keyed by the row's day instead. nil = the row doesn't carry this metric.
    let read: (DailyMetric, MetricSeriesSet) -> Double?
    /// Extra strings the fuzzy search also matches, beyond `label`. Exists so renaming a label to the
    /// app's own vocabulary does not make the metric unfindable by the name it used to carry (Charge was
    /// "Recovery", Effort was "Strain") — and so the WHOOP-native words a user arrives with still work.
    var searchAliases: [String] = []

    var id: String { key }

    // MARK: Series

    /// The (date, value) series for this metric over the repository's merged days, oldest → newest
    /// (rows without the metric are skipped, so gaps never fabricate zeros).
    func series(days: [DailyMetric], series: MetricSeriesSet) -> [(date: Date, value: Double)] {
        days.compactMap { row in
            guard let v = read(row, series), let d = MetricCatalog.date(fromDayKey: row.day) else { return nil }
            return (d, v)
        }
    }

    // MARK: Formatting

    /// The metric's display string for `value` (signed formats keep their sign; h:mm for durations).
    func string(for value: Double) -> String {
        switch format {
        case .integer:              return String(format: "%.0f", value)
        case .groupedInteger:       return Self.grouped(value)
        case .decimal(let p):       return String(format: "%.\(p)f", value)
        case .signedDecimal(let p): return (value < 0 ? "" : "+") + String(format: "%.\(p)f", value)
        case .hoursMinutes:         return (value < 0 ? "−" : "") + Self.hmm(value)
        }
    }

    /// Unsigned magnitude string (the ▲/▼ arrow carries the direction).
    func magnitudeString(for value: Double) -> String {
        let a = abs(value)
        switch format {
        case .integer:                               return String(format: "%.0f", a)
        case .groupedInteger:                        return Self.grouped(a)
        case .decimal(let p), .signedDecimal(let p): return String(format: "%.\(p)f", a)
        case .hoursMinutes:                          return Self.hmm(a)
        }
    }

    /// Always-signed string — the stats row's slope, where the sign IS the finding.
    func signedString(for value: Double) -> String {
        (value < 0 ? "−" : "+") + magnitudeString(for: value)
    }

    /// True when `value` renders as an all-zero magnitude in THIS metric's display format — "0"
    /// (integer), "0.00" (decimal/signedDecimal), or "0:00" (h:mm). Derived from the formatted string
    /// so it agrees with what the tile actually prints at the exact-half boundary a raw threshold can't
    /// (C2). Any real digit (e.g. "0.1", "6", "1:00") makes this false.
    private func formattedMagnitudeIsZero(_ value: Double) -> Bool {
        magnitudeString(for: value).allSatisfy { $0 == "0" || $0 == "." || $0 == ":" }
    }

    /// Decimal hours as "h:mm" (7.2 → "7:12"). Unsigned — the `.hoursMinutes` cases above prepend
    /// their own "−", which is why this is the `hours:` entry point and NOT `RestFormat.hmm`'s
    /// minutes-with-a-zero-clamp one.
    private static func hmm(_ hours: Double) -> String { WMFormat.hmm(hours: hours) }

    /// Whole number with locale thousands grouping (12403 → "12,403"). Cached — NumberFormatter
    /// construction is expensive (the `DayKey.formatter` precedent).
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static func grouped(_ value: Double) -> String {
        Self.groupedFormatter.string(from: NSNumber(value: value.rounded())) ?? String(format: "%.0f", value)
    }

    // MARK: Delta vs the 30-day mean

    /// The tile/detail delta: latest value vs the mean of the PRIOR 30 days (latest excluded so a
    /// spike doesn't drag its own baseline). nil when there's too little history (< 3 prior points)
    /// or the difference is below what the format can show.
    func delta(series: [(date: Date, value: Double)]) -> WMDelta? {
        guard let latest = series.last else { return nil }
        // C3: the "typical" is the last 30 PRIOR points — a ROW-COUNT window (latest excluded so a spike
        // can't drag its own baseline), the SAME population Today / the widget use (TodayModel.priorMean,
        // WidgetDayResolver). A calendar-30-day cutoff diverged from them under sparse wear, so the SAME
        // metric on the SAME day could show a different vs-typical delta (even a different ▲/▼) here than
        // on Today. Matching the row-count form makes the Data tab agree.
        let history = Array(series.dropLast().suffix(30).map(\.value))
        guard history.count >= 3, let mean = MetricMath.mean(history) else { return nil }
        let diff = latest.value - mean
        guard abs(diff) >= format.minimumVisible else { return nil }
        // C2: hide the delta when the FORMATTED magnitude prints zero. `minimumVisible` still lets an
        // exactly-±0.5 integer diff through, but `%.0f` renders it "0" — a colored ▲0 for no real change.
        // Gate on what the tile actually shows (mirrors TodayModel.signalDelta), not the raw threshold.
        guard !formattedMagnitudeIsZero(diff) else { return nil }
        let up = diff > 0
        return WMDelta(up: up, text: magnitudeString(for: diff), sentiment: sentiment(up: up))
    }

    /// Direction → meaning, per `sense` (neutral metrics stay ink — color only where it means something).
    func sentiment(up: Bool) -> WMDelta.Sentiment {
        switch sense {
        case .higherBetter: return up ? .good : .bad
        case .lowerBetter:  return up ? .bad : .good
        case .neutral:      return .neutral
        }
    }
}

extension MetricDef: Hashable {
    static func == (lhs: MetricDef, rhs: MetricDef) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

extension MetricDef {
    /// This def resolved for the current unit system. Only `skin_temp` changes: its stored values are a
    /// ±°C DEVIATION, so imperial wraps `read` to scale every value by the delta rule (×9/5, NO +32) and
    /// relabels the unit °F — which makes the hero value, the delta, the chart, and the mean/min/max/slope
    /// stats all read in °F coherently (they all flow through this one `read`/`unit`). Every other metric
    /// is unit-agnostic and returns unchanged. Identity in metric.
    func resolved(imperial: Bool) -> MetricDef {
        guard imperial, key == "skin_temp" else { return self }
        let base = read
        return MetricDef(key: key, label: label, unit: TempUnit.label(imperial: true),
                         domain: domain, sense: sense, format: format, note: note,
                         read: { d, r in base(d, r).map { TempUnit.delta($0, imperial: true) } })
    }
}

// MARK: - Catalog

enum MetricCatalog {

    /// Every browsable metric, in wall order. Domains: recovery drivers ride Charge ember, strain
    /// rides Effort signal, everything sleep-derived rides Rest indigo.
    static let all: [MetricDef] = [
        // Labelled with the app's OWN score names, not the WHOOP ones. Everywhere else in the app this
        // exact value is "Charge" (ScoreColumn's overline, the Today hero, ChargeDetailScreen); the Data
        // wall was the one surface still calling it Recovery, so the same number carried two names
        // depending on which tab you were on. Keys stay as they are — they are internal (MetricDef.==
        // and one preview lookup), never persisted, so renaming them would be pure churn.
        MetricDef(key: "recovery", label: "Charge", unit: "%", domain: .charge,
                  sense: .higherBetter, format: .integer,
                  read: { d, _ in d.recovery },
                  searchAliases: ["Recovery"]),
        // Strain and Calories are ACCUMULATED over the day with no coverage term (see
        // `MetricSeriesSet.isLowCoverage`), so a half-captured day is withheld instead of being charted
        // as an ordinary point. On the real 2026-07-15 that day reported strain 27.01 (vs a 27.01…65.28
        // honest range) and 1055.8 kcal against 2223–2790 on its neighbours.
        MetricDef(key: "strain", label: "Effort", unit: nil, domain: .effort,
                  sense: .neutral, format: .integer,
                  read: { d, s in s.isLowCoverage(d.day) ? nil : d.strain },
                  searchAliases: ["Strain"]),
        // Daily activity totals ride Effort (they are load, not recovery). Both are APPROXIMATE
        // on-device estimates (DailyMetric v11 columns) and say so in their notes.
        MetricDef(key: "steps", label: "Steps", unit: nil, domain: .effort,
                  sense: .neutral, format: .groupedInteger,
                  note: "Approximate. Experimental count from the strap's raw motion counter — "
                      + "not validated step detection.",
                  read: { d, _ in d.steps.map(Double.init) }),
        MetricDef(key: "active_kcal", label: "Calories", unit: "kcal", domain: .effort,
                  sense: .neutral, format: .groupedInteger,
                  note: "Estimate. Whole-day energy from heart rate alone.",
                  read: { d, s in s.isLowCoverage(d.day) ? nil : d.activeKcalEst }),
        MetricDef(key: "sleep", label: "Sleep", unit: "h", domain: .rest,
                  sense: .higherBetter, format: .hoursMinutes,
                  read: { d, _ in d.totalSleepMin.map { $0 / 60 } }),
        // The Rest lane's answer to `isLowCoverage` — the SAME idea as the Effort/Calories withholding
        // above, applied to the night. Effort accumulates with no coverage term, so a half-captured day's
        // shortfall is unknowable and the only honest move is to withhold the number. A night's shortfall
        // IS knowable: ScoreEngine measures the minutes inside the staged span that overlap unexplained
        // worn silence and banks them under `sleep_unmeasured_min`, so here the honest move is the
        // opposite one — print the shortfall rather than delete the total. Withholding `sleep` instead
        // would throw away the minutes that WERE measured, and quietly shrinking the total to only the
        // measured minutes would be the app asserting a smaller number it did not measure either.
        //
        // It sits directly under Sleep, out of the Deep/REM/Light grouping, because it qualifies that one
        // number: on the corpus's best-looking night the wall otherwise reads a clean 10:10 while the same
        // minutes made Effort withhold itself for low capture — two lanes, one night, opposite stories.
        //
        // `.neutral` is the only truthful sense. `.lowerBetter` would paint a fall green, but this is a
        // fact about the RECORDING, not about the sleeper: fewer unmeasured minutes can just as easily
        // mean a shorter night, and nothing in the engine grades the strap's capture as good or bad for
        // the person wearing it. So the delta stays ink — the call `skin_temp`, `resp` and `rem_latency`
        // already make. The population reinforces it: only nights that HAD a gap carry a point, so a
        // delta here compares one flawed night against a history of flawed nights.
        //
        // The read drops anything under half a minute rather than charting it. A night with nothing
        // missing must be ABSENT here, never a 0 — `.integer` prints such a point "0", which on this
        // wall reads as a measured "no gap tonight", and it is not distinguishable from the explicit
        // reconciling zeros ScoreEngine writes on the `nap_min` precedent (`Repository.napSeries`
        // filters those on read for exactly this reason). 0.5 is `.integer`'s `minimumVisible`: the
        // smallest value this format can show as a real digit.
        MetricDef(key: "sleep_unmeasured_min", label: "Unmeasured", unit: "min", domain: .rest,
                  sense: .neutral, format: .integer,
                  note: "Minutes inside this night's staged span where the strap was worn but banked "
                      + "nothing. The stages either side of the gap were measured; these minutes were "
                      + "not, so the night's totals cover more clock time than the strap actually read. "
                      + "A night with nothing missing has no reading here, not a zero.",
                  read: { d, s in
                      guard let m = s.unmeasuredMin[d.day], m >= 0.5 else { return nil }
                      return m
                  }),
        MetricDef(key: "rest", label: "Rest", unit: nil, domain: .rest,
                  sense: .higherBetter, format: .integer,
                  read: { d, s in s.rest[d.day] }),
        MetricDef(key: "hrv", label: "HRV", unit: "ms", domain: .charge,
                  sense: .higherBetter, format: .integer,
                  read: { d, _ in d.avgHrv }),
        MetricDef(key: "rhr", label: "RHR", unit: "bpm", domain: .charge,
                  sense: .lowerBetter, format: .integer,
                  read: { d, _ in d.restingHr.map(Double.init) }),
        MetricDef(key: "resp", label: "Resp rate", unit: "rpm", domain: .charge,
                  sense: .neutral, format: .decimal(1),
                  read: { d, _ in d.respRateBpm }),
        MetricDef(key: "skin_temp", label: "Skin temp", unit: "°C", domain: .charge,
                  sense: .neutral, format: .signedDecimal(2),
                  read: { d, _ in d.skinTempDevC }),
        // SpO2 carries a CAPABILITY statement, not an estimate — it is the one catalog entry whose note
        // says a number will never arrive. Measured on the real backup (523,179 rows, 6.2 days, WHOOP
        // 4.0), the raw `spo2Sample` stream is a slow sample-and-hold register rather than a pulse
        // waveform: 76 distinct (red, ir) pairs across the week, 76 s median hold, and d_red == d_ir in
        // 99.9996 % of consecutive pairs — so R collapses to DC_ir/DC_red > 1 and a sub-85 % result is
        // an algebraic identity, not a reading. `Spo2Estimator.windowPct` ported verbatim over that same
        // week puts 0 of 1750 windows inside the 85–100 band, which is why `ScoreEngine` correctly gets
        // nil on every real night. The old note ("Estimate. Uncalibrated, from the strap's raw red/IR
        // pulse-ox signal during sleep.") promised a value the hardware cannot produce, and the last
        // time that optimism was acted on the clamp wrote exactly 85.0 % to 21/21 sleep sessions and
        // into Apple Health — `Spo2Heal` exists for no other reason.
        //
        // `read` is DELIBERATELY unchanged. An `spo2Pct` on the raw "my-whoop" lane came from a WHOOP
        // cloud export, is genuinely measured, and `Spo2Heal` never touches it (`Spo2Heal.swift:24-25`),
        // so it must still read, chart and print. The note stays true on such a day: it says nothing can
        // be read from the STRAP's own channel offline, which is exactly as true when the number beside
        // it was imported.
        MetricDef(key: "spo2", label: "SpO2", unit: "%", domain: .charge,
                  sense: .higherBetter, format: .decimal(1),
                  note: "Your strap banks a raw red/infrared optical channel, but it is a slow "
                      + "register rather than a pulse waveform, so no oxygen percentage can be read "
                      + "from it offline. Nothing is estimated here.",
                  read: { d, _ in d.spo2Pct }),
        MetricDef(key: "efficiency", label: "Efficiency", unit: "%", domain: .rest,
                  sense: .higherBetter, format: .integer,
                  // DailyMetric.efficiency is a 0–1 fraction (engine: asleep/in-bed); the tile shows a
                  // percent, so scale ×100. (A prior DemoSeed stored it as 0–100 and masked this.)
                  read: { d, _ in d.efficiency.map { $0 * 100 } }),
        MetricDef(key: "deep", label: "Deep sleep", unit: "min", domain: .rest,
                  sense: .higherBetter, format: .integer,
                  read: { d, _ in d.deepMin }),
        MetricDef(key: "rem", label: "REM sleep", unit: "min", domain: .rest,
                  sense: .higherBetter, format: .integer,
                  read: { d, _ in d.remMin }),
        MetricDef(key: "light", label: "Light sleep", unit: "min", domain: .rest,
                  sense: .neutral, format: .integer,
                  read: { d, _ in d.lightMin }),
        // REM latency — measured, persisted, healed and merged since v23, and until now read by NOTHING.
        // `dailyMetric.remLatencyMin` is filled by `AnalyticsEngine`, carried through `ScoreEngine`'s
        // persisted rebuild, preserved by both heals and merged across the two device lanes by
        // `Repository` — and no surface in App/, Widgets/ or Shared/ ever showed it. Its two v23 siblings
        // had each been resolved one way or the other: `wasoMin` reached the user as the Rest screen's
        // awake row, and `solMin` carries a written refusal (always nil, because the strap gives no
        // in-bed reference to measure a latency from — see `SleepStaging.HypnogramMetrics.leadingNonSleepS`).
        // This one was neither surfaced nor refused, so it sat as a write-only column. It is a genuine
        // measurement with a real reference, which is why the resolution here is a reader and not a third
        // silence. It sits AFTER the Deep/REM/Light trio rather than inside it: those three are stage
        // TOTALS that belong together on the wall, while this is a timing statistic, like Regularity below.
        //
        // `.neutral` is the only honest sense. A short REM latency is not "better" and a long one is not
        // "worse" — the direction carries no within-user meaning this app can stand behind — so the delta
        // stays ink, the same call `skin_temp` and `resp rate` make. Coloring it would assert a judgement
        // nothing in the engine computes.
        //
        // The note names the REFERENCE because that is precisely what separates this column from the nil
        // one beside it: the stager measures from the night's own sleep ONSET (first REM segment start
        // minus first sleep segment start), which is exactly the anchor `solMin` lacks. And on a night
        // bridged from several fragments it is the FIRST fragment's, never a sum — REM latency is a
        // property of the onset, so `AnalyticsEngine` deliberately takes it from the first fragment alone.
        // Someone reading a figure against a two-stretch night is owed the fact that it describes the
        // first stretch.
        //
        // Expect a sparse history rather than a year of bars: only the trailing rescore ever wrote this
        // column, so days outside `analyzeRecent(maxDays: 21)`'s reach keep whatever they already had —
        // nil, for most of them — permanently. That gap IS the honest picture. `series` skips a nil row,
        // so the 90/365 ranges show real absence rather than backfilled zeros, and a night with no REM at
        // all (the stager's NaN, mapped to nil at the DailyMetric build) draws no point, no 0, and no dash
        // that would read as "REM arrived the instant you fell asleep".
        //
        // No `searchAliases`: the label is this metric's own name, and `MetricCatalogVocabularyTests` pins
        // aliases as belonging only to the two entries RENAMED away from the WHOOP vocabulary.
        MetricDef(key: "rem_latency", label: "REM latency", unit: "min", domain: .rest,
                  sense: .neutral, format: .integer,
                  note: "Minutes from sleep onset to the night's first REM. The reference is when you "
                      + "fell asleep, not when you got into bed \u{2014} the strap has no lights-out "
                      + "signal to measure from. On a night bridged from more than one stretch of sleep "
                      + "this is the first stretch's, and a night with no REM has no latency to measure, "
                      + "so it stays empty.",
                  read: { d, _ in d.remLatencyMin }),
        // Sleep regularity (011 W2.1) — a MULTI-NIGHT statistic, unlike every other entry above, which
        // is why the note names its window. Read-only: no score consumes it (011 decision 2).
        MetricDef(key: "sleep_regularity", label: "Regularity", unit: nil, domain: .rest,
                  sense: .higherBetter, format: .integer,
                  note: "Sleep Regularity Index over the trailing 14 nights: how often you were in the "
                      + "same state \u{2014} asleep or awake \u{2014} at the same clock minute on two "
                      + "consecutive days. 100 means identical timing every night; 0 means the two "
                      + "nights matched on half the day's minutes. Naps count, and a night with no "
                      + "banked sleep is left out along with its two comparisons.",
                  // No `searchAliases`: the label IS the metric's real name, and
                  // `MetricCatalogVocabularyTests` pins aliases as belonging only to the two entries
                  // that were RENAMED away from the WHOOP vocabulary.
                  read: { d, s in s.regularity[d.day] }),
        MetricDef(key: "nap_min", label: "Naps", unit: "h", domain: .rest,
                  sense: .neutral, format: .hoursMinutes,
                  // The `nap_min` series stores credited MINUTES; `.hoursMinutes` renders decimal
                  // HOURS as h:mm, so scale ÷60 here — and the unit is "h" to match the rendered
                  // h:mm value (the Sleep entry's pairing), never the stored minutes.
                  read: { d, s in s.napMin[d.day].map { $0 / 60 } })
    ]

    static func def(forLabel label: String) -> MetricDef? {
        all.first { $0.label == label }
    }

    // MARK: Day-key dates

    /// `yyyy-MM-dd` local-zone parse, matching how `DailyMetric.day` is written.
    static func date(fromDayKey key: String) -> Date? {
        DayKey.date(from: key)
    }

    // MARK: Fuzzy search

    /// Case-insensitive SUBSEQUENCE match ("rhr" hits "RHR", "slp" hits "Sleep", "dps" hits
    /// "Deep sleep") — whitespace in the query is ignored. Empty query matches everything.
    static func fuzzyMatch(query: String, in candidate: String) -> Bool {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return true }
        var qIndex = q.startIndex
        for ch in candidate.lowercased() {
            if ch == q[qIndex] {
                qIndex = q.index(after: qIndex)
                if qIndex == q.endIndex { return true }
            }
        }
        return false
    }
}

// MARK: - Series math

/// Tiny stats over a metric window: mean / sample SD (the ±1σ typical band) / least-squares slope.
enum MetricMath {

    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n−1); nil below 2 points.
    static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Simple least-squares slope in metric units PER DAY over the (date, value) points; nil below
    /// 2 points or when all points share one day (degenerate fit).
    static func slopePerDay(_ points: [(date: Date, value: Double)]) -> Double? {
        guard points.count >= 2, let first = points.first else { return nil }
        let xs = points.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = points.map(\.value)
        let xMean = xs.reduce(0, +) / Double(xs.count)
        let yMean = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, den = 0.0
        for i in xs.indices {
            let dx = xs[i] - xMean
            num += dx * (ys[i] - yMean)
            den += dx * dx
        }
        guard den > 0 else { return nil }
        return num / den
    }
}
