import Foundation
import StrapStore

/// Per-day verdict for one habit. `pending` is an OPEN (today) day not yet resolved. `noData` is
/// kept for the UI (glyphs/history render it) but the log-driven evaluator no longer emits it —
/// a closed day with no log is simply a miss.
struct HabitDayResult: Equatable {
    enum State: Equatable { case done, missed, pending, noData, notScheduled }
    enum Source: Equatable { case manual, none }
    let state: State
    let source: Source
    /// Short caption for the row, when the source has one.
    var detail: String? = nil
}

/// Current-period adherence: `done` of `target` scheduled occurrences, with `excludedNoData` days
/// dropped from the denominator.
struct HabitAdherence: Equatable {
    let done: Int
    let target: Int
    let excludedNoData: Int
}

/// Pure habit verdicts + adherence. Log-driven only (strap auto-verification was removed): a day's
/// state comes solely from the manual log row, so there is no clock, no store, no BLE here.
enum HabitEvaluator {

    // MARK: - Scheduling

    /// Whether the habit is scheduled on a day of the given `weekday` (Calendar 1=Sun … 7=Sat).
    /// `weekly` is eligible every day (its rate is done/N across the week); `anytime` never schedules.
    static func isScheduled(_ habit: Habit, weekday: Int) -> Bool {
        switch habit.cadence {
        case .daily:              return true
        case .weekly:             return true
        case let .weekdays(mask): return (mask & (1 << weekday)) != 0
        case .anytime:            return false
        }
    }

    // MARK: - Per-day verdict

    /// Resolve one day from its log alone. A log (ANY source string — legacy "override" rows count
    /// the same as "manual") decides done/missed; with no log, a closed (past) scheduled day is a
    /// miss and an open (today) day is `pending`, never a miss.
    static func dayResult(_ habit: Habit, closed: Bool, log: HabitLog?) -> HabitDayResult {
        if let log {
            return HabitDayResult(state: log.done ? .done : .missed, source: .manual)
        }
        return HabitDayResult(state: closed ? .missed : .pending, source: .none)
    }

    // MARK: - Adherence over a period

    /// Aggregate per-day results for the current period. `daily`/`weekdays` count scheduled,
    /// data-bearing days; `weekly` counts done days against N. `pending` (today, unresolved) is not
    /// yet a hit or a miss — it's excluded from the denominator until it resolves.
    static func periodAdherence(results: [HabitDayResult], cadence: HabitCadence) -> HabitAdherence {
        switch cadence {
        case let .weekly(n):
            let done = results.filter { $0.state == .done }.count
            return HabitAdherence(done: min(done, max(n, 0)), target: max(n, 0), excludedNoData: 0)
        case .anytime:
            let done = results.filter { $0.state == .done }.count
            return HabitAdherence(done: done, target: 0, excludedNoData: 0)
        case .daily, .weekdays:
            var done = 0, target = 0, excluded = 0
            for r in results {
                switch r.state {
                case .done:              done += 1; target += 1
                case .missed:            target += 1
                case .noData:            excluded += 1
                case .pending, .notScheduled: break   // not yet counted / not scheduled
                }
            }
            return HabitAdherence(done: done, target: target, excludedNoData: excluded)
        }
    }

    // MARK: - Display neutralization

    /// Map a per-day verdict to how it should DISPLAY for a cadence. A `weekly` or `anytime` habit is
    /// never "missed" on a specific day (the week's rate / no-schedule carries it), so a `.missed`
    /// reads as neutral `.pending` in glyphs and history cells. `daily`/`weekdays` keep real misses.
    /// Display-only — adherence math still sees the true verdict (weekly/anytime rates count `.done`
    /// only, so neutralizing a miss never changes the number).
    static func displayState(_ result: HabitDayResult, cadence: HabitCadence) -> HabitDayResult {
        switch cadence {
        case .weekly, .anytime:
            if result.state == .missed {
                return HabitDayResult(state: .pending, source: result.source, detail: result.detail)
            }
        case .daily, .weekdays:
            break
        }
        return result
    }
}
