import SwiftUI

/// The grouped-list navigation row: title (+ optional caption subtitle) on the left, `WMDisclosure`
/// at the trailing edge, the whole row tappable at `WM.Space.m` vertical padding.
///
/// THE row shape for "this opens somewhere else" inside a `RuleSection`. It exists because More had
/// five byte-identical copies of it whose doc comments had started to chain — three of them literally
/// read "Mirrors `breatheRow`", which is the tell that a primitive was missing (the `WMCoverHeader`
/// story, one level down).
///
/// `subtitle` is the caption line under the title; omit it for a bare title row (More's "Pair strap").
/// `hint` is the VoiceOver hint naming what opens — the row already combines its children into one
/// element, so the hint is the only part a call site must word itself. Omit it when the title alone
/// says where the row goes.
struct WMNavRow: View {
    let title: String
    let subtitle: String?
    let hint: String?
    let action: () -> Void

    init(title: String,
         subtitle: String? = nil,
         hint: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.hint = hint
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        // `.accessibilityHint("")` is not a no-op (it publishes an empty hint), so the modifier is
        // applied only when a call site worded one.
        if let hint {
            row.accessibilityHint(hint)
        } else {
            row
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                }
                Spacer()
                WMDisclosure()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }
}

#Preview("WMNavRow — light") {
    WMNavRowSpecimen().preferredColorScheme(.light)
}

#Preview("WMNavRow — dark") {
    WMNavRowSpecimen().preferredColorScheme(.dark)
}

private struct WMNavRowSpecimen: View {
    var body: some View {
        VStack(spacing: 0) {
            WMNavRow(title: "Breathe",
                     subtitle: "Guided paced breathing",
                     hint: "Opens a guided paced-breathing session") {}
            WMRule()
            WMNavRow(title: "Pair strap") {}
        }
        .padding(.horizontal, WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
