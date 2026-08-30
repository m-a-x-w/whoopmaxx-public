import SwiftUI

/// A centered line for "how far did this pull the score" (037): a short ink tick marks zero, a
/// fill grows left for a negative pull and right for a positive one, and a dot sits at its end.
/// Charge detail's drivers and the journal insights' effects.
struct Diverge: View {
    /// Signed pull, in the caller's units (points, ms).
    let delta: Double
    /// The magnitude that reaches the end of either half. Larger pulls clamp to the edge.
    let span: Double
    let color: Color
    var width: CGFloat = 92

    init(delta: Double, span: Double, color: Color, width: CGFloat = 92) {
        self.delta = delta
        self.span = span
        self.color = color
        self.width = width
    }

    var body: some View {
        let half = width / 2
        let reach = span > 0 ? min(abs(delta) / span, 1) * (half - 5) : 0
        let end = delta < 0 ? half - reach : half + reach
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(WM.Ground.track)
                .frame(width: width, height: 2)
                .position(x: half, y: 7)
            RoundedRectangle(cornerRadius: 1)
                .fill(WM.Ground.inkTertiary)
                .frame(width: 2, height: 12)
                .position(x: half, y: 7)
            if reach > 0.5 {
                Capsule()
                    .fill(color)
                    .frame(width: reach, height: 3)
                    .position(x: (half + end) / 2, y: 7)
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .background(Circle().fill(WM.Ground.ground).frame(width: 15, height: 15))
                .position(x: end, y: 7)
        }
        .frame(width: width, height: 14)
        .accessibilityHidden(true)
    }
}

#Preview("Diverge — light") {
    DivergeSpecimen().preferredColorScheme(.light)
}

#Preview("Diverge — dark") {
    DivergeSpecimen().preferredColorScheme(.dark)
}

private struct DivergeSpecimen: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: WM.Space.l) {
            Diverge(delta: -9, span: 10, color: WM.Semantic.bad)
            Diverge(delta: -4, span: 10, color: WM.Semantic.bad)
            Diverge(delta: 0, span: 10, color: WM.Ground.inkTertiary)
            Diverge(delta: 6, span: 10, color: WM.Semantic.good)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(WM.Ground.ground)
    }
}
