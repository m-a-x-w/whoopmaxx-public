import Foundation

/// Whether to write the phone's time onto the strap on this connect.
enum ClockPolicy {
    /// Set the clock only when it has actually drifted.
    ///
    /// Writing it on every connect looks harmless and is not: the strap timestamps its own records
    /// from that clock, so a gratuitous reset puts a step in the middle of a history that every
    /// derived figure is keyed by. A couple of seconds of drift is not worth a discontinuity.
    static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = 2) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }
}
