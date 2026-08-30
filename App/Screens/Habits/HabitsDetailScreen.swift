import SwiftUI

/// The Habits management + history detail (008), pushed from Today. Add / edit / archive / delete
/// habits and read each one's 30-day history (tap a day cell to backfill). Renders its own back
/// header (the Today stack hides the nav bar).
struct HabitsDetailScreen: View {
    @EnvironmentObject private var habits: HabitsStore
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Habit?
    @State private var showingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if habits.active.isEmpty && habits.archived.isEmpty {
                        emptyState
                    } else {
                        ForEach(habits.active) { habit in
                            HabitManageCard(habit: habit, onEdit: { editing = habit })
                        }
                        if !habits.archived.isEmpty {
                            RuleSection("Archived") {
                                VStack(alignment: .leading, spacing: WM.Space.m) {
                                    ForEach(habits.archived) { habit in
                                        archivedRow(habit)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WM.Ground.ground)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingNew) { HabitEditor(existing: nil) }
        .sheet(item: $editing) { HabitEditor(existing: $0) }
    }

    private var header: some View {
        HStack(spacing: WM.Space.s) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WM.Ground.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Text("Habits")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Button { showingNew = true } label: {
                Image(systemName: "plus")
                    .font(WMType.icon(.action))
                    .foregroundStyle(WM.Ground.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add habit")
        }
        .padding(.horizontal, WM.Space.gutter - 8)
        .padding(.top, WM.Space.s)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            Text("No habits yet.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Text("Add a daily discipline and check it off each day.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button { showingNew = true } label: {
                Text("Add a habit")
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.ground)
                    .padding(.horizontal, WM.Space.l)
                    .padding(.vertical, WM.Space.m)
                    .background(Capsule().fill(WM.Ground.ink))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, WM.Space.section)
    }

    private func archivedRow(_ habit: Habit) -> some View {
        HStack(spacing: WM.Space.m) {
            Text(habit.displayName)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
            Spacer()
            Button("Restore") { Task { await habits.setArchived(habit, false) } }
                .font(WMType.caption)
                .buttonStyle(.plain)
                .foregroundStyle(WM.Ground.ink)
            Button("Delete", role: .destructive) { Task { await habits.delete(habit) } }
                .font(WMType.caption)
                .buttonStyle(.plain)
                .foregroundStyle(WM.Semantic.bad)
        }
    }
}

/// One active-habit management card: name + cadence summary + trailing-30 readout, a tappable 30-day
/// history strip, and edit / archive affordances.
struct HabitManageCard: View {
    let habit: Habit
    var onEdit: () -> Void
    @EnvironmentObject private var habits: HabitsStore

    var body: some View {
        let dated = habits.historyDated(habit, count: 30)
        let adherence = habits.trailingAdherence(habit)

        RuleSection(habit.displayName) {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                HStack(spacing: WM.Space.m) {
                    Text(cadenceSummary)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                    Spacer()
                    if adherence.target > 0 {
                        Text("\(adherence.done)/\(adherence.target) · 30d")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkSecondary)
                            .monospacedDigit()
                    }
                }
                // The 30-day strip's today cell is a 10pt-wide tap target at the right edge — hard to
                // hit, so every habit gets a dedicated full-width, 44pt "today" toggle here. A
                // notScheduled today (weekdays off-day) shows none.
                if let today = dated.last,
                   today.result.state != .notScheduled {
                    let doneToday = today.result.state == .done
                    Button {
                        Task { await habits.logManual(habit, day: today.day, done: !doneToday) }
                    } label: {
                        HStack(spacing: WM.Space.s) {
                            HabitCheckbox(state: today.result.state)
                            Text(doneToday ? "Done today" : "Mark today done")
                                .font(WMType.body)
                                .foregroundStyle(WM.Ground.ink)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(doneToday ? "Mark today not done" : "Mark today done")
                }
                HabitHistoryStrip(dated: dated) { day in
                    Task { await habits.editDay(habit, day: day) }
                }
                HStack(spacing: WM.Space.l) {
                    Button("Edit", action: onEdit)
                        .font(WMType.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(WM.Ground.ink)
                    Button("Archive") { Task { await habits.setArchived(habit, true) } }
                        .font(WMType.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(WM.Ground.inkTertiary)
                    Spacer()
                }
                .padding(.top, WM.Space.xs)
            }
        }
    }

    private var cadenceSummary: String {
        switch habit.cadence {
        case .daily: return "Daily"
        case let .weekly(n): return "\(n)× per week"
        case let .weekdays(mask): return HabitManageCard.weekdaysSummary(mask)
        case .anytime: return "Anytime"
        }
    }

    static func weekdaysSummary(_ mask: Int) -> String {
        let names = ["S", "M", "T", "W", "T", "F", "S"]
        let on = (1...7).filter { (mask & (1 << $0)) != 0 }.map { names[$0 - 1] }
        // Mon–Fri special-case for the common weekday habit.
        if mask == 0b0_1111100 { return "Weekdays" }
        return on.isEmpty ? "No days" : on.joined(separator: " ")
    }
}

/// The 30-day history strip: one tappable cell per day. Done → good, missed → warn, no-data → faint,
/// pending → ink outline, not-scheduled → a bare dot.
struct HabitHistoryStrip: View {
    let dated: [(day: String, result: HabitDayResult)]
    var onTapDay: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(dated, id: \.day) { entry in
                // A `.notScheduled` cell (a weekdays off-day) has nothing to edit — render it plain,
                // not a Button, so a tap can't write an inert, invisible override/log row.
                if entry.result.state == .notScheduled {
                    cell(entry.result)
                } else {
                    Button { onTapDay(entry.day) } label: { cell(entry.result) }
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11ySummary)
    }

    @ViewBuilder
    private func cell(_ r: HabitDayResult) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        shape
            .fill(fill(r.state))
            .frame(width: 8, height: 16)
            .overlay {
                if r.state == .pending { shape.strokeBorder(WM.Ground.inkTertiary, lineWidth: WM.hairline) }
            }
            .frame(width: 10, height: 32)          // ≥ tap target height (width stays tight; 30 fit a row)
            .contentShape(Rectangle())
    }

    private func fill(_ state: HabitDayResult.State) -> Color {
        switch state {
        case .done:         return WM.Semantic.good
        case .missed:       return WM.Semantic.warn
        case .noData:       return WM.Ground.rule
        case .pending:      return Color.clear
        case .notScheduled: return WM.Ground.rule.opacity(0.4)
        }
    }

    private var a11ySummary: String {
        let done = dated.filter { $0.result.state == .done }.count
        let scheduled = dated.filter { $0.result.state == .done || $0.result.state == .missed }.count
        return "30-day history: \(done) of \(scheduled) done"
    }
}
