import Foundation

/// A habit's current run of kept days, read off the per-day verdicts `HabitsStore` already holds in
/// memory (037: the Log tab's habit rows carry a streak trailing, bad-colored once broken).
/// Pure — the caller hands it `HabitsStore.historyDated`, so there is no store read and no clock here.
///
/// Only `daily` and `weekdays` habits have one: they are the cadences whose per-day misses are
/// genuine (`HabitEvaluator.displayState`). A `weekly` habit's day off is not a miss and an `anytime`
/// habit has no schedule, so a "run" would count nothing real — those rows show their period
/// adherence, or nothing.
enum HabitStreak: Equatable {
    /// `days` consecutive scheduled days kept, counting today once it is done and never breaking on
    /// an open today. `isFloor` when the run reaches the edge of the window in memory: the true run
    /// may be longer, so the reading says "N+" rather than claiming a start it cannot see.
    case running(days: Int, isFloor: Bool)
    /// Nothing kept since the most recent closed scheduled day, which was missed.
    case broken
    /// Nothing to say — a weekly/anytime habit, or one with no kept or missed day yet. (Not `none`,
    /// which would shadow `Optional.none` wherever a streak is looked up.)
    case empty

    /// Days the walk covers: `HabitsStore`'s log cache spans a trailing 120 days (its private
    /// `readWindowDays`), so this is how far back a verdict is actually known.
    static let windowDays = 120

    /// - Parameters:
    ///   - dated: the habit's last `windowDays` verdicts, oldest first, ending today
    ///     (`HabitsStore.historyDated(habit, count: windowDays)`).
    ///   - createdDay: the habit's creation day on the LOGICAL clock — the walk stops there, because a
    ///     day before the habit existed is neither kept nor missed (historyDated marks those days
    ///     `.notScheduled`, which alone would read as an off-day and carry the run to the window edge).
    static func compute(dated: [(day: String, result: HabitDayResult)], cadence: HabitCadence,
                        createdDay: String) -> HabitStreak {
        switch cadence {
        case .weekly, .anytime:
            return .empty
        case .daily, .weekdays:
            break
        }
        var kept = 0
        var missed = false
        var reachedEdge = true
        for (index, entry) in dated.reversed().enumerated() {
            if entry.day < createdDay {
                reachedEdge = false
                break
            }
            // Today is still open: done counts, anything else neither extends nor breaks the run.
            if index == 0 {
                if entry.result.state == .done { kept += 1 }
                continue
            }
            switch entry.result.state {
            case .done:
                kept += 1
                continue
            case .notScheduled, .pending:
                continue
            case .missed:
                missed = true
            case .noData:
                break
            }
            reachedEdge = false
            break
        }
        // Ran off the window's oldest day still counting — a floor, unless the habit was created on
        // that very day, in which case the whole run is in view.
        let floor = reachedEdge && (dated.first.map { $0.day > createdDay } ?? false)
        if kept > 0 { return .running(days: kept, isFloor: floor) }
        return missed ? .broken : .empty
    }

    /// The visible reading ("12 d", "120+ d", "broken"), or nil for `.empty`.
    var text: String? {
        switch self {
        case let .running(days, isFloor): return "\(days)\(isFloor ? "+" : "") d"
        case .broken: return "broken"
        case .empty: return nil
        }
    }

    /// The spoken reading.
    var spoken: String? {
        switch self {
        case let .running(days, isFloor):
            return "\(isFloor ? "at least " : "")\(days) day\(days == 1 ? "" : "s") running"
        case .broken: return "streak broken"
        case .empty: return nil
        }
    }
}
