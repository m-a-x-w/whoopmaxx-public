import SwiftUI
import StrapStore

/// The Data tab (037): `TabHeader`, a `track` search capsule, an All · Charge · Effort · Rest
/// domain filter, then every catalog metric that HAS data as a hairline-split `MetricWall` row — name,
/// delta, value and a `.compact` `LineScale` placing today inside the metric's own recent window —
/// grouped under Charge / Effort / Rest labels while the filter is All. "Labs" closes the tab: Signal
/// Lab and Body Clock open as full-screen covers, and Health monitor pushes for the newest night that
/// carries vitals. Tap a row → `MetricDetailScreen` push (the shell's per-tab `NavigationStack` hosts
/// every push; this screen draws its own header).
struct DataScreen: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        DataRoot(repo: repo)
    }
}

/// Observes the repository and owns every navigation off the tab: row → metric detail, the two Labs
/// covers and the Health monitor push.
private struct DataRoot: View {
    @ObservedObject var repo: Repository
    @State private var query = ""
    @State private var selection: MetricDef?
    /// Signal Lab / Body Clock. One `item:` state rather than a Bool per cover, so the two are mutually
    /// exclusive by construction (the idiom they moved here with from the old More tab).
    @State private var cover: DataLabCover?
    /// The Health monitor push — carries the day key the Labs row resolved.
    @State private var monitorDay: DataMonitorDay?

    var body: some View {
        DataWallView(days: repo.days,
                     series: MetricSeriesSet(rest: repo.restSeries, napMin: repo.napSeries,
                                             effortCoverage: repo.effortCoverage,
                                             regularity: repo.regularitySeries,
                                             unmeasuredMin: repo.unmeasuredSeries),
                     loaded: repo.loaded,
                     refreshSeq: repo.refreshSeq, query: $query,
                     onSelect: { selection = $0 },
                     onLab: { lab in
                         switch lab {
                         case .signalLab:               cover = .signalLab
                         case .bodyClock:               cover = .bodyClock
                         case .healthMonitor(let day):  monitorDay = DataMonitorDay(day: day)
                         }
                     })
            .navigationDestination(item: $selection) { def in
                MetricDetailScreen(def: def, repo: repo)
            }
            .navigationDestination(item: $monitorDay) { ref in
                HealthMonitorScreen(day: ref.day, backLabel: "Data")
            }
            // AppRoot / Repository / LiveState / alarm settings all propagate through the cover's
            // environment (injected at the app root), so each case is a bare screen init.
            .fullScreenCover(item: $cover) { cover in
                switch cover {
                case .signalLab: SignalLabScreen()
                case .bodyClock: BodyClockScreen()
                }
            }
    }
}

/// Where a Labs row goes.
private enum DataLab: Equatable {
    case signalLab
    case bodyClock
    /// The Health monitor for this day key.
    case healthMonitor(day: String)
}

/// The two Labs destinations that are immersive covers rather than pushes.
private enum DataLabCover: String, Identifiable {
    case signalLab, bodyClock
    var id: String { rawValue }
}

/// The Health monitor push's day key, wrapped so it can drive `navigationDestination(item:)`.
private struct DataMonitorDay: Identifiable, Hashable {
    let day: String
    var id: String { day }
}

/// Pure tab content (previewable without a live Repository): header, search capsule, domain filter,
/// grouped metric rows and Labs.
private struct DataWallView: View {
    let days: [DailyMetric]
    let series: MetricSeriesSet
    let loaded: Bool
    /// Bumps only on a real (diff-guarded) repository change — the rebuild trigger for the memo (P6).
    let refreshSeq: Int
    @Binding var query: String
    var onSelect: (MetricDef) -> Void
    var onLab: (DataLab) -> Void

    /// Metric/Imperial pref → resolves the catalog (skin temp °C↔°F). @AppStorage so a Units change rebuilds
    /// the rows below (via the onChange), re-rendering every row's value + unit live.
    @AppStorage(TempUnit.systemKey) private var unitSystem = "metric"

    /// The domain filter; nil = All. Combined with the search query, never instead of it.
    @State private var domain: WM.Domain?

    /// One metric row, fully derived: the CATALOG def (unresolved — `MetricDetailScreen` resolves units
    /// itself, and resolving twice would convert skin temp twice) plus the row's model.
    private struct WallRow {
        let def: MetricDef
        let model: MetricTileModel
    }

    /// One labelled group while the filter is All.
    private struct DomainGroup: Identifiable {
        let domain: WM.Domain
        let rows: [WallRow]
        var id: WM.Domain { domain }
    }

    /// Every catalog metric that has at least one data point, as finished row models — value, lag caption,
    /// delta and line scale all computed here. Memoized in @State (P6) and rebuilt only when the repository
    /// republishes (`refreshSeq`) or Units flips — NOT on a search keystroke or a filter tap, where only the
    /// cheap filter in `body` depends on `query` / `domain`.
    @State private var rows: [WallRow] = []
    /// The newest day that carries any of the four overnight vitals the Health monitor reads; nil hides
    /// its Labs row, since there is nothing for it to show. Resolved in the same rebuild, never in `body`.
    @State private var healthDay: String?

    /// Rebuild every catalog metric's row from the current days / keyed series. O(catalog × days); runs
    /// on a repo change (and first appearance), never per keystroke.
    private func rebuildRows() {
        let imperial = unitSystem == "imperial"
        let built = MetricCatalog.all.compactMap { catalogDef -> (def: MetricDef, shown: MetricDef,
                                                                    series: [(date: Date, value: Double)])? in
            let shown = catalogDef.resolved(imperial: imperial)
            let s = shown.series(days: days, series: series)
            return s.isEmpty ? nil : (catalogDef, shown, s)
        }
        // The staleness reference for every row, taken over EVERY present metric — so neither a search nor
        // the domain filter can ever change which rows carry a date.
        let freshest = WallFreshness.newest(built.compactMap { $0.series.last?.date })
        rows = built.compactMap { entry in
            Self.tileModel(entry.shown, series: entry.series, freshest: freshest)
                .map { WallRow(def: entry.def, model: $0) }
        }
        healthDay = days.last(where: Self.hasVitals)?.day
    }

    var body: some View {
        // Match the label OR any alias — a metric renamed to the app's own vocabulary must stay findable
        // by the name it used to carry (see `MetricDef.searchAliases`).
        let visible = rows.filter { row in
            (domain == nil || row.def.domain == domain)
                && (MetricCatalog.fuzzyMatch(query: query, in: row.def.label)
                    || row.def.searchAliases.contains { MetricCatalog.fuzzyMatch(query: query, in: $0) })
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabHeader("Data", subtitle: subtitle)

                WMSearchField(placeholder: searchPrompt, text: $query)
                    .padding(.top, WM.Space.l)

                WMTextTabs(options: Self.domainOptions, selection: $domain, label: "Show")
                    .padding(.top, WM.Space.s)

                metrics(visible)

                labs
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)   // same header seat as Today / Rest / Log
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .scrollDismissesKeyboard(.immediately)
        // Build on first appearance and whenever the repo republishes; typing re-evaluates body (the
        // cheap filter) but leaves `refreshSeq` unchanged, so the rows are never rebuilt per key.
        .onChange(of: refreshSeq, initial: true) { _, _ in rebuildRows() }
        // A Units change re-resolves the catalog (skin temp °C↔°F) — cheap, and NOT tied to refreshSeq.
        .onChange(of: unitSystem) { _, _ in rebuildRows() }
    }

    // MARK: Header

    /// "19 metrics · dot = today in your 30 days". Shorter than the board's "bar = where today sits in
    /// your 30 days", which measures ~304 pt at the label role and wraps inside the 24 pt gutters on a
    /// 375 pt phone — and the Line language draws a dot on a line, not a bar. Absent while there is no row
    /// for it to count (the empty/loading copy below says why).
    private var subtitle: String? {
        guard !rows.isEmpty else { return nil }
        return "\(rows.count) \(rows.count == 1 ? "metric" : "metrics") · dot = today in your 30 days"
    }

    // MARK: Search

    /// The search field's placeholder (`WMSearchField`), counting what it searches once there is
    /// something to count.
    private var searchPrompt: String {
        rows.isEmpty ? "Search metrics" : "Search \(rows.count) metrics"
    }

    // MARK: Domain filter

    /// All · Charge · Effort · Rest, in the domains' own order.
    private static let domainOptions: [(value: WM.Domain?, name: String)] = {
        var options: [(value: WM.Domain?, name: String)] = [(value: nil, name: "All")]
        for d in WM.Domain.allCases { options.append((value: d, name: d.displayName)) }
        return options
    }()

    // MARK: Metric rows

    /// The matched rows: one labelled group per domain (catalog order inside each) while the filter is
    /// All, one plain list while it names a domain — the tab under the search already says which.
    @ViewBuilder
    private func metrics(_ visible: [WallRow]) -> some View {
        if visible.isEmpty {
            emptyText
                .padding(.top, WM.Space.sectionTight)
        } else if domain == nil {
            let groups = WM.Domain.allCases.compactMap { d -> DomainGroup? in
                let members = visible.filter { $0.def.domain == d }
                return members.isEmpty ? nil : DomainGroup(domain: d, rows: members)
            }
            ForEach(groups) { group in
                RuleSection(group.domain.displayName,
                            topGap: group.id == groups.first?.id ? WM.Space.l : WM.Space.sectionTight) {
                    wall(group.rows)
                }
            }
        } else {
            wall(visible)
                .padding(.top, WM.Space.s)
        }
    }

    private func wall(_ rows: [WallRow]) -> some View {
        MetricWall(items: rows.map(\.model)) { model in
            if let def = MetricCatalog.def(forLabel: model.label) { onSelect(def) }
        }
    }

    /// `freshest` has NO default: the lag caption is the whole point of the Data packet it came from (015),
    /// and a defaulted reference is a value the one call site can quietly stop passing while the build
    /// stays green and the rows stay undated.
    private static func tileModel(_ def: MetricDef, series: [(date: Date, value: Double)],
                                  freshest: Date?) -> MetricTileModel? {
        guard let latest = series.last else { return nil }
        return MetricTileModel(label: def.label,
                               value: def.string(for: latest.value),
                               unit: WallFreshness.caption(unit: def.unit,
                                                           measured: latest.date, freshest: freshest),
                               delta: def.delta(series: series),
                               domain: def.domain,
                               scale: def.scale(series: series))
    }

    /// Plain-voice empty states: not loaded yet / genuinely no data / a domain with nothing yet / search
    /// found nothing.
    private var emptyText: some View {
        Text(emptyMessage)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyMessage: String {
        if rows.isEmpty {
            return loaded ? "No data yet. Metrics appear after your first synced night." : "Loading…"
        }
        // `fuzzyMatch` ignores whitespace, so a blank-ish query filters nothing: an empty list then means
        // the chosen domain simply has no data yet, and it must not be reported as a failed search.
        let searching = !query.allSatisfy(\.isWhitespace)
        switch (domain, searching) {
        case (let d?, false): return "No \(d.displayName) metric has data yet."
        case (let d?, true):  return "No \(d.displayName) metrics match \u{201C}\(query)\u{201D}."
        case (nil, _):        return "No metrics match \u{201C}\(query)\u{201D}."
        }
    }

    // MARK: Labs

    /// The instruments that moved here from the old More tab (037 IA-1), plus a second door to the
    /// Health monitor. Shown whatever the search or filter says — they are places, not metrics.
    private var labs: some View {
        RuleSection("Labs", topGap: WM.Space.section) {
            VStack(spacing: 0) {
                WMNavRow(title: "Signal Lab",
                         subtitle: "Raw sensors, HRV, detection, stages",
                         hint: "Opens a raw-sensor oscilloscope of the strap's live and stored signals") {
                    onLab(.signalLab)
                }
                WMRule()
                WMNavRow(title: "Body Clock",
                         subtitle: "Thermal midnight & jet-lag plan",
                         hint: "Opens your body-clock readout and jet-lag planner") {
                    onLab(.bodyClock)
                }
                if let healthDay {
                    WMRule()
                    WMNavRow(title: "Health monitor",
                             subtitle: "Vitals against your range",
                             hint: "Opens the health monitor for your latest night with vitals") {
                        onLab(.healthMonitor(day: healthDay))
                    }
                }
            }
        }
    }

    /// Whether a day carries any of the four overnight vitals `HealthMonitorModel.compute` bands — the
    /// rows the Health monitor screen would otherwise print as "—".
    private static func hasVitals(_ d: DailyMetric) -> Bool {
        d.restingHr != nil || d.avgHrv != nil || d.respRateBpm != nil || d.skinTempDevC != nil
    }
}

// MARK: - Tile freshness

/// When a Data row ("tile" in the names below, from when the rows were a 2-column tile wall) has to
/// say WHEN its value was measured. Pure and value-in/value-out so the rule is testable without a view
/// host (`Tests/StaleTileTests.swift`).
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
    /// The row has ONE caption slot (`MetricTileModel.unit`, which `MetricTile` renders as caption-sized
    /// tertiary ink on the numeral's baseline), so the date joins the unit there behind the same "·"
    /// separator the app uses for its "carried · Tue" caveat, rather than a second line the row does not
    /// have.
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

// The Naps series stops four days before every other metric, so its row — and only its row — carries
// the measured date.
#Preview("DataScreen — stale row, light") {
    DataWallSpecimen(series: DataPreviewFixture.laggingNaps).preferredColorScheme(.light)
}

#Preview("DataScreen — stale row, dark") {
    DataWallSpecimen(series: DataPreviewFixture.laggingNaps).preferredColorScheme(.dark)
}

private struct DataWallSpecimen: View {
    var series = MetricSeriesSet(rest: DataPreviewFixture.rest)
    @State private var query = ""

    var body: some View {
        NavigationStack {
            DataWallView(days: DataPreviewFixture.days, series: series,
                         loaded: true, refreshSeq: 1, query: $query,
                         onSelect: { _ in }, onLab: { _ in })
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

    /// The default rows plus a Naps series that stops four days early — one metric lagging the rest,
    /// which is the state `WallFreshness` captions. Everything else keeps today's point and stays bare.
    static let laggingNaps = MetricSeriesSet(
        rest: rest,
        napMin: Dictionary(uniqueKeysWithValues:
            days.dropLast(4).enumerated().map { ($0.element.day, 30 + 20 * sin(Double($0.offset) / 2.7)) }))
}
