import SwiftUI

/// A toggle chip (037): the journal day tags, sheet option pickers. On = ink capsule with
/// ground text; off = a 1.5pt track outline with inkSecondary text. At least 36pt tall (the title
/// rides Dynamic Type from `.subheadline`), ≥44pt hit region.
struct WMChip: View {
    let title: String
    let isOn: Bool
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, isOn: Bool, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(isOn ? WM.Ground.ground : WM.Ground.inkSecondary)
                .padding(.horizontal, 15)
                .frame(minHeight: 36)
                .background(Capsule().fill(isOn ? WM.Ground.ink : Color.clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : WM.Ground.track, lineWidth: 1.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .wmAnimation(WMMotion.transition, value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

#Preview("WMChip — light") {
    ChipSpecimen().preferredColorScheme(.light)
}

#Preview("WMChip — dark") {
    ChipSpecimen().preferredColorScheme(.dark)
}

private struct ChipSpecimen: View {
    @State private var on: Set<String> = ["Late caffeine"]

    var body: some View {
        HStack(spacing: WM.Space.s) {
            ForEach(["Alcohol", "Late caffeine", "Stress"], id: \.self) { tag in
                WMChip(tag, isOn: on.contains(tag)) {
                    if on.contains(tag) { on.remove(tag) } else { on.insert(tag) }
                }
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
