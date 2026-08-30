import SwiftUI
import StrapAnalytics

/// One behavior row (037, mockup `L_Insights`): the behavior's name over a one-line reading
/// ("HRV 16 ms lower · next morning · 12 days"), and a `Diverge` line trailing — a tick at zero, the
/// fill growing left for a drop and right for a rise, scaled by the effect size (|Cohen's d|, capped
/// at 1.5). Below the n=5-per-group gate: how many days are logged, the "keep logging" copy, and
/// never a number or a line.
///
/// Lifted out of the insights list (009 F3) so the Weed screen can render the SAME row for `"weed"`
/// that Insights does — one verdict in the app, structurally incapable of disagreeing.
///
/// COLOR: a family-corrected significant effect takes a semantic color by which way the OUTCOME
/// moved — bad when it moved the worse way (HRV, Charge or Rest down; resting HR up), good when the
/// better way (`JournalInsightsModel.higherIsBetter`). A non-significant effect stays inkTertiary:
/// it is logged, not concluded, and coloring it would read as a verdict the data has not reached.
struct InsightRow: View {
    let row: JournalInsightRow
    /// What the row says below the gate. nil ⇒ "N days logged — not enough yet, keep logging", the
    /// Insights wording; the Weed screen passes its own because its whole subject is one behavior
    /// and "days" there would blur with sessions.
    var emptyText: String? = nil
    /// Adds the full plain sentence (both averages, both group sizes) under the row. Off in the
    /// Insights list, where the compact reading is the point; on for Weed's single verdict.
    var showsSentence: Bool = false

    init(row: JournalInsightRow, emptyText: String? = nil, showsSentence: Bool = false) {
        self.row = row
        self.emptyText = emptyText
        self.showsSentence = showsSentence
    }

    /// |Cohen's d| that reaches either end of the `Diverge` (≥1.5 reads "very large" by any
    /// convention). Larger effects clamp to the edge.
    private static let divergeSpan = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(alignment: .center, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: WM.Space.xs) {
                        Text(row.label)
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.ink)
                        if row.significant {
                            // Significance marker — ink, a finding rather than a color.
                            Circle()
                                .fill(WM.Ground.ink)
                                .frame(width: 5, height: 5)
                        }
                    }
                    Text(reading)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WM.Space.m)
                if let e = row.effect {
                    Diverge(delta: e.effect.cohensD, span: Self.divergeSpan, color: color(e))
                }
            }
            if showsSentence, let e = row.effect {
                Text(e.sentence())
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, WM.Space.m)
        .frame(minHeight: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
    }

    // MARK: - Copy

    /// The one-line reading: outcome, magnitude in its unit and direction, the lag, and the
    /// logged-day n it rests on. Below the gate: the logged count and why there is no number.
    private var reading: String {
        guard let e = row.effect else {
            return emptyText
                ?? "\(row.loggedDays) day\(row.loggedDays == 1 ? "" : "s") logged — not enough yet, keep logging"
        }
        let effect = e.effect
        let n = "\(effect.nWith) day\(effect.nWith == 1 ? "" : "s")"
        guard effect.delta != 0 else {
            return "\(e.outcome) unchanged · \(e.leadLagText) · \(n)"
        }
        let unit = JournalInsightsModel.unit(forOutcome: e.outcome).map { " \($0)" } ?? ""
        let direction = effect.delta > 0 ? "higher" : "lower"
        return "\(e.outcome) \(Self.magnitude(effect.delta))\(unit) \(direction) · \(e.leadLagText) · \(n)"
    }

    /// |delta| to a whole number from 10 up, to one decimal below it ("2.4", "16"), with a trailing
    /// ".0" dropped so a round number never carries false precision.
    static func magnitude(_ delta: Double) -> String {
        let m = abs(delta)
        if m >= 9.95 { return String(Int(m.rounded())) }
        let text = String(format: "%.1f", m)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private func color(_ e: RankedEffect) -> Color {
        guard row.significant, e.effect.delta != 0 else { return WM.Ground.inkTertiary }
        let rose = e.effect.delta > 0
        return rose == JournalInsightsModel.higherIsBetter(outcome: e.outcome)
            ? WM.Semantic.good : WM.Semantic.bad
    }

    /// Spoken: the name, whether it cleared the family correction, and the FULL sentence (averages and
    /// both group sizes) — the compact reading is a visual shorthand, VoiceOver gets the whole claim.
    private var a11yLabel: String {
        var parts = [row.label]
        if row.significant { parts.append("significant") }
        if let e = row.effect {
            parts.append(e.sentence())
        } else {
            parts.append(reading)
        }
        return parts.joined(separator: ", ")
    }
}
