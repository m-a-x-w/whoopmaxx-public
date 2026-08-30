import Foundation
import Combine
import StrapStore

/// A view-model row for the Today section (and reused by the detail list): a habit + its verdict on
/// the selected day, plus the current-period adherence for cadence habits (nil for daily/anytime,
/// which show only the day glyph).
struct HabitRowVM: Identifiable, Equatable {
    let habit: Habit
    let today: HabitDayResult
    let adherence: HabitAdherence?
    var id: String { habit.id }
}

/// `@MainActor` facade over the v25 `habit` / `habitLog` tables (008 Habits). Same shape as
/// `JournalStore`: load the definitions + the manual logs into published caches, then serve per-day
/// verdicts through the pure `HabitEvaluator`. Every habit is manually logged (no more derived auto
/// completions — strap verification was removed). Writes update the cache optimistically, persist,
/// and reload.
@MainActor
final class HabitsStore: ObservableObject {
    /// Trailing window the log cache spans (matches the Repository dashboard window).
    private static let readWindowDays = 120

    /// All habit definitions (including archived — the detail screen lists them; Today filters).
    @Published private(set) var habits: [Habit] = []
    /// Manual logs (incl. legacy "override"-source rows, read the same), keyed "habitId|day".
    @Published private(set) var logs: [String: HabitLog] = [:]

    private let repo: Repository
    private var deviceId: String { repo.deviceId }

    init(repo: Repository) {
        self.repo = repo
    }

    // MARK: - Load

    /// Re-read definitions + the trailing-window log cache from the store. Diff-guarded.
    func refresh() async {
        guard let store = await repo.storeHandle() else { return }
        let defs = (try? await store.habits(deviceId: deviceId)) ?? []
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-Double(Self.readWindowDays) * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let rows = (try? await store.habitLogs(deviceId: deviceId, from: from, to: to)) ?? []

        let mappedHabits = defs.map(Habit.init)
        var map: [String: HabitLog] = [:]
        for r in rows { map[Self.logKey(r.habitId, r.day)] = r }

        if habits != mappedHabits { habits = mappedHabits }
        if logs != map { logs = map }
    }

    /// Active (non-archived) habits pinned to Today, in sort order.
    var pinnedActive: [Habit] { habits.filter { !$0.archived && $0.pinned } }
    /// Active habits (for the detail screen's live list).
    var active: [Habit] { habits.filter { !$0.archived } }
    /// Archived habits (detail screen, restore/delete).
    var archived: [Habit] { habits.filter { $0.archived } }

    // MARK: - Verdicts

    private static func logKey(_ habitId: String, _ day: String) -> String { habitId + "|" + day }

    /// Today's LOGICAL day key — the same 4-hour-rollover anchor the Today screen resolves its
    /// `selectedKey` from, so a habit viewed on the "Today" row is never mis-judged as a closed past
    /// day during the 00:00–04:00 window (where localDayKey would already read tomorrow's date).
    func todayKey() -> String { Repository.logicalDayKey(Date()) }

    /// The row VM for one habit on `selectedKey` (the day the Today section is showing).
    func rowVM(_ habit: Habit, selectedKey: String) -> HabitRowVM {
        let today = todayKey()
        // A `weekdays` habit isn't scheduled on off-days — show `.notScheduled` (a real verdict there
        // would falsely read as a miss). Daily/weekly/anytime are eligible every day.
        // A day BEFORE the habit existed is not a miss — the same rule `historyDated` and
        // `trailingAdherence` already apply. That guard was only ever added to the Manage surfaces, so
        // Today kept inventing a failure record: browsing back rendered a warn-coloured miss square, and
        // every pre-creation weekday in the current week counted toward `target` in `periodAdherence`,
        // deflating the fraction. Manage and Today therefore disagreed about the identical habit and day.
        //
        // `createdDayKey` is on the LOGICAL clock, matching `todayKey()` and `selectedKey` — comparing
        // like with like, so a habit created inside the 00:00–04:00 window is loggable straight away.
        let created = createdDayKey(habit)
        let result: HabitDayResult
        if selectedKey < created {
            result = HabitDayResult(state: .notScheduled, source: .none)
        } else if case .weekdays = habit.cadence,
                  !HabitEvaluator.isScheduled(habit, weekday: weekday(of: selectedKey)) {
            result = HabitDayResult(state: .notScheduled, source: .none)
        } else {
            result = self.result(habit, day: selectedKey, todayKey: today)
        }
        var adherence: HabitAdherence? = nil
        switch habit.cadence {
        case .weekly, .weekdays:
            let week = weekDays(containing: selectedKey, todayKey: today)
            let scheduled = week
                .filter { $0 >= created }
                .filter { HabitEvaluator.isScheduled(habit, weekday: weekday(of: $0)) }
            let results = scheduled.map { self.result(habit, day: $0, todayKey: today) }
            adherence = HabitEvaluator.periodAdherence(results: results, cadence: habit.cadence)
        case .daily, .anytime:
            break
        }
        return HabitRowVM(habit: habit, today: result, adherence: adherence)
    }

    /// The pinned Today rows for the selected day.
    func todayRows(selectedKey: String) -> [HabitRowVM] {
        pinnedActive.map { rowVM($0, selectedKey: selectedKey) }
    }

    /// One day's verdict, from its manual log alone.
    func result(_ habit: Habit, day: String, todayKey: String) -> HabitDayResult {
        let closed = day < todayKey
        let log = logs[Self.logKey(habit.id, day)]
        return HabitEvaluator.dayResult(habit, closed: closed, log: log)
    }

    /// Last `count` days ending today, oldest first, each paired with its day key — the detail
    /// screen's history strip (keys let a cell tap backfill a day). A `weekdays` off-day
    /// is `.notScheduled`; every other cadence (including `anytime`, so logged days stay visible) is
    /// evaluated and neutralized for display (weekly/anytime never render a per-day miss).
    func historyDated(_ habit: Habit, count: Int = 30) -> [(day: String, result: HabitDayResult)] {
        let today = todayKey()
        guard let end = TodayModel.date(fromKey: today) else { return [] }
        let cal = Calendar.current
        var out: [(day: String, result: HabitDayResult)] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: end) else { continue }
            let key = TodayModel.key(from: d)
            // A day BEFORE the habit existed is not a miss. `createdAt` was always stored and never
            // consulted here, so a habit added today rendered a month of red "missed" cells and a 0/N
            // adherence for days on which it had not been set — the app inventing a failure record.
            if key < createdDayKey(habit) {
                out.append((key, HabitDayResult(state: .notScheduled, source: .none)))
            } else if isScheduledForDisplay(habit, key: key) {
                let r = result(habit, day: key, todayKey: today)
                out.append((key, HabitEvaluator.displayState(r, cadence: habit.cadence)))
            } else {
                out.append((key, HabitDayResult(state: .notScheduled, source: .none)))
            }
        }
        return out
    }

    /// The habit's creation day — the first day it could possibly be kept — on the LOGICAL (04:00
    /// rollover) clock.
    ///
    /// ONE helper on ONE clock, deliberately. Every surface that applies this gate walks the logical
    /// clock: `rowVM` compares against `todayKey()`/`selectedKey`, and `historyDated` seeds its walk from
    /// `todayKey()` too. Keying the gate on the plain LOCAL day instead put two clocks in one function —
    /// they diverge between 00:00 and 04:00, so a habit created at 01:00 had a creation day one AHEAD of
    /// the logical day it was created on, and its first day was erased from the Manage history and
    /// adherence while Today wrote its log to the earlier key.
    private func createdDayKey(_ habit: Habit) -> String {
        Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(habit.createdAt)))
    }

    /// Whether a day should be EVALUATED (vs `.notScheduled`) in the history: daily/weekly always,
    /// `anytime` always (so logged days show), `weekdays` only on its scheduled weekdays.
    private func isScheduledForDisplay(_ habit: Habit, key: String) -> Bool {
        if habit.cadence == .anytime { return true }
        return HabitEvaluator.isScheduled(habit, weekday: weekday(of: key))
    }

    /// Last `count` day results ending today, oldest first.
    func history(_ habit: Habit, count: Int = 30) -> [HabitDayResult] {
        historyDated(habit, count: count).map { $0.result }
    }

    /// Trailing-`count` adherence for the detail header (excludes no-data days). A `weekly(n)` habit
    /// is aggregated PER WEEK — done = Σ min(doneThatWeek, n), target = n × FULLY-observed weeks —
    /// rather than through the single-week `periodAdherence(.weekly)` (which would cap the window at
    /// n/n). Only weeks with all 7 days inside the window AND entirely on/after the habit's creation day
    /// count, so neither a partial edge week nor a week from before the habit existed skews it.
    func trailingAdherence(_ habit: Habit, count: Int = 30) -> HabitAdherence {
        if case let .weekly(n) = habit.cadence {
            let dated = historyDated(habit, count: count)
            // Drop pre-creation days BEFORE bucketing. `historyDated` emits `.notScheduled` for them
            // precisely so the app stops "inventing a failure record", but counting them here still let a
            // week entirely before the habit existed reach 7, land in `fullWeeks`, and contribute n to the
            // target with 0 done — a brand-new weekly(4) habit logged 3× read "3/12 · 30d" instead of 3/4.
            // A week straddling the creation day now falls short of 7 and is excluded as not fully
            // observed, which is exactly what this method's own contract already promises.
            let created = createdDayKey(habit)
            var daysByWeek: [String: Int] = [:]
            var doneByWeek: [String: Int] = [:]
            for entry in dated where entry.day >= created {
                let wk = weekBucket(entry.day)
                daysByWeek[wk, default: 0] += 1
                if entry.result.state == .done { doneByWeek[wk, default: 0] += 1 }
            }
            let fullWeeks = daysByWeek.filter { $0.value == 7 }.map(\.key)
            let done = fullWeeks.reduce(0) { $0 + min(doneByWeek[$1] ?? 0, n) }
            return HabitAdherence(done: done, target: max(n, 0) * fullWeeks.count, excludedNoData: 0)
        }
        let results = history(habit, count: count).filter { $0.state != .notScheduled }
        return HabitEvaluator.periodAdherence(results: results, cadence: habit.cadence)
    }

    /// A "year-week" bucket key for grouping days into calendar weeks.
    private func weekBucket(_ key: String) -> String {
        guard let d = TodayModel.date(fromKey: key) else { return key }
        let c = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    /// Toggle a day cell in the detail history — the manual backfill (tap on / off). No-op on
    /// future days.
    func editDay(_ habit: Habit, day: String) async {
        let today = todayKey()
        // No future days, and no editing an off-day for a weekdays habit (its history cell is
        // `.notScheduled` — a tap there would write an inert, invisible row).
        guard day <= today, isScheduledForDisplay(habit, key: day) else { return }
        let current = result(habit, day: day, todayKey: today)
        await logManual(habit, day: day, done: current.state != .done)
    }

    // MARK: - Day helpers

    private func weekday(of key: String) -> Int {
        guard let d = TodayModel.date(fromKey: key) else { return 1 }
        return Calendar.current.component(.weekday, from: d)
    }

    /// The wall-calendar week's day keys containing `key`, clamped to `todayKey` (no future days).
    private func weekDays(containing key: String, todayKey: String) -> [String] {
        guard let date = TodayModel.date(fromKey: key) else { return [key] }
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .weekOfYear, for: date) else { return [key] }
        var out: [String] = []
        var d = interval.start
        while d < interval.end {
            let k = TodayModel.key(from: d)
            if k <= todayKey { out.append(k) }
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    // MARK: - Writes

    /// Insert or update a habit definition, then reload.
    func save(_ habit: Habit) async {
        var next = habits.filter { $0.id != habit.id }
        next.append(habit)
        next.sort { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        habits = next
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.upsertHabits([habit.def], deviceId: deviceId)
        await refresh()
    }

    /// Archive / unarchive.
    func setArchived(_ habit: Habit, _ archived: Bool) async {
        var h = habit; h.archived = archived
        await save(h)
    }

    /// Hard-delete a habit and its logs.
    func delete(_ habit: Habit) async {
        habits.removeAll { $0.id == habit.id }
        logs = logs.filter { !$0.key.hasPrefix(habit.id + "|") }
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteHabit(deviceId: deviceId, id: habit.id)
        await refresh()
    }

    /// Log / clear a habit for a day. `done == false` CLEARS the log (a habit with no log reads
    /// pending today / miss once closed, so an explicit false row is redundant).
    func logManual(_ habit: Habit, day: String, done: Bool) async {
        if done {
            await upsertLog(habit.id, day: day, done: true, source: "manual")
        } else {
            await clearLog(habit.id, day: day)
        }
    }

    private func upsertLog(_ habitId: String, day: String, done: Bool, source: String) async {
        let log = HabitLog(habitId: habitId, day: day, done: done, source: source,
                           value: nil, stampedAt: Int(Date().timeIntervalSince1970))
        logs[Self.logKey(habitId, day)] = log
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.upsertHabitLogs([log], deviceId: deviceId)
        await refresh()
    }

    private func clearLog(_ habitId: String, day: String) async {
        logs[Self.logKey(habitId, day)] = nil
        guard let store = await repo.storeHandle() else { return }
        _ = try? await store.deleteHabitLog(deviceId: deviceId, habitId: habitId, day: day)
        await refresh()
    }

    // MARK: - Buzz support (008)

    /// Active habits eligible for a wrist-buzz (buzz window set), for the AppRoot live-loop hook.
    /// Buzz-enabled habits that are actually SCHEDULED on `day`.
    ///
    /// The cadence term is the point: without it a `weekdays` habit nudged the wrist on its off-days —
    /// on a row Today simultaneously renders as `.notScheduled` and refuses to let the user tap, so the
    /// buzz asked for something that could not be done and could not be dismissed. Every other consumer
    /// of "is this habit due today" already asks (`rowVM`, `isScheduledForDisplay`, `editDay`); the buzz
    /// path was the one that never did. `anytime` stays eligible — it is loggable every day by design.
    func buzzHabits(day: String) -> [Habit] {
        active.filter { $0.buzz != nil && isScheduledForDisplay($0, key: day) }
    }

    /// Whether a habit reads DONE for a day (logged done) — the buzz hook skips already-done habits.
    func isDone(_ habit: Habit, day: String) -> Bool {
        result(habit, day: day, todayKey: todayKey()).state == .done
    }
}
