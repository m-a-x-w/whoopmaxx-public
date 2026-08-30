import SwiftUI
import UIKit

// MARK: - Adaptive color plumbing

extension Color {
    /// Adaptive color from explicit light/dark variants via a UIColor dynamic provider — the backbone
    /// of every WM token. Both themes are DESIGNED, never inverted.
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// Adaptive color from two RGB hex values (0xRRGGBB) with optional per-theme opacity.
    init(lightHex: UInt32, darkHex: UInt32, lightOpacity: CGFloat = 1, darkOpacity: CGFloat = 1) {
        self.init(light: UIColor(hex: lightHex, alpha: lightOpacity),
                  dark: UIColor(hex: darkHex, alpha: darkOpacity))
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - WM design tokens ("precision instrument on paper")

enum WM {

    /// Hairline width for rules, borders, gridlines.
    static let hairline: CGFloat = 0.5

    // MARK: Grounds — papery warm light / soft graphite dark, never pure extremes.

    enum Ground {
        /// App canvas.
        static let ground = Color(lightHex: 0xFAF8F3, darkHex: 0x1B1A18)
        /// Rare tinted panels (strap panel, editors, sheets).
        static let groundRaised = Color(lightHex: 0xFFFFFF, darkHex: 0x232220)
        /// Primary text.
        static let ink = Color(lightHex: 0x1C1B19, darkHex: 0xF1EFE9)
        /// Secondary text.
        static let inkSecondary = Color(lightHex: 0x5A574F, darkHex: 0xA5A29A)
        /// Captions, axes. Darkened (light) / lightened (dark) from 0x8E8A80/0x6E6B63 to clear WCAG AA
        /// 4.5:1 for small informational text (units, deltas, axis labels): now ~4.7:1 light / ~5.1:1 dark.
        static let inkTertiary = Color(lightHex: 0x736F66, darkHex: 0x8E8A80)
        /// Thin section rules (0.5–1pt), ink @ 12%.
        static let rule = Color(lightHex: 0x1C1B19, darkHex: 0xF1EFE9,
                                lightOpacity: 0.12, darkOpacity: 0.12)
        /// Emphasized rules, ink @ 20%.
        static let ruleHeavy = Color(lightHex: 0x1C1B19, darkHex: 0xF1EFE9,
                                     lightOpacity: 0.20, darkOpacity: 0.20)
        /// Control accent (switch ON-tracks): ink in light; a mid warm graphite in dark — near-white ink
        /// would swallow the white thumb, so the dark track drops to a visible mid tone.
        static let control = Color(lightHex: 0x1C1B19, darkHex: 0x6E6A61)
    }

    // MARK: Domain color — color is DATA ONLY; chrome stays ink/neutral.

    enum Domain: String, CaseIterable, Hashable {
        case charge   // ember — warm ember orange
        case effort   // signal — signal red-pink
        case rest     // deep — deep indigo

        /// Full-strength domain color, adaptive per theme (dark variants are brightened per 001).
        var color: Color {
            switch self {
            case .charge: return Color(lightHex: 0xE8722A, darkHex: 0xF08A45)
            case .effort: return Color(lightHex: 0xE23D5E, darkHex: 0xF05A78)
            case .rest:   return Color(lightHex: 0x4B4FC7, darkHex: 0x7B7FF2)
            }
        }

        /// ~22% fill for secondary chart fills.
        var dim: Color { color.opacity(0.22) }

        /// ~10% fill for chart bands / washes.
        var wash: Color { color.opacity(0.10) }

        /// Display name for overlines ("CHARGE" once uppercased by the overline modifier).
        var displayName: String { rawValue.capitalized }
    }

    // MARK: Semantic — deltas and statuses only, never an accent.

    enum Semantic {
        static let good = Color(lightHex: 0x3E9B4F, darkHex: 0x59B96C)
        static let warn = Color(lightHex: 0xD9930D, darkHex: 0xE9AC33)
        static let bad  = Color(lightHex: 0xC93B3B, darkHex: 0xE05F5F)
    }

    // MARK: Spacing — 4pt grid.

    enum Space {
        /// The base 4pt grid unit.
        static let unit: CGFloat = 4
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        /// Screen edge gutters.
        static let gutter: CGFloat = 20
        /// Between-sections gap, tight end.
        static let sectionTight: CGFloat = 24
        /// Between-sections gap, default.
        static let section: CGFloat = 28
        /// Between-sections gap, loose end.
        static let sectionLoose: CGFloat = 36
    }

    // MARK: Radius

    enum Radius {
        /// The ONLY contained surface: groundRaised soft panel.
        static let panel: CGFloat = 14
    }
}
