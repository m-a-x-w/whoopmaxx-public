import SwiftUI

/// The Habits management + history detail (008), pushed from Log's "Manage". Add / edit / archive /
/// delete habits and read each one's 30-day history (tap a day cell to backfill). Renders its own
/// back link and title in the Line language (the host stack hides the nav bar).
struct HabitsDetailScreen: View {
    @EnvironmentObject private var habits: HabitsStore
    @Environment(\.dismiss) private var dismiss

    /// Names the screen this was pushed from — the visible back label and its VoiceOver one.
    var backLabel: String = "Log"

    @State private var editing: Habit?
    @State private var showingNew = false

    init(backLabel: String = "Log") {
        self.backLabel = backLabel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WMBackLink(title: backLabel) { dismiss() }
                    .padding(.top, WM.Space.s)
                TabHeader("Habits", subtitle: "Check-offs, cadence and 30-day history") {
                    WMIconButton(systemName: "plus", label: "Add habit") { showingNew = true }
                }
                if habits.active.isEmpty && habits.archived.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(habits.active.enumerated()), id: \.element.id) { index, habit in
                        HabitManageCard(habit: habit, onEdit: { editing = habit },
                                        topGap: index == 0 ? WM.Space.sectionTight : WM.Space.section)
                    }
                    if !habits.archived.isEmpty {
                        RuleSection("Archived") {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(habits.archived.enumerated()), id: \.element.id) { idx, habit in
                                    if idx > 0 { WMRule() }
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
        .background(WM.Ground.ground)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingNew) { HabitEditor(existing: nil) }
        .sheet(item: $editing) { HabitEditor(existing: $0) }
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
            WMPrimaryButton("Add a habit", systemImage: "plus") { showingNew = true }
                .padding(.top, WM.Space.s)
        }
        .padding(.top, WM.Space.sectionTight)
    }

    private func archivedRow(_ habit: Habit) -> some View {
        HStack(spacing: WM.Space.l) {
            Text(habit.displayName)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: WM.Space.s)
            textAction("Restore", color: WM.Ground.inkSecondary) {
                Task { await habits.setArchived(habit, false) }
            }
            textAction("Delete", color: WM.Semantic.bad) {
                Task { await habits.delete(habit) }
            }
        }
        .frame(minHeight: WM.Space.row)
    }

    private func textAction(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(WMType.label)
                .foregroundStyle(color)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One active habit (Line language): its name as the section label with the cadence and trailing-30
/// adherence under it, a full-width "today" check row, the tappable 30-day history strip, and Edit /
/// Archive as quiet text actions.
struct HabitManageCard: View {
    let habit: Habit
    var onEdit: () -> Void
    var topGap: CGFloat = WM.Space.section
    @EnvironmentObject private var habits: HabitsStore

    var body: some View {
        let dated = habits.historyDated(habit, count: 30)
        let adherence = habits.trailingAdherence(habit)

        RuleSection(habit.displayName, topGap: topGap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
                    Text(cadenceSummary)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                    Spacer()
                    if adherence.target > 0 {
                        Text("\(adherence.done)/\(adherence.target) · 30 d")
                            .font(WMType.label)
                            .foregroundStyle(WM.Ground.inkSecondary)
                            .monospacedDigit()
                    }
                }
                // The 30-day strip's today cell is a narrow tap target at the right edge — hard to
                // hit, so every habit gets a dedicated full-width, 48pt "today" row here. A
                // notScheduled today (weekdays off-day) shows none.
                if let today = dated.last,
                   today.result.state != .notScheduled {
                    let doneToday = today.result.state == .done
                    Button {
                        Task { await habits.logManual(habit, day: today.day, done: !doneToday) }
                    } label: {
                        HStack(spacing: WM.Space.m) {
                            HabitCheckbox(state: today.result.state)
                            Text(doneToday ? "Done today" : "Mark today done")
                                .font(WMType.body)
                                .foregroundStyle(WM.Ground.ink)
                            Spacer()
                        }
                        .frame(minHeight: WM.Space.row)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(doneToday ? "Mark today not done" : "Mark today done")
                    .padding(.top, WM.Space.xs)
                }
                HabitHistoryStrip(dated: dated) { day in
                    Task { await habits.editDay(habit, day: day) }
                }
                .padding(.top, WM.Space.xs)
                HStack(spacing: WM.Space.l) {
                    WMSecondaryButton("Edit", fillsWidth: false, action: onEdit)
                    WMSecondaryButton("Archive", fillsWidth: false) {
                        Task { await habits.setArchived(habit, true) }
                    }
                    Spacer()
                }
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

/// The 30-day history strip: one tappable rounded cell per day, spread across the width. Done → good,
/// missed → warn, no-data → `track`, pending (today, open) → an inkTertiary outline, not-scheduled → a
/// faint `track` cell that is not a button.
struct HabitHistoryStrip: View {
    let dated: [(day: String, result: HabitDayResult)]
    var onTapDay: (String) -> Void

    var body: some View {
        HStack(spacing: 3) {
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
        let shape = RoundedRectangle(cornerRadius: 3)
        shape
            .fill(fill(r.state))
            .frame(height: 20)
            .overlay {
                if r.state == .pending { shape.strokeBorder(WM.Ground.inkTertiary, lineWidth: 1) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)                     // HIG tap height; the width is the row's 30th
            .contentShape(Rectangle())
    }

    private func fill(_ state: HabitDayResult.State) -> Color {
        switch state {
        case .done:         return WM.Semantic.good
        case .missed:       return WM.Semantic.warn
        case .noData:       return WM.Ground.track
        case .pending:      return Color.clear
        case .notScheduled: return WM.Ground.track.opacity(0.5)
        }
    }

    private var a11ySummary: String {
        let done = dated.filter { $0.result.state == .done }.count
        let scheduled = dated.filter { $0.result.state == .done || $0.result.state == .missed }.count
        return "30-day history: \(done) of \(scheduled) done"
    }
}
