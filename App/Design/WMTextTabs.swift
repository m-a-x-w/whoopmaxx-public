import SwiftUI

/// Word tabs with a 4pt ink dot under the active one (037): range pickers (7D · 30D · 90D · 1Y),
/// Breathe presets, Signal Lab modes, Data's domain filter, Live's Raw · 5 s. The single replacement
/// for the hand-rolled ink-underline word toggles.
struct WMTextTabs<Value: Hashable>: View {
    /// (value, visible name) pairs, in display order.
    let options: [(value: Value, name: String)]
    @Binding var selection: Value
    /// The word size at the default Dynamic Type setting (15 = `.subheadline`, 13 = `.footnote`). It
    /// scales with the user's text size from there (`typeScale`).
    var size: CGFloat = 15
    var spacing: CGFloat = 22
    /// VoiceOver prefix ("Range"), read as "Range: 30D".
    var label: String? = nil

    /// Dynamic Type multiplier for `size`, 1 at the default setting. A system font has no
    /// `relativeTo:` form, so the caller's point size is scaled here instead.
    @ScaledMetric(relativeTo: .subheadline) private var typeScale: CGFloat = 1

    init(options: [(value: Value, name: String)], selection: Binding<Value>, size: CGFloat = 15,
         spacing: CGFloat = 22, label: String? = nil) {
        self.options = options
        self._selection = selection
        self.size = size
        self.spacing = spacing
        self.label = label
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                tab(option)
            }
        }
    }

    private func tab(_ option: (value: Value, name: String)) -> some View {
        let active = option.value == selection
        return Button {
            selection = option.value
        } label: {
            VStack(spacing: 5) {
                Text(option.name)
                    .font(.system(size: size * typeScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(active ? WM.Ground.ink : WM.Ground.inkTertiary)
                Circle()
                    .fill(active ? WM.Ground.ink : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .wmAnimation(WMMotion.transition, value: active)
        .accessibilityLabel(label.map { "\($0): \(option.name)" } ?? option.name)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

#Preview("WMTextTabs — light") {
    TextTabsSpecimen().preferredColorScheme(.light)
}

#Preview("WMTextTabs — dark") {
    TextTabsSpecimen().preferredColorScheme(.dark)
}

private struct TextTabsSpecimen: View {
    @State private var range = "30D"
    @State private var domain = 0

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            WMTextTabs(options: [("7D", "7D"), ("30D", "30D"), ("90D", "90D"), ("1Y", "1Y")],
                       selection: $range, label: "Range")
            WMTextTabs(options: [(0, "All"), (1, "Charge"), (2, "Effort"), (3, "Rest")], selection: $domain)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
