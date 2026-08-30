import Foundation

/// Pure formatting for the Live tab's sync-progress row: how far BEHIND the persisted store frontier
/// is while an offload runs. The gap is `now − newest persisted sample ts` — never a percent (the
/// protocol can't know the strap's total pending, so a duration is the only honest read).
enum SyncGap {
    /// The row's three honest states. `behind` carries the compact duration numeral ("2d 4h");
    /// the other two are word states with no numeral.
    enum Reading: Equatable {
        /// No persisted sample has ever landed — everything the strap holds is still to come.
        case firstSync
        /// The frontier is within the noise floor of now (< 5 min behind, or AHEAD of now — a strap
        /// clock drifted into the future must read as caught up, not a negative gap).
        case caughtUp
        /// Compact duration the store trails the wall clock: "2d 4h" / "4h 12m" / "12m".
        case behind(String)
    }

    /// Gaps under this read "caught up" — sub-5-minute lag is steady-state offload cadence, not a
    /// backlog worth a numeral.
    static let caughtUpFloor: TimeInterval = 5 * 60

    /// Resolve the frontier against `now`. nil frontier → `.firstSync`; gap < 5 min (including a
    /// frontier at/past now, i.e. strap clock drift) → `.caughtUp`; else `.behind(compact)`.
    static func reading(frontierUnix: TimeInterval?, now: TimeInterval) -> Reading {
        guard let frontierUnix else { return .firstSync }
        let gap = now - frontierUnix
        guard gap >= caughtUpFloor else { return .caughtUp }
        return .behind(compact(seconds: gap))
    }

    /// Compact two-unit duration: days+hours ("2d 4h"), hours+minutes ("4h 12m"), or minutes
    /// ("12m"). A zero remainder is dropped ("2d", "4h") — never a fabricated "0h"/"0m" filler.
    static func compact(seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}
