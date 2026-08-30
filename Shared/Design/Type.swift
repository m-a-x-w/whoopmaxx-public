import SwiftUI

/// Type roles — SF Pro Rounded throughout (037). Display/numeral sizes are FIXED
/// (hero numerals; pair with `minimumScaleFactor` where space is tight) and always light with tabular
/// digits; the text roles ride Dynamic Type via the nearest system text style.
enum WMType {

    /// Hero numerals: SF Pro Rounded Light, fixed size, tabular digits. Today 104, Rest 96, Live 128.
    static func display(_ size: CGFloat = 72) -> Font {
        Font.system(size: size, weight: .light, design: .rounded).monospacedDigit()
    }

    /// Row and readout numerals: SF Pro Rounded Light, fixed size, tabular digits (22–40).
    static func numeral(_ size: CGFloat = 28) -> Font {
        Font.system(size: size, weight: .light, design: .rounded).monospacedDigit()
    }

    /// Screen titles — SF Pro Rounded Bold, rides .title (28pt base).
    static let title: Font = .system(.title, design: .rounded, weight: .bold)

    /// SF Pro Rounded Medium 13pt (rides .footnote).
    static let label: Font = .system(.footnote, design: .rounded, weight: .medium)

    /// SF Pro Rounded Medium 15pt (rides .subheadline) — row titles and paragraphs.
    static let body: Font = .system(.subheadline, design: .rounded, weight: .medium)

    /// SF Pro Rounded Regular 12pt, pair with `inkTertiary` (rides .caption).
    static let caption: Font = .system(.caption, design: .rounded, weight: .regular)

    /// Section labels: SF Pro Rounded Semibold 13pt — apply via `.wmOverline()`, which colors it
    /// inkTertiary. Sentence case: no uppercase, no tracking (the Line language drops the eyebrow).
    static let overline: Font = .system(.footnote, design: .rounded, weight: .semibold)

    /// The CHROME glyph roles. SF Symbols in the app's furniture (disclosure chevrons, back/close
    /// affordances, bar icons) get their size from here instead of a hand-written `.system(size:)`,
    /// so one glyph never drifts a point away from its twin. DATA glyphs (habit checkboxes, pair
    /// status) are deliberately NOT roles — they size with the reading they illustrate.
    enum IconRole {
        /// Row disclosure chevrons (`chevron.right`), paired with `inkTertiary`.
        case disclosure
        /// In-content back affordance (`chevron.left`), paired with the row's text label.
        case nav
        /// Full-screen-cover / sheet close (`xmark`), paired with `inkSecondary`.
        case close
        /// Header action glyphs (`plus`, the settings button's `slider.horizontal.3`) that stand alone
        /// in a 44×44 hit region.
        case action
        /// The custom tab bar's five symbols.
        case tab
        /// Small glyphs set inside a control: the −/+ of an amount stepper, the ‹ › of a day stepper,
        /// a search field's magnifier and its clear button.
        case inline
    }

    /// Fixed glyph font for a chrome role — SF Symbols scale off the point size, so these stay
    /// fixed (like the numerals) rather than riding Dynamic Type.
    static func icon(_ role: IconRole) -> Font {
        switch role {
        case .disclosure: return Font.system(size: 12, weight: .semibold)
        case .nav:        return Font.system(size: 16, weight: .semibold)
        case .close:      return Font.system(size: 17, weight: .semibold)
        case .action:     return Font.system(size: 19, weight: .regular)
        case .tab:        return Font.system(size: 21, weight: .regular)
        case .inline:     return Font.system(size: 14, weight: .semibold)
        }
    }
}

/// The section-label role as a single modifier: 13pt rounded semibold + inkTertiary, sentence case.
/// (The name predates the Line language, when this was an uppercased tracked eyebrow; the call sites
/// kept it, so the look changed here instead of at each of them.)
struct WMOverlineModifier: ViewModifier {
    var color: Color = WM.Ground.inkTertiary

    func body(content: Content) -> some View {
        content
            .font(WMType.overline)
            .foregroundStyle(color)
    }
}

extension View {
    /// Style this text as a section label (sentence case, inkTertiary by default).
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
