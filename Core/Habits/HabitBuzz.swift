import Foundation

/// Pure decision for the windowed wrist-buzz (008). No clock, no BLE — the `AppRoot` hook feeds it
/// the current local minute + today's done/buzzed sets and fires `BLEManager.buzzStrap` for whatever
/// it returns. v1 buzzes at the window START (first live+worn tick inside the window), once per habit
/// per day, only if the habit isn't already done. HR-picked "smart moment" timing within the window
/// is deferred (008, with wind-down auto-verify).
enum HabitBuzz {
    /// Whether `now` (minutes-since-midnight) is inside `[start, end]`, supporting a window that
    /// CROSSES MIDNIGHT (start > end, e.g. a wind-down 23:00→00:30): then "open" means now >= start
    /// OR now <= end. A same-day window (start <= end) is the plain inclusive range.
    static func windowOpen(now: Int, start: Int, end: Int) -> Bool {
        start <= end ? (now >= start && now <= end) : (now >= start || now <= end)
    }

    /// The habit to buzz right now, or nil. Picks the buzz-enabled habit whose window contains `now`,
    /// isn't already done today, and hasn't buzzed today — earliest window end first so a tighter
    /// window wins when two overlap. At most one per tick (never stack buzzes).
    static func due(now: Int, habits: [Habit], doneToday: Set<String>,
                    buzzedToday: Set<String>) -> Habit? {
        habits
            .filter { h in
                guard let w = h.buzz else { return false }
                return windowOpen(now: now, start: w.start, end: w.end)
                    && !doneToday.contains(h.id)
                    && !buzzedToday.contains(h.id)
            }
            .min { ($0.buzz?.end ?? .max) < ($1.buzz?.end ?? .max) }
    }
}
