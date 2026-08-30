import SwiftUI

/// Add / edit a habit (008). A sheet-hosted Form: name it, pick a cadence, and optionally set a
/// wrist-buzz window. Every habit is manually checked off (no kinds/targets — strap verification
/// was removed). Passing an existing `habit` edits it; nil creates a new one.
struct HabitEditor: View {
    /// The habit being edited, or nil for a new one.
    let existing: Habit?

    @EnvironmentObject private var habits: HabitsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var cadenceMode: CadenceMode = .daily
    @State private var weekdaysMask: Int = 0b0_1111100   // Mon–Fri default (bits 2…6)
    @State private var weeklyN: Int = 4
    @State private var buzzOn: Bool = false
    @State private var buzzStart: Date = HabitEditor.time(hour: 21, minute: 0)
    @State private var buzzEnd: Date = HabitEditor.time(hour: 22, minute: 30)
    @State private var pinned: Bool = true

    private enum CadenceMode: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, anytime
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "N per week"
            case .anytime: return "Anytime"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Habit") {
                    TextField("Habit name", text: $name)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Cadence") {
                    Picker("Repeats", selection: $cadenceMode) {
                        ForEach(CadenceMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    if cadenceMode == .weekdays { weekdayToggles }
                    if cadenceMode == .weekly {
                        Stepper("\(weeklyN)× per week", value: $weeklyN, in: 1...7)
                    }
                }

                Section("Wrist buzz") {
                    Toggle("Buzz me", isOn: $buzzOn)
                        .tint(WM.Ground.control)
                    if buzzOn {
                        DatePicker("From", selection: $buzzStart, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $buzzEnd, displayedComponents: .hourAndMinute)
                        Text("Buzzes once inside the window while the strap is connected and worn. No notifications.")
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                    }
                }

                Section {
                    Toggle("Show in Today", isOn: $pinned)
                        .tint(WM.Ground.control)
                }
            }
            .navigationTitle(existing == nil ? "New habit" : "Edit habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var weekdayToggles: some View {
        HStack(spacing: WM.Space.xs) {
            ForEach(1...7, id: \.self) { wd in
                let on = (weekdaysMask & (1 << wd)) != 0
                Button {
                    if on { weekdaysMask &= ~(1 << wd) } else { weekdaysMask |= (1 << wd) }
                } label: {
                    Text(Self.weekdayInitials[wd - 1])
                        .font(WMType.label)
                        .foregroundStyle(on ? WM.Ground.ground : WM.Ground.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(on ? WM.Ground.ink : Color.clear))
                        .overlay(Circle().strokeBorder(on ? Color.clear : WM.Ground.ruleHeavy,
                                                       lineWidth: WM.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.weekdayNames[wd - 1]), \(on ? "on" : "off")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private static let weekdayInitials = ["S", "M", "T", "W", "T", "F", "S"]
    private static let weekdayNames =
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private var canSave: Bool {
        // Weekdays with no day selected is unschedulable — reject before the name check.
        if cadenceMode == .weekdays && weekdaysMask == 0 { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Load / save

    private func load() {
        guard let h = existing else { return }
        // A legacy (kind-based) habit may be unnamed — prefill its kind label so the name survives
        // the manual-only save.
        name = h.name.isEmpty ? h.kind.displayName : h.name
        pinned = h.pinned
        switch h.cadence {
        case .daily:              cadenceMode = .daily
        case let .weekdays(mask): cadenceMode = .weekdays; weekdaysMask = mask
        case let .weekly(n):      cadenceMode = .weekly; weeklyN = n
        case .anytime:            cadenceMode = .anytime
        }
        if let b = h.buzz {
            buzzOn = true
            buzzStart = Self.time(minutes: b.start)
            buzzEnd = Self.time(minutes: b.end)
        }
    }

    private func save() async {
        let cadence: HabitCadence
        switch cadenceMode {
        case .daily:    cadence = .daily
        case .weekdays: cadence = .weekdays(weekdaysMask)
        case .weekly:   cadence = .weekly(weeklyN)
        case .anytime:  cadence = .anytime
        }
        let buzz: HabitBuzzWindow? = buzzOn
            ? HabitBuzzWindow(start: Self.minutes(from: buzzStart), end: Self.minutes(from: buzzEnd))
            : nil
        let habit = Habit(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: .manual,
            cadence: cadence,
            targetMinutes: nil,
            buzz: buzz,
            pinned: pinned,
            sortOrder: existing?.sortOrder ?? habits.active.count,
            archived: existing?.archived ?? false,
            createdAt: existing?.createdAt ?? Int(Date().timeIntervalSince1970))
        await habits.save(habit)
        dismiss()
    }

    // MARK: - Minutes ↔ Date helpers

    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func time(minutes: Int) -> Date { time(hour: minutes / 60, minute: minutes % 60) }
    static func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: max(0, min(hour, 23)), minute: max(0, min(minute, 59)),
                              second: 0, of: Date()) ?? Date()
    }
}
