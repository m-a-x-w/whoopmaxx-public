import SwiftUI

/// The strap status panel — one of the RARE contained surfaces (groundRaised, radius 14):
/// connection dot + strap name, battery micro bar strip + state caption, trailing action slot
/// (reconnect / forget button etc.).
struct StrapPanel<Action: View>: View {
    let name: String
    let connected: Bool
    /// 0–100; nil hides the battery strip.
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

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            Circle()
                .fill(connected ? WM.Semantic.good : WM.Ground.inkTertiary)
                .frame(width: 8, height: 8)
                .accessibilityLabel(connected ? "Connected" : "Disconnected")

            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(name)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.ink)
                HStack(spacing: WM.Space.s) {
                    if let batteryPct {
                        BatteryBars(pct: batteryPct)
                        Text("\(batteryPct)%")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                    Text(stateText)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: WM.Space.s)

            action
        }
        .padding(WM.Space.l)
        .background(
            RoundedRectangle(cornerRadius: WM.Radius.panel, style: .continuous)
                .fill(WM.Ground.groundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WM.Radius.panel, style: .continuous)
                .strokeBorder(WM.Ground.rule, lineWidth: WM.hairline)
        )
    }
}

extension StrapPanel where Action == EmptyView {
    init(name: String, connected: Bool, batteryPct: Int? = nil, stateText: String) {
        self.init(name: name, connected: connected, batteryPct: batteryPct,
                  stateText: stateText) { EmptyView() }
    }
}

/// Battery level in the bar motif: 10 micro bars, filled count = pct/10, level-colored
/// (good > 30, warn 15–30, bad < 15); empty bars in rule ink.
private struct BatteryBars: View {
    let pct: Int

    private var filled: Int { min(max(Int((Double(pct) / 10).rounded()), 0), 10) }

    private var levelColor: Color {
        switch pct {
        case ..<15: return WM.Semantic.bad
        case ..<31: return WM.Semantic.warn
        default:    return WM.Semantic.good
        }
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? levelColor : WM.Ground.rule)
                    .frame(width: 2.5, height: 10)
            }
        }
        .accessibilityHidden(true)
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
