import SwiftUI
import UIKit

/// The in-app appearance override ("system" / "light" / "dark"), mirrored into the App-Group suite so the
/// widget / Live-Activity process can honor it. The extension never sees the app's standard defaults or the
/// root `.preferredColorScheme` — without the mirror it resolves every adaptive token against the SYSTEM
/// scheme and the widget/activity disagrees with the app whenever the pref isn't "system".
enum WMAppearance {
    /// Same key name as the app's `@AppStorage("ui.appearance")`, but in the SHARED suite.
    static let storageKey = "ui.appearance"

    /// App side: mirror the pref into the shared suite. Called on launch (covers installs that set the
    /// pref before the mirror existed) and on every change.
    static func mirror(_ raw: String) {
        UserDefaults(suiteName: WidgetSnapshot.suiteName)?.set(raw, forKey: storageKey)
    }

    /// The scheme a raw pref value forces; nil for "system" (or a not-yet-mirrored suite). Pure so the
    /// mapping is unit-testable.
    static func scheme(for raw: String?) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    /// Extension side: the forced scheme per the mirrored pref, re-read on every render (widget timeline
    /// reloads / activity content pushes are the app's job on a pref change).
    static var forced: ColorScheme? {
        scheme(for: UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: storageKey))
    }

    /// Resolve a WM token to the CONCRETE variant for the forced scheme (identity when "system"). Needed
    /// where SwiftUI resolves a Color OUTSIDE the view environment — `.activityBackgroundTint` and
    /// `.containerBackground(_:for: .widget)` ignore an `.environment(\.colorScheme, …)` override and
    /// would follow the system scheme. Tokens stay the single source of color truth; this only picks
    /// one of a token's two designed variants.
    static func resolve(_ color: Color) -> Color {
        guard let forced else { return color }
        return Color(uiColor: UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: forced == .dark ? .dark : .light)))
    }
}

extension View {
    /// Force the mirrored in-app scheme onto extension content; no-op when the pref is "system".
    @ViewBuilder func wmAppearance() -> some View {
        if let scheme = WMAppearance.forced {
            environment(\.colorScheme, scheme)
        } else {
            self
        }
    }
}
