import SwiftUI
import StrapStore
import StrapAnalytics

/// Charge detail (037, pushed from Today's Charge hero): back to Today → "Charge" over the scored
/// day → the Charge as a hero numeral on its line (band = the typical range) → "What shaped it", one
/// row per driver (name and value, its typical, a centered `Diverge` line and the signed points —
/// `RecoveryScorer.chargeDrivers` via ScoreEngine, so the rows can never disagree with the headline
/// score) → "Last 30 days" as a `SparkHistory`.
struct ChargeDetailScreen: View {
    /// Merged daily rows, oldest → newest (`repo.days`).
    let days: [DailyMetric]
    /// The driver breakdown for the newest scored day (`scores.results`, matched by day). Empty
    /// until whoopmaxx has scored a night itself — imported-only history carries no drivers.
    let drivers: [ChargeDriver]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Every number on the screen from ONE clamped pass over `days`, resolved once per body pass.
        let history = ChargeHistory(days: days)
        // The pull that reaches either end of a driver's line: the day's largest, but never under 10
        // points, so a quiet day's ±2 does not stretch to look like a dramatic one.
        let span = Double(max(10, drivers.map { abs($0.deltaPoints) }.max() ?? 0))

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WMBackLink(title: "Today") { dismiss() }
                    .padding(.top, WM.Space.s)

                TabHeader("Charge", subtitle: history.dayLabel)

                hero(history)
                    .padding(.top, WM.Space.l + WM.Space.s)

                RuleSection("What shaped it", topGap: WM.Space.sectionTight + WM.Space.s) {
                    if drivers.isEmpty {
                        Text("The driver breakdown appears once whoopmaxx scores a night itself — imported history carries the scores but not the working-out.")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(drivers.enumerated()), id: \.offset) { i, driver in
                                if i > 0 {
                                    WMRule()
                                }
                                DriverRow(driver: driver, span: span)
                            }
                        }
                    }
                }

                RuleSection("Last 30 days", topGap: WM.Space.sectionTight + WM.Space.s) {
                    if history.values.isEmpty {
                        Text("No scored days yet.")
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: WM.Space.s) {
                            // The latest point is spoken, never drawn: the hero above prints it.
                            SparkHistory(values: history.values, domain: .charge,
                                         range: 0...100, height: SparkHistory.chart,
                                         spokenValue: { String(Int($0.rounded())) },
                                         xLabels: history.xLabels)
                            Text("Shaded band = your typical range")
                                .font(WMType.caption)
                                .foregroundStyle(WM.Ground.inkTertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            // `sectionLoose` (matching Metric/Workout/HealthMonitor detail): pushed screens sit on the
            // shell's NavigationStack, whose `.safeAreaPadding(.bottom)` lands on the TAB ROOT only — so
            // each pushed screen self-pads its last rows clear of the floating tab bar.
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        // Match the sibling detail screens (Workout / Metric): draw an in-content back link and hide
        // the system nav bar, so the nav-bar-hidden Today flow still has a visible back control.
        .toolbar(.hidden, for: .navigationBar)
        .tint(WM.Ground.ink)
    }

    /// The hero numeral and its line: the band is the typical range the reading is worded against.
    private func hero(_ history: ChargeHistory) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HeroReadout(value: history.current.map { String(Int($0.rounded())) } ?? "—",
                        title: "Charge",
                        subtitle: history.caption,
                        color: history.current == nil ? WM.Ground.inkTertiary : WM.Ground.ink,
                        size: 96)
            LineScale(value: history.current.map { $0 / 100 },
                      band: history.band.map { ($0.lowerBound / 100)...($0.upperBound / 100) },
                      color: WM.Domain.charge.color, style: .hero)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The detail's series, derived in one pass and clamped to the resolved anchor day.
///
/// The #547 future-day guard: the daily read window admits rows keyed up to TOMORROW (a tz-ahead
/// backup import / transient clock skew), and taking the last recovery by ARRAY POSITION would describe
/// that future row instead of today — headline, reading and drivers all diverging from the hero the
/// detail was pushed from. Every value here is clamped to `day <= anchorKey`, resolved the SAME way
/// Today resolves "today".
private struct ChargeHistory {
    /// The trailing 30 recovery values up to the anchor day, oldest → newest (the strip).
    let values: [Double]
    /// One x label per value: "Today" for the anchor day, else a short date ("31 Aug").
    let xLabels: [String]
    /// The newest scored value — the one the Today hero showed (own day or its fresh carry).
    let current: Double?
    /// The scored day's spelled-out date, or nil when nothing is scored yet.
    let dayLabel: String?
    /// The typical band: the 25th…75th percentile of the 30 values STRICTLY before `current` —
    /// `dropLast().suffix(30)`, not `suffix(30).dropLast()` (only 29) — which is the same window
    /// Today's Charge band and baseline take, so the detail can never read a different typical than
    /// the hero it was pushed from. `typicalBand` carries `minBaselineSamples`, as the hero does.
    let band: ClosedRange<Double>?

    init(days: [DailyMetric]) {
        let anchorKey = Repository.anchorKey(days: days)
        let scored = days.filter { $0.day <= anchorKey && $0.recovery != nil }
        let recoveries = scored.compactMap(\.recovery)
        let tail = scored.suffix(30)
        values = tail.compactMap(\.recovery)
        xLabels = tail.map { row -> String in
            guard row.day != anchorKey else { return "Today" }
            return TodayModel.date(fromKey: row.day)?.formatted(.dateTime.day().month(.abbreviated)) ?? ""
        }
        current = recoveries.last
        dayLabel = scored.last.flatMap { TodayModel.date(fromKey: $0.day) }?
            .formatted(.dateTime.weekday(.wide).day().month(.wide))
        band = TodayModel.typicalBand(Array(recoveries.dropLast().suffix(30)))
    }

    /// "below typical 36–48" / "near typical" / "above typical 36–48" — the hero's own wording.
    var caption: String? {
        guard let current, let band else { return nil }
        return TodayModel.bandCaption(value: Int(current.rounded()), band: band)
    }
}

/// One driver: its name and tonight's value, the typical it was measured against (or, for a driver
/// with no baseline, the engine's verdict), then a centered `Diverge` line and the signed points —
/// bad for a pull down, good for a push up, tertiary ink for none.
private struct DriverRow: View {
    let driver: ChargeDriver
    /// The pull that reaches either end of the line (shared by every row on the screen).
    let span: Double

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(driver.label).foregroundStyle(WM.Ground.ink)) \(Text(driver.valueText).foregroundStyle(WM.Ground.inkSecondary))")
                    .font(WMType.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.caption(driver))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WM.Space.s)
            Diverge(delta: Double(driver.deltaPoints), span: span, color: color)
            Text(deltaText)
                .font(WMType.numeral(18))
                .foregroundStyle(color)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.vertical, WM.Space.s)
        .frame(minHeight: WM.Space.row + 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(driver.label), \(driver.valueText), \(driver.verdict), \(driver.deltaPoints) points")
    }

    /// "typical 62 ms" from the engine's "62 ms baseline": "typical" is the word every other surface
    /// uses for a personal norm. A driver with no baseline (sleep, skin temp) captions its verdict,
    /// and a baseline worded some other way is shown as the engine wrote it.
    static func caption(_ driver: ChargeDriver) -> String {
        let suffix = " baseline"
        if driver.baselineText.hasSuffix(suffix) {
            return "typical \(driver.baselineText.dropLast(suffix.count))"
        }
        return driver.baselineText.isEmpty ? driver.verdict : driver.baselineText
    }

    private var deltaText: String {
        driver.deltaPoints > 0 ? "+\(driver.deltaPoints)"
            : driver.deltaPoints < 0 ? "−\(abs(driver.deltaPoints))"
            : "0"
    }

    /// The line and the signed points share one color. A push up takes `WM.Semantic.good` on purpose:
    /// a driver's pull is a delta, and deltas are what the semantic colors are for, so a positive pull
    /// reads as good news rather than as a neutral mark. A pull down is `bad`, none is tertiary ink.
    private var color: Color {
        driver.deltaPoints > 0 ? WM.Semantic.good
            : driver.deltaPoints < 0 ? WM.Semantic.bad
            : WM.Ground.inkTertiary
    }
}

#if DEBUG
#Preview("ChargeDetail — light") {
    NavigationStack {
        ChargeDetailScreen(days: ChargeDetailSpecimen.days,
                           drivers: ChargeDetailSpecimen.drivers)
    }
    .preferredColorScheme(.light)
}

#Preview("ChargeDetail — dark") {
    NavigationStack {
        ChargeDetailScreen(days: ChargeDetailSpecimen.days,
                           drivers: ChargeDetailSpecimen.drivers)
    }
    .preferredColorScheme(.dark)
}

#Preview("ChargeDetail — imported history, no drivers") {
    NavigationStack {
        ChargeDetailScreen(days: ChargeDetailSpecimen.days, drivers: [])
    }
    .preferredColorScheme(.light)
}

/// Deterministic 30-day preview rows + a representative driver list.
private enum ChargeDetailSpecimen {
    static let days: [DailyMetric] = (0..<30).map { i in
        let recovery = 55 + 25 * sin(Double(i) / 4) + Double((i * 31) % 13)
        let anchor = Calendar.current.date(byAdding: .day, value: i - 29, to: Date())!
        return DailyMetric(day: TodayModel.key(from: anchor), totalSleepMin: nil, efficiency: nil,
                           deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                           restingHr: nil, avgHrv: nil, recovery: min(max(recovery, 0), 100),
                           strain: nil, exerciseCount: nil)
    }

    static let drivers: [ChargeDriver] = ChargeDriverDemo.rows
}

/// Representative driver rows for previews and the `--demo-drivers` launch arg (the demo seed
/// writes imported-lane days only, so real computed drivers never exist on the simulator).
enum ChargeDriverDemo {
    static let rows: [ChargeDriver] = [
        ChargeDriver(label: "Heart rate variability", deltaPoints: -18, valueText: "47 ms",
                     baselineText: "62 ms baseline",
                     verdict: "well below baseline, suppressing recovery"),
        ChargeDriver(label: "Resting heart rate", deltaPoints: 6, valueText: "50 bpm",
                     baselineText: "53 bpm baseline",
                     verdict: "below baseline, supporting recovery"),
        ChargeDriver(label: "Sleep", deltaPoints: 3, valueText: "7 h 12 m",
                     baselineText: "", verdict: "near your need, mildly supportive"),
        ChargeDriver(label: "Respiratory rate", deltaPoints: 0, valueText: "14.3 rpm",
                     baselineText: "14.2 rpm baseline", verdict: "at baseline, neutral"),
    ]
}
#endif
