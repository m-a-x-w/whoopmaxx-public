import Foundation

/// Temperature-unit resolution for the whole app. The Metric/Imperial pref (`units.system`, set on the
/// More screen) is the SINGLE source of truth: metric shows °C, imperial shows °F. There is no separate
/// temperature override any more — it was folded into Units (W?/1.2), and a stale `units.temperature`
/// key left by an older build (or a restored backup) is migrated away once at launch by
/// `migrateTemperatureOverride`.
///
/// Two conversions, because the app shows temperature in two forms:
///   • an ABSOLUTE temperature (Signal Lab's physical skin-temp trace + cursor) converts °C→°F as ×9/5+32;
///   • a DEVIATION / delta (Today + Data skin-temp deviation — a ±°C move vs a personal baseline) converts
///     as ×9/5 ONLY, no +32: a +0.3 °C change is a +0.5 °F change, not +32.5.
enum TempUnit {
    /// The pref key both this helper and the More `@AppStorage` read/write.
    static let systemKey = "units.system"

    /// True when the user has chosen Imperial (°F). Reads the shared pref directly so non-View callers
    /// (the Signal Lab math seam) resolve the SAME value the `@AppStorage` views see.
    static var isImperial: Bool {
        UserDefaults.standard.string(forKey: systemKey) == "imperial"
    }

    /// The unit label to show for the current system.
    static func label(imperial: Bool) -> String { imperial ? "°F" : "°C" }

    /// Absolute °C → the display unit (°F when imperial). Identity in metric.
    static func absolute(_ celsius: Double, imperial: Bool) -> Double {
        imperial ? celsius * 9 / 5 + 32 : celsius
    }

    /// A ±°C DEVIATION/delta → the display unit (°F when imperial): scale only, NO +32 offset.
    /// Identity in metric.
    static func delta(_ celsius: Double, imperial: Bool) -> Double {
        imperial ? celsius * 9 / 5 : celsius
    }

    /// One-time migration of the retired `units.temperature` override into `units.system`: a user who had
    /// explicitly chosen Fahrenheit becomes Imperial; the "" (auto) / "celsius" cases just drop the key so
    /// Units alone drives temperature. Removing the key means this can't re-run. Cheap — call once at launch
    /// (AppRoot init) before any temperature surface reads the pref.
    static func migrateTemperatureOverride(_ defaults: UserDefaults = .standard) {
        let key = "units.temperature"
        guard defaults.object(forKey: key) != nil else { return }
        if defaults.string(forKey: key) == "fahrenheit" {
            defaults.set("imperial", forKey: systemKey)
        }
        defaults.removeObject(forKey: key)
    }
}
