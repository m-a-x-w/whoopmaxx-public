import SwiftUI

/// The grouped-list navigation row: title (+ optional caption subtitle) on the left, `WMDisclosure`
/// at the trailing edge, the whole row tappable at `WM.Space.s` vertical padding and at least
/// `WM.Space.row` tall (`row + 8` with a subtitle).
///
/// THE row shape for "this opens somewhere else" inside a `RuleSection`. It exists because More had
/// five byte-identical copies of it whose doc comments had started to chain — three of them literally
/// read "Mirrors `breatheRow`", which is the tell that a primitive was missing (the `WMCoverHeader`
/// story, one level down).
///
/// `subtitle` is the caption line under the title; omit it for a bare title row (Settings' "Pair a different strap").
/// `hint` is the VoiceOver hint naming what opens — the row already combines its children into one
/// element, so the hint is the only part a call site must word itself. Omit it when the title alone
/// says where the row goes.
struct WMNavRow: View {
    let title: String
    let subtitle: String?
    /// Trailing value text before the chevron ("whoopmaxx", "Now · 15:40"), inkSecondary.
    let value: String?
    let hint: String?
    /// Title color — ink by default; `WM.Semantic.bad` for a destructive row.
    let titleColor: Color
    /// false hides the chevron (a row that acts in place rather than pushing).
    let showsDisclosure: Bool
    let action: () -> Void

    init(title: String,
         subtitle: String? = nil,
         value: String? = nil,
         hint: String? = nil,
         titleColor: Color = WM.Ground.ink,
         showsDisclosure: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.hint = hint
        self.titleColor = titleColor
        self.showsDisclosure = showsDisclosure
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
                        .foregroundStyle(titleColor)
                    if let subtitle {
                        Text(subtitle)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: WM.Space.s)
                if let value {
                    Text(value)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .lineLimit(1)
                }
                if showsDisclosure {
                    WMDisclosure()
                }
            }
            .padding(.vertical, WM.Space.s)
            .frame(minHeight: subtitle == nil ? WM.Space.row : WM.Space.row + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
