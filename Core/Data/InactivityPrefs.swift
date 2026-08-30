import Foundation
import Combine
import StrapAnalytics

/// The knobs behind the inactivity nudge, and the memory that stops it repeating itself.
///
/// The global gates deliberately REUSE the notification settings keys rather than forking them: an
/// app-wide "no notifications" or "quiet hours" that this feature ignored would be a bug, and two
/// copies of the same switch eventually disagree.
///
/// All the deciding lives in the engine. This is only storage — the screen edits it, and the
/// collection hook reads the same keys straight out of defaults so it never has to reach a
/// main-actor object from the connection layer.
///
/// The active-hours window is judged against the BOUT'S OWN local end time, never `now`. Movement
/// reaches the app when the strap flushes, so an overnight bout is examined the next morning;
/// keying off the current time would let "daytime only" fire at breakfast for a bout that happened
/// at 3 a.m.
@MainActor
final class InactivityPrefs: ObservableObject {

    /// Opt-in, and inert until the notification master switch is also on.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: K.enabled) } }
    /// Minutes seated before the first nudge.
    @Published var thresholdMinutes: Int { didSet { d.set(thresholdMinutes, forKey: K.threshold) } }
    /// How often to nudge again while still seated.
    @Published var reNudgeMinutes: Int { didSet { d.set(reNudgeMinutes, forKey: K.reNudge) } }
    /// Buzz strength, in loops.
    @Published var buzzLoops: Int { didSet { d.set(buzzLoops, forKey: K.buzzLoops) } }
    @Published var activeHoursEnabled: Bool { didSet { d.set(activeHoursEnabled, forKey: K.activeOn) } }
    /// Minutes since local midnight.
    @Published var activeStartMinutes: Int { didSet { d.set(activeStartMinutes, forKey: K.activeStart) } }
    @Published var activeEndMinutes: Int { didSet { d.set(activeEndMinutes, forKey: K.activeEnd) } }

    private let d = UserDefaults.standard

    private enum K {
        static let enabled     = "inactivity.enabled"
        static let threshold   = "inactivity.thresholdMinutes"
        static let reNudge     = "inactivity.reNudgeMinutes"
        static let buzzLoops   = "inactivity.buzzLoops"
        static let activeOn    = "inactivity.activeHoursEnabled"
        static let activeStart = "inactivity.activeStartMinutes"
        static let activeEnd   = "inactivity.activeEndMinutes"
        // Persisted so a relaunch cannot re-buzz a window that was already handled.
        static let lastProcessedTs = "inactivity.lastProcessedGravityTs"
        static let lastBuzzAt      = "inactivity.lastBuzzAt"
        static let lastBoutStart   = "inactivity.lastBuzzedBoutStart"
        static let lastBoutEnd     = "inactivity.lastBuzzedBoutEnd"
    }

    /// The notification switches, read where they already live.
    private enum NotifK {
        static let master     = "notif.masterEnabled"
        static let worn       = "notif.onlyWhenWorn"
        static let quiet      = "notif.quietHoursEnabled"
        static let quietStart = "notif.quietStartMinutes"
        static let quietEnd   = "notif.quietEndMinutes"
    }

    init() {
        let e = SedentaryDetector.self
        enabled            = d.object(forKey: K.enabled) as? Bool ?? false
        thresholdMinutes   = d.object(forKey: K.threshold) as? Int ?? e.defaultThresholdMinutes
        reNudgeMinutes     = d.object(forKey: K.reNudge) as? Int ?? e.defaultReNudgeMinutes
        buzzLoops          = d.object(forKey: K.buzzLoops) as? Int ?? e.defaultBuzzLoops
        activeHoursEnabled = d.object(forKey: K.activeOn) as? Bool ?? true
        activeStartMinutes = d.object(forKey: K.activeStart) as? Int ?? e.defaultActiveStartMin
        activeEndMinutes   = d.object(forKey: K.activeEnd) as? Int ?? e.defaultActiveEndMin
    }

    // MARK: - What the collection hook reads

    /// The knobs and the shared gates, as the engine wants them. The detector's own tunables keep
    /// their engine defaults — they are not user-facing and have no business in a settings screen.
    static func loadConfig(_ d: UserDefaults = .standard) -> SedentaryDetector.SedentaryConfig {
        let e = SedentaryDetector.self
        return SedentaryDetector.SedentaryConfig(
            enabled: d.object(forKey: K.enabled) as? Bool ?? false,
            notificationsMasterOn: d.object(forKey: NotifK.master) as? Bool ?? false,
            thresholdMinutes: d.object(forKey: K.threshold) as? Int ?? e.defaultThresholdMinutes,
            reNudgeMinutes: d.object(forKey: K.reNudge) as? Int ?? e.defaultReNudgeMinutes,
            buzzLoops: d.object(forKey: K.buzzLoops) as? Int ?? e.defaultBuzzLoops,
            activeHoursEnabled: d.object(forKey: K.activeOn) as? Bool ?? true,
            activeStartMinutes: d.object(forKey: K.activeStart) as? Int ?? e.defaultActiveStartMin,
            activeEndMinutes: d.object(forKey: K.activeEnd) as? Int ?? e.defaultActiveEndMin,
            quietHoursEnabled: d.object(forKey: NotifK.quiet) as? Bool ?? false,
            quietStartMinutes: d.object(forKey: NotifK.quietStart) as? Int ?? e.defaultQuietStartMin,
            quietEndMinutes: d.object(forKey: NotifK.quietEnd) as? Int ?? e.defaultQuietEndMin,
            onlyWhenWorn: d.object(forKey: NotifK.worn) as? Bool ?? true)
    }

    /// A cheap pre-check, so the hook can give up before touching the database.
    static func isEnabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: K.enabled) as? Bool ?? false
    }

    static func loadState(_ d: UserDefaults = .standard) -> SedentaryDetector.SedentaryState {
        SedentaryDetector.SedentaryState(
            lastProcessedGravityTs: d.object(forKey: K.lastProcessedTs) as? Int ?? 0,
            lastBuzzAt: d.object(forKey: K.lastBuzzAt) as? Int ?? 0,
            lastBuzzedBoutStart: d.object(forKey: K.lastBoutStart) as? Int ?? 0,
            lastBuzzedBoutEnd: d.object(forKey: K.lastBoutEnd) as? Int ?? 0)
    }

    static func saveState(_ s: SedentaryDetector.SedentaryState, to d: UserDefaults = .standard) {
        d.set(s.lastProcessedGravityTs, forKey: K.lastProcessedTs)
        d.set(s.lastBuzzAt, forKey: K.lastBuzzAt)
        d.set(s.lastBuzzedBoutStart, forKey: K.lastBoutStart)
        d.set(s.lastBuzzedBoutEnd, forKey: K.lastBoutEnd)
    }

    /// The offset in effect AT that instant, not the current one — so a bout either side of a
    /// daylight-saving change is judged against the clock the wearer was actually living by.
    static func tzOffsetSec(_ epochSec: Int) -> Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }
}
