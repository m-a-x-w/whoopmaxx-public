import SwiftUI

/// The quiet "why did the band buzz" history — reached from the Buzz history row at the bottom of
/// Strap health, presented as a sheet. Lists app-sent wrist buzzes (habit reminders, smart-alarm early
/// wakes, inactivity nudges, time checks) newest-first, grouped by day under sentence-case day labels:
/// each row is the buzz reason + an absolute time. Chrome stays neutral ink (color = data only). A
/// low-key Clear in the header wipes the record.
struct BuzzHistoryScreen: View {
    @EnvironmentObject private var buzzLog: BuzzLog
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false

    var body: some View {
        ZStack {
            WM.Ground.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if buzzLog.events.isEmpty {
                        emptyState
                    } else {
                        content
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        WMCoverHeader(title: "Buzz history", closeLabel: "Close buzz history") {
            dismiss()
        } accessory: {
            if !buzzLog.events.isEmpty {
                Button { confirmingClear = true } label: {
                    Text("Clear")
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Asks to confirm, then deletes the buzz history")
                .confirmationDialog("Clear buzz history?", isPresented: $confirmingClear,
                                    titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { buzzLog.clear() }
                    Button("Cancel", role: .cancel) { }
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No buzzes recorded yet. Habit reminders, smart-alarm wakes, inactivity nudges, test buzzes, and time checks appear here after they fire.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, WM.Space.s)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Grouped once per pass (one sort + one scan), then only read below.
        let groups = self.groups
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
                RuleSection(group.header, topGap: index == 0 ? WM.Space.l : WM.Space.sectionTight,
                            contentGap: WM.Space.xs) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.events) { event in
                            row(event)
                            if event.id != group.events.last?.id {
                                WMRule()
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: BuzzEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            Text(e.label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: WM.Space.s)
            Text(WMFormat.timeOfDay(e.date))
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, WM.Space.s)
        .frame(minHeight: WM.Space.row)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Grouping (newest first, one section per local day)

    private struct DayGroup { let key: String; let header: String; let events: [BuzzEvent] }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let ordered = buzzLog.events.sorted { $0.ts > $1.ts }   // newest first
        var out: [DayGroup] = []
        var currentKey = ""
        var bucket: [BuzzEvent] = []
        func flush() {
            guard let first = bucket.first else { return }
            out.append(DayGroup(key: currentKey,
                                header: Self.dayHeader(first.date, cal: cal),
                                events: bucket))
        }
        for e in ordered {
            let key = Self.dayKey(e.date, cal: cal)
            if key != currentKey {
                flush()
                bucket = []
                currentKey = key
            }
            bucket.append(e)
        }
        flush()
        return out
    }

    private static func dayKey(_ date: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func dayHeader(_ date: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()
}

#Preview("Buzz history — light") {
    BuzzHistoryScreen()
        .environmentObject(BuzzLog())
        .preferredColorScheme(.light)
}

#Preview("Buzz history — dark") {
    BuzzHistoryScreen()
        .environmentObject(BuzzLog())
        .preferredColorScheme(.dark)
}
