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

// MARK: - WM design tokens ("Line" — 037)

enum WM {

    /// Hairline width for rules, borders, gridlines.
    static let hairline: CGFloat = 0.5

    // MARK: Grounds — warm paper light / soft graphite dark, never pure extremes.

    enum Ground {
        /// App canvas.
        static let ground = Color(lightHex: 0xF3F2EE, darkHex: 0x1B1A1E)
        /// The floating tab-bar pill and sheets — the only raised surfaces.
        static let groundRaised = Color(lightHex: 0xFFFFFF, darkHex: 0x26242A)
        /// Primary text.
        static let ink = Color(lightHex: 0x2A2622, darkHex: 0xF3EFE9)
        /// Row detail and paragraphs (~7.1:1 light / ~9.6:1 dark on `ground`).
        static let inkSecondary = Color(lightHex: 0x574F48, darkHex: 0xBDB5AC)
        /// Labels, units, axes. Measured ≥ 4.5:1 on `ground` in both themes (~4.7:1 light / ~4.9:1
        /// dark), because it carries small informational text.
        static let inkTertiary = Color(lightHex: 0x736A61, darkHex: 0x8E877F)
        /// The line-scale track, segmented-control background, search field, empty stage rail. A
        /// SURFACE tint, never text.
        static let track = Color(lightHex: 0xE6E4DE, darkHex: 0x2E2C32)
        /// Hairlines between list rows (and nowhere else).
        static let rule = Color(lightHex: 0x2A2622, darkHex: 0xF3EFE9,
                                lightOpacity: 0.10, darkOpacity: 0.12)
        /// Emphasized rules and dashed reference lines, ink @ 20%.
        static let ruleHeavy = Color(lightHex: 0x2A2622, darkHex: 0xF3EFE9,
                                     lightOpacity: 0.20, darkOpacity: 0.22)
        /// Toggle on-track only. Ink in light; a mid warm grey in dark, because a near-white track would
        /// swallow the system toggle's white thumb. Filled buttons and selected segments use `ink`
        /// (with `ground` text) instead, so they read as the brightest mark in both themes.
        static let control = Color(lightHex: 0x2A2622, darkHex: 0x8E877F)
    }

    // MARK: Domain color — color is DATA ONLY; chrome stays ink/neutral.

    enum Domain: String, CaseIterable, Hashable {
        case charge   // ember
        case effort   // rose
        case rest     // iris

        /// Full-strength domain color, adaptive per theme (dark variants brightened).
        var color: Color {
            switch self {
            case .charge: return Color(lightHex: 0xE8813F, darkHex: 0xFF9D5C)
            case .effort: return Color(lightHex: 0xDB5A80, darkHex: 0xFF7AA0)
            case .rest:   return Color(lightHex: 0x5F66D0, darkHex: 0x9297FF)
            }
        }

        /// ~30% fill for secondary chart fills.
        var dim: Color { color.opacity(0.30) }

        /// ~18% — the typical band on a line scale, chart area washes.
        var wash: Color { color.opacity(0.18) }

        /// Display name for section labels ("Charge").
        var displayName: String { rawValue.capitalized }
    }

    // MARK: Semantic — deltas and statuses only, never an accent.

    enum Semantic {
        static let good = Color(lightHex: 0x3B9463, darkHex: 0x62CC91)
        static let warn = Color(lightHex: 0xD9930D, darkHex: 0xE9AC33)
        static let bad  = Color(lightHex: 0xC9523F, darkHex: 0xFF8573)
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
        static let gutter: CGFloat = 24
        /// Between-sections gap, tight end.
        static let sectionTight: CGFloat = 28
        /// Between-sections gap, default.
        static let section: CGFloat = 40
        /// Between-sections gap, loose end.
        static let sectionLoose: CGFloat = 48
        /// Minimum list-row height (56 when the row carries a subtitle).
        static let row: CGFloat = 48
    }

    // MARK: Radius

    enum Radius {
        /// Sheet top corners.
        static let sheet: CGFloat = 28
    }
}
