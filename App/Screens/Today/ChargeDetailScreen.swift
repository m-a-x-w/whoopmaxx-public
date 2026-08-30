import SwiftUI
import StrapStore
import StrapAnalytics

/// Charge detail (pushed from the Today trio's Charge column): the current Charge as a display
/// numeral, the ordered "What shaped it" driver rows (label + value vs baseline + verdict + signed
/// points — `RecoveryScorer.chargeDrivers` via ScoreEngine, so the rows can never disagree with the
/// headline score), and a 30-day recovery `SparkHistory`.
struct ChargeDetailScreen: View {
    /// Merged daily rows, oldest → newest (`repo.days`).
    let days: [DailyMetric]
    /// The driver breakdown for the newest scored day (`scores.results`, matched by day). Empty
    /// until whoopmaxx has scored a night itself — imported-only history carries no drivers.
    let drivers: [ChargeDriver]

    @Environment(\.dismiss) private var dismiss

    /// The resolved "today" day key the tapped Charge column describes (#547 future-day guard). The daily
    /// read window admits rows keyed up to TOMORROW (a tz-ahead backup import / transient clock skew),
    /// and taking `compactMap(\.recovery).last` by ARRAY POSITION would describe that future row instead of
    /// today — headline, verdict, and drivers all diverging from the column. Clamp every derivation to
    /// `day <= anchorKey`, resolved the SAME way the column resolves "today".
    private var anchorKey: String {
        Repository.anchorKey(days: days)
    }

    /// Recovery values up to and including the anchor day (oldest → newest), the guarded series behind
    /// current + baseline + the strip.
    private var recoveries: [Double] {
        days.filter { $0.day <= anchorKey }.compactMap(\.recovery)
    }

    /// Trailing 30 recovery values (oldest → newest) for the history strip.
    private var recentRecoveries: [Double] {
        Array(recoveries.suffix(30))
    }

    private var current: Double? { recentRecoveries.last }

    private var baseline: Double? {
        // Match the Today Charge column's baseline tick: the 30 STRICTLY-PRIOR recovery values
        // (`dropLast().suffix(30)`), not `suffix(30).dropLast()` (which is only 29). Otherwise the detail
        // verdict ("above/below your typical") could disagree with the column it was pushed from.
        // …and through `typicalMean`, so the caption honours `minBaselineSamples` exactly like the column
        // it was pushed from. Bare `mean` here said "above your typical" against a single prior night.
        TodayModel.typicalMean(Array(recoveries.dropLast().suffix(30)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.m)

                Text("Charge")
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .padding(.top, WM.Space.sectionTight)

                HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                    Text(current.map { String(Int($0.rounded())) } ?? "—")
                        .font(WMType.display())
                        .foregroundStyle(WM.Ground.ink)
                    if let current, let baseline {
                        Text(current >= baseline ? "above your typical" : "below your typical")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                }
                .padding(.top, WM.Space.m)

                RuleSection("What shaped it") {
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
                                DriverRow(driver: driver)
                            }
                        }
                    }
                }

                RuleSection("Last 30 days") {
                    if recentRecoveries.isEmpty {
                        Text("No scored days yet.")
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkSecondary)
                    } else {
                        SparkHistory(values: recentRecoveries, domain: .charge,
                                     range: 0...100, height: SparkHistory.chart,
                                     valueLabel: { "\(Int($0.rounded()))" })
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            // `sectionLoose` (matching Metric/Workout/HealthMonitor detail): pushed screens sit on the
            // shell's NavigationStack, whose `.safeAreaPadding(.bottom)` lands on the TAB ROOT only — so
            // each pushed screen self-pads its last rows clear of the floating InkTabBar.
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        // Match the sibling detail screens (Workout / Metric): draw an in-content back chevron and
        // hide the system nav bar, so the nav-bar-hidden Today flow still has a visible back control.
        .toolbar(.hidden, for: .navigationBar)
        .tint(WM.Ground.ink)
    }

    /// Ink back affordance (chrome stays neutral). Pushed only from Today, so the label reads "Today".
    private var backLink: some View {
        WMBackLink(title: "Today") { dismiss() }
    }
}

/// One driver row: label over value·baseline over verdict on the left, the signed points
/// contribution on the right (semantic color — positive supported the score, negative suppressed it).
private struct DriverRow: View {
    let driver: ChargeDriver

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(driver.label)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.ink)
                Text(driver.baselineText.isEmpty
                     ? driver.valueText
                     : "\(driver.valueText) · \(driver.baselineText)")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Text(driver.verdict)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: WM.Space.m)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(deltaText)
                    .font(WMType.numeral(22))
                    .foregroundStyle(deltaColor)
                Text("pts")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(driver.label), \(driver.valueText), \(driver.verdict), \(driver.deltaPoints) points")
    }

    private var deltaText: String {
        driver.deltaPoints > 0 ? "+\(driver.deltaPoints)"
            : driver.deltaPoints < 0 ? "−\(abs(driver.deltaPoints))"
            : "0"
    }

    private var deltaColor: Color {
        driver.deltaPoints > 0 ? WM.Semantic.good
            : driver.deltaPoints < 0 ? WM.Semantic.bad
            : WM.Ground.inkSecondary
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
