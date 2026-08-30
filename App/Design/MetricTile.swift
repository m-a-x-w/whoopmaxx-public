import SwiftUI

/// The data a wall tile shows. Identified by its label (unique within a wall).
struct MetricTileModel: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var unit: String? = nil
    var delta: WMDelta? = nil

    init(label: String, value: String, unit: String? = nil, delta: WMDelta? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
    }
}

/// Data-tab wall tile: overline label, numeral value + unit, optional delta arrow. NO box — rule
/// separators come from the `MetricWall` container. The view tree IS `SignalCell`'s, at the wall's
/// slightly smaller numeral and filling its grid cell.
struct MetricTile: View {
    let model: MetricTileModel

    init(_ model: MetricTileModel) { self.model = model }

    var body: some View {
        SignalCell(label: model.label, value: model.value, unit: model.unit, delta: model.delta,
                   valueSize: 26, minScale: 0.7, fillsWidth: true)
    }
}

/// 2-column tile wall with thin rules between cells (no boxes): a vertical hairline between the
/// columns of each row and a horizontal hairline between rows.
struct MetricWall: View {
    let items: [MetricTileModel]
    var onTap: ((MetricTileModel) -> Void)? = nil

    init(items: [MetricTileModel], onTap: ((MetricTileModel) -> Void)? = nil) {
        self.items = items
        self.onTap = onTap
    }

    private var rows: [[MetricTileModel]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    WMRule()
                }
                HStack(alignment: .top, spacing: 0) {
                    cell(row[0])
                    Rectangle().fill(WM.Ground.rule).frame(width: WM.hairline)
                    if row.count > 1 {
                        cell(row[1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func cell(_ model: MetricTileModel) -> some View {
        let tile = MetricTile(model)
            .padding(.vertical, WM.Space.m)
            .padding(.horizontal, WM.Space.l)
        if let onTap {
            Button { onTap(model) } label: { tile }
                .buttonStyle(.plain)
        } else {
            tile
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
                            delta: WMDelta(up: true, text: "0:24", sentiment: .good)),
            MetricTileModel(label: "HRV", value: "74", unit: "ms",
                            delta: WMDelta(up: false, text: "3", sentiment: .bad)),
            MetricTileModel(label: "RHR", value: "52", unit: "bpm"),
            MetricTileModel(label: "SpO₂", value: "96.5", unit: "%",
                            delta: WMDelta(up: true, text: "0.2", sentiment: .neutral)),
            MetricTileModel(label: "Steps", value: "9,412")
        ], onTap: { _ in })
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
