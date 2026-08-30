import Foundation

/// What the Live-Activity controller should do on a given live tick. Pure + value-in/value-out so the
/// start/stop truth table is unit-tested away from ActivityKit (which can't run under XCTest).
enum LiveActivityAction: Equatable {
    case none    // leave things as they are
    case start   // request a new activity
    case update  // push fresh state to the existing activity
    case end     // tear the activity down
}

enum LiveActivityDecision {
    /// The decision for one live tick.
    ///
    /// - `systemEnabled`: iOS Settings → Live Activities master switch (`areActivitiesEnabled`). Off ⇒
    ///   never anything — the request would throw and an existing activity is the system's to dismiss.
    /// - `connected`: the LIVE link (not the sticky "bonded/paired" flag). A dropped link ends the
    ///   activity immediately so a frozen, fabricated "live" HR can't linger on the Lock Screen.
    /// - `hasBpm`: a heart rate is present to show.
    /// - `activityExists`: an activity is already running (possibly re-adopted from a prior launch).
    /// - `autoStartEnabled`: the user's auto-start preference for the continuous path. The manual
    ///   "Pin to Lock Screen" path passes `true` to force a start; once running, updates/ends don't
    ///   consult it (an existing activity keeps updating until disconnect or an explicit stop).
    static func decide(systemEnabled: Bool, connected: Bool, hasBpm: Bool,
                       activityExists: Bool, autoStartEnabled: Bool) -> LiveActivityAction {
        guard systemEnabled else { return .none }
        guard connected else { return activityExists ? .end : .none }
        if activityExists { return hasBpm ? .update : .none }
        if autoStartEnabled, hasBpm { return .start }
        return .none
    }
}
