import SwiftUI

/// Where a reading sits inside its own recent history, as 0…1 fractions of that window's min…max —
/// the `.compact` `LineScale` under a metric row (037).
struct MetricScale: Equatable {
    /// Today's value within the window.
    let value: Double
    /// The window's 25th…75th percentile; nil when the window is too thin to have one.
    let band: ClosedRange<Double>?

    init(value: Double, band: ClosedRange<Double>?) {
        self.value = value
        self.band = band
    }
}

/// The data a metric row shows. Identified by its label (unique within a wall).
struct MetricTileModel: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var unit: String? = nil
    var delta: WMDelta? = nil
    /// Colors the row's line; nil draws it in ink.
    var domain: WM.Domain? = nil
    /// Today inside its window; nil shows the row without a line (counts, patterns).
    var scale: MetricScale? = nil

    init(label: String, value: String, unit: String? = nil, delta: WMDelta? = nil,
         domain: WM.Domain? = nil, scale: MetricScale? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.domain = domain
        self.scale = scale
    }
}

/// One metric row (037): name leading; delta, value and unit trailing on one baseline; the
/// optional `.compact` line underneath.
struct MetricTile: View {
    let model: MetricTileModel

    init(_ model: MetricTileModel) { self.model = model }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                Text(model.label)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                Spacer(minLength: WM.Space.s)
                if let delta = model.delta {
                    WMDeltaText(delta: delta)
                }
                Text(model.value)
                    .font(WMType.numeral(22))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(model.unit ?? "")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .frame(minWidth: 26, alignment: .leading)
            }
            if let scale = model.scale {
                LineScale(value: scale.value, band: scale.band,
                          color: model.domain?.color ?? WM.Ground.ink, style: .compact)
            }
        }
        .padding(.vertical, WM.Space.m)
        // One element, worded in reading order: the row draws the delta BEFORE the value, so a
        // combined read would say "HRV, down 3, worse, 74, ms" (`SignalCell.spokenLabel`'s rule).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var s = "\(model.label), \(model.value)"
        if let unit = model.unit, !unit.isEmpty { s += " \(unit)" }
        if let delta = model.delta { s += ", \(delta.spoken)" }
        return s
    }
}

/// A list of metric rows split by hairlines (037) — the Data tab's wall and Weed's pattern block.
struct MetricWall: View {
    let items: [MetricTileModel]
    var onTap: ((MetricTileModel) -> Void)? = nil

    init(items: [MetricTileModel], onTap: ((MetricTileModel) -> Void)? = nil) {
        self.items = items
        self.onTap = onTap
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, model in
                if index > 0 {
                    WMRule()
                }
                row(model)
            }
        }
    }

    @ViewBuilder
    private func row(_ model: MetricTileModel) -> some View {
        if let onTap {
            Button { onTap(model) } label: {
                MetricTile(model).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            MetricTile(model)
        }
    }
}

#Preview("MetricWall — light") {
    MetricWallSpecimen().preferredColorScheme(.light)
}

#Preview("MetricWall — dark") {
    MetricWallSpecimen().preferredColorScheme(.dark)
}

private struct MetricWallSpecimen: View {
    var body: some View {
        MetricWall(items: [
            MetricTileModel(label: "Sleep", value: "7:12", unit: "h",
                            delta: WMDelta(up: true, text: "0:24", sentiment: .good),
                            domain: .rest, scale: MetricScale(value: 0.62, band: 0.35...0.68)),
            MetricTileModel(label: "HRV", value: "74", unit: "ms",
                            delta: WMDelta(up: false, text: "3", sentiment: .bad),
                            domain: .charge, scale: MetricScale(value: 0.35, band: 0.40...0.72)),
            MetricTileModel(label: "RHR", value: "52", unit: "bpm"),
            MetricTileModel(label: "SpO₂", value: "96.5", unit: "%",
                            delta: WMDelta(up: true, text: "0.2", sentiment: .neutral)),
            MetricTileModel(label: "Steps", value: "9,412", domain: .effort,
                            scale: MetricScale(value: 0.68, band: nil))
        ], onTap: { _ in })
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
