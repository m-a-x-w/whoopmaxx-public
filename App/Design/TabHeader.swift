import SwiftUI

/// A tab screen's header (037): the screen title (28 bold rounded) over a one-line subtitle,
/// with a trailing slot for the screen's own controls (strap chip, settings button, night stepper,
/// Raw/5 s). No horizontal padding — it sits inside the screen's gutter like the rest of the content.
struct TabHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Spacer(minLength: WM.Space.s)
            HStack(spacing: WM.Space.s) {
                trailing
            }
            .foregroundStyle(WM.Ground.inkSecondary)
        }
        .frame(minHeight: 64)
    }
}

extension TabHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// A bare SF Symbol button in a header (the settings button, add): 44×44 hit region, inkSecondary
/// glyph.
struct WMIconButton: View {
    let systemName: String
    /// VoiceOver label ("Settings").
    let label: String
    let action: () -> Void

    init(systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.action))
                .foregroundStyle(WM.Ground.inkSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The strap's battery at a glance (037): battery glyph + "82%". Tapping opens Strap health.
/// Pure — the caller reads `LiveState` and passes plain values, so the chip re-renders only when the
/// caller decides to observe the strap.
struct StrapChip: View {
    /// 0–100; nil when no reading has arrived.
    let batteryPct: Int?
    let connected: Bool
    /// false ⇒ no strap is paired at all.
    let paired: Bool
    let action: () -> Void

    init(batteryPct: Int?, connected: Bool, paired: Bool, action: @escaping () -> Void) {
        self.batteryPct = batteryPct
        self.connected = connected
        self.paired = paired
        self.action = action
    }

    private var symbol: String {
        guard let pct = batteryPct else { return "battery.0percent" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var text: String {
        guard paired else { return "No strap" }
        return batteryPct.map { "\($0)%" } ?? "—"
    }

    private var tint: Color {
        guard paired, connected else { return WM.Ground.inkTertiary }
        if let pct = batteryPct, pct < 15 { return WM.Semantic.bad }
        return WM.Ground.inkSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if paired {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .regular))
                }
                Text(text)
                    .font(WMType.label)
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paired
            ? "Strap battery \(batteryPct.map { "\($0) percent" } ?? "unknown"), \(connected ? "connected" : "not connected")"
            : "No strap paired")
        .accessibilityHint("Opens strap health")
    }
}

#Preview("TabHeader — light") {
    TabHeaderSpecimen().preferredColorScheme(.light)
}

#Preview("TabHeader — dark") {
    TabHeaderSpecimen().preferredColorScheme(.dark)
}

private struct TabHeaderSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.l) {
            TabHeader("Tuesday", subtitle: "29 September") {
                StrapChip(batteryPct: 82, connected: true, paired: true) {}
                WMIconButton(systemName: "slider.horizontal.3", label: "Settings") {}
            }
            TabHeader("Log", subtitle: "Tuesday 29 September")
            TabHeader("Today") {
                StrapChip(batteryPct: nil, connected: false, paired: false) {}
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
