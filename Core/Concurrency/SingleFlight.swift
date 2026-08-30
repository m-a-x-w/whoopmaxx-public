import Foundation

/// Join-in-flight coalescer: at most ONE `work` Task runs per key at a time, and everyone who asks while
/// it runs joins THAT Task instead of starting a second one.
///
/// A race guard, not a memo — the slot frees as soon as the work finishes, so the next call afterwards
/// runs fresh work. Where a finished result should also be REUSED, that's a cache sitting alongside this
/// (e.g. `BodyClockEngine.sharedCache`), never this map.
///
/// Main-actor by design: the lookup-then-install is one step under actor isolation, so two callers on the
/// same turn can never each install a Task for the same key.
///
/// NOT the right tool for mutual exclusion with domain-specific re-arm semantics (`ScoreEngine.computing`
/// + `pendingForcedRescore`, `Collector.flushInFlight`, `LiveActivityController.isStarting`): those
/// deliberately DROP or RE-ARM the second caller rather than joining the first, which is a different
/// contract.
@MainActor
final class SingleFlight<Key: Hashable, Value> {
    private var tasks: [Key: Task<Value, Never>] = [:]

    /// Run `work` for `key`, or join the Task already in flight for it; either way returns that Task's
    /// value.
    ///
    /// - Parameter restart: start a FRESH flight instead of joining an existing one — for a forced
    ///   recompute, which must not be served by a flight that began before the change that forced it.
    ///   Callers arriving after the restart join the fresh flight. (The superseded flight still clears
    ///   the slot when it finishes, which can free the fresh one's slot early: benign — the next caller
    ///   starts new work rather than joining, and the restart path is rare.)
    func run(_ key: Key, restart: Bool = false, _ work: @escaping () async -> Value) async -> Value {
        if !restart, let existing = tasks[key] { return await existing.value }
        let task = Task { [weak self] () -> Value in
            // Free the slot once the work is done (main-actor), so the next call runs fresh work rather
            // than joining a completed flight.
            defer { self?.tasks[key] = nil }
            return await work()
        }
        tasks[key] = task
        return await task.value
    }
}
