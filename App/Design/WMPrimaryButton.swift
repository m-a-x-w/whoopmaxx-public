import SwiftUI

/// The filled primary action (037): a full-width capsule, at least 54pt tall, ink with ground
/// text — the one filled control in the language (chrome stays neutral ink, color stays on data). The
/// title rides Dynamic Type from `.callout` (16pt).
struct WMPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WM.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(WM.Ground.ground)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(enabled ? WM.Ground.ink : WM.Ground.inkTertiary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The quiet companion action (037): text only in inkSecondary, with an optional leading
/// symbol ("Breathe", "Skip for now", "Test buzz"). At least 44×44, full width by default; the title
/// rides Dynamic Type from `.subheadline` (15pt).
struct WMSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    var fillsWidth: Bool = true
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, enabled: Bool = true, fillsWidth: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.enabled = enabled
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(enabled ? WM.Ground.inkSecondary : WM.Ground.inkTertiary)
            // minWidth keeps a short hugging title ("Edit") at the HIG 44 across.
            .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
