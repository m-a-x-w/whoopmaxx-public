import Foundation
import Combine

/// Everything that BUZZES the wrist on the app's own initiative, in one place: the windowed habit
/// reminder (008), the Haptic Clock time check (#460), and the two buzz sources that only need
/// RECORDING (the smart-alarm early wake and BLEManager's inactivity nudge). It also owns the low-battery
/// notification, the other "the app decided to interrupt you" surface fed off the same live state.
///
/// Publishes nothing — `AppRoot` holds it as a plain `let` and calls `tick()` from the smoothed-HR sink
/// and the 15-minute backstop; the Strap Health button calls `buzzTimeCheck`. Lifted out of `AppRoot` so
/// the buzz policy (day scoping, per-habit once, cooldowns) is one readable unit instead of four blocks
/// interleaved with the composition root's wiring.
@MainActor
final class HabitBuzzScheduler {
    private let habits: HabitsStore
    private let ble: BLEManager
    private let live: LiveState
    private let buzzLog: BuzzLog
    /// Low strap-battery notification (007 F4): fires once per discharge cycle at ≤15% while not
    /// charging, deduped via a UserDefaults cycle marker. Fed by the `live.$batteryPct` sink below.
    private let batteryNotifier = BatteryNotifier()
    private var cancellables = Set<AnyCancellable>()

    init(habits: HabitsStore, ble: BLEManager, live: LiveState, buzzLog: BuzzLog) {
        self.habits = habits
        self.ble = ble
        self.live = live
        self.buzzLog = buzzLog

        // Haptic Clock (#460): a strap DOUBLE_TAP buzzes the current time back on the wrist. Funnels
        // through the same debounced trigger as the Strap Health button (buzzTimeCheck self-gates on a
        // live link + the cooldown), and records a `.timeCheck` buzz-history entry.
        live.onDoubleTap = { [weak self] in
            self?.buzzTimeCheck(label: "Time check (double-tap)")
        }

        // Low strap battery → one notification per discharge cycle (007 F4). The notifier's log
        // callback can arrive from a UNUserNotificationCenter completion handler (a background
        // queue), so hop to the main actor before touching the @MainActor strap log.
        batteryNotifier.log = { [weak live] line in
            Task { @MainActor in live?.append(log: line) }
        }
        // Use the EMITTED pct — @Published fires in willSet, so reading `live.batteryPct` back here
        // would see the stale pre-assignment value. `charging` is a DIFFERENT property (it did not
        // emit this event), so reading its current value is correct.
        live.$batteryPct
            .compactMap { $0 }
            .sink { [weak self] pct in
                guard let self else { return }
                self.batteryNotifier.handle(pct: pct, charging: self.live.charging)
            }
            .store(in: &cancellables)
    }

    /// The two hooks that must NOT be installed by a `#Preview`-built object graph: `AppModel.onInactivity`
    /// is a PROCESS-GLOBAL static, and the alarm sink belongs with the rest of the launch side effects.
    /// Called once from `AppRoot.start()`, which is itself one-shot guarded.
    func attachLaunchHooks(alarm: SmartAlarmCoordinator) {
        // Persist the smart-alarm early-wake buzz to the buzz-history log (the habit buzz records itself
        // in `tick`). Both run on the main actor, where BuzzLog.record is isolated.
        alarm.onBuzz = { [weak self] label in
            self?.buzzLog.record(source: .smartAlarm, label: label)
        }
        // The inactivity nudge buzzes inside the verbatim-frozen BLEManager, which already calls the
        // AppModel.postInactivity seam 1:1 with that buzz — hook it to record the buzz's reason without
        // editing BLEManager. (Fires on the main actor via maybeBuzzInactivity's @MainActor Task.)
        AppModel.onInactivity = { [weak self] _ in
            self?.buzzLog.record(source: .inactivity, label: "Inactivity nudge")
        }
    }

    // MARK: - Habit wrist-buzz (008)

    /// Habits already buzzed today (reset when the local day rolls) — the once-per-habit-per-day guard.
    private var habitBuzzedToday: Set<String> = []
    /// The logical day key `habitBuzzedToday` is scoped to (matches the store's habit day).
    private var habitBuzzDayKey = ""
    /// When the last habit buzz fired — enforces a cooldown so overlapping windows don't burst.
    private var habitLastBuzz: Date?
    /// Minimum spacing between habit buzzes (overlapping windows drain one/minute, not per-second).
    private static let habitBuzzCooldown: TimeInterval = 60

    /// Fire at most one gentle wrist buzz for a habit whose window is open right now. Gated on the
    /// strap being connected + worn (the buzz is a BLE write — no link, no buzz), the habit not
    /// already done / already buzzed today, and a cooldown since the last buzz. Purely the strap
    /// (008 — zero notifications). Called from the smoothed-HR sink (~1 Hz, responsive) and the
    /// 15-min tick (backstop).
    func tick() {
        guard live.connected, live.worn else { return }
        let now = Date()
        // Scope "buzzed today" + the isDone check to the store's LOGICAL habit day (not localDayKey),
        // so both agree on which day a buzz habit belongs to.
        let dayKey = habits.todayKey()
        if dayKey != habitBuzzDayKey {
            habitBuzzDayKey = dayKey
            habitBuzzedToday = []
        }
        let candidates = habits.buzzHabits(day: dayKey)
        guard !candidates.isEmpty else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        // Cheap first pass — any window open (incl. midnight-crossing) + not yet buzzed? Skips the
        // O(sleeps)+O(workouts) isDone scan on the ~1 Hz ticks whenever no window is open.
        let inWindow = candidates.filter { h in
            guard let w = h.buzz else { return false }
            return HabitBuzz.windowOpen(now: minute, start: w.start, end: w.end)
                && !habitBuzzedToday.contains(h.id)
        }
        guard !inWindow.isEmpty else { return }
        // Cooldown so several overlapping windows don't fire back-to-back buzzes seconds apart.
        if let last = habitLastBuzz, now.timeIntervalSince(last) < Self.habitBuzzCooldown { return }
        let doneToday = Set(inWindow.filter { habits.isDone($0, day: dayKey) }.map { $0.id })
        guard let habit = HabitBuzz.due(now: minute, habits: inWindow,
                                        doneToday: doneToday, buzzedToday: habitBuzzedToday)
        else { return }
        habitBuzzedToday.insert(habit.id)
        habitLastBuzz = now
        ble.buzzStrap(loops: 2)   // gentle, one-shot (patternId=2, 2 loops)
        live.append(log: "Habit buzz: \(habit.displayName)")
        buzzLog.record(source: .habit, label: habit.displayName)
    }

    // MARK: - Haptic Clock time check (#460)

    /// When the last time-check buzz started — re-triggers inside the cooldown are dropped, not queued.
    private var lastTimeCheckAt: Date?
    /// Minimum spacing between time-check buzzes. The longest sequence (12:55 → 12 longs + 11 shorts)
    /// runs ~20 s of scheduled pulses, so anything sooner would overlap the motor mid-readout — and a
    /// double-tap gesture often registers more than once in quick succession.
    private static let timeCheckCooldown: TimeInterval = 20

    /// Buzz the current time on the strap (Haptic Clock #460): long pulses count the hour on a 12-hour
    /// dial, short pulses count 5-minute blocks. Shared by the strap double-tap hook and the Strap
    /// Health button; `label` is the frozen buzz-history reason. Self-gates on a live link (the buzz is
    /// a BLE write — no link, no buzz) and the cooldown above, so tap storms can't stack sequences.
    @discardableResult
    func buzzTimeCheck(label: String) -> Bool {
        guard live.connected else { return false }
        let now = Date()
        if let last = lastTimeCheckAt, now.timeIntervalSince(last) < Self.timeCheckCooldown { return false }
        lastTimeCheckAt = now
        ble.buzzTimeNow()
        live.append(log: "Time check: buzzing the current time on the strap (\(label))")
        buzzLog.record(source: .timeCheck, label: label)
        return true
    }
}
