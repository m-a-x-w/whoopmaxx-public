import SwiftUI

/// The universal section wrapper: overline eyebrow + 0.5pt rule + content slot, with the section's
/// own top gap (24–36pt scale) so stacked sections space themselves.
struct RuleSection<Content: View>: View {
    let title: String
    /// Gap ABOVE this section (set 0 for the first section on a screen).
    var topGap: CGFloat = WM.Space.section
    /// Gap between the rule and the content.
    var contentGap: CGFloat = WM.Space.m
    private let content: Content

    init(_ title: String,
         topGap: CGFloat = WM.Space.section,
         contentGap: CGFloat = WM.Space.m,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.topGap = topGap
        self.contentGap = contentGap
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .wmOverline()
                .accessibilityAddTraits(.isHeader)   // app-wide: enables the VoiceOver Headings rotor to
                                                     // jump between sections instead of linear-swiping
                .padding(.bottom, WM.Space.s)
            WMRule()
                .padding(.bottom, contentGap)
            content
        }
        .padding(.top, topGap)
        .frame(maxWidth: .infinity, alignment: .leading)
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
