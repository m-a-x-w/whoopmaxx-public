import SwiftUI

/// The shared history motif: a thin sparkline riding over a faintly shaded "typical range" band, so a
/// glance says better / typical / worse than usual. One renderer for BOTH the sleep-duration history and
/// the score (Charge / Effort / Rest) history — replacing the two divergent bar renderers.
///
/// Anatomy (oldest → newest, left → right):
///   • Band — domain color washed at ~12%, spanning the 25th…75th percentile of the visible values
///     (the personal IQR). The line sitting above / inside / below the band is the whole point.
///   • Sparkline — a ~1.5 pt stroked polyline through the values, x evenly distributed full-width, y
///     normalized into `range` (nil ⇒ the data's own min…max with a little headroom). History at 70%
///     opacity, the latest segment at full weight.
///   • Latest point — a filled dot at the last value in full domain color, its value labeled just above
///     and to the right in tabular numerals (caller supplies the formatter — "7:12" / "72").
///   • Reference line (optional) — a dashed neutral hairline across the track at a caller value with a
///     right-aligned label (the sleep "need" line, e.g. "8h"); drawn ON TOP of the band. Omitted for scores.
///   • X labels (optional) — a sparse row of tabular date labels below the floor rule (latest, then every
///     ~4th walking back), so the strip stays uncrowded.
///
/// Color is DATA ONLY — the line, band and dot are domain-colored; the floor rule and need line stay
/// neutral ink. Both themes are first-class.
struct SparkHistory: View {

    /// The window's values, oldest → newest.
    let values: [Double]
    /// Domain that colors the line, band, and dot.
    let domain: WM.Domain
    /// Y normalization range; nil ⇒ the data's own min…max with headroom.
    var range: ClosedRange<Double>? = nil
    var height: CGFloat = SparkHistory.chart

    /// Formats the latest value into its dot label (e.g. `{ RestFormat.hmm($0) }` or `{ "\(Int($0)) " }`).
    /// nil hides the label.
    var valueLabel: ((Double) -> String)? = nil

    /// Optional dashed reference line: its value (same units as `values`) and a short right-aligned label.
    var reference: (value: Double, label: String)? = nil

    /// Optional sparse x labels, ONE per value (same count, oldest → newest). SparkHistory picks which to
    /// actually show (latest, then every 4th back) so the row never crowds. nil hides the row.
    var xLabels: [String]? = nil

    /// Chart size — matches the other detail-strip charts.
    static let chart: CGFloat = 160
    /// Inline spark size.
    static let spark: CGFloat = 44

    private var restCount: Int { values.count }
    private var domainColor: Color { domain.color }

    /// The 25th…75th percentile band of the visible values (nil when empty).
    private var band: ClosedRange<Double>? { SparkStats.iqrBand(values) }

    /// Sparse label indices: the latest, then every 4th walking back — kept sparse so labels never crowd.
    private var labelIndices: Set<Int> {
        guard restCount > 0 else { return [] }
        return Set(stride(from: restCount - 1, through: 0, by: -4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            track
                .frame(height: height)

            // The floor the strip stands on.
            WMRule()

            if xLabels != nil {
                labelRow
                    .frame(height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Track (band + reference + line + dot + value label)

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bounds = yBounds()

            ZStack(alignment: .topTrailing) {
                Canvas { ctx, size in
                    guard restCount > 0 else { return }

                    // Band — the personal typical range, washed domain color.
                    if let band {
                        let top = yFor(band.upperBound, bounds: bounds, height: size.height)
                        let bottom = yFor(band.lowerBound, bounds: bounds, height: size.height)
                        let rect = CGRect(x: 0, y: top, width: size.width, height: max(bottom - top, 0))
                        ctx.fill(Path(rect), with: .color(domainColor.opacity(0.12)))
                    }

                    // Reference line — dashed neutral hairline across the track, on top of the band.
                    if let reference {
                        let y = yFor(reference.value, bounds: bounds, height: size.height)
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(path, with: .color(WM.Ground.ruleHeavy),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    // Sparkline — history at 70%, latest segment at full weight.
                    let pts = (0..<restCount).map { i in
                        CGPoint(x: xFor(i, width: size.width),
                                y: yFor(values[i], bounds: bounds, height: size.height))
                    }
                    if pts.count >= 2 {
                        var line = Path()
                        line.addLines(pts)
                        ctx.stroke(line, with: .color(domainColor.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                        var latest = Path()
                        latest.move(to: pts[pts.count - 2])
                        latest.addLine(to: pts[pts.count - 1])
                        ctx.stroke(latest, with: .color(domainColor),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }

                    // Latest point — filled dot in full domain color.
                    if let last = pts.last {
                        let r: CGFloat = 3
                        let dot = CGRect(x: last.x - r, y: last.y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: dot), with: .color(domainColor))
                    }
                }

                // Reference label ("8h") — right-aligned near its line. Normally just ABOVE the line;
                // but when the latest night's value ≈ the reference, the value label ("6:25") lands in
                // the same right-edge band and the two collide. In that case drop the reference label
                // just BELOW its line so the value stays above-right of the dot and the reference sits
                // below-right of its line, clear of each other.
                if let reference {
                    let refY = yFor(reference.value, bounds: bounds, height: h)
                    let collides: Bool = {
                        guard valueLabel != nil, let last = values.last else { return false }
                        let valY = yFor(last, bounds: bounds, height: h)
                        return abs((refY - 15) - (valY - 24)) < 22
                    }()
                    // Clamp the chosen offset into 0…(h-14) so the label stays on-track even when the
                    // need line rides near the top or bottom edge.
                    let refOffset = collides ? min(max(refY + 4, 0), h - 14)
                                             : min(max(refY - 15, 0), h - 14)
                    Text(reference.label)
                        .font(WMType.caption)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .offset(y: refOffset)
                }

                // Latest value label — tabular numerals just above / right of the dot.
                if let valueLabel, let last = values.last {
                    let y = yFor(last, bounds: bounds, height: h)
                    Text(valueLabel(last))
                        .font(WMType.numeral(17))
                        .foregroundStyle(domainColor)
                        .fixedSize()
                        .offset(y: min(max(y - 24, 0), h - 22))
                }
            }
            .frame(width: w, height: h)
        }
    }

    // MARK: - Sparse x-label row

    private var labelRow: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = geo.size.height / 2
            ForEach(Array((xLabels ?? []).enumerated()), id: \.offset) { i, text in
                if labelIndices.contains(i), !text.isEmpty {
                    Text(text)
                        .font(WMType.caption)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize()
                        // Sit under the point, nudged in from the edges so latest/earliest never clip.
                        .position(x: min(max(xFor(i, width: w), 10), w - 10), y: mid)
                }
            }
        }
    }

    // MARK: - Geometry

    /// Normalization bounds: the explicit `range`, else the data's min…max with ~12% headroom each side.
    private func yBounds() -> (lo: Double, hi: Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        guard let mn = values.min(), let mx = values.max() else { return (0, 1) }
        if mx == mn {
            let pad = max(abs(mn) * 0.1, 1)
            return (mn - pad, mx + pad)
        }
        // Include the reference value so the need line never falls off the track.
        let lo0 = min(mn, reference?.value ?? mn)
        let hi0 = max(mx, reference?.value ?? mx)
        let pad = (hi0 - lo0) * 0.12
        return (lo0 - pad, hi0 + pad)
    }

    private func yFor(_ v: Double, bounds: (lo: Double, hi: Double), height: CGFloat) -> CGFloat {
        let span = max(bounds.hi - bounds.lo, .ulpOfOne)
        let frac = min(max((v - bounds.lo) / span, 0), 1)
        return height * (1 - CGFloat(frac))
    }

    private func xFor(_ i: Int, width: CGFloat) -> CGFloat {
        restCount <= 1 ? width : width * CGFloat(i) / CGFloat(restCount - 1)
    }

    private var accessibilityText: String {
        let latest = values.last.flatMap { v in valueLabel.map { $0(v) } }
        if let latest { return "\(domain.displayName) history, \(restCount) points, latest \(latest)" }
        return "\(domain.displayName) history, \(restCount) points"
    }
}

// MARK: - Pure stats (unit-tested app-side)

/// Small pure helpers for the SparkHistory band. Linear-interpolated (numpy-style) percentiles, safe for
/// small n. StrapAnalytics carries an equivalent `StrainScorer.percentile`, but it is `internal` to that
/// frozen package and unreachable from the app layer, so this mirrors the same interpolation here.
enum SparkStats {

    /// Linear-interpolated percentile of `values` (unsorted ok), `pct` in 0…100.
    /// nil when empty; the single value itself when n == 1.
    static func percentile(_ values: [Double], _ pct: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        if n == 1 { return s[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = Swift.min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return s[lower] + frac * (s[upper] - s[lower])
    }

    /// The personal typical band: 25th…75th percentile of the values.
    /// nil when empty; a degenerate `v…v` range when n == 1.
    static func iqrBand(_ values: [Double]) -> ClosedRange<Double>? {
        guard let lo = percentile(values, 25), let hi = percentile(values, 75) else { return nil }
        return Swift.min(lo, hi)...Swift.max(lo, hi)
    }
}

// MARK: - Previews

#Preview("SparkHistory — light") {
    SparkHistorySpecimen().preferredColorScheme(.light)
}

#Preview("SparkHistory — dark") {
    SparkHistorySpecimen().preferredColorScheme(.dark)
}

private struct SparkHistorySpecimen: View {
    /// 14 nights of sleep minutes (undulating around ~7 h).
    private let sleep: [Double] = (0..<14).map { (i: Int) -> Double in
        let wave: Double = 60 * sin(Double(i) / 2.2)
        let noise = Double((i * 37) % 29)
        return 430 + wave + noise
    }
    /// 30 days of Charge scores.
    private let scores: [Double] = (0..<30).map { (i: Int) -> Double in
        let wave: Double = 25 * sin(Double(i) / 4)
        let noise = Double((i * 31) % 13)
        let raw: Double = 55 + wave + noise
        return min(max(raw, 0), 100)
    }

    private var dayLabels: [String] {
        (0..<14).map { "\(($0 + 2) % 28 + 1)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionLoose) {
            Text("Sleep").wmOverline()
            SparkHistory(values: sleep, domain: .rest,
                         valueLabel: { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) },
                         reference: (480, "8h"),
                         xLabels: dayLabels)

            Text("Charge").wmOverline()
            SparkHistory(values: scores, domain: .charge, range: 0...100,
                         valueLabel: { "\(Int($0.rounded()))" })
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
