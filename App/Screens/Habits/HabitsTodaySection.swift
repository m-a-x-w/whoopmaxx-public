import SwiftUI
import StrapStore

/// "Habits · x of y" on the Log tab (008; moved off Today by 037): ALL pinned habits on the given
/// day, each row a check-off, with "Manage" in the label row pushing the detail. Env-driven (like
/// `AutoWorkoutRow`) since each row's verdict comes from the manual logs through `HabitsStore`.
///
/// Renders its own section label (the x of y count lives in it), so a host places it like any other
/// section. x of y counts only the habits DUE that day — a weekdays habit on its off-day is not a y.
///
/// Each daily/weekdays row carries its current streak trailing (`HabitStreak`; "broken" in the bad
/// color), a weekly row its week's adherence. The streaks are derived once per `HabitsStore` publish
/// or change of day — never on a body pass — from verdicts already in memory.
struct HabitsTodaySection: View {
    let selectedKey: String
    /// Pushes the Habits detail (owned by the host's NavigationStack) — the label row's "Manage".
    let onOpenDetail: () -> Void

    @EnvironmentObject private var habits: HabitsStore

    /// Current streak per habit id; recomputed by the `.task(id:)` below.
    @State private var streaks: [String: HabitStreak] = [:]
    /// Bumped on every `HabitsStore` publish (definitions or log cache) — the cheap half of the streak
    /// stamp. `objectWillChange` fires BEFORE the store writes, but the re-render it schedules runs
    /// after the write lands, so the `.task(id:)` it restarts reads the new values.
    @State private var storeRevision = 0

    init(selectedKey: String, onOpenDetail: @escaping () -> Void) {
        self.selectedKey = selectedKey
        self.onOpenDetail = onOpenDetail
    }

    var body: some View {
        let rows = habits.todayRows(selectedKey: selectedKey)

        RuleSection(Self.title(rows),
                    action: (title: "Manage", handler: onOpenDetail),
                    actionHint: "Add, edit, and see 30-day history") {
            if rows.isEmpty {
                // Distinguish "no habits at all" from "habits exist but none pinned here".
                Text(habits.active.isEmpty
                     ? "Add a habit to track a daily discipline."
                     : "No habits pinned here — pin one in Manage.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, vm in
                        if idx > 0 { WMRule() }
                        HabitTodayRow(vm: vm, day: selectedKey, streak: streaks[vm.id] ?? .empty)
                    }
                }
            }
        }
        .onReceive(habits.objectWillChange) { _ in storeRevision &+= 1 }
        .task(id: StreakStamp(revision: storeRevision, day: selectedKey, today: habits.todayKey())) {
            streaks = computeStreaks()
        }
    }

    /// "Habits · 1 of 4" — done of DUE on the day; plain "Habits" when nothing is due.
    static func title(_ rows: [HabitRowVM]) -> String {
        let due = rows.filter { $0.today.state != .notScheduled }
        guard !due.isEmpty else { return "Habits" }
        let done = due.filter { $0.today.state == .done }.count
        return "Habits · \(done) of \(due.count)"
    }

    /// Everything a streak depends on: the store's contents (definitions — cadence, creation day,
    /// pinning — and the log cache, both behind `revision`), the day shown, and the logical today the
    /// verdicts are closed against. `today` stays in because the store publishes only on launch and
    /// on writes: without it, a render after the 04:00 rollover would keep the previous day's streaks
    /// until the next habit write.
    private struct StreakStamp: Equatable {
        let revision: Int
        let day: String
        let today: String
    }

    private func computeStreaks() -> [String: HabitStreak] {
        var out: [String: HabitStreak] = [:]
        for habit in habits.pinnedActive {
            switch habit.cadence {
            case .weekly, .anytime:
                continue   // no per-day run to count (see `HabitStreak`)
            case .daily, .weekdays:
                break
            }
            // The creation day on the LOGICAL clock — `HabitsStore.createdDayKey`'s rule, which is
            // private to the store; the same one line, so the streak and the history agree on day one.
            let created = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(habit.createdAt)))
            out[habit.id] = HabitStreak.compute(
                dated: habits.historyDated(habit, count: HabitStreak.windowDays),
                cadence: habit.cadence, createdDay: created)
        }
        return out
    }
}

/// One habit row on the selected day (037): a 24pt circle check (done = ink disc with a ground
/// check; open = a 1.5pt ring), the name (+ the verdict's caption), and trailing the streak — or, for
/// a weekly habit, the week's adherence. The whole row toggles (backfill allowed on past days); only
/// a weekdays off-day is inert, drawing the dotted not-scheduled glyph.
struct HabitTodayRow: View {
    let vm: HabitRowVM
    let day: String
    var streak: HabitStreak = .empty
    @EnvironmentObject private var habits: HabitsStore

    init(vm: HabitRowVM, day: String, streak: HabitStreak = .empty) {
        self.vm = vm
        self.day = day
        self.streak = streak
    }

    private var habit: Habit { vm.habit }
    private var result: HabitDayResult { vm.today }

    var body: some View {
        if result.state == .notScheduled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(a11yLabel)
        } else {
            Button {
                Task { await habits.logManual(habit, day: day, done: result.state != .done) }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(result.state == .done ? "Marks it not done" : "Marks it done")
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            if result.state == .notScheduled {
                HabitStateGlyph(state: .notScheduled)   // off-day for a weekdays habit — nothing to log
            } else {
                HabitCheckbox(state: trailingState)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.displayName)
                    .font(WMType.body)
                    .foregroundStyle(result.state == .notScheduled ? WM.Ground.inkTertiary : WM.Ground.ink)
                    .lineLimit(1)
                if let detail = result.detail {
                    Text(detail)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Spacer(minLength: WM.Space.s)
            if let trailing = trailingText {
                Text(trailing)
                    .font(WMType.label)
                    .monospacedDigit()
                    .foregroundStyle(streak == .broken ? WM.Semantic.bad : WM.Ground.inkTertiary)
            }
        }
        .frame(minHeight: WM.Space.row)
        .contentShape(Rectangle())
    }

    /// A `weekly`/`anytime` habit isn't "missed" on a specific day — the week's rate / no-schedule
    /// carries it, so a per-day miss reads neutral. `weekdays`/`daily` misses are genuine. Shares the
    /// pure `HabitEvaluator.displayState` used by the detail history so both surfaces agree.
    private var trailingState: HabitDayResult.State {
        HabitEvaluator.displayState(result, cadence: habit.cadence).state
    }

    /// Streak for a daily/weekdays habit; the week's done/target for a weekly one; nothing for
    /// anytime (no schedule, no rate).
    private var trailingText: String? {
        if case .weekly = habit.cadence, let a = vm.adherence, a.target > 0 {
            return "\(a.done)/\(a.target) this week"
        }
        return streak.text
    }

    private var a11yLabel: String {
        let stateWord: String
        switch result.state {
        case .done: stateWord = "done"
        case .missed: stateWord = "missed"
        case .pending: stateWord = "not done yet"
        case .noData: stateWord = "no data"
        case .notScheduled: stateWord = "not scheduled"
        }
        var s = "\(habit.displayName), \(stateWord)"
        if let spoken = streak.spoken { s += ", \(spoken)" }
        if let a = vm.adherence, a.target > 0 { s += ", \(a.done) of \(a.target) this period" }
        return s
    }
}

// MARK: - Row atoms

/// The read-only verdict glyph at check size (the not-scheduled off-day on Log; it renders every
/// state): done → good check, missed → warn cross, pending → dashed circle, no-data → minus,
/// not-scheduled → dotted circle. Color is SEMANTIC only (008 viz decision).
struct HabitStateGlyph: View {
    let state: HabitDayResult.State
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
    }
    private var symbol: String {
        switch state {
        case .done: return "checkmark"
        case .missed: return "xmark"
        case .pending: return "circle.dashed"
        case .noData: return "minus"
        case .notScheduled: return "circle.dotted"
        }
    }
    private var tint: Color {
        switch state {
        case .done: return WM.Semantic.good
        case .missed: return WM.Semantic.warn
        case .pending, .noData, .notScheduled: return WM.Ground.inkTertiary
        }
    }
}

/// The 24pt circle check (037): done → an ink disc with a ground-colored check; open → a 1.5pt
/// inkTertiary ring; missed (a closed day never backfilled, still tappable) → the ring in warn.
struct HabitCheckbox: View {
    let state: HabitDayResult.State
    var body: some View {
        ZStack {
            if state == .done {
                Circle().fill(WM.Ground.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(WM.Ground.ground)
            } else {
                Circle().strokeBorder(state == .missed ? WM.Semantic.warn : WM.Ground.inkTertiary,
                                      lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
        .wmAnimation(WMMotion.transition, value: state == .done)
        .accessibilityHidden(true)
    }
}
