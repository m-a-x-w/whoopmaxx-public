import SwiftUI

/// The Today "Habits" section (008): current-period rows for ALL pinned habits on the SELECTED day,
/// with a manage chevron pushing the detail. Env-driven (like `AutoWorkoutRow`) since each row's
/// verdict comes from the manual logs through `HabitsStore`. Every row is a tappable check-off
/// (backfill allowed on past days) — there are no read-only auto rows anymore.
struct HabitsTodaySection: View {
    let selectedKey: String
    /// Pushes the Habits detail (owned by Today's NavigationStack).
    var onOpenDetail: (() -> Void)? = nil

    @EnvironmentObject private var habits: HabitsStore

    var body: some View {
        let rows = habits.todayRows(selectedKey: selectedKey)

        VStack(alignment: .leading, spacing: WM.Space.m) {
            if rows.isEmpty {
                // Distinguish "no habits at all" from "habits exist but none pinned to Today".
                Text(habits.active.isEmpty
                     ? "Add a habit to track a daily discipline."
                     : "No habits pinned to Today — pin one in Manage.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Rows sit in their own tight group (xs) so the list reads as one block; the outer
                // stack keeps the `m` gap only around the Manage affordance.
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    ForEach(rows) { vm in
                        HabitTodayRow(vm: vm, day: selectedKey)
                    }
                }
            }
            manageLink
        }
    }

    /// Chevron link row (the More-screen idiom) pushing the Habits detail.
    private var manageLink: some View {
        Button { onOpenDetail?() } label: {
            HStack(spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    Text("Manage habits")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text("Add, edit, and see 30-day history")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                Spacer(minLength: WM.Space.s)
                WMDisclosure()
            }
            .contentShape(Rectangle())
            .padding(.vertical, WM.Space.xs)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One habit row on the selected day: a tappable checkbox (backfill on any day) — only a weekdays
/// off-day shows the inert not-scheduled glyph. Cadence (weekly/weekdays) habits also show a
/// current-period fraction + a neutral-ink adherence bar.
struct HabitTodayRow: View {
    let vm: HabitRowVM
    let day: String
    @EnvironmentObject private var habits: HabitsStore

    private var habit: Habit { vm.habit }
    private var result: HabitDayResult { vm.today }

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(habit.displayName)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                if let detail = result.detail {
                    Text(detail)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            Spacer(minLength: WM.Space.s)
            if let adherence = vm.adherence {
                HabitAdherenceReadout(adherence: adherence)
            }
            trailing
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// A `weekly`/`anytime` habit isn't "missed" on a specific day — the week's rate / no-schedule
    /// carries it, so a per-day miss reads neutral. `weekdays`/`daily` misses are genuine. Shares the
    /// pure `HabitEvaluator.displayState` used by the detail history so both surfaces agree.
    private var trailingState: HabitDayResult.State {
        HabitEvaluator.displayState(result, cadence: habit.cadence).state
    }

    @ViewBuilder
    private var trailing: some View {
        if result.state == .notScheduled {
            HabitStateGlyph(state: .notScheduled)   // off-day for a weekdays habit — nothing to log
        } else {
            Button {
                Task { await habits.logManual(habit, day: day, done: result.state != .done) }
            } label: {
                HabitCheckbox(state: trailingState)
                    .frame(width: 44, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var a11yLabel: String {
        let stateWord: String
        switch result.state {
        case .done: stateWord = "done"
        case .missed: stateWord = "missed"
        case .pending: stateWord = "pending"
        case .noData: stateWord = "no data"
        case .notScheduled: stateWord = "not scheduled"
        }
        var s = "\(habit.displayName), \(stateWord)"
        if let a = vm.adherence, a.target > 0 { s += ", \(a.done) of \(a.target) this period" }
        return s
    }
}

// MARK: - Row atoms

/// The read-only verdict glyph (now only the not-scheduled off-day in Today, but it renders every
/// state): done → good check, missed → warn cross, pending → dashed circle, no-data → minus. Color
/// is SEMANTIC only (008 viz decision).
struct HabitStateGlyph: View {
    let state: HabitDayResult.State
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
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

/// A tappable manual checkbox: done → filled good check, pending (today) → hollow ink square, missed
/// (past, un-backfilled) → hollow warn square (still tappable to backfill).
struct HabitCheckbox: View {
    let state: HabitDayResult.State
    var body: some View {
        Image(systemName: state == .done ? "checkmark.square.fill" : "square")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(tint)
    }
    private var tint: Color {
        switch state {
        case .done:   return WM.Semantic.good
        case .missed: return WM.Semantic.warn
        default:      return WM.Ground.inkTertiary
        }
    }
}

/// The current-period fraction + a thin neutral-ink adherence bar (bars = the signature motif; ink,
/// not domain color, per the 008 viz decision).
struct HabitAdherenceReadout: View {
    let adherence: HabitAdherence
    var body: some View {
        HStack(spacing: WM.Space.s) {
            Text("\(adherence.done)/\(max(adherence.target, adherence.done))")
                .font(WMType.numeral(17))
                .foregroundStyle(WM.Ground.ink)
                .monospacedDigit()
            AdherenceBar(fraction: fraction)
        }
    }
    private var fraction: Double {
        let target = max(adherence.target, adherence.done)
        guard target > 0 else { return 0 }
        return min(Double(adherence.done) / Double(target), 1)
    }
}

/// A fixed-width hairline-track bar with an ink fill = the adherence fraction.
struct AdherenceBar: View {
    let fraction: Double
    var width: CGFloat = 44
    var height: CGFloat = 4
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(WM.Ground.rule).frame(width: width, height: height)
            Capsule().fill(WM.Ground.ink)
                .frame(width: max(0, min(CGFloat(fraction), 1)) * width, height: height)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
