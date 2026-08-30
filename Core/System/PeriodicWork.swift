import Foundation

/// The app's one register of timer-driven work: what runs on a schedule, under which id, and how to stop
/// it. Before this, each scheduled job was its own island — answering "what does this app run on a timer"
/// meant reading `AppRoot.init` end to end, and the deferred launch backup catch-up was spawned into the
/// void: never stored, never cancellable.
///
/// Deliberately NOT the home for every scheduling primitive in the app. Three stay where they are because
/// moving them would cost more than the uniformity is worth:
///  • The daily 00:01 smart-alarm re-arm (`AppRoot.scheduleDailySmartAlarmRearm`) is a `Timer` anchored to
///    a WALL-CLOCK instant via `Calendar.nextDate(matching:)`, with a foreground re-arm as its backstop.
///    Re-expressing it as a 24 h interval would trade DST-correct anchoring for uniformity.
///  • `BreathController`'s `Timer.publish` and the Live screen's HR sampler are VIEW-lifetime-scoped and
///    already cancelled when their view goes away. They are session UI, not app-level schedules.
///
/// There is no `suspendAll()` on `.background`, either: `UIBackgroundModes: bluetooth-central` buys BLE
/// wake-ups, not continuous scheduling. A suspended process does not resume a `Task.sleep`, so these jobs
/// stall by themselves and pick up when the process does — the honest foreground catch-up is the one
/// immediate pass `WhoopmaxxApp` fires on scenePhase `.active`.
///
/// Main-actor by design: cancel-then-install is one step under actor isolation (so a double registration
/// can never leave two loops ticking the same id), and every body registered here touches main-actor state.
@MainActor
final class PeriodicWork {
    /// Live jobs by id. One id = one job.
    private var jobs: [String: Task<Void, Never>] = [:]

    /// Run `body` every `interval` seconds until cancelled. The first run lands AFTER one interval, never
    /// at registration — the callers here are steady-state backstops whose launch-time pass is already
    /// covered explicitly on the launch path.
    func add(id: String, interval: TimeInterval, priority: TaskPriority = .utility,
             _ body: @escaping @MainActor () async -> Void) {
        cancel(id: id)
        jobs[id] = Task(priority: priority) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // Stop when the register itself is gone (its owner was torn down), not just on an
                // explicit cancel — otherwise a loop whose body can no longer do anything keeps waking.
                guard !Task.isCancelled, self != nil else { return }
                await body()
            }
        }
    }

    /// Run `body` ONCE, `delay` seconds from now — a deferred launch job that belongs in the register even
    /// though it doesn't repeat, so it is owned and cancellable like every interval job instead of being
    /// fired and forgotten. The slot frees when the body finishes. (Re-adding the same id while a one-shot
    /// is still in flight replaces it; the superseded body can then free the fresh one's slot on its way
    /// out — benign, and these ids are registered once at launch.)
    func once(id: String, after delay: TimeInterval, priority: TaskPriority = .utility,
              _ body: @escaping @MainActor () async -> Void) {
        cancel(id: id)
        jobs[id] = Task(priority: priority) { [weak self] in
            defer { self?.jobs[id] = nil }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    /// Stop the job registered under `id` and free its slot. A no-op when nothing is registered.
    func cancel(id: String) {
        jobs.removeValue(forKey: id)?.cancel()
    }

    /// Stop every job — the teardown handle for the whole register.
    func cancelAll() {
        for (_, task) in jobs { task.cancel() }
        jobs.removeAll()
    }
}
