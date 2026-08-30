import SwiftUI

/// A simple ink segmented row: label on the left, the options on the right. Selection is ink
/// with a thin ink underline; unselected options are tertiary. Chrome stays neutral — no system
/// segmented control, no tint. Shared (also used by the Wake-window Buzz-strength control).
struct InkSegmentRow: View {
    let label: String
    /// (stored raw value, display name) pairs.
    let options: [(value: String, name: String)]
    @Binding var selection: String

    var body: some View {
        HStack {
            Text(label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.l)
            HStack(spacing: WM.Space.l) {
                ForEach(options, id: \.value) { option in
                    segment(option)
                }
            }
        }
    }

    private func segment(_ option: (value: String, name: String)) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            VStack(spacing: 3) {
                Text(option.name)
                    .font(WMType.label)
                    .foregroundStyle(selected ? WM.Ground.ink : WM.Ground.inkTertiary)
                Rectangle()
                    .fill(selected ? WM.Ground.ink : Color.clear)
                    .frame(height: 1.5)
            }
            // ≥44 hit target (HIG): horizontal padding widens the tap area (the underline stays
            // text-width), minHeight makes each segment 44 tall — which now also sets the row height.
            .padding(.horizontal, WM.Space.m)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(option.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
