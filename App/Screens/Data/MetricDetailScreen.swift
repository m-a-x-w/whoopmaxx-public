import SwiftUI
import StrapStore
import StrapAnalytics

/// Pushed metric detail (data tab): huge display value + delta vs the 30-day mean, `BandChart`
/// over the selected range with a mean±1σ typical band, a plain-ink segmented range control
/// (7/30/90/365), and a mean/min/max/slope stats row as `SignalCell`s, closed by the
/// window-over-window comparison (`PeriodDeltaReadout`). Draws its own header
/// (back chevron) — the shell hides the system navigation bar.
struct MetricDetailScreen: View {
    let def: MetricDef
    @ObservedObject var repo: Repository
    /// Metric/Imperial pref → resolves the def (skin temp °C↔°F) before it feeds the value/delta/chart/stats.
    /// @AppStorage so switching Units re-renders the whole detail live.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    /// The deep (annual) window, loaded lazily the first time the user picks a range the dashboard
    /// caches cannot serve. nil until then — and on a failed read, which just keeps the cached window.
    @State private var deep: (days: [DailyMetric], series: MetricSeriesSet)?
    /// How many days the loaded `deep` spans. The deep read, once loaded, backs EVERY range
    /// (`Repository.deepDailyWindow`), so a DEEPER request has to win: now that 90D also needs its own
    /// read (it compares against the 90 days before it), keeping the first read would leave 1Y charting
    /// 90D's history while labelling it a year. 0 = nothing loaded.
    @State private var deepDays = 0

    var body: some View {
        let def = def.resolved(imperial: unitSystem == "imperial")
        let live = MetricSeriesSet(rest: repo.restSeries, napMin: repo.napSeries,
                                   effortCoverage: repo.effortCoverage,
                                   regularity: repo.regularitySeries,
                                   unmeasuredMin: repo.unmeasuredSeries)
        // The deep read is a one-shot SNAPSHOT; `repo`'s caches keep refreshing under it (the 15-min
        // tick rescores today, and an offload can land while this screen is open). So the snapshot
        // supplies only the HISTORY the 120-day cache cannot reach, and the live cache is layered back
        // over it per day. Without the overlay, one 90D tap would pin the hero, the chart and the whole
        // stats strip to the store as of that tap — for EVERY range, since `deep` backs them all — while
        // Today showed the new number, until the screen was popped.
        let source = deep.map { d in
            (days: Self.overlay(live: repo.days, onto: d.days),
             series: MetricSeriesSet(
                rest: d.series.rest.merging(live.rest) { _, fresh in fresh },
                napMin: d.series.napMin.merging(live.napMin) { _, fresh in fresh },
                effortCoverage: d.series.effortCoverage.merging(live.effortCoverage) { _, fresh in fresh },
                regularity: d.series.regularity.merging(live.regularity) { _, fresh in fresh },
                unmeasuredMin: d.series.unmeasuredMin.merging(live.unmeasuredMin) { _, fresh in fresh }))
        } ?? (days: repo.days, series: live)
        return MetricDetailView(
            def: def,
            series: def.series(days: source.days, series: source.series),
            // `repo.days` stops at the 120-day refresh window, so the detail screen has to fetch its own
            // history before it can honestly offer "1Y". Handed up as a closure so the pure content view
            // stays previewable without a live Repository.
            loadDeep: { days in
                guard days > deepDays else { return }
                guard let window = await repo.deepDailyWindow(days: days) else { return }
                // Re-check after the await: the user can switch ranges faster than the store answers,
                // and a shallower read landing last would truncate the deeper one it raced.
                guard days > deepDays else { return }
                deep = window
                deepDays = days
            })
            .toolbar(.hidden, for: .navigationBar)
    }

    /// Day-keyed overlay: every day the LIVE cache carries wins outright, the snapshot supplies the rest.
    /// Deliberately not `Repository.mergeDaily`, which resolves the imported-vs-computed LANES and fills
    /// nil fields from the loser — here the loser is merely older, so a field that has since become nil
    /// must stay nil rather than be resurrected from the snapshot.
    /// Internal rather than private so the freshness rule is pinned by a test — it is the whole reason
    /// a deep read no longer detaches this screen from the repository.
    static func overlay(live: [DailyMetric], onto snapshot: [DailyMetric]) -> [DailyMetric] {
        var byDay: [String: DailyMetric] = [:]
        for d in snapshot { byDay[d.day] = d }
        for d in live { byDay[d.day] = d }
        return byDay.values.sorted { $0.day < $1.day }
    }
}

/// Pure detail content (previewable without a live Repository). `series` is the metric's full
/// (date, value) history, oldest → newest.
private struct MetricDetailView: View {
    let def: MetricDef
    let series: [(date: Date, value: Double)]
    /// Fetch a deeper history than the dashboard caches hold. No-op in previews.
    var loadDeep: (Int) async -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var range: MetricRange = .month
    /// The chart scrub: the date of the PLOTTED POINT under the finger while the chart is being
    /// scrubbed, nil the rest of the time. `BandChart` owns every write (it resolves the gesture's
    /// continuous x to a real point, and clears on release), the hero owns the read.
    @State private var scrubbed: Date?

    /// `range` and `scrubbed` are seeded only by previews. A scrub exists only while a finger is down,
    /// and the weekly-column geometry only past the density threshold — neither is otherwise renderable
    /// anywhere it can be LOOKED at. Production omits both: it starts unscrubbed on 30D, exactly as
    /// before, so a forgotten argument here cannot make anything shipped go missing.
    init(def: MetricDef, series: [(date: Date, value: Double)],
         loadDeep: @escaping (Int) async -> Void = { _ in },
         range: MetricRange = .month, scrubbed: Date? = nil) {
        self.def = def
        self.series = series
        self.loadDeep = loadDeep
        _range = State(initialValue: range)
        _scrubbed = State(initialValue: scrubbed)
    }

    /// The charted window: the trailing `range` days ANCHORED AT THE LATEST DATA POINT (not the
    /// wall clock), so a strap that hasn't synced in a while still shows its history. The cutoff is
    /// derived with calendar day arithmetic (C3) rather than `n × 86_400` seconds, so a DST transition
    /// inside the window can't shift the boundary by an hour and clip/keep a stray day.
    private var window: [(date: Date, value: Double)] {
        guard let last = series.last?.date else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -(range.rawValue - 1), to: last) ?? last
        return series.filter { $0.date >= cutoff }
    }

    /// Wall-clock days of history this range needs. TWICE the range, because the stats strip also
    /// compares the charted window against the one immediately before it — and a comparison against a
    /// previous window that is really "however much of it the last read happened to reach" is exactly
    /// the plausible-looking number this app refuses to print. Plus the staleness of the latest point,
    /// since both windows are anchored at IT, not at the wall clock.
    private var historyDaysNeeded: Int {
        let staleness = series.last.map { max(0, Int(Date().timeIntervalSince($0.date) / 86_400)) } ?? 0
        return staleness + range.rawValue * 2
    }

    /// The typical band over the PLOTTED population: mean ± 1 sample SD. nil below 2 points or when
    /// that population is flat (a zero-height band would just underline the bars).
    ///
    /// It takes the plotted VALUES rather than the window, because past the density threshold those are
    /// weekly means (`PlottedSeries`). Banding the daily values under weekly columns would sit the band
    /// several times too tall around the marks it exists to explain — the columns and the band must be
    /// two readings of one population (017 P2).
    private func band(_ values: [Double]) -> ClosedRange<Double>? {
        guard let m = MetricMath.mean(values),
              let sd = MetricMath.standardDeviation(values), sd > 0 else { return nil }
        return (m - sd)...(m + sd)
    }

    var body: some View {
        // P8: resolve the window ONCE per render — `band`, the chart, and every stat cell read it, so
        // recomputing the computed property at each use re-filtered the full series ~4× per pass.
        let window = self.window
        // What the chart DRAWS: the measured days, or — once the window is denser than a bar per day can
        // honestly carry — one column per calendar week (017 decision 4). Resolved once and shared, so
        // the bars, the band and the hero's scrub cannot disagree about what is plotted: the hero reads
        // its readout off THESE columns, and the band is computed over their values.
        let plotted = PlottedSeries.make(window: window)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.m)

                hero(plotted)
                    .padding(.top, WM.Space.sectionTight)

                // The unit a mark SPANS has to move with the aggregation, or nothing widens: Charts
                // sizes a binned bar to fill its unit, so 53 weekly means binned at `.day` measure the
                // same 0.71 pt as the 365 daily bars they replaced — each week's mean standing on its
                // own first day with the other six blank. `plotted` already knows its period; this is
                // the one place that has to say so.
                BandChart(points: plotted.points, band: band(plotted.values),
                          domain: def.domain, selection: $scrubbed, unit: plotted.chartUnit)
                    .padding(.top, WM.Space.section)

                // Aggregation is disclosed on the chart itself, not only in the scrubbed hero: a reader
                // who never touches the chart must still be told these are weekly means (017 decision
                // 5). nil — the daily case — adds nothing, so the untouched geometry is untouched.
                if let caption = plotted.caption {
                    Text(caption)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.s)
                }

                rangeControl
                    .padding(.top, WM.Space.l)

                stats(window)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .wmAnimation(WMMotion.transition, value: range)
        // A scrub belongs to the window it was made in. `BandChart` clears on release, but a release
        // the ScrollView swallowed could leave one standing — and a stale date that happens to also be
        // a point in the NEW window would otherwise keep the hero on a day nobody is touching.
        .onChange(of: range) { _, _ in scrubbed = nil }
        // Fetch the deep history as soon as a range outruns the dashboard caches. Keyed on `range` so
        // it fires on the switch, and the loader itself no-ops once a read this deep has landed.
        .task(id: range) {
            let needed = historyDaysNeeded
            guard needed > MetricRange.cachedWindowDays else { return }
            await loadDeep(needed + MetricRange.deepWindowSlackDays)
        }
    }

    // MARK: - Header

    /// Ink back affordance (chrome stays neutral — no tint).
    private var backLink: some View {
        WMBackLink(title: "Data") { dismiss() }
    }

    // MARK: - Hero

    /// Overline label, huge display numeral + unit, delta caption vs the 30-day mean — or, while the
    /// chart is being scrubbed, the touched COLUMN's own value in the provisional register with its
    /// caption beneath. The plotted columns are passed in (never re-derived) so the numeral and the
    /// chart can only ever be reading the same marks — and so a column that is a weekly MEAN arrives
    /// carrying the fact, rather than being rendered as if it were a measured day (017 decision 5).
    private func hero(_ plotted: PlottedSeries) -> some View {
        let scrub = ScrubReadout.make(selection: scrubbed, columns: plotted.columns)
        return VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(def.label).wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                Text(scrub.map { def.string(for: $0.value) }
                     ?? series.last.map { def.string(for: $0.value) } ?? "—")
                    .font(WMType.display(64))
                    // A scrubbed numeral is a day the user is POINTING AT, not the newest reading, so
                    // it takes the provisional register `ScoreColumn` already uses for a carried
                    // score: secondary ink. Full ink stays reserved for the newest value.
                    .foregroundStyle(scrub == nil ? WM.Ground.ink : WM.Ground.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = def.unit {
                    Text(unit)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            if let scrub {
                // The date REPLACES the delta line rather than joining it: `def.delta` compares the
                // NEWEST value against its 30-day typical, so under a scrubbed numeral it would pin a
                // comparison to a number it does not describe. `def.note` below is a property of the
                // METRIC rather than of a point, so it stays in both states.
                //
                // `captionText`, not `dateText`: on a weekly column it composes the week WITH the count
                // of measured days behind the mean. The composition lives in `ScrubReadout` precisely so
                // a layout change here cannot drop the half that says the numeral is an aggregate.
                Text(scrub.captionText)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The secondary-ink numeral that marks this as "the point you are pointing at" is
                    // invisible to VoiceOver, and a bare date under a number does not say it either.
                    .accessibilityLabel(scrub.accessibilityText)
            } else if let delta = def.delta(series: series) {
                HStack(spacing: WM.Space.xs) {
                    WMDeltaText(delta: delta)
                    Text("vs 30-day typical")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            // Honest-labeling caption (approximate/estimated metrics): plain tertiary ink — it
            // qualifies the number, it is not chrome and not a warning color.
            if let note = def.note {
                Text(note)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Range control

    /// Plain-ink segmented range: equal-width text segments on a shared hairline, the active one
    /// in ink with a heavier underline. No colored chrome (color = data only).
    private var rangeControl: some View {
        HStack(spacing: 0) {
            ForEach(MetricRange.allCases) { r in
                let active = r == range
                Button {
                    range = r
                } label: {
                    VStack(spacing: WM.Space.s) {
                        Text(r.label)
                            .font(WMType.label)
                            .foregroundStyle(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                        Rectangle()
                            .fill(active ? WM.Ground.ink : WM.Ground.rule)
                            .frame(height: active ? 2 : WM.hairline)
                            .frame(height: 2, alignment: .bottom)
                    }
                    // ≥44 tall hit target (HIG); the segment already fills its width.
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }

    // MARK: - Stats

    /// Mean / min / max / slope over the charted window, then the window-over-window comparison.
    ///
    /// Deliberately over the RAW window, never the plotted columns: the strip describes the window, not
    /// the plotted geometry, and its label already says which window. Two aggregations on one screen —
    /// a "Mean" of weekly means beside a chart of weekly means — is a worse screen, and min/max over
    /// weekly means would print an extreme nobody had (017 P2).
    ///
    /// Slope is the simple least-squares fit in metric units per day, always signed — the sign IS the
    /// finding. It stays on `MetricMath.slopePerDay` (units per REAL day) and deliberately NOT on the
    /// comparison engine's `SeriesStat.slopePerDay`, which is units per ARRAY INDEX: on series this
    /// sparse (a day is only written with enough samples behind it) the two disagree under one label.
    /// The engine is used for the comparison cell and nothing else.
    private func stats(_ window: [(date: Date, value: Double)]) -> some View {
        RuleSection("Stats · \(range.label)") {
            let values = window.map(\.value)
            let readout = PeriodDeltaReadout.make(
                current: values,
                previous: PeriodDeltaReadout.previousValues(series: series, windowDays: range.rawValue),
                windowDays: range.rawValue)
            VStack(alignment: .leading, spacing: WM.Space.l) {
                HStack(alignment: .top, spacing: WM.Space.m) {
                    statCell("Mean", MetricMath.mean(values).map { def.string(for: $0) }, def.unit)
                    statCell("Min", values.min().map { def.string(for: $0) }, def.unit)
                    statCell("Max", values.max().map { def.string(for: $0) }, def.unit)
                    statCell("Slope", MetricMath.slopePerDay(window).map { def.signedString(for: $0) },
                             def.unit.map { "\($0)/d" } ?? "/d")
                }
                comparison(readout)
            }
        }
    }

    private func statCell(_ label: String, _ value: String?, _ unit: String?) -> some View {
        SignalCell(label: label, value: value ?? "—", unit: value == nil ? nil : unit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The fifth cell, on its own line so the four above keep their width: the signed change in mean
    /// against the window immediately before this one, the percent change as the arrow run, and a
    /// caption naming what was compared — or why nothing was.
    private func comparison(_ readout: PeriodDeltaReadout) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            SignalCell(label: "vs prev \(range.label)",
                       value: readout.valueText(def),
                       unit: readout.delta == nil ? nil : def.unit,
                       delta: readout.percentDelta(for: def))
            Text(readout.caption)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The detail ranges, raw value = trailing days charted.
private enum MetricRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90, year = 365

    /// What `Repository.refresh(days:)` caches. A range wider than this cannot be served from
    /// `repo.days` and needs the screen's own deep read, or it silently charts (and computes stats over)
    /// only the cached window while labelling itself with the range the user picked.
    static let cachedWindowDays = 120
    /// A little past the span the screen computed it needs. The anchor's own staleness is counted
    /// explicitly now (`historyDaysNeeded`), so this is pure margin: the read resolves its own `now`,
    /// a day or two of drift must never clip the oldest day either window depends on.
    static let deepWindowSlackDays = 45

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week:    return "7D"
        case .month:   return "30D"
        case .quarter: return "90D"
        case .year:    return "1Y"
        }
    }
}

// MARK: - Plotted columns

/// What the chart actually draws for a window: the measured days themselves, or — once the window is
/// denser than one bar per day can honestly carry — one column per calendar week, each the mean of the
/// days that week really holds (017 decision 4). View-free on purpose, so the screen and its tests read
/// the SAME rule, the way `PeriodDeltaReadout` already works.
///
/// Aggregating is not cosmetic. At 365 points a bar is under a pixel wide and a fingertip covers a
/// fortnight, so a per-day read off that chart is a fiction; meaning the weeks makes the marks and the
/// scrub describe the same thing. What it must never do is invent population: a week nobody measured
/// gets NO column (a zero-height one reads as a measured zero), and a week built from three days says
/// three rather than calling itself a week.
struct PlottedSeries {

    /// One plotted column: a measured day, or a week's mean.
    struct Column {
        /// The column's own x, and what the hero captions: the measured day itself, or — for a weekly
        /// mean — the calendar week's FIRST DAY. A week's first day is not itself a measurement, which
        /// is exactly why `period` travels beside it.
        let date: Date
        /// The measured value, or the mean of the week's measured days. Never a filled zero.
        let value: Double
        /// Measured days behind `value`. Always 1 for `.day`. For `.week` it is 1…7 and is USUALLY
        /// fewer than 7 — these series are sparse (`ScoreEngine` writes a day only once it has seen
        /// 200+ HR samples) and a window's oldest and newest weeks are partial nearly every time. The
        /// count is carried rather than assumed so the readout can print it.
        let days: Int
        let period: Period

        enum Period { case day, week }
    }

    /// Oldest → newest, the order the chart draws in.
    let columns: [Column]
    /// What the chart must disclose about its own geometry — nil when the columns ARE the measurements
    /// and there is nothing to disclose.
    let caption: String?

    /// The calendar unit ONE MARK must span, so the bar fills the period it stands for.
    ///
    /// Derived from the columns rather than passed alongside them: the geometry and the aggregation
    /// cannot then disagree, which is exactly how weekly means first shipped drawn one day wide.
    var chartUnit: Calendar.Component {
        columns.first?.period == .week ? .weekOfYear : .day
    }

    /// Past this many DAYS OF SPAN the chart stops drawing a bar per day (017 decision 4).
    ///
    /// The number is the plot's usable width over the narrowest mark still readable as a bar: inside
    /// the 20 pt gutters the chart is ~353 pt on a 393 pt phone, ~320 pt of plot area once Charts has
    /// taken its y-axis strip, and below ~2.3 pt a bar is thinner than a hairline pair —
    /// 320 / 2.3 ≈ 140.
    ///
    /// SPAN, not point count. 017 shipped this as a count and the reviewer measured what that bought:
    /// nothing in the sparse case. A binned mark fills its calendar unit, so a daily bar's width is the
    /// plot divided by the window's span in days — 60 measured days scattered over a year drew 0.73 pt
    /// marks while sitting comfortably under a 140-POINT limit. The arithmetic is identical for the
    /// dense case (365 points span 365 days, both formulations aggregate) and only the sparse case
    /// moves, which is the case that was wrong.
    static let dailySpanLimitDays = 140

    /// Whether `window` should be aggregated, decided on the SPAN it covers rather than on how many
    /// points it holds.
    ///
    /// A binned `BarMark` fills its calendar unit, so a daily mark's width is the plot divided by the
    /// window's span IN DAYS — the point count never enters it. That is why a point-count threshold
    /// could not govern legibility: a sparse year (60 measured days scattered across 365) sat under the
    /// count limit, kept daily marks, and drew them ~0.73 pt wide — exactly as unreadable as the dense
    /// year the limit existed to catch.
    ///
    /// Span answers both cases. 365 days gives ~52 weekly columns at ~4.3 pt whether the year holds 365
    /// measured days or 60; a 90-day window keeps daily marks at ~3.6 pt. And it is the DATA's span,
    /// not the range's nominal length, so a user with three months of history who taps 1Y still gets
    /// daily bars — their data does not span a year, and the chart should not pretend it does.
    static func shouldAggregate(window: [(date: Date, value: Double)],
                                calendar: Calendar = .current) -> Bool {
        guard let first = window.first?.date, let last = window.last?.date else { return false }
        let spanDays = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return spanDays > dailySpanLimitDays
    }

    /// Bucket `window` (oldest → newest) into what the chart should draw.
    static func make(window: [(date: Date, value: Double)]) -> PlottedSeries {
        guard shouldAggregate(window: window) else {
            return PlottedSeries(
                columns: window.map { Column(date: $0.date, value: $0.value, days: 1, period: .day) },
                caption: nil)
        }
        let cal = Calendar.current
        // First-seen order, not the dictionary's: `window` runs oldest → newest, so collecting the week
        // starts as they appear puts the columns in chart order without a second sort — and a week with
        // no measured day never opens a bucket, so it simply has no column. That absence IS the design:
        // a zero-height column would read as a measured zero, which on series this sparse would be the
        // commonest mark on the chart.
        var order: [Date] = []
        var buckets: [Date: [Double]] = [:]
        for point in window {
            guard let start = cal.dateInterval(of: .weekOfYear, for: point.date)?.start else { continue }
            if buckets[start] == nil { order.append(start) }
            buckets[start, default: []].append(point.value)
        }
        let columns = order.compactMap { start -> Column? in
            guard let values = buckets[start], let mean = MetricMath.mean(values) else { return nil }
            return Column(date: start, value: mean, days: values.count, period: .week)
        }
        // Plural is structural, not luck: past the threshold there are more than 140 measured days here,
        // which cannot fit in fewer than 21 calendar weeks.
        return PlottedSeries(columns: columns,
                             caption: "Weekly means — \(columns.count) weeks.")
    }

    /// The marks, in `BandChart`'s own shape.
    var points: [(Date, Double)] { columns.map { ($0.date, $0.value) } }

    /// The population the typical band must be computed over — the PLOTTED one, whatever it is.
    var values: [Double] { columns.map(\.value) }
}

// MARK: - Scrub readout

/// What the hero shows while the chart is being scrubbed: the value under the finger and the caption
/// naming what it is. View-free on purpose — the screen and its tests read the SAME rule, the way
/// `PeriodDeltaReadout` already works.
///
/// `BandChart` resolves the gesture's continuous x to a PLOTTED COLUMN and writes that column's own date
/// back, so the match here is EXACT and never a near-miss. Anything that doesn't match — a selection
/// left standing from a wider range, or no touch at all — is nil, and the hero falls back to the newest
/// value. It deliberately does not re-approximate: a 64pt numeral captioned with a day the series has
/// no row for is a reading nobody took, and on these sparse series (`ScoreEngine` writes a day only
/// once it has seen 200+ HR samples) most days have no row.
///
/// It reads `PlottedSeries.Column` rather than the raw window on purpose: the 64pt numeral is the same
/// slot in both states, so the ONLY thing separating a measured day from a weekly mean is the label —
/// and taking the columns means the fact arrives attached to the number instead of having to be
/// remembered and passed alongside it (017 decision 5).
struct ScrubReadout {
    /// The value under the finger, in the metric's own units: a measured day, or — when the chart is
    /// plotting weekly means — a MEAN. `aggregateText` is non-nil in exactly the second case.
    let value: Double
    /// The column's own day, or the week it covers ("Week of 3 Aug"). ABSOLUTE, never a relative
    /// "3 days ago" — that one goes wrong while the screen is still open (015 decision 3). The year
    /// appears only when the scrubbed column falls in a different one from the newest charted column,
    /// the same rule the Data wall's measured-date label uses: on the 1Y range a bare "Sep 3" would
    /// otherwise be read as this year's.
    let dateText: String
    /// nil when `value` is a measured day. Otherwise what the numeral IS and how many days it rests on
    /// — "mean of 5 days" — because a mean rendered in the slot that otherwise holds a measurement,
    /// without saying which it is, is the app claiming something it did not measure (017 decision 5).
    /// It carries the partial-bucket answer too: an end week built from three days says three, and is
    /// never rounded up to "a week".
    let aggregateText: String?

    /// The caption printed under the numeral: the date alone for a measured day, the week AND its day
    /// count for an aggregate. Composed HERE rather than in the view so no layout change can drop the
    /// half that says the numeral is not a measurement.
    var captionText: String {
        aggregateText.map { "\(dateText) · \($0)" } ?? dateText
    }

    /// What VoiceOver reads: the secondary-ink numeral says "provisional" to the eye and nothing at all
    /// to the screen reader, so the register has to be spoken.
    var accessibilityText: String {
        guard let aggregateText else { return "Reading for \(dateText)" }
        return "\(dateText), \(aggregateText)"
    }

    /// nil = nothing is being scrubbed, or the selection names no column the chart is drawing.
    static func make(selection: Date?, columns: [PlottedSeries.Column]) -> ScrubReadout? {
        guard let selection,
              let column = columns.first(where: { $0.date == selection }) else { return nil }
        let sameYear = columns.last.map {
            Calendar.current.isDate(column.date, equalTo: $0.date, toGranularity: .year)
        } ?? true
        // A week column's x IS its own first day, so a weekday name on it reads as a measurement it is
        // not; a measured day's weekday is worth having. Field ORDER is the locale's, not this chain's.
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if case .day = column.period { style = style.weekday(.abbreviated) }
        if !sameYear { style = style.year() }
        let text = column.date.formatted(style)

        switch column.period {
        case .day:
            return ScrubReadout(value: column.value, dateText: text, aggregateText: nil)
        case .week:
            return ScrubReadout(value: column.value, dateText: "Week of \(text)",
                                aggregateText: "mean of \(column.days) "
                                    + (column.days == 1 ? "day" : "days"))
        }
    }
}

// MARK: - Period comparison

/// The stats strip's "vs previous period" readout: the mean of the charted window against the mean of
/// the window immediately before it, same length. View-free on purpose — the slicing, the refusals and
/// the strings all live here, so the screen and its tests read the SAME rule.
///
/// Wraps `ComparisonEngine.compare(current:previous:)`. Only the comparison uses that engine: its
/// `SeriesStat.slopePerDay` is a slope per ARRAY INDEX, while the strip's own Slope cell is a slope per
/// REAL day (`MetricMath.slopePerDay`), and on series as sparse as these the two disagree under one
/// label. They are not interchangeable and must not be "unified".
///
/// Copy register (011 locked decision 5): descriptive, within-user, no condition name, no probability,
/// no call to action. Never in this copy: thermoregulation, vasodilation, impaired, poor, abnormal,
/// apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should", "talk to".
struct PeriodDeltaReadout {
    /// Signed change in mean, in the metric's own units. nil = there was nothing comparable, and the
    /// cell reads "—". Notably NOT `ComparisonEngine`'s raw delta in that case: against an empty
    /// previous period the engine returns `current.mean − 0`, i.e. the current mean wearing a plus
    /// sign — a change nobody measured.
    let delta: Double?
    /// Percent change vs the previous mean. nil when the previous mean is 0 (the ratio is undefined) or
    /// the change is exactly flat — a nil renders as NO arrow, never as "0%".
    let pct: Double?
    /// −1 / 0 / +1 on the means, straight off `ComparisonEngine`.
    let direction: Int
    /// Days that carried a value in each window — said out loud in the caption, so two means built on
    /// very different amounts of wear can be weighed rather than just compared.
    let currentDays: Int
    let previousDays: Int
    /// What was compared, or why nothing was.
    let caption: String

    /// The values of the window immediately BEFORE the charted one: same length, same calendar-day
    /// arithmetic the charted window uses (C3 — day arithmetic, not `n × 86_400`), the charted window's
    /// own first day excluded.
    ///
    /// nil when the loaded series does not start on or before that window's first day. The screen cannot
    /// tell "there is no older data" from "older data is not loaded yet" — `deepDailyWindow` reads a
    /// bounded span — so it refuses rather than compare this window against whatever fragment of the
    /// previous one happens to be in memory.
    static func previousValues(series: [(date: Date, value: Double)], windowDays: Int) -> [Double]? {
        guard windowDays > 0, let earliest = series.first?.date, let last = series.last?.date else { return nil }
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -(windowDays - 1), to: last),
              let prevStart = cal.date(byAdding: .day, value: -(windowDays * 2 - 1), to: last),
              earliest <= prevStart else { return nil }
        return series.filter { $0.date >= prevStart && $0.date < start }.map(\.value)
    }

    /// Build the readout. `previous` is nil when there is no window to vouch for (see `previousValues`);
    /// either side empty means no comparison, not a zero.
    static func make(current: [Double], previous: [Double]?, windowDays: Int) -> PeriodDeltaReadout {
        guard let previous, !previous.isEmpty, !current.isEmpty else {
            return PeriodDeltaReadout(delta: nil, pct: nil, direction: 0,
                                      currentDays: current.count, previousDays: previous?.count ?? 0,
                                      caption: "No comparable \(windowDays)-day window before this one.")
        }
        let c = ComparisonEngine.compare(current: current, previous: previous)
        return PeriodDeltaReadout(
            delta: c.delta,
            // Flat is flat: the engine's pctChange is a true 0 there, but "▲ 0%" reads as a measured
            // move in a direction, which it is not.
            pct: c.direction == 0 ? nil : c.pctChange,
            direction: c.direction,
            currentDays: c.current.n, previousDays: c.previous.n,
            caption: "Mean vs the preceding \(windowDays) days · "
                + "\(c.current.n) days measured vs \(c.previous.n).")
    }

    /// The cell's numeral: the signed change in the metric's own format, or an em dash.
    func valueText(_ def: MetricDef) -> String {
        delta.map { def.signedString(for: $0) } ?? "—"
    }

    /// The percent change as a magnitude string — "<1%" for a real but sub-percent move, since "%.0f"
    /// would round it to a "0%" that contradicts the arrow beside it. nil when there is no percent.
    var percentText: String? {
        guard let pct else { return nil }
        let magnitude = abs(pct)
        return magnitude < 0.5 ? "<1%" : String(format: "%.0f%%", magnitude)
    }

    /// The percent change as the cell's arrow run, colored by what a move in THIS metric means
    /// (HRV up is good, RHR up is bad, Effort is just information).
    func percentDelta(for def: MetricDef) -> WMDelta? {
        // A percent change needs a RATIO scale — a true zero to divide by. `.signedDecimal` marks the
        // metrics that are a signed deviation from the user's own baseline (skin temp), whose mean sits
        // near zero by construction, so `(cur − prev) / |prev|` has an arbitrary denominator and no
        // bound: a 0.13 °C move against a +0.02 °C baseline prints "▼ 650%". The signed change in the
        // metric's own units is the honest readout there, so the arrow is withheld and only it remains.
        if case .signedDecimal = def.format { return nil }
        guard let text = percentText else { return nil }
        let up = direction > 0
        return WMDelta(up: up, text: text, sentiment: def.sentiment(up: up))
    }
}

// MARK: - Previews

#Preview("MetricDetail — light") {
    MetricDetailSpecimen().preferredColorScheme(.light)
}

#Preview("MetricDetail — dark") {
    MetricDetailSpecimen().preferredColorScheme(.dark)
}

#Preview("MetricDetail — sleep h:mm") {
    MetricDetailSpecimen(key: "sleep").preferredColorScheme(.light)
}

// The shared wall fixture is 30 days, so on the default 30D range it has no preceding window and the
// comparison cell correctly reads "—". These two carry a 90-day history, the compared state.
#Preview("MetricDetail — vs previous, light") {
    MetricDetailSpecimen(syntheticDays: 90).preferredColorScheme(.light)
}

#Preview("MetricDetail — vs previous, dark") {
    MetricDetailSpecimen(syntheticDays: 90).preferredColorScheme(.dark)
}

// The scrubbed hero. It exists only while a finger is on the chart, so it can be neither screenshot
// nor gesture-tested — these two hard-code the selection so the state at least has somewhere it can be
// LOOKED at: secondary-ink numeral, the touched day's own date where the vs-typical delta usually sits.
#Preview("MetricDetail — scrubbed, light") {
    MetricDetailSpecimen(scrubbedColumnsBack: 6).preferredColorScheme(.light)
}

#Preview("MetricDetail — scrubbed, dark") {
    MetricDetailSpecimen(scrubbedColumnsBack: 6).preferredColorScheme(.dark)
}

// Weekly columns (017 P2), scrubbed. A year of dense daily history is what turns the chart to weekly
// means, and `DemoSeed` carries 30 days — so on the simulator this state is unreachable and these two
// previews are the ONLY place it can be looked at. What to check: the columns are weeks, the caption
// under the chart says so, and the scrubbed hero's caption says "Week of … · mean of N days" rather
// than presenting a mean as a measured day (decision 5).
#Preview("MetricDetail — weekly columns, light") {
    MetricDetailSpecimen(syntheticDays: 400, range: .year, scrubbedColumnsBack: 6)
        .preferredColorScheme(.light)
}

#Preview("MetricDetail — weekly columns, dark") {
    MetricDetailSpecimen(syntheticDays: 400, range: .year, scrubbedColumnsBack: 6)
        .preferredColorScheme(.dark)
}

private struct MetricDetailSpecimen: View {
    var key: String = "recovery"
    /// nil = the shared 30-day wall fixture. A count synthesizes a daily history that long instead, so
    /// the "vs previous" cell has a window before the charted one to compare against.
    var syntheticDays: Int?
    /// The range the detail opens on. Production always takes the default; a preview needs 1Y to reach
    /// the weekly-column geometry at all.
    var range: MetricRange = .month
    /// nil = unscrubbed, the state everything else previews. A count renders the hero as if the chart
    /// were being scrubbed that many COLUMNS back from the newest — resolved through `PlottedSeries`,
    /// so it lands on a real plotted mark in both geometries: a measured day at 30D, a week's first day
    /// at 1Y. A raw series date would simply not match a weekly column and the hero would sit unscrubbed.
    var scrubbedColumnsBack: Int?

    var body: some View {
        let def = MetricCatalog.all.first { $0.key == key }!
        let series = syntheticDays.map(Self.synthetic(days:))
            ?? def.series(days: DataPreviewFixture.days,
                          series: MetricSeriesSet(rest: DataPreviewFixture.rest))
        // The fixtures are unbroken daily runs, so the trailing `range` ROWS are the trailing `range`
        // DAYS — i.e. the same window the view derives by date. Fine for a preview; the view keeps the
        // date arithmetic, which is what a real (sparse) series needs.
        let columns = PlottedSeries.make(window: Array(series.suffix(range.rawValue))).columns
        NavigationStack {
            MetricDetailView(def: def, series: series, range: range,
                             scrubbed: scrubbedColumnsBack.flatMap { back -> Date? in
                                 let i = columns.count - 1 - back
                                 return columns.indices.contains(i) ? columns[i].date : nil
                             })
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Deterministic daily wander ending today, in the same spirit as `DataPreviewFixture` — the older
    /// half sits lower, so the comparison cell has something to report.
    private static func synthetic(days: Int) -> [(date: Date, value: Double)] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        return (0..<days).compactMap { i -> (date: Date, value: Double)? in
            guard let date = cal.date(byAdding: .day, value: i, to: start) else { return nil }
            let x = Double(i)
            return (date: date, value: 54 + x * 0.12 + 9 * sin(x / 4.5))
        }
    }
}
