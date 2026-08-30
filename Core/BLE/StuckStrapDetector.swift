import Foundation

/// Is the strap holding data it will not hand over?
///
/// Two facts have to hold together. The strap must say it has records NEWER than ours, and our own
/// frontier must have stopped moving. Either alone is normal: a frozen frontier just means nothing
/// new was recorded (the band is off the wrist), and a strap ahead of us is the ordinary state
/// mid-offload.
///
/// The frontier is the newest record actually PERSISTED, never the sync cursor — the cursor keeps
/// climbing on empty responses, which is exactly what happens while stuck.
struct StuckStrapDetector {
    let stuckAfterSeconds: TimeInterval
    /// How far ahead the strap must be before a frozen frontier means anything.
    let behindGapSeconds: Int

    private var lastFrontierTs: Int?
    private var lastAdvanceWall: TimeInterval?

    init(stuckAfterSeconds: TimeInterval, behindGapSeconds: Int = 300) {
        self.stuckAfterSeconds = stuckAfterSeconds
        self.behindGapSeconds = behindGapSeconds
    }

    mutating func observe(strapNewestTs: Int?, ourFrontierTs: Int?, now: TimeInterval) -> Bool {
        guard let strapNewest = strapNewestTs, let frontier = ourFrontierTs else { return false }

        // First sighting seeds the clock. Nothing can be stuck before there is a previous value.
        guard let last = lastFrontierTs else {
            lastFrontierTs = frontier
            lastAdvanceWall = now
            return false
        }
        if frontier > last {                      // moving — healthy, and the clock restarts
            lastFrontierTs = frontier
            lastAdvanceWall = now
            return false
        }
        guard strapNewest - frontier > behindGapSeconds else {
            lastAdvanceWall = now                 // caught up: a still frontier is correct here
            return false
        }
        return now - (lastAdvanceWall ?? now) >= stuckAfterSeconds
    }
}
