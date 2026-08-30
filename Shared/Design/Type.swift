import SwiftUI

/// Type roles — SF Pro only. Display/numeral sizes are FIXED (huge instrument numerals;
/// pair with `minimumScaleFactor` where space is tight); the text roles ride Dynamic Type via the
/// nearest system text style.
enum WMType {

    /// The huge score/value numerals: SF Pro Light, fixed size, tabular digits.
    static func display(_ size: CGFloat = 72) -> Font {
        Font.system(size: size, weight: .light).monospacedDigit()
    }

    /// Secondary values (tiles, rows): SF Pro Light, fixed size, tabular digits. 22–40pt per 001.
    static func numeral(_ size: CGFloat = 28) -> Font {
        Font.system(size: size, weight: .light).monospacedDigit()
    }

    /// Screen titles — SF Pro Semibold 17–22pt (rides .title3, 20pt base).
    static let title: Font = .system(.title3, design: .default, weight: .semibold)

    /// SF Pro Medium 13pt (rides .footnote).
    static let label: Font = .system(.footnote, design: .default, weight: .medium)

    /// SF Pro Regular 15pt (rides .subheadline).
    static let body: Font = .system(.subheadline, design: .default, weight: .regular)

    /// SF Pro Regular 12pt, pair with `inkTertiary` (rides .caption).
    static let caption: Font = .system(.caption, design: .default, weight: .regular)

    /// Section eyebrows: SF Pro Semibold 11pt — apply via `.wmOverline()` which adds tracking,
    /// uppercase, and inkTertiary.
    static let overline: Font = .system(.caption2, design: .default, weight: .semibold)

    /// +8% tracking of the 11pt overline size.
    static let overlineTracking: CGFloat = 0.88

    /// The CHROME glyph roles. SF Symbols in the app's furniture (disclosure chevrons, back/close
    /// affordances, bar icons) get their size from here instead of a hand-written `.system(size:)`,
    /// so one glyph never drifts a point away from its twin. DATA glyphs (habit checkboxes, sport
    /// icons, pair status) are deliberately NOT roles — they size with the reading they illustrate.
    enum IconRole {
        /// Row disclosure chevrons (`chevron.right`), paired with `inkTertiary`.
        case disclosure
        /// In-content back affordance (`chevron.left`), paired with the row's text label.
        case nav
        /// Full-screen-cover / sheet close (`xmark`), paired with `inkSecondary`.
        case close
        /// Header action glyphs (`plus`) that stand alone in a 44×44 hit region.
        case action
        /// The custom tab bar's five symbols.
        case tab
    }

    /// Fixed glyph font for a chrome role — SF Symbols scale off the point size, so these stay
    /// fixed (like the numerals) rather than riding Dynamic Type.
    static func icon(_ role: IconRole) -> Font {
        switch role {
        case .disclosure: return Font.system(size: 11, weight: .semibold)
        case .nav:        return Font.system(size: 14, weight: .semibold)
        case .close:      return Font.system(size: 16, weight: .semibold)
        case .action:     return Font.system(size: 17, weight: .semibold)
        case .tab:        return Font.system(size: 18, weight: .medium)
        }
    }
}

/// The overline role as a single modifier: semibold 11pt + tracking + UPPERCASE + inkTertiary.
struct WMOverlineModifier: ViewModifier {
    var color: Color = WM.Ground.inkTertiary

    func body(content: Content) -> some View {
        content
            .font(WMType.overline)
            .kerning(WMType.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension View {
    /// Style this text as a section eyebrow / overline (uppercased, tracked, inkTertiary by default).
    func wmOverline(_ color: Color = WM.Ground.inkTertiary) -> some View {
        modifier(WMOverlineModifier(color: color))
    }
}

#Preview("Type — light") {
    TypeSpecimen().preferredColorScheme(.light)
}

#Preview("Type — dark") {
    TypeSpecimen().preferredColorScheme(.dark)
}

private struct TypeSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            Text("82").font(WMType.display()).foregroundStyle(WM.Ground.ink)
            Text("7:12").font(WMType.numeral()).foregroundStyle(WM.Ground.ink)
            Text("Today").font(WMType.title).foregroundStyle(WM.Ground.ink)
            Text("Resting heart rate").font(WMType.label).foregroundStyle(WM.Ground.ink)
            Text("Charge 82 — above your typical.").font(WMType.body).foregroundStyle(WM.Ground.inkSecondary)
            Text("vs 30-day typical").font(WMType.caption).foregroundStyle(WM.Ground.inkTertiary)
            Text("Signals").wmOverline()
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
