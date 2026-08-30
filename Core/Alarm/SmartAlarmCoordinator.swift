import Foundation
import UserNotifications

// MARK: - Injectable seams (so the coordinator is unit-testable with a fake strap + notifier)

/// The strap-alarm surface the coordinator drives — the three EXISTING, verbatim-frozen BLEManager
/// methods (`Core/BLE/BLEManager.swift`). Abstracted only so tests can inject a fake; the app passes
/// the real `BLEManager`.
@MainActor
protocol AlarmStrap: AnyObject {
    /// Arm the firmware alarm for `date` (kill-proof backstop). BLEManager gates 5/MG behind Experimental.
    func armStrapAlarm(at date: Date)
    /// Drop the currently-armed firmware alarm.
    func disableStrapAlarm()
    /// One-shot on-device-confirmed wrist buzz.
    func buzzStrapOnce()
    /// One-shot wrist buzz at a caller-chosen insistence (motor loops) — the early-wake buzz + Test buzz.
    func buzzStrap(loops: Int)
    /// Whether `armStrapAlarm(at:)` will ACTUALLY arm, rather than log a refusal and return. A bond alone
    /// does not imply this: a 5/MG reaches `encryptedBond == true` on a plain CLIENT_HELLO ack, but the
    /// firmware alarm is additionally gated behind Experimental (BLEManager.swift:2450) because the 5/MG
    /// wake has never been observed firing. Without this the Rest screen promised a kill-proof wrist buzz
    /// that was silently never armed.
    var strapAlarmArmable: Bool { get }
}

extension AlarmStrap {
    /// Default keeps every existing conformer (the test fakes) compiling and behaving as before.
    var strapAlarmArmable: Bool { true }
}

extension BLEManager: AlarmStrap {
    /// App-driven buzz at a caller-chosen insistence (motor loops), via `runHapticsPattern` — the same
    /// preset (patternId=2) as the hardware-confirmed `buzzStrapOnce`, varying only the loop count (a safe,
    /// known parameter the haptic-clock + inactivity nudges already vary). `send` already remaps cmd 79 to
    /// the 5/MG maverick notify buzz, so this one ACKed (.withResponse, avoiding the #921 dropped-write)
    /// call covers both families. Uses the public `send`, so the frozen BLEManager body stays untouched.
    /// The GUARANTEED latest-edge firmware alarm buzz is a fixed captured pattern and is unaffected.
    func buzzStrap(loops: Int) {
        let n = UInt8(clamping: max(1, loops))
        send(.runHapticsPattern, payload: [2, n, 0, 0, 0], writeType: .withResponse)
    }

    /// Mirrors the family gate inside the frozen `armStrapAlarm(at:)` (BLEManager.swift:2445-2452) so the
    /// UI can tell "armed" from "refused". Read-only; changes nothing on the wire.
    var strapAlarmArmable: Bool { !isWhoop5 || PuffinExperiment.isEnabled }
}

/// The best-effort backup-wake notification surface (UNUserNotificationCenter). Abstracted so tests can
/// assert scheduling/cancel without touching the real center; the app uses `UserNotificationWakeNotifier`.
protocol WakeNotifier: AnyObject {
    /// (Re)schedule a SINGLE (non-repeating) backup wake for the NEXT occurrence of `minute`
    /// (minutes-since-midnight), re-armed each day by the coordinator's `apply()` path. Requests
    /// notification authorization lazily the first time. Replaces by stable id — never stacks.
    func scheduleBackup(atMinute minute: Int)
    /// Remove the pending backup wake (user disable / early fire). Drops only the single pending
    /// occurrence — the next day's is (re)scheduled by `apply()`.
    func cancelBackup()
    /// Post the wake notification NOW (strap fired, or a light-sleep early wake).
    func postWakeNow()
    /// Optional strap-log sink for diagnostics (which trigger was scheduled, why a schedule bailed).
    var log: ((String) -> Void)? { get set }
}

// MARK: - Coordinator

/// Orchestrates the Rest wake-window smart alarm (W9), constructed + wired by `AppRoot`.
///
/// LAYERS, floor-of-safety first:
///  1. FIRMWARE BACKSTOP — `armStrapAlarm(at:)` at the window's LATEST edge, armed only over a genuine
///     encrypted bond. Kill-proof: the strap buzzes even if whoopmaxx is closed.
///  2. NOTIFICATION BACKUP — a SINGLE (non-repeating) `UNCalendarNotificationTrigger` for the NEXT
///     latest-edge instant, scheduled regardless of bond so an unbonded / strap-absent user still gets an
///     OS wake, and re-armed each day by the same `apply()` path as the firmware backstop. Single (not
///     repeating) so an early fire's `cancelBackup()` drops ONLY today's occurrence — a repeating trigger
///     would have deleted every future day's wake too (C6). Best-effort (a sideloaded build has no
///     critical-alert entitlement; Focus / silent can mute it).
///  3. LIVE EARLY WAKE — while the app is alive, connected, worn AND inside the window, the pure
///     `SmartWakeWatcher` fires on a detected light-sleep HR-trough rise: buzz the strap NOW, post the
///     wake notification, DISARM the backstop, cancel the backup so nothing double-fires. Detection only
///     ever advances the wake EARLIER within [earliest, latest]; it can never wake the user later.
///
/// Re-arms on: strap-fired (`onStrapFired`), (re)bond, foreground, and a daily 00:01 timer (all via
/// `apply()`, which is idempotent and self-gates on `settings.enabled`).
@MainActor
final class SmartAlarmCoordinator: ObservableObject {

    let settings: SmartAlarmSettings

    private let ble: AlarmStrap
    private let live: LiveState
    private let notifier: WakeNotifier
    private let watcher: SmartWakeWatcher
    private let now: () -> Date
    private let cal: Calendar

    /// The deadline (epoch seconds) the watcher + fire-once state are currently bound to. A re-arm for a
    /// DIFFERENT deadline is a fresh night (reset the watcher); a re-arm for the same deadline preserves
    /// the trough + fired flags so a foreground bounce mid-window can't re-detect.
    private var armedDeadline: Double = 0
    /// True once this night was woken (early fire OR strap fire), so it can't buzz/re-arm again tonight.
    private var firedThisNight = false
    /// Wall-clock instant of the last wake this coordinator fired — an early-watcher fire OR a strap-driven
    /// backstop. `onStrapFired` de-dupes a firmware backstop by this instant's LOCAL DAY. Kept SEPARATE from
    /// firedThisNight / the scheduled+fired epochs because `onStrapFired` calls apply(), which advances those
    /// to tomorrow within the same call — so only an instant apply() never touches can dedup a stray/second
    /// frame for the same morning (see onStrapFired / earlyFire).
    private var lastStrapFiredEpoch: Double = 0

    private(set) var log: ((String) -> Void)?

    /// Records a real wake buzz to the persisted buzz-history ("why did the band buzz"), wired by AppRoot.
    /// Separate from `log` (the transient strap console) and NOT called from `testBuzz` — the test buzz is
    /// still recorded (as `.test`), but by its Rest call site, keeping this sink wake-only.
    var onBuzz: ((String) -> Void)?

    init(ble: AlarmStrap,
         live: LiveState,
         settings: SmartAlarmSettings,
         notifier: WakeNotifier = UserNotificationWakeNotifier(),
         watcher: SmartWakeWatcher = SmartWakeWatcher(),
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.ble = ble
        self.live = live
        self.settings = settings
        self.notifier = notifier
        self.watcher = watcher
        self.now = now
        self.cal = calendar
    }

    /// Wire the strap-log sink (AppRoot passes `live.append(log:)`). Threads it into the notifier too.
    func attachLog(_ sink: @escaping (String) -> Void) {
        log = sink
        notifier.log = sink
    }

    /// True only when the firmware backstop is actually armed on the strap right now (enabled + a genuine
    /// encrypted bond + a family/opt-in combination BLEManager will really arm). Drives the Rest section's
    /// armed-status line, whose copy promises a buzz "even if whoopmaxx is closed" — so a refused arm must
    /// read as `.backupOnly`, not `.armedOnStrap`.
    var isArmedOnStrap: Bool { settings.enabled && live.encryptedBond && ble.strapAlarmArmable }

    // MARK: - Arm / disarm

    /// Recompute + (re)arm everything from the current settings. Idempotent; safe to call on every
    /// trigger (settings change, bond edge, foreground, daily timer). Self-gates on `enabled`.
    func apply() {
        guard settings.enabled else {
            disarm()
            return
        }
        guard let deadline = Self.nextSmartAlarmDate(minutes: settings.latestMin, weekdays: [],
                                                     from: now(), calendar: cal) else {
            disarm()
            return
        }
        let deadlineEpoch = deadline.timeIntervalSince1970

        // Already woke for this exact deadline — this session (armedDeadline+firedThisNight) OR a prior one
        // (the PERSISTED firedDeadlineEpoch, which survives a force-quit). Don't re-arm the backstop/backup
        // the early fire deliberately dropped; a relaunch mid-window must not double-wake. Re-sync the
        // in-memory flags so the rest of the session stays consistent.
        if (deadlineEpoch == armedDeadline && firedThisNight) || deadlineEpoch == settings.firedDeadlineEpoch {
            armedDeadline = deadlineEpoch
            firedThisNight = true
            return
        }

        // A new night: re-arm the live detector's fire-once + trough.
        if deadlineEpoch != armedDeadline {
            armedDeadline = deadlineEpoch
            watcher.reset()
            firedThisNight = false
        }

        let windowStart = deadline.addingTimeInterval(-Double(settings.windowWidthMin) * 60)
        settings.scheduledDeadlineEpoch = deadlineEpoch
        settings.scheduledWindowStartEpoch = windowStart.timeIntervalSince1970

        // Layer 1: the firmware backstop, only over a genuine encrypted bond (a plain-bonded 5/MG has no
        // SET_ALARM_TIME characteristic, so arming there would silently no-op). BLEManager logs + gates.
        if live.encryptedBond {
            // Called unconditionally: BLEManager owns the refusal and its own log line, so the wire
            // behaviour is identical whether or not the family gate lets it through.
            ble.armStrapAlarm(at: deadline)
            if ble.strapAlarmArmable {
                log?("Smart alarm: armed strap backstop for the latest edge")
            } else {
                log?("Smart alarm: backup notification only — the 5/MG firmware alarm needs the Experimental toggle")
            }
        } else {
            log?("Smart alarm: strap not bonded — backup notification only")
        }

        // Layer 2: the best-effort OS backup, scheduled regardless of bond.
        notifier.scheduleBackup(atMinute: settings.latestMin)
    }

    /// Tear everything down (user turned the alarm off). The only path (besides an early fire dropping the
    /// backstop) that cancels — never reachable from detection.
    func disarm() {
        ble.disableStrapAlarm()
        notifier.cancelBackup()
        settings.scheduledDeadlineEpoch = 0
        settings.scheduledWindowStartEpoch = 0
        settings.firedDeadlineEpoch = 0
        armedDeadline = 0
        firedThisNight = false
        lastStrapFiredEpoch = 0
    }

    // MARK: - Live early wake

    /// Feed one smoothed live HR sample. Self-gates: does nothing unless the alarm is enabled, the night
    /// hasn't already fired, the strap is connected + worn, and we're INSIDE the armed window. On a
    /// detected light-sleep rise it advances the wake early.
    func feedHR(_ bpm: Int?) {
        guard settings.enabled, !firedThisNight else { return }
        guard live.connected, live.worn else { return }
        guard let bpm else { return }
        let t = now().timeIntervalSince1970
        let start = settings.scheduledWindowStartEpoch
        let deadline = settings.scheduledDeadlineEpoch
        // Never re-fire a deadline that already woke (guards the relaunch window before apply() runs).
        guard deadline > 0, deadline != settings.firedDeadlineEpoch, t >= start, t < deadline else { return }
        if watcher.shouldWake(bpm: bpm) { earlyFire() }
    }

    /// A light-sleep phase was detected inside the window: buzz now, notify, drop the backstop, cancel the
    /// backup, and mark the night fired so nothing double-fires.
    private func earlyFire() {
        firedThisNight = true
        // Mark this morning as woken so a stray/redelivered firmware backstop (event 57) is deduped by
        // onStrapFired even after a post-07:00 apply() advances the scheduled deadline to tomorrow.
        lastStrapFiredEpoch = now().timeIntervalSince1970
        settings.firedDeadlineEpoch = settings.scheduledDeadlineEpoch   // persist so a relaunch can't re-arm
        // Capture the decision at the instant of fire so the Rest "This morning's wake" panel can explain it
        // honestly. An early-watcher fire is provably app-alive + connected + worn + streaming.
        settings.record(WakeEvent(firedEpoch: now().timeIntervalSince1970,
                                  deadlineEpoch: settings.scheduledDeadlineEpoch,
                                  windowStartEpoch: settings.scheduledWindowStartEpoch,
                                  trigger: .earlyWatcher,
                                  troughBpm: watcher.currentTrough,
                                  thresholdBpm: watcher.fireThreshold,
                                  connected: live.connected,
                                  worn: live.worn,
                                  encryptedBond: live.encryptedBond))
        ble.buzzStrap(loops: settings.buzzLoops)   // early-wake buzz at the user's chosen strength
        onBuzz?("Smart alarm wake")                // persist the reason for the buzz-history surface
        notifier.postWakeNow()
        ble.disableStrapAlarm()      // detection advances the wake — drop the latest-edge backstop
        notifier.cancelBackup()      // and TODAY's single OS backup, so the deadline can't also fire this
                                     // morning; tomorrow's is (re)armed by the next apply() (C6)
        log?("Smart alarm: light-sleep early wake — buzzed strap, dropped the latest-edge backstop")
    }

    /// Fire the wake buzz NOW at the user's chosen strength so they can feel it — a pure one-shot buzz that
    /// arms/disarms nothing. The Rest UI gates the control on a connected strap (no strap = nothing to buzz).
    func testBuzz() {
        ble.buzzStrap(loops: settings.buzzLoops)
        log?("Smart alarm: test buzz (loops=\(settings.buzzLoops))")
    }

    // MARK: - Strap-driven fire

    /// The strap reported it executed its firmware alarm (STRAP_DRIVEN_ALARM_EXECUTED=57). Mirror the wake
    /// to a notification (phone-in-pocket) and re-arm the next occurrence. Never re-buzzes.
    func onStrapFired() {
        guard settings.enabled else { return }
        // Ignore a firmware backstop for a morning we've ALREADY woken — an early-watcher fire, or a
        // prior/redelivered event 57. Key off the last fired wall-clock's LOCAL DAY, NOT
        // scheduledDeadlineEpoch: a post-07:00 apply() advances the scheduled deadline to tomorrow, which
        // would otherwise reopen this path for the SAME morning's stray fire — earlyFire's
        // disableStrapAlarm() write is unacked (#921), so the firmware can fire anyway (dropped, or racing
        // the latest edge, possibly minutes after the early fire — past any short wall-clock debounce). If
        // it proceeded it would append a second .strapBackstop WakeEvent that OVERWRITES the true
        // .earlyWatcher attribution (latestWakeEvent = ring.last), post a second banner, AND persist
        // firedDeadlineEpoch = tomorrow's deadline — silently disabling the NEXT night. A genuine standalone
        // backstop has lastStrapFiredEpoch from a prior/zero morning, so it proceeds; a firmware alarm fires
        // once per morning, so a same-day gate can never swallow a genuine next fire (~24 h later).
        let t = now().timeIntervalSince1970
        if lastStrapFiredEpoch > 0,
           cal.isDate(Date(timeIntervalSince1970: t),
                      inSameDayAs: Date(timeIntervalSince1970: lastStrapFiredEpoch)) {
            return
        }
        lastStrapFiredEpoch = t
        firedThisNight = true
        settings.firedDeadlineEpoch = settings.scheduledDeadlineEpoch   // persist: today's deadline is spent
        // Record BEFORE apply() re-arms (which overwrites the scheduled epochs to tomorrow's). The firmware
        // backstop woke the user at the latest edge — the live watcher never engaged, so trough/threshold
        // are nil and the panel says so plainly rather than fabricating a detection.
        settings.record(WakeEvent(firedEpoch: now().timeIntervalSince1970,
                                  deadlineEpoch: settings.scheduledDeadlineEpoch,
                                  windowStartEpoch: settings.scheduledWindowStartEpoch,
                                  trigger: .strapBackstop,
                                  troughBpm: nil,
                                  thresholdBpm: nil,
                                  connected: live.connected,
                                  worn: live.worn,
                                  encryptedBond: live.encryptedBond))
        notifier.postWakeNow()
        apply()   // re-arm tomorrow (a new deadline resets the watcher inside apply)
    }

    // MARK: - Pure date math

    /// The next fire date for the alarm at `minutes` (minutes-since-midnight), honouring an optional
    /// weekday selection (kept for forward-compat; MVP always passes `[]` = every day). Returns the next
    /// strictly-future occurrence, scanning today + the next 7 days, or nil if no enabled weekday falls in
    /// range. Pure + side-effect-free so it's unit-testable against a fixed clock. (Ported from the original
    /// AppModel.nextSmartAlarmDate.)
    nonisolated static func nextSmartAlarmDate(minutes: Int,
                                               weekdays: Set<Int> = [],
                                               from now: Date = Date(),
                                               calendar cal: Calendar = .current) -> Date? {
        let valid = weekdays.filter { (1...7).contains($0) }
        if !weekdays.isEmpty && valid.isEmpty { return nil }
        // Support a latest edge that rolls past midnight by taking the minute mod a day.
        let mod = ((minutes % SmartAlarmSettings.minutesPerDay) + SmartAlarmSettings.minutesPerDay)
            % SmartAlarmSettings.minutesPerDay
        let hour = mod / 60
        let minute = mod % 60
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if fire <= now { continue }
            if weekdays.isEmpty { return fire }
            if valid.contains(cal.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }
}

// MARK: - Real notifier (UNUserNotificationCenter)

/// The app's `WakeNotifier`: a repeating daily backup wake + an immediate wake post, ported from the original's
/// AppModel notification helpers. Auth + enabled are the only gates (no separate master switch — a hidden
/// master would be a silent failure mode). Non-actor-isolated: UNUserNotificationCenter is thread-safe and
/// its completion handlers arrive off the main queue.
final class UserNotificationWakeNotifier: WakeNotifier {

    /// Stable id — a re-arm removes + re-adds this one request, so the backup never stacks.
    static let backupId = "wm.alarm.backup"
    /// The immediate wake post (strap-fired mirror / early wake). A fresh add replaces, never stacks.
    static let wakeId = "wm.alarm.wake"

    var log: ((String) -> Void)?

    func scheduleBackup(atMinute minute: Int) {
        let center = UNUserNotificationCenter.current()
        // Always clear first so a re-arm replaces rather than stacks.
        center.removePendingNotificationRequests(withIdentifiers: [Self.backupId])
        let logSink = log
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Lazy first-enable authorization request.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        logSink?("Smart alarm: backup NOT scheduled (notifications denied)")
                        return
                    }
                    Self.addBackup(center: center, minute: minute, log: logSink)
                }
            case .authorized, .provisional, .ephemeral:
                Self.addBackup(center: center, minute: minute, log: logSink)
            default:
                logSink?("Smart alarm: backup NOT scheduled (notifications not authorized)")
            }
        }
    }

    private static func addBackup(center: UNUserNotificationCenter, minute: Int,
                                  log: ((String) -> Void)?) {
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // C6: a SINGLE (non-repeating) trigger — with partial (hour/minute) components it fires exactly at
        // the NEXT time the clock reaches the latest edge, then never again. The daily 00:01 / foreground /
        // bond `apply()` path re-arms tomorrow's, so an early fire's `cancelBackup()` drops only today's
        // occurrence instead of wiping every future day (a `repeats: true` trigger would have).
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wake window")
        content.body = String(localized: "Backup wake: your latest wake time is here.")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: backupId, content: content, trigger: trigger))
        log?(String(format: "Smart alarm: backup wake scheduled for %02d:%02d (next occurrence, single request)",
                    minute / 60, minute % 60))
    }

    func cancelBackup() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.backupId])
    }

    func postWakeNow() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let ok: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: ok = true
            default: ok = false
            }
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Wake window")
            content.body = String(localized: "Good morning. Your wake window just woke you.")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: Self.wakeId, content: content, trigger: nil))
        }
    }
}

/// Presents wake notifications even while the app is FOREGROUND. iOS suppresses a `trigger: nil`
/// notification that posts while the app is active unless a delegate returns presentation options — which
/// is exactly the early-fire wake case (the watcher fires while the app is alive). Without this the
/// in-foreground wake alert is silently swallowed. Scoped to the app's own id prefixes — the alarm's
/// "wm.alarm." plus the strap alerts' "wm.strap." (007 F4 low battery, which likewise posts with
/// `trigger: nil` while the app streams battery events in the foreground) — so it never force-presents
/// an unrelated notification. Registered once at launch (AppRoot). Retained via the shared singleton.
final class WakeNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WakeNotificationPresenter()

    /// Set the notification-center delegate to the shared presenter (idempotent).
    static func register() { UNUserNotificationCenter.current().delegate = shared }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        let present = id.hasPrefix("wm.alarm.") || id.hasPrefix("wm.strap.")
        completionHandler(present ? [.banner, .sound] : [])
    }
}
