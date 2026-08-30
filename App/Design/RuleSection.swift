import SwiftUI

/// The universal section wrapper (037): a sentence-case section label + content slot, with the
/// section's own top gap so stacked sections space themselves. The Line language separates sections
/// with whitespace only — the rule under the label is gone; hairlines live between list rows.
struct RuleSection<Content: View>: View {
    let title: String
    /// Gap ABOVE this section (set 0 for the first section on a screen).
    var topGap: CGFloat = WM.Space.section
    /// Gap between the label and the content.
    var contentGap: CGFloat = WM.Space.m
    private let content: Content

    /// Optional trailing action beside the label ("All workouts", "History", "Manage").
    private let action: (title: String, handler: () -> Void)?
    /// VoiceOver hint for `action`, naming what it opens; nil when the title alone says it.
    private let actionHint: String?

    init(_ title: String,
         topGap: CGFloat = WM.Space.section,
         contentGap: CGFloat = WM.Space.m,
         action: (title: String, handler: () -> Void)? = nil,
         actionHint: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.topGap = topGap
        self.contentGap = contentGap
        self.action = action
        self.actionHint = actionHint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .wmOverline()
                    .accessibilityAddTraits(.isHeader)   // app-wide: enables the VoiceOver Headings rotor to
                                                         // jump between sections instead of linear-swiping
                Spacer(minLength: WM.Space.s)
                if let action {
                    actionButton(action)
                }
            }
            .padding(.bottom, contentGap)
            content
        }
        .padding(.top, topGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionButton(_ action: (title: String, handler: () -> Void)) -> some View {
        let button = Button(action: action.handler) {
            Text(action.title)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
                // Hit region grows to 44×44 without moving the label off the section's baseline or
                // the text off the trailing edge.
                .frame(minWidth: 44, alignment: .trailing)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .padding(.vertical, -14)
        }
        .buttonStyle(.plain)
        // `.accessibilityHint("")` is not a no-op (it publishes an empty hint), so it is applied only
        // when a call site worded one — the `WMNavRow` rule.
        if let actionHint {
            button.accessibilityHint(actionHint)
        } else {
            button
        }
    }
}

#Preview("RuleSection — light") {
    RuleSectionSpecimen().preferredColorScheme(.light)
}

#Preview("RuleSection — dark") {
    RuleSectionSpecimen().preferredColorScheme(.dark)
}

private struct RuleSectionSpecimen: View {
    var body: some View {
        VStack(spacing: 0) {
            RuleSection("Signals", topGap: 0) {
                Text("HRV 74 ms — above your typical.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
            }
            RuleSection("Today") {
                Text("One workout, 58 minutes.")
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
