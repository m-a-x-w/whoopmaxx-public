import SwiftUI

/// A labelled segmented row (037): label on the leading side, a rounded segmented control
/// trailing — a `track` capsule holding the options, the selected one filled ink with ground text.
/// Chrome stays neutral: no system segmented control, no tint. Shared (Appearance, Units, Sex, the
/// Wake-window Buzz strength, the Intake and Weed sheet pickers).
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
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    segment(option)
                }
            }
            .padding(3)
            .background(Capsule().fill(WM.Ground.track))
        }
        .frame(minHeight: WM.Space.row + 4)
    }

    private func segment(_ option: (value: String, name: String)) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Text(option.name)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(selected ? WM.Ground.ground : WM.Ground.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, WM.Space.m)
                .frame(minHeight: 34)
                .background(Capsule().fill(selected ? WM.Ground.ink : Color.clear))
                // A segment is 34pt tall (40 with the track's 3pt inset); the hit region reaches 5pt past
                // it on every side, to the HIG 44.
                .contentShape(Rectangle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .wmAnimation(WMMotion.transition, value: selected)
        .accessibilityLabel("\(label): \(option.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
