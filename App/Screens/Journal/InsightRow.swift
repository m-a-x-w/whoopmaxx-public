import SwiftUI
import StrapAnalytics

/// One behavior row: label + significance marker, ink magnitude bar, plain-English sentence.
/// Below the n=5-per-group gate: the "keep logging" copy and never a number.
///
/// Lifted out of `JournalInsightsView` (009 F3) so the Weed screen can render the SAME row for
/// `"weed"` that Journal insights does — one verdict in the app, structurally incapable of
/// disagreeing. A fourth hand-copy of an ink magnitude bar + significance mark is how these drift.
struct InsightRow: View {
    let row: JournalInsightRow
    /// What the row says below the gate. Defaulted to Journal insights' own wording, which is what
    /// every behavior on that screen says; the Weed screen passes its own because its whole subject
    /// is one behavior and "data" there would mean sessions.
    var emptyText = "Not enough data yet — keep logging."

    /// |Cohen's d| the magnitude bar tops out at (≥1.5 reads "very large" by any convention).
    private static let magnitudeBarCap = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(spacing: WM.Space.s) {
                Text(row.label)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                if row.significant {
                    // Significance marker — ink, not semantic color (a finding, not a verdict).
                    Circle()
                        .fill(WM.Ground.ink)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Significant")
                }
                Spacer(minLength: WM.Space.s)
                if let e = row.effect {
                    Text(e.leadLagText)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            if let e = row.effect {
                magnitudeBar(d: e.effect.cohensD)
                Text(e.sentence())
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(emptyText)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    /// Cohen's-d magnitude as an ink bar over a hairline track (capped at |d| = 1.5).
    private func magnitudeBar(d: Double) -> some View {
        WMTrackBar(segments: [(min(abs(d) / Self.magnitudeBarCap, 1.0), WM.Ground.ink)],
                   track: WM.Ground.rule)
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}
