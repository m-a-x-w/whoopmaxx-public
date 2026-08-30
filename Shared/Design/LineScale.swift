import SwiftUI

/// The Line language's one instrument (037): a 0…1 hairline track, the user's
/// typical range as a pale band, a colored fill up to the value, and a dot sitting on the value.
/// Every number in the app that has a "compared with usual" reading reuses it at one of three sizes,
/// so Today's hero, a Data row and a health vital all read the same way.
///
/// All inputs are FRACTIONS of the scale (0…1); the caller maps its own units (a 0–100 score, a
/// metric's 30-day min…max, sleep against need). Out-of-range inputs clamp to the ends — a vital
/// outside the whole window still lands on the rail's edge rather than off-screen.
///
/// Pure renderer: no store reads, no formatting, no accessibility identity (the row that owns the
/// number carries the spoken reading).
struct LineScale: View {

    enum Style {
        /// Today / Rest / Live heroes.
        case hero
        /// Score rows (Effort, Rest, Regularity) and health vitals.
        case row
        /// Dense lists: the Data metric rows, capture days, time-in-zone.
        case compact

        var bandHeight: CGFloat {
            switch self {
            case .hero: return 10
            case .row: return 8
            case .compact: return 6
            }
        }

        var dot: CGFloat {
            switch self {
            case .hero: return 12
            case .row: return 10
            case .compact: return 8
            }
        }
    }

    /// The reading, 0…1. nil draws the track (and band) alone — "no value yet".
    let value: Double?
    /// The typical range, 0…1 fractions; nil hides it.
    var band: ClosedRange<Double>? = nil
    /// A 2pt ink tick (e.g. the sleep need at 1.0); nil hides it.
    var reference: Double? = nil
    let color: Color
    var style: Style = .row
    /// false for range readouts (health vitals), where a bar grown from zero means nothing and only
    /// the dot's position against the band matters.
    var showsFill: Bool = true
    /// false drops the dot (bar-style rows: time in zone, capture coverage).
    var showsDot: Bool = true

    init(value: Double?, band: ClosedRange<Double>? = nil, reference: Double? = nil,
         color: Color, style: Style = .row, showsFill: Bool = true, showsDot: Bool = true) {
        self.value = value
        self.band = band
        self.reference = reference
        self.color = color
        self.style = style
        self.showsFill = showsFill
        self.showsDot = showsDot
    }

    private static func clamp(_ v: Double) -> CGFloat { CGFloat(min(max(v, 0), 1)) }

    private var height: CGFloat { max(style.bandHeight + 6, style.dot + 6) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(WM.Ground.track)
                    .frame(width: w, height: 2)
                    .position(x: w / 2, y: mid)

                if let band {
                    let lo = Self.clamp(band.lowerBound) * w
                    let hi = Self.clamp(band.upperBound) * w
                    // A near-degenerate band still shows as a pill the height of the band, centered on it.
                    let width = max(hi - lo, style.bandHeight)
                    Capsule()
                        .fill(color.opacity(0.18))
                        .frame(width: width, height: style.bandHeight)
                        .position(x: min(max((lo + hi) / 2, width / 2), w - width / 2), y: mid)
                }

                if let value, showsFill {
                    let x = Self.clamp(value) * w
                    Capsule()
                        .fill(color)
                        .frame(width: max(x, 3), height: 3)
                        .position(x: max(x, 3) / 2, y: mid)
                }

                if let reference {
                    let x = Self.clamp(reference) * w
                    RoundedRectangle(cornerRadius: 1)
                        .fill(WM.Ground.ink)
                        .frame(width: 2, height: style.bandHeight + 6)
                        .position(x: min(max(x, 1), w - 1), y: mid)
                }

                if let value, showsDot {
                    let x = Self.clamp(value) * w
                    Circle()
                        .fill(color)
                        .frame(width: style.dot, height: style.dot)
                        // The ground-colored ring lifts the dot off the band and the fill.
                        .background(Circle().fill(WM.Ground.ground).frame(width: style.dot + 6, height: style.dot + 6))
                        .position(x: min(max(x, style.dot / 2), w - style.dot / 2), y: mid)
                }
            }
            .wmAnimation(WMMotion.value, value: value)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview("LineScale — light") {
    LineScaleSpecimen().preferredColorScheme(.light)
}

#Preview("LineScale — dark") {
    LineScaleSpecimen().preferredColorScheme(.dark)
}

private struct LineScaleSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionTight) {
            LineScale(value: 0.30, band: 0.36...0.48, color: WM.Domain.charge.color, style: .hero)
            LineScale(value: 0.51, band: 0.38...0.52, color: WM.Domain.effort.color)
            LineScale(value: 0.90, reference: 1.0, color: WM.Domain.rest.color, style: .hero)
            LineScale(value: 0.96, band: 0.30...0.62, color: WM.Semantic.bad, showsFill: false)
            LineScale(value: 0.68, band: 0.35...0.70, color: WM.Domain.effort.color, style: .compact)
            LineScale(value: nil, band: 0.40...0.60, color: WM.Domain.charge.color, style: .hero)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
