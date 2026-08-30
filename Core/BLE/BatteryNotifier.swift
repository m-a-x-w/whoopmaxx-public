import Foundation
import UserNotifications

/// UserDefaults key + default for the strap alert preferences — the single source both this read
/// and the More → Preferences `@AppStorage` bind to.
enum StrapAlerts {
    /// "Low battery alert" (More → Preferences). Read via `object(forKey:)` so a stored value
    /// overrides in BOTH directions and only an unset key falls back to the default. Governs BOTH
    /// battery tiers — one switch, so turning it off silences the strap entirely.
    static let lowBatteryKey = "wm.strap.lowBatteryAlert"
    static let lowBatteryDefault = true

    static func lowBatteryEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: lowBatteryKey) as? Bool ?? lowBatteryDefault
    }

    static var lowBatteryEnabled: Bool { lowBatteryEnabled(in: .standard) }
}

/// Two-tier "strap battery is low" notification (007 F4), modeled on
/// `UserNotificationWakeNotifier`: stable ids, remove-then-add so posts never stack, lazy
/// authorization request on first use, `getNotificationSettings` gate. Non-actor-isolated —
/// UNUserNotificationCenter is thread-safe and its completion handlers arrive off the main queue.
///
/// TIERS: a WARNING at `thresholdPct` ("on the charger soon") and, further down the same discharge
/// cycle, a CRITICAL alert at `criticalPct` ("charge it now"). Each tier fires at most once per
/// cycle and carries its own request id, so the second is a new notification rather than a silent
/// replacement of a warning the user may have already dismissed.
///
/// DEDUPE is per DISCHARGE CYCLE, not per launch: UserDefaults markers are set when a tier fires
/// and cleared when the strap charges (live `charging` flag), climbs back over `rearmPct`, or
/// climbs `rearmRisePct` above the pct it last notified at (a PARTIAL charge we didn't watch —
/// e.g. topped up from 15 % to 28 % while the app was dead; the persisted battery read-back drops
/// the charging flag, so a SoC rise is the honest signal even when it never crosses `rearmPct`).
/// So the user hears about one low battery exactly once per tier until it actually charges.
///
/// The FIRE path additionally requires `charging == false` — an UNKNOWN (nil) charging state must
/// never notify: `charging` is nil at connect / after every disconnect and only populates from a
/// BATTERY_LEVEL event (~every 8 min), while the pct arrives immediately — and "docked the strap,
/// then opened the app" is exactly the moment a nil-state reading at 12 % would otherwise fire
/// "pop it on the charger" while it is already charging.
final class BatteryNotifier {

    /// Which tier a reading earned, or nil for "say nothing".
    enum Tier { case warning, critical }

    /// Stable id — presented in-foreground by `WakeNotificationPresenter` via the "wm.strap."
    /// prefix; a re-post removes + re-adds this one request.
    static let lowBatteryId = "wm.strap.lowBattery"
    /// The critical tier's OWN id (still under the presented "wm.strap." prefix) so it neither
    /// replaces nor is replaced by a warning that may still be sitting in Notification Centre.
    static let criticalId = "wm.strap.lowBattery.critical"
    /// Fire at or below this SoC while (known to be) not charging.
    static let thresholdPct: Double = 15
    /// Second, louder tier — fires again once the same discharge cycle reaches this SoC.
    static let criticalPct: Double = 5
    /// Climbing back over this clears the per-cycle markers (see type doc).
    static let rearmPct: Double = 30
    /// A rise of at least this much over the last-notified pct also clears the markers — the
    /// unwatched partial charge that peaks below `rearmPct` (see type doc).
    static let rearmRisePct: Double = 5
    /// UserDefaults marker: true once this discharge cycle already fired the WARNING tier.
    static let notifiedCycleKey = "wm.strap.lowBattery.notified"
    /// UserDefaults marker: true once this discharge cycle already fired the CRITICAL tier.
    static let notifiedCriticalKey = "wm.strap.lowBattery.notifiedCritical"
    /// UserDefaults: the pct the alert last fired at (the `rearmRisePct` reference point).
    static let notifiedPctKey = "wm.strap.lowBattery.notifiedPct"

    /// Optional strap-log sink for diagnostics (AppRoot threads `live.append(log:)`, hopping to
    /// the main actor — this can be called from a notification-center completion handler).
    var log: ((String) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Feed one battery reading (AppRoot's sink on `live.$batteryPct` — the EMITTED value).
    /// `charging` is the strap's live charging flag (nil until the first BATTERY_LEVEL event).
    func handle(pct: Double, charging: Bool?) {
        guard let tier = evaluate(pct: pct, charging: charging) else { return }
        post(pct: pct, tier: tier)
    }

    /// The decision + marker bookkeeping, with the post left out — everything here is testable
    /// without touching UNUserNotificationCenter.
    @discardableResult
    func evaluate(pct: Double, charging: Bool?) -> Tier? {
        // A charge, a climb back over the re-arm bar, or a ≥`rearmRisePct` rise above the pct we
        // last notified at ends the discharge cycle: clear the markers so the NEXT dip to a
        // threshold notifies again.
        let lastNotifiedPct = defaults.object(forKey: Self.notifiedPctKey) as? Double
        if charging == true || pct > Self.rearmPct
            || lastNotifiedPct.map({ pct >= $0 + Self.rearmRisePct }) == true {
            if defaults.bool(forKey: Self.notifiedCycleKey)
                || defaults.bool(forKey: Self.notifiedCriticalKey) {
                defaults.set(false, forKey: Self.notifiedCycleKey)
                defaults.set(false, forKey: Self.notifiedCriticalKey)
                defaults.removeObject(forKey: Self.notifiedPctKey)
            }
        }
        // Fire only on a KNOWN not-charging reading (see type doc — nil must stay silent).
        guard charging == false else { return nil }
        guard StrapAlerts.lowBatteryEnabled(in: defaults) else { return nil }
        // Mark a tier spent BEFORE the async auth hop in `post` — battery events land ~every 8
        // minutes, and the marker is the dedupe. A denied post just stays quiet for this cycle.
        //
        // Critical is checked FIRST and also spends the warning tier: a strap seen for the first
        // time at 4 % (a cold connect, or an 8-minute gap between BATTERY_LEVEL events that skips
        // straight past 15 %) should be told "now", and must not then post the milder copy after.
        if pct <= Self.criticalPct, !defaults.bool(forKey: Self.notifiedCriticalKey) {
            defaults.set(true, forKey: Self.notifiedCriticalKey)
            defaults.set(true, forKey: Self.notifiedCycleKey)
            defaults.set(pct, forKey: Self.notifiedPctKey)
            return .critical
        }
        guard pct <= Self.thresholdPct else { return nil }
        guard !defaults.bool(forKey: Self.notifiedCycleKey) else { return nil }
        defaults.set(true, forKey: Self.notifiedCycleKey)
        defaults.set(pct, forKey: Self.notifiedPctKey)
        return .warning
    }

    private func post(pct: Double, tier: Tier) {
        let center = UNUserNotificationCenter.current()
        let logSink = log
        let pctText = "\(Int(pct.rounded()))"
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Lazy first-use authorization request (the wake notifier's idiom).
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        logSink?("Strap battery: low-battery alert NOT posted (notifications denied)")
                        return
                    }
                    Self.add(center: center, pctText: pctText, tier: tier, log: logSink)
                }
            case .authorized, .provisional, .ephemeral:
                Self.add(center: center, pctText: pctText, tier: tier, log: logSink)
            default:
                logSink?("Strap battery: low-battery alert NOT posted (notifications not authorized)")
            }
        }
    }

    private static func add(center: UNUserNotificationCenter, pctText: String, tier: Tier,
                            log: ((String) -> Void)?) {
        let critical = tier == .critical
        let id = critical ? criticalId : lowBatteryId
        // Remove-then-add on the stable id so a re-fire replaces rather than stacks — DELIVERED as
        // well as pending, since these carry `trigger: nil` and so are delivered on the spot and
        // never sit in the pending list at all.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = critical
            ? String(localized: "Strap battery critical")
            : String(localized: "Strap battery low")
        content.body = critical
            ? String(localized: "Your strap is at \(pctText)% — charge it now or it stops recording.")
            : String(localized: "Your strap is at \(pctText)% — pop it on the charger soon.")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        log?("Strap battery: \(critical ? "critical" : "low")-battery notification posted at \(pctText)%")
    }
}
