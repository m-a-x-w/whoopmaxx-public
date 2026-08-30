import SwiftUI

/// The horizontal bar motif: fills laid leading-to-trailing, plus an optional reference tick
/// (baseline / typical). Since 037 the app draws its lines with `LineScale`; this primitive now
/// renders only the widgets' `ScoreBar`, which lays its own two-layer track underneath (see there).
///
/// HORIZONTAL ONLY, deliberately. The one vertical renderer, the widget's `ScoreColumn`, carries state
/// this primitive does not model — calibrating hollow tracks and dashed ticks, carried-score
/// half-strength fills, the numeral's tick-hop, per-column overlines and shared max normalization — so
/// an axis parameter here would make it worse. It stays separate on purpose.
///
/// Greedy in both axes: the caller sets the bar's thickness with `.frame(height:)`.
struct WMTrackBar: View {
    /// The fills, in leading-to-trailing order; each fraction is 0…1 of the bar's width.
    var segments: [(fraction: Double, color: Color)]
    /// Radius of the segments. 0 = square.
    var cornerRadius: CGFloat = 0
    /// A reference mark (baseline / target) at `fraction` of the width, explicitly sized. It is pinned
    /// inside the trailing edge so a mark at 1.0 stays visible, centred vertically, and never clipped —
    /// a tick TALLER than the bar overhangs it symmetrically.
    var reference: (fraction: Double, color: Color, width: CGFloat, height: CGFloat)? = nil

    /// A segment always paints at least this wide, so a small-but-real value never vanishes entirely.
    private static let minSegmentWidth: CGFloat = 2
    /// Hairline gap between adjacent segments, so two fills read as two quantities and not one run.
    private static let segmentGap: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: Self.segmentGap) {
                ForEach(segments.indices, id: \.self) { i in
                    shape
                        .fill(segments[i].color)
                        .frame(width: max(w * Self.clamped(segments[i].fraction),
                                          Self.minSegmentWidth))
                }
            }
            // Pin the fills to the bar's own box before the tick goes on: an overhanging tick must not
            // be able to grow the stack, or it would re-centre the fills inside a taller frame.
            .frame(width: w, height: geo.size.height, alignment: .leading)
            .overlay(alignment: .leading) {
                if let reference {
                    Rectangle()
                        .fill(reference.color)
                        .frame(width: reference.width, height: reference.height)
                        .offset(x: min(w * Self.clamped(reference.fraction),
                                       max(w - reference.width, 0)))
                }
            }
        }
    }

    /// Square below any radius, so a hard-edged bar renders through the plain `Rectangle` path.
    private var shape: AnyShape {
        cornerRadius > 0
            ? AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            : AnyShape(Rectangle())
    }

    private static func clamped(_ fraction: Double) -> CGFloat {
        CGFloat(min(max(fraction, 0), 1))
    }
}

/// A thin horizontal score bar in the WM bar motif: a half-wash track, a domain-colored fill to
/// score/100, and a quiet baseline tick at baseline/100. The small widget's Charge indicator.
struct ScoreBar: View {
    let score: Int?
    let baseline: Int?
    let domain: WM.Domain

    /// The height the widget frames this bar at — the baseline tick is sized to span it exactly.
    private static let barHeight: CGFloat = 6
    private static let radius: CGFloat = 3

    private var segments: [(fraction: Double, color: Color)] {
        guard let score else { return [] }
        return [(Double(score) / 100, domain.color)]
    }

    private var baselineTick: (fraction: Double, color: Color, width: CGFloat, height: CGFloat)? {
        guard let baseline else { return nil }
        return (Double(baseline) / 100, WM.Ground.inkSecondary, 1, Self.barHeight)
    }

    var body: some View {
        WMTrackBar(segments: segments, cornerRadius: Self.radius, reference: baselineTick)
            .background {
                // The track is a PAIR — half-wash fill under a hairline rule — and both must sit UNDER
                // the domain fill (an overlaid border would draw a dark line across the colored fill).
                // One background layer keeps that order.
                let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                ZStack {
                    shape.fill(domain.wash.opacity(0.45))
                    shape.strokeBorder(WM.Ground.rule, lineWidth: WM.hairline)
                }
            }
    }
}
