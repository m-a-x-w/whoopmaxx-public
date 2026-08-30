import SwiftUI

/// The strap status block (037) — no longer a raised panel: strap name over a status dot and
/// state caption, the battery as a numeral trailing, a `.row` `LineScale` of charge beneath, and the
/// caller's action (reconnect / forget) under that.
struct StrapPanel<Action: View>: View {
    let name: String
    let connected: Bool
    /// 0–100; nil hides the battery numeral and line.
    var batteryPct: Int? = nil
    /// State caption, e.g. "Connected — synced 2 min ago".
    var stateText: String
    private let action: Action

    init(name: String, connected: Bool, batteryPct: Int? = nil, stateText: String,
         @ViewBuilder action: () -> Action) {
        self.name = name
        self.connected = connected
        self.batteryPct = batteryPct
        self.stateText = stateText
        self.action = action()
    }

    /// Battery reads neutral until it is low enough to matter: warn under 31%, bad under 15%.
    private var levelColor: Color {
        guard let batteryPct else { return WM.Ground.ink }
        switch batteryPct {
        case ..<15: return WM.Semantic.bad
        case ..<31: return WM.Semantic.warn
        default:    return WM.Ground.ink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connected ? WM.Semantic.good : WM.Ground.inkTertiary)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(connected ? "Connected" : "Disconnected")
                        Text(stateText)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: WM.Space.s)
                if let batteryPct {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(batteryPct)")
                            .font(WMType.numeral(26))
                            .foregroundStyle(levelColor)
                        Text("%")
                            .font(WMType.label)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Battery \(batteryPct) percent")
                }
            }
            if let batteryPct {
                LineScale(value: Double(batteryPct) / 100, color: levelColor, style: .row)
            }
            action
        }
    }
}

extension StrapPanel where Action == EmptyView {
    init(name: String, connected: Bool, batteryPct: Int? = nil, stateText: String) {
        self.init(name: name, connected: connected, batteryPct: batteryPct,
                  stateText: stateText) { EmptyView() }
    }
}

#Preview("StrapPanel — light") {
    StrapPanelSpecimen().preferredColorScheme(.light)
}

#Preview("StrapPanel — dark") {
    StrapPanelSpecimen().preferredColorScheme(.dark)
}

private struct StrapPanelSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.sectionTight) {
            StrapPanel(name: "WHOOP 4.0", connected: true, batteryPct: 62,
                       stateText: "Synced 2 min ago") {
                Button("Details") {}
                    .font(WMType.label)
                    .tint(WM.Ground.ink)
            }
            StrapPanel(name: "WHOOP 4.0", connected: false, batteryPct: 12,
                       stateText: "Searching…") {
                Button("Reconnect") {}
                    .font(WMType.label)
                    .tint(WM.Ground.ink)
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
