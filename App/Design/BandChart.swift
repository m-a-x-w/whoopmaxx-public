import SwiftUI
import Charts

/// Swift Charts line series with an optional typical-range band (a rounded `track` `RectangleMark`),
/// caption-ink axes, no legend chrome — the Line language's chart (037). The metric-detail
/// workhorse; the latest point carries a dot.
///
/// Scrubbing is OPT-IN (`selection`). Unbound — the default, and what `StrapHealthScreen` keeps
/// getting — the chart carries no gesture and no selection state at all: the view tree is the one it
/// has always drawn (017 decision 6).
struct BandChart: View {
    let points: [(Date, Double)]
    /// The typical band (e.g. mean ± sd over 30 days); nil hides it.
    let band: ClosedRange<Double>?
    let domain: WM.Domain
    var height: CGFloat = 200
    /// Opt-in scrub. While a finger is on the chart this carries the date OF A PLOTTED POINT — never
    /// the raw continuous x the gesture yields — and it returns to nil when the finger lifts: the
    /// scrub is a READ and leaves no state behind (017 decision 1). The chart itself renders
    /// identically selected or not; the readout is the caller's own (017 decision 2).
    var selection: Binding<Date?>?
    /// The calendar unit ONE POINT STANDS FOR. Required, no default.
    ///
    /// Each point is binned to this unit, so a weekly mean sits inside its own week rather than on the
    /// week's first day, and the scrub (`nearestPointDate`) matches a touch to the unit the finger is
    /// on. It has to move with the aggregation: a year of 53 weekly means plotted at `.day` would
    /// place every mean on one day of its week and let a touch on the other six fall through to
    /// "nearest".
    ///
    /// No default precisely because a wrong value here is invisible: the chart still draws, the tests
    /// still pass, and the only symptom is a scrub that names the wrong week.
    let unit: Calendar.Component
    /// false (default) lets the y axis fit the data — a line reads its shape, not its distance from
    /// zero. true pins zero in view (a 0–100% battery trace).
    var includesZero: Bool = false
    /// Overrides the domain color for the line and dot — a neutral trace that isn't a score (the
    /// strap's battery) passes `WM.Ground.inkSecondary`. nil draws in `domain.color`.
    var lineColor: Color? = nil

    init(points: [(Date, Double)], band: ClosedRange<Double>?, domain: WM.Domain,
         height: CGFloat = 200, selection: Binding<Date?>? = nil,
         unit: Calendar.Component, includesZero: Bool = false, lineColor: Color? = nil) {
        self.points = points
        self.band = band
        self.domain = domain
        self.height = height
        self.selection = selection
        self.unit = unit
        self.includesZero = includesZero
        self.lineColor = lineColor
    }

    var body: some View {
        Group {
            if let selection {
                chart
                    // `chartXSelection` yields a CONTINUOUS x: a date anywhere along the axis, which on
                    // these series is usually a day with no row at all (`ScoreEngine` writes a day only
                    // once it has seen 200+ HR samples, so gaps are the normal case). The binding
                    // therefore stores the NEAREST PLOTTED POINT's own date, so a caller can only ever
                    // read and caption a day that was really measured.
                    //
                    // The write is GUARDED because that continuity is exactly what makes it redundant:
                    // a finger crossing one point's unit emits a touch-move per frame and every one of them
                    // resolves to the same plotted date. Writing unconditionally invalidated the
                    // caller — `MetricDetailView` — at the touch-event rate, and each invalidation
                    // re-ran its whole per-pass derivation (cutoff filter → `PlottedSeries.make` →
                    // band → a full Charts mark rebuild) to arrive at the identical chart. Now the
                    // binding only writes when the SELECTED POINT actually changes, so the pass count
                    // falls to the number of distinct units the finger crosses. This narrows the
                    // write, not the answer: the value stored is the same value it always was.
                    .chartXSelection(value: Binding<Date?>(
                        get: { selection.wrappedValue },
                        set: {
                            let resolved = Self.nearestPointDate(to: $0, in: points, unit: unit)
                            if resolved != selection.wrappedValue { selection.wrappedValue = resolved }
                        }))
                    // Releasing returns the caller to its own default (017 decision 1) —
                    // `chartXSelection` alone leaves the last selection standing after the finger
                    // lifts. SIMULTANEOUS so the enclosing ScrollView keeps its pan: a vertical drag
                    // that starts on the chart must still scroll the page. `minimumDistance: 0` so a
                    // tap ends the same way a drag does.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { _ in selection.wrappedValue = nil })
            } else {
                chart
            }
        }
        // The single `frame` both branches had before, hoisted so the selection modifiers sit directly
        // on the chart's own chain (where every Charts sample puts them) rather than behind a layout
        // modifier. `Group` is layout-transparent, so the unbound caller is framed exactly as it was.
        .frame(height: height)
    }

    /// The chart proper — identical in both the plain and the scrubbable branch. Selection adds
    /// modifiers around this, never marks inside it: the line, the band and the axes are untouched.
    private var chart: some View {
        Chart {
            if let band {
                RectangleMark(
                    yStart: .value("Typical low", band.lowerBound),
                    yEnd: .value("Typical high", band.upperBound)
                )
                .foregroundStyle(WM.Ground.track)
                .cornerRadius(8)
            }
            ForEach(points.indices, id: \.self) { i in
                LineMark(
                    x: .value("Day", points[i].0, unit: unit),
                    y: .value("Value", points[i].1)
                )
                .foregroundStyle(lineColor ?? domain.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
            if let last = points.last {
                PointMark(
                    x: .value("Day", last.0, unit: unit),
                    y: .value("Value", last.1)
                )
                .foregroundStyle(lineColor ?? domain.color)
                .symbolSize(100)
            }
        }
        .chartYScale(domain: .automatic(includesZero: includesZero))
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: WM.hairline))
                    .foregroundStyle(WM.Ground.rule)
                AxisValueLabel()
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .chartLegend(.hidden)
    }

    /// The date of the point nearest `x` in time — the only honest answer to a continuous selection
    /// over a sparse series. Deliberately NEAREST, not "the last point at or before x": those two
    /// differ on every gap, and on a series whose gaps run to a fortnight the second one captions a day
    /// the finger is nowhere near. Ties go to the earlier point (`points` runs oldest → newest).
    ///
    /// nil x — or no points at all — resolves to nil: an empty chart has nothing to select.
    /// Internal so the resolution rule is pinned by a test; it is the whole correctness of the scrub.
    static func nearestPointDate(to x: Date?, in points: [(Date, Double)],
                                 unit: Calendar.Component = .day,
                                 calendar: Calendar = .current) -> Date? {
        guard let x else { return nil }
        // A point stands for `unit` FORWARD from its own date — a weekly mean's date is its week's
        // first day, and the point covers the whole week. So a touch is first matched to the unit it
        // is physically IN. Nearest-by-date would answer the NEXT week for anything past a week's
        // midpoint, i.e. half of every week, naming a week the finger is not over.
        //
        // Only when the touch lands in no point's unit at all — the normal case for a sparse DAILY
        // series, where most days have no row — does it fall back to nearest, the honest answer there.
        for point in points where x >= point.0 {
            guard let end = calendar.date(byAdding: unit, value: 1, to: point.0) else { continue }
            if x < end { return point.0 }
        }
        var nearest: Date?
        var smallestGap = TimeInterval.infinity
        for point in points {
            let gap = abs(point.0.timeIntervalSince(x))
            if gap < smallestGap {
                smallestGap = gap
                nearest = point.0
            }
        }
        return nearest
    }
}

#Preview("BandChart — light") {
    BandChartSpecimen().preferredColorScheme(.light)
}

#Preview("BandChart — dark") {
    BandChartSpecimen().preferredColorScheme(.dark)
}

private struct BandChartSpecimen: View {
    /// The scrubbable branch, held at a hard-coded point: a gesture cannot be previewed, so this is
    /// what pins that binding a selection still draws the same chart (the readout is the caller's).
    @State private var pinned: Date?

    private var demo: [(Date, Double)] {
        let day0 = Calendar.current.startOfDay(for: Date())
        return (0..<30).map { i in
            (Calendar.current.date(byAdding: .day, value: -29 + i, to: day0)!,
             62 + 18 * sin(Double(i) / 4.5) + Double((i * 31) % 11))
        }
    }

    var body: some View {
        VStack(spacing: WM.Space.section) {
            BandChart(points: demo, band: 58...78, domain: .rest, unit: .day)
            BandChart(points: demo, band: nil, domain: .charge, height: 140, unit: .day)
            BandChart(points: demo, band: 58...78, domain: .rest, height: 140,
                      selection: $pinned, unit: .day)
                .onAppear { pinned = demo[demo.count - 7].0 }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
