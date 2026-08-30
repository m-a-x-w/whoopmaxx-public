import SwiftUI

/// Solid ink primary action — the one filled control in the language (chrome stays neutral ink).
struct WMPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.ground)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: WM.Radius.panel, style: .continuous)
                        .fill(enabled ? WM.Ground.ink : WM.Ground.inkTertiary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
