import SwiftUI

/// A semantic delta vs baseline: ▲/▼ + magnitude, colored by what the direction MEANS (the caller
/// decides — e.g. RHR up is bad, HRV up is good). Shared by SignalCell and MetricTile.
struct WMDelta {
    enum Sentiment {
        case good, warn, bad, neutral

        var color: Color {
            switch self {
            case .good:    return WM.Semantic.good
            case .warn:    return WM.Semantic.warn
            case .bad:     return WM.Semantic.bad
            case .neutral: return WM.Ground.inkTertiary
            }
        }

        /// Spoken verdict for VoiceOver — the good/warn/bad meaning is otherwise color-only, so a favorable
        /// vs unfavorable move (e.g. HRV up vs RHR up) sounds identical. Empty for neutral (no trailing token).
        var voiceOver: String {
            switch self {
            case .good:    return "better"
            case .warn:    return "watch"
            case .bad:     return "worse"
            case .neutral: return ""
            }
        }
    }

    /// Arrow direction (true = ▲).
    let up: Bool
    /// Magnitude text, e.g. "6" or "0.4°".
    let text: String
    let sentiment: Sentiment

    init(up: Bool, text: String, sentiment: Sentiment) {
        self.up = up
        self.text = text
        self.sentiment = sentiment
    }

    var arrow: String { up ? "▲" : "▼" }
}

/// Delta as a compact caption run — the single renderer both cells use.
struct WMDeltaText: View {
    let delta: WMDelta

    var body: some View {
        Text("\(delta.arrow) \(delta.text)")
            .font(WMType.caption)
            .foregroundStyle(delta.sentiment.color)
            .accessibilityLabel("\(delta.up ? "up" : "down") \(delta.text)"
                + (delta.sentiment.voiceOver.isEmpty ? "" : ", " + delta.sentiment.voiceOver))
    }
}

/// Vitals mini-stat: overline label, numeral value + unit caption, optional semantic delta arrow.
/// Also THE renderer behind `MetricTile` (the Data wall's cell) — the two were the same view tree
/// apart from these three knobs, so the tile is now a preset rather than a second copy.
struct SignalCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var delta: WMDelta? = nil
    /// Numeral point size (the wall's tile runs one step smaller than the Today signal row).
    var valueSize: CGFloat = 28
    /// How far the numeral may shrink before truncating.
    var minScale: CGFloat = 0.6
    /// Take the full width offered (the wall's grid cells), vs sizing to content.
    var fillsWidth: Bool = false

    init(label: String, value: String, unit: String? = nil, delta: WMDelta? = nil,
         valueSize: CGFloat = 28, minScale: CGFloat = 0.6, fillsWidth: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.valueSize = valueSize
        self.minScale = minScale
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(label).wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text(value)
                    .font(WMType.numeral(valueSize))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(minScale)
                if let unit {
                    Text(unit)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            if let delta {
                WMDeltaText(delta: delta)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("SignalCell — light") {
    SignalCellSpecimen().preferredColorScheme(.light)
}

#Preview("SignalCell — dark") {
    SignalCellSpecimen().preferredColorScheme(.dark)
}

private struct SignalCellSpecimen: View {
    var body: some View {
        HStack(alignment: .top, spacing: WM.Space.sectionTight) {
            SignalCell(label: "HRV", value: "74", unit: "ms",
                       delta: WMDelta(up: true, text: "6", sentiment: .good))
            SignalCell(label: "RHR", value: "52", unit: "bpm",
                       delta: WMDelta(up: true, text: "2", sentiment: .bad))
            SignalCell(label: "Resp", value: "14.2", unit: "rpm",
                       delta: WMDelta(up: false, text: "0.1", sentiment: .neutral))
            SignalCell(label: "Skin temp", value: "+0.1", unit: "°C")
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
