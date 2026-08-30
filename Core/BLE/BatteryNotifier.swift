import Foundation
import UserNotifications

/// UserDefaults key + default for the strap alert preferences — the single source both this read
/// and the More → Preferences `@AppStorage` bind to.
enum StrapAlerts {
    /// "Low battery alert" (More → Preferences). Read via `object(forKey:)` so a stored value
    /// overrides in BOTH directions and only an unset key falls back to the default.
    static let lowBatteryKey = "wm.strap.lowBatteryAlert"
    static let lowBatteryDefault = true

    static var lowBatteryEnabled: Bool {
        UserDefaults.standard.object(forKey: lowBatteryKey) as? Bool ?? lowBatteryDefault
    }
}

/// One-shot "strap battery is low" notification (007 F4), modeled on
/// `UserNotificationWakeNotifier`: stable id, remove-then-add so posts never stack, lazy
/// authorization request on first use, `getNotificationSettings` gate. Non-actor-isolated —
/// UNUserNotificationCenter is thread-safe and its completion handlers arrive off the main queue.
///
/// DEDUPE is per DISCHARGE CYCLE, not per launch: a UserDefaults marker is set when the alert
/// fires and cleared when the strap charges (live `charging` flag), climbs back over `rearmPct`,
/// or climbs `rearmRisePct` above the pct it last notified at (a PARTIAL charge we didn't watch —
/// e.g. topped up from 15 % to 28 % while the app was dead; the persisted battery read-back drops
/// the charging flag, so a SoC rise is the honest signal even when it never crosses `rearmPct`).
/// So the user hears about one low battery exactly once until it actually charges.
///
/// The FIRE path additionally requires `charging == false` — an UNKNOWN (nil) charging state must
/// never notify: `charging` is nil at connect / after every disconnect and only populates from a
/// BATTERY_LEVEL event (~every 8 min), while the pct arrives immediately — and "docked the strap,
/// then opened the app" is exactly the moment a nil-state reading at 12 % would otherwise fire
/// "pop it on the charger" while it is already charging.
final class BatteryNotifier {

    /// Stable id — presented in-foreground by `WakeNotificationPresenter` via the "wm.strap."
    /// prefix; a re-post removes + re-adds this one request.
    static let lowBatteryId = "wm.strap.lowBattery"
    /// Fire at or below this SoC while (known to be) not charging.
    static let thresholdPct: Double = 15
    /// Climbing back over this clears the per-cycle marker (see type doc).
    static let rearmPct: Double = 30
    /// A rise of at least this much over the last-notified pct also clears the marker — the
    /// unwatched partial charge that peaks below `rearmPct` (see type doc).
    static let rearmRisePct: Double = 5
    /// UserDefaults marker: true once this discharge cycle already notified.
    static let notifiedCycleKey = "wm.strap.lowBattery.notified"
    /// UserDefaults: the pct the alert last fired at (the `rearmRisePct` reference point).
    static let notifiedPctKey = "wm.strap.lowBattery.notifiedPct"

    /// Optional strap-log sink for diagnostics (AppRoot threads `live.append(log:)`, hopping to
    /// the main actor — this can be called from a notification-center completion handler).
    var log: ((String) -> Void)?

    /// Feed one battery reading (AppRoot's sink on `live.$batteryPct` — the EMITTED value).
    /// `charging` is the strap's live charging flag (nil until the first BATTERY_LEVEL event).
    func handle(pct: Double, charging: Bool?) {
        let defaults = UserDefaults.standard
        // A charge, a climb back over the re-arm bar, or a ≥`rearmRisePct` rise above the pct we
        // last notified at ends the discharge cycle: clear the marker so the NEXT dip to the
        // threshold notifies again.
        let lastNotifiedPct = defaults.object(forKey: Self.notifiedPctKey) as? Double
        if charging == true || pct > Self.rearmPct
            || lastNotifiedPct.map({ pct >= $0 + Self.rearmRisePct }) == true {
            if defaults.bool(forKey: Self.notifiedCycleKey) {
                defaults.set(false, forKey: Self.notifiedCycleKey)
                defaults.removeObject(forKey: Self.notifiedPctKey)
            }
        }
        // Fire only on a KNOWN not-charging reading (see type doc — nil must stay silent).
        guard charging == false else { return }
        guard pct <= Self.thresholdPct else { return }
        guard StrapAlerts.lowBatteryEnabled else { return }
        guard !defaults.bool(forKey: Self.notifiedCycleKey) else { return }
        // Mark the cycle spent BEFORE the async auth hop — battery events land ~every 8 minutes,
        // and the marker is the dedupe. A denied post just stays quiet for this cycle.
        defaults.set(true, forKey: Self.notifiedCycleKey)
        defaults.set(pct, forKey: Self.notifiedPctKey)
        post(pct: pct)
    }

    private func post(pct: Double) {
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
                    Self.add(center: center, pctText: pctText, log: logSink)
                }
            case .authorized, .provisional, .ephemeral:
                Self.add(center: center, pctText: pctText, log: logSink)
            default:
                logSink?("Strap battery: low-battery alert NOT posted (notifications not authorized)")
            }
        }
    }

    private static func add(center: UNUserNotificationCenter, pctText: String,
                            log: ((String) -> Void)?) {
        // Remove-then-add on the stable id so a re-fire replaces rather than stacks.
        center.removePendingNotificationRequests(withIdentifiers: [lowBatteryId])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Strap battery low")
        content.body = String(localized: "Your strap is at \(pctText)% — pop it on the charger soon.")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: lowBatteryId, content: content, trigger: nil))
        log?("Strap battery: low-battery notification posted at \(pctText)%")
    }
}
