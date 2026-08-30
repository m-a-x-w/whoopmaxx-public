import SwiftUI
import StrapStore

/// The data tab: plain rule-underlined search over the metric catalog, then a 2-column
/// `MetricWall` of every catalog metric that HAS data. Tap a tile → `MetricDetailScreen` push
/// (the shell's per-tab `NavigationStack` hosts the push; this screen draws its own header).
struct DataScreen: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        DataRoot(repo: repo)
    }
}

/// Observes the repository and owns tile → detail navigation.
private struct DataRoot: View {
    @ObservedObject var repo: Repository
    @State private var query = ""
    @State private var selection: MetricDef?

    var body: some View {
        DataWallView(days: repo.days,
                     series: MetricSeriesSet(rest: repo.restSeries, napMin: repo.napSeries,
                                             effortCoverage: repo.effortCoverage,
                                             regularity: repo.regularitySeries,
                                             unmeasuredMin: repo.unmeasuredSeries),
                     loaded: repo.loaded,
                     refreshSeq: repo.refreshSeq, query: $query) { def in
            selection = def
        }
        .navigationDestination(item: $selection) { def in
            MetricDetailScreen(def: def, repo: repo)
        }
    }
}

/// Pure wall content (previewable without a live Repository): header, search field, tile wall.
private struct DataWallView: View {
    let days: [DailyMetric]
    let series: MetricSeriesSet
    let loaded: Bool
    /// Bumps only on a real (diff-guarded) repository change — the rebuild trigger for the memo (P6).
    let refreshSeq: Int
    @Binding var query: String
    var onSelect: (MetricDef) -> Void

    @FocusState private var searchFocused: Bool

    /// Metric/Imperial pref → resolves the catalog (skin temp °C↔°F). @AppStorage so a Units change rebuilds
    /// the series below (via the onChange), re-rendering every tile's value + unit live.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    /// Catalog metrics that have at least one data point, with their series built once. Memoized in
    /// @State (P6) and rebuilt only when the repository republishes (`refreshSeq`) — NOT on every search
    /// keystroke, where only the cheap fuzzy filter below depends on `query`.
    @State private var present: [(def: MetricDef, series: [(date: Date, value: Double)])] = []

    /// Rebuild every catalog metric's series from the current days / keyed series. O(catalog × days);
    /// runs on a repo change (and first appearance), never per keystroke.
    private func rebuildSeries() {
        let imperial = unitSystem == "imperial"
        present = MetricCatalog.all.compactMap { catalogDef in
            let def = catalogDef.resolved(imperial: imperial)
            let s = def.series(days: days, series: series)
            return s.isEmpty ? nil : (def, s)
        }
    }

    var body: some View {
        // Match the label OR any alias — a metric renamed to the app's own vocabulary must stay findable
        // by the name it used to carry (see `MetricDef.searchAliases`).
        let matched = present.filter { row in
            MetricCatalog.fuzzyMatch(query: query, in: row.def.label)
                || row.def.searchAliases.contains { MetricCatalog.fuzzyMatch(query: query, in: $0) }
        }
        // The staleness reference for every tile below, taken over EVERY present metric — not the
        // filtered `matched`, so typing a search can never change which tiles carry a date. nil only
        // for an empty wall, which draws no tiles at all.
        let freshest = WallFreshness.newest(present.compactMap { $0.series.last?.date })

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Data")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .padding(.top, WM.Space.m)

                searchField
                    .padding(.top, WM.Space.l)

                if matched.isEmpty {
                    emptyText(anyData: !present.isEmpty)
                        .padding(.top, WM.Space.section)
                } else {
                    MetricWall(items: matched.map { tileModel($0, freshest: freshest) }) { model in
                        if let def = MetricCatalog.def(forLabel: model.label) { onSelect(def) }
                    }
                    .padding(.top, WM.Space.sectionTight)
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .scrollDismissesKeyboard(.immediately)
        // Build on first appearance and whenever the repo republishes; typing re-evaluates body (the
        // cheap fuzzy filter) but leaves `refreshSeq` unchanged, so the series are never rebuilt per key.
        .onChange(of: refreshSeq, initial: true) { _, _ in rebuildSeries() }
        // A Units change re-resolves the catalog (skin temp °C↔°F) — cheap, and NOT tied to refreshSeq.
        .onChange(of: unitSystem) { _, _ in rebuildSeries() }
    }

    /// Plain search field on a hairline rule (heavier while focused) — no box, no chrome.
    private var searchField: some View {
        VStack(spacing: WM.Space.s) {
            HStack(spacing: WM.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                TextField("Search metrics", text: $query)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .tint(WM.Ground.ink)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .frame(minWidth: 44, minHeight: 44)   // HIG tap target (glyph stays caption-sized)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            Rectangle()
                .fill(searchFocused ? WM.Ground.ruleHeavy : WM.Ground.rule)
                .frame(height: WM.hairline)
        }
    }

    /// `freshest` has NO default: the caption is the whole point of this wave's Data packet, and a
    /// defaulted reference is a value the one call site can quietly stop passing while the build stays
    /// green and the tiles stay undated.
    private func tileModel(_ entry: (def: MetricDef, series: [(date: Date, value: Double)]),
                           freshest: Date?) -> MetricTileModel {
        let latest = entry.series.last!   // `present` guarantees non-empty
        return MetricTileModel(label: entry.def.label,
                               value: entry.def.string(for: latest.value),
                               unit: WallFreshness.caption(unit: entry.def.unit,
                                                           measured: latest.date, freshest: freshest),
                               delta: entry.def.delta(series: entry.series))
    }

    /// Plain-voice empty states: not loaded yet / genuinely no data / search found nothing.
    private func emptyText(anyData: Bool) -> some View {
        Text(anyData ? "No metrics match \u{201C}\(query)\u{201D}."
             : loaded ? "No data yet. Metrics appear after your first synced night."
             : "Loading…")
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
    }
}

// MARK: - Tile freshness

/// When a wall tile has to say WHEN its value was measured. Pure and value-in/value-out so the rule
/// is testable without a view host (`Tests/StaleTileTests.swift`).
///
/// The reference is the wall's OWN freshest point, never the wall clock: a wearer who last synced
/// three days ago has a wall that is uniformly three days old, and captioning all of it would say
/// nothing about any tile. What the caption exists to catch is ONE metric lagging the others — the
/// Naps tile still showing last Tuesday's credit, an imported-only SpO2 that stopped arriving — where
/// the wall otherwise prints `series.last` with nothing to place it in time.
///
/// Today HIDES a stale value where the wall dates it. That is deliberate (015 decision 4): the two
/// screens answer different questions, both answers are honest, and this wave does not unify them.
enum WallFreshness {

    /// How many whole calendar days a tile may lag the wall's freshest point and still read as
    /// current. One, because a fully-synced wall is ALREADY ragged by a day: last night's overnight
    /// vitals land on yesterday's key beside a step count still accumulating on today's. Captioning
    /// that would put a date on nearly every tile and so mean nothing.
    static let currentWithinDays = 1

    /// The wall's freshest point — the newest measured date across every present metric.
    static func newest(_ dates: [Date]) -> Date? { dates.max() }

    /// The caption run a tile shows beside its numeral: its unit, plus — only when this metric's
    /// latest point lags the wall — the date that value was measured.
    ///
    /// The tile has ONE caption slot (`MetricTileModel.unit`, which `SignalCell` renders as
    /// caption-sized tertiary ink on the numeral's baseline), so the date joins the unit there behind
    /// the same "·" separator `ScoreColumn` uses for its "carried · Tue" caveat, rather than a second
    /// line the component does not have.
    static func caption(unit: String?, measured: Date, freshest: Date?) -> String? {
        guard let day = measuredLabel(measured: measured, freshest: freshest) else { return unit }
        guard let unit else { return day }
        return "\(unit) · \(day)"
    }

    /// The measured date as a label, or nil while the value is current. ABSOLUTE, never a relative
    /// "3 days ago" — that one goes wrong while the screen is still open (015 decision 3).
    private static func measuredLabel(measured: Date, freshest: Date?) -> String? {
        guard let freshest,
              // `TodayModel`'s counter rather than a second one: it counts calendar days by day
              // ordinality, which stays exact across the 23-hour DST day where `dateComponents([.day])`
              // truncates one short (see the note on `DayKey.date(from:)`).
              let age = TodayModel.daysBetween(TodayModel.key(from: measured),
                                               TodayModel.key(from: freshest)),
              age > currentWithinDays
        else { return nil }
        // The year appears only once the two fall in different years: a metric that stopped arriving
        // months ago would otherwise read a bare "Nov 3" and be taken for this year's.
        return Calendar.current.isDate(measured, equalTo: freshest, toGranularity: .year)
            ? measured.formatted(.dateTime.month(.abbreviated).day())
            : measured.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

// MARK: - Previews

#Preview("DataScreen — light") {
    DataWallSpecimen().preferredColorScheme(.light)
}

#Preview("DataScreen — dark") {
    DataWallSpecimen().preferredColorScheme(.dark)
}

// The Naps series stops four days before every other metric, so its tile — and only its tile —
// carries the measured date.
#Preview("DataScreen — stale tile, light") {
    DataWallSpecimen(series: DataPreviewFixture.laggingNaps).preferredColorScheme(.light)
}

#Preview("DataScreen — stale tile, dark") {
    DataWallSpecimen(series: DataPreviewFixture.laggingNaps).preferredColorScheme(.dark)
}

private struct DataWallSpecimen: View {
    var series = MetricSeriesSet(rest: DataPreviewFixture.rest)
    @State private var query = ""

    var body: some View {
        NavigationStack {
            DataWallView(days: DataPreviewFixture.days, series: series,
                         loaded: true, refreshSeq: 1, query: $query) { _ in }
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Deterministic 30-day fixture for previews (sine-wander around plausible values; no store needed).
enum DataPreviewFixture {
    static let days: [DailyMetric] = {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date()))!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (0..<30).map { i in
            let x = Double(i)
            let sleepMin = 430 + 50 * sin(x / 3.1) + Double((i * 17) % 23)
            let deep = sleepMin * 0.20, rem = sleepMin * 0.23
            return DailyMetric(
                day: fmt.string(from: cal.date(byAdding: .day, value: i, to: start)!),
                totalSleepMin: sleepMin,
                efficiency: 0.90 + 0.04 * sin(x / 2.3),   // 0–1 fraction (MetricCatalog scales ×100 for display)
                deepMin: deep, remMin: rem, lightMin: sleepMin - deep - rem,
                disturbances: 5 + (i % 4),
                restingHr: 52 + Int(3 * sin(x / 4.2)),
                avgHrv: 74 + 12 * sin(x / 3.7),
                recovery: 62 + 18 * sin(x / 4.5),
                strain: 24 + 16 * sin(x / 2.9),
                exerciseCount: i % 2,
                spo2Pct: 96.5,
                skinTempDevC: 0.25 * sin(x / 5.0),
                respRateBpm: 14.4 + 0.6 * sin(x / 3.3))
        }
    }()

    static let rest: [String: Double] = Dictionary(uniqueKeysWithValues:
        days.enumerated().map { ($0.element.day, 74 + 14 * sin(Double($0.offset) / 3.9)) })

    /// The default wall plus a Naps series that stops four days early — one metric lagging the rest,
    /// which is the state `WallFreshness` captions. Everything else keeps today's point and stays bare.
    static let laggingNaps = MetricSeriesSet(
        rest: rest,
        napMin: Dictionary(uniqueKeysWithValues:
            days.dropLast(4).enumerated().map { ($0.element.day, 30 + 20 * sin(Double($0.offset) / 2.7)) }))
}
