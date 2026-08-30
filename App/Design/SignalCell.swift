import SwiftUI

/// A semantic delta vs baseline: ▲/▼ + magnitude, colored by what the direction MEANS (the caller
/// decides — e.g. RHR up is bad, HRV up is good). Shared by SignalCell, the Data metric rows
/// (`MetricTile`) and the metric detail.
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

    /// The spoken form ("down 2, worse") — one wording for every surface that reads a delta aloud.
    var spoken: String {
        "\(up ? "up" : "down") \(text)" + (sentiment.voiceOver.isEmpty ? "" : ", " + sentiment.voiceOver)
    }
}

/// Delta as a compact caption run — the single renderer every delta uses. Semibold so a 12pt colored
/// arrow still reads as a verdict beside a light numeral (the Line boards set deltas heavier than the
/// caption role's regular weight).
struct WMDeltaText: View {
    let delta: WMDelta

    var body: some View {
        Text("\(delta.arrow) \(delta.text)")
            .font(WMType.caption.weight(.semibold))
            .foregroundStyle(delta.sentiment.color)
            .accessibilityLabel(delta.spoken)
    }
}

/// A small labelled reading (037): a sentence-case label (`.wmOverline()`), a light numeral
/// (26 by default), and a caption line.
///
/// WHERE THE UNIT SITS follows the Line boards. With a delta, the unit rides the caption line after
/// it ("▼ 2 ms"): Today's four Signals share one row, and a unit beside a 26pt numeral does not fit a
/// quarter of the width. Without a delta (Live's HRV / Stress / Battery, Rest's timing, the workout
/// stats) the unit sits beside the numeral ("87 %"), where there is room and no caption to carry it.
struct SignalCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var delta: WMDelta? = nil
    /// Numeral point size.
    var valueSize: CGFloat = 26
    /// How far the numeral may shrink before truncating.
    var minScale: CGFloat = 0.6
    /// Take the full width offered (grid cells), vs sizing to content.
    var fillsWidth: Bool = false

    init(label: String, value: String, unit: String? = nil, delta: WMDelta? = nil,
         valueSize: CGFloat = 26, minScale: CGFloat = 0.6, fillsWidth: Bool = false) {
        self.label = label
        self.value = value
        self.unit = unit
        self.delta = delta
        self.valueSize = valueSize
        self.minScale = minScale
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text(value)
                    .font(WMType.numeral(valueSize))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(minScale)
                if delta == nil, let unit {
                    unitText(unit)
                }
            }
            if let delta {
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                    WMDeltaText(delta: delta)
                    if let unit {
                        unitText(unit)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        // One element, worded in reading order: the caption line puts the unit AFTER the arrow, so a
        // combined read would say "60, down 2, worse, ms".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private func unitText(_ unit: String) -> some View {
        Text(unit)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
    }

    private var spokenLabel: String {
        var s = "\(label), \(value)"
        if let unit, !unit.isEmpty { s += " \(unit)" }
        if let delta { s += ", \(delta.spoken)" }
        return s
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
        VStack(alignment: .leading, spacing: WM.Space.section) {
            // Today's Signals row: every cell carries a delta, so the units ride the caption line.
            HStack(alignment: .top, spacing: WM.Space.m) {
                SignalCell(label: "HRV", value: "60", unit: "ms",
                           delta: WMDelta(up: false, text: "2", sentiment: .bad), fillsWidth: true)
                SignalCell(label: "RHR", value: "60", unit: "bpm",
                           delta: WMDelta(up: true, text: "6", sentiment: .bad), fillsWidth: true)
                SignalCell(label: "Resp", value: "13.5", unit: "rpm",
                           delta: WMDelta(up: true, text: "1.0", sentiment: .warn), fillsWidth: true)
                SignalCell(label: "Skin", value: "+0.1", unit: "°C",
                           delta: WMDelta(up: true, text: "0.0°", sentiment: .neutral), fillsWidth: true)
            }
            // Delta-less cells (Live, Rest timing): the unit sits beside the numeral.
            HStack(alignment: .top, spacing: WM.Space.m) {
                SignalCell(label: "Efficiency", value: "87", unit: "%", fillsWidth: true)
                SignalCell(label: "Bed", value: "11:06", unit: "pm", fillsWidth: true)
                SignalCell(label: "Wake", value: "6:47", unit: "am", fillsWidth: true)
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
