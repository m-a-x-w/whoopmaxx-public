import Foundation

/// Small, Codable glance snapshot shared between the app and its widget / Live-Activity extension via an
/// App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process database
/// access — the widget NEVER opens SQLite (W6 decision: snapshot-only). Ported from the original's WidgetSnapshot,
/// with whoopmaxx's Charge/Effort/Rest axis and the three trailing-30d baselines that let the medium
/// widget draw the signature ScoreColumn baseline tick.
public struct WidgetSnapshot: Codable, Equatable {
    // Headline glance.
    public var recovery: Int?    // Charge (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date

    // Richer stats. All OPTIONAL with nil defaults so a snapshot written by an OLDER app build (which
    // never encoded these keys) still decodes — Codable fills a missing optional with nil. Never remove or
    // renumber a field for the same reason; only add optional ones.
    public var effort: Int?      // Effort / strain, 0–100 axis
    public var rest: Int?        // Rest (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)

    // 30-day typicals (whoopmaxx W6) — the baseline ticks on the medium widget's ScoreTrio. Optional so
    // an older snapshot decodes; a nil baseline simply hides that column's tick (the calibrating look).
    public var chargeBaseline: Int?
    public var effortBaseline: Int?
    public var restBaseline: Int?

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                chargeBaseline: Int? = nil, effortBaseline: Int? = nil, restBaseline: Int? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.chargeBaseline = chargeBaseline
        self.effortBaseline = effortBaseline
        self.restBaseline = restBaseline
    }

    /// App Group suite the app and widget both use.
    ///
    /// Resolved by `AppGroup`, NOT read straight off the `AppGroupIdentifier` Info.plist key: the id the
    /// build asks for and the id the install is granted can differ, and when they do every consumer here
    /// silently no-ops against a private per-process store. See `AppGroup` for the two ways that happens
    /// and `isGroupProvisioned` for how a broken install reports itself.
    public static let suiteName: String = AppGroup.resolved
    public static let storageKey = "wm.widget.snapshot"

    /// Whether the shared container is actually reachable from this process.
    ///
    /// Checks the CONTAINER, not `UserDefaults(suiteName:)` — the latter returns non-nil even without the
    /// entitlement (it only returns nil for a nil/empty/bundle-id/global suite), so it cannot detect a
    /// dropped or rewritten app-group entitlement. `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// resolves ONLY when the entitlement is really present, which is the failure that matters.
    ///
    /// Readable in Release deliberately. This shipped as a Debug `assert` and so could only ever fire on
    /// the simulator, where Xcode signs properly and the group always works — it was structurally unable
    /// to fire on the sideloaded build, which is the only place the misprovisioning happens.
    public static var isGroupProvisioned: Bool { AppGroup.isProvisioned }

    /// Debug canary, kept for the fail-fast it gives during development. `isGroupProvisioned` is what
    /// Release code should read.
    public static func assertGroupProvisioned() {
        assert(isGroupProvisioned,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    /// Sample data for the widget GALLERY, where invented numbers are the point — the user is choosing a
    /// widget, not reading their health.
    ///
    /// NOT for a real timeline. `getTimeline`/`getSnapshot` used to fall back to this when the App Group
    /// held nothing, so a widget added before the app had ever published showed Charge 82, 58 bpm, 84 %
    /// battery and a green bonded dot — indistinguishable from measurement, on a phone that had never
    /// seen the strap. Those paths use `empty` instead; see it.
    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(recovery: 82, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 47, rest: 91, hrv: 64, restingHr: 52,
                       chargeBaseline: 61, effortBaseline: 55, restBaseline: 74)
    }

    /// The honest "nothing published yet" snapshot: every field nil, not bonded. Renders as em-dashes and
    /// an unbonded dot, which is exactly true on a fresh install.
    public static var empty: WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: Date(),
                       effort: nil, rest: nil, hrv: nil, restingHr: nil,
                       chargeBaseline: nil, effortBaseline: nil, restBaseline: nil)
    }

    /// True when this snapshot carries no measurement at all — the app has never published. Views use it
    /// to say "not set up yet" instead of printing a fresh `updated` timestamp over a grid of em-dashes,
    /// which reads as a broken extension rather than an app that has not run.
    public var isEmpty: Bool {
        recovery == nil && effort == nil && rest == nil && bpm == nil
            && hrv == nil && restingHr == nil && batteryPct == nil && !bonded
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared suite.
    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }

    /// Perf2: do two snapshots carry the same GLANCE VALUES, ignoring only the `updated` timestamp? The
    /// publish path always `.save()`s (so the freshest `updated` is stored) but only spends a WidgetKit
    /// reload when a value actually changed — an unconditional reload on every publish (incl. the 15-min
    /// background tick) burns WidgetKit's background-refresh budget on byte-identical data.
    public func sameValues(as other: WidgetSnapshot) -> Bool {
        var a = self
        a.updated = other.updated
        return a == other
    }
}
