import Foundation

/// What asked for a sync.
enum BackfillTrigger {
    /// The repeating timer while connected.
    case periodic
    /// A connect, or a bond confirmation.
    case connect
    /// The app came to the foreground.
    case foreground
    /// The user asked.
    case manual
    /// The strap said it has something.
    case strap
    /// An immediate continuation of a deep backlog, fired straight after an idle-cap exit while
    /// still connected. Like `.manual` it skips the floor — waiting the full periodic interval
    /// between chunks of one backlog is the thing it exists to avoid — and its runaway protection
    /// is a consecutive-run cap held by the caller, not a floor here.
    case autoContinue
}

/// When a historical offload is allowed to run.
///
/// Pure, so the cadence can be tested without a radio or a store.
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900
    /// Absorbs reconnect flapping and bursts of strap events.
    static let eventFloorSeconds: TimeInterval = 90
    static let emptyBackoffThreshold = 3
    static let maxEmptyBackoff: Double = 4

    /// `emptyStreak` counts completed offloads that banked no records at all.
    ///
    /// Past the threshold the AUTOMATIC triggers stretch their floor, doubling per empty up to the
    /// cap. A strap that is off the wrist still emits events every ninety seconds, and re-offloading
    /// nothing every ninety seconds drains both batteries for no data.
    ///
    /// A user-, connect- or foreground-driven sync never backs off, and the first real record resets
    /// the streak — so the moment the band is worn again, normal cadence resumes.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?, emptyStreak: Int = 0) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        let backoff: Double = emptyStreak >= emptyBackoffThreshold
            ? min(pow(2.0, Double(emptyStreak - emptyBackoffThreshold + 1)), maxEmptyBackoff)
            : 1.0
        switch trigger {
        case .manual, .autoContinue: return true
        case .connect, .foreground:  return elapsed >= eventFloorSeconds
        case .strap:                 return elapsed >= eventFloorSeconds * backoff
        case .periodic:              return elapsed >= periodicFloorSeconds * backoff
        }
    }
}
