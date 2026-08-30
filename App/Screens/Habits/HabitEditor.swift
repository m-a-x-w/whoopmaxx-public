import SwiftUI

/// Add / edit a habit (008) — a `groundRaised` sheet in the Line language (037 "Sheets"), sharing
/// the other editors' chrome (`WMSheetChrome.swift`) instead of the system `Form` it used to be: Cancel / title / Save, the name in a `track` field, the cadence as a rounded segmented
/// picker (weekday circles or a times-per-week stepper under it), the optional wrist-buzz window, and
/// whether it shows on Log. Every habit is manually checked off (no kinds/targets — strap
/// verification was removed). Passing an existing `habit` edits it; nil creates a new one.
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
    @State private var saving = false

    private enum CadenceMode: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, anytime
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .anytime: return "Anytime"
            }
        }
    }

    init(existing: Habit?) {
        self.existing = existing
    }

    var body: some View {
        VStack(spacing: 0) {
            WMSheetHeader(title: existing == nil ? "New habit" : "Edit habit",
                          canSave: canSave && !saving,
                          onCancel: { dismiss() },
                          onSave: { Task { await save() } })
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Habit name", text: $name)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                        .textInputAutocapitalization(.sentences)
                        .padding(.horizontal, WM.Space.l)
                        .frame(height: 44)
                        .background(Capsule().fill(WM.Ground.track))
                        .padding(.top, WM.Space.m)

                    cadenceField
                        .padding(.top, WM.Space.sectionTight)

                    buzzField
                        .padding(.top, WM.Space.sectionTight)

                    VStack(alignment: .leading, spacing: 0) {
                        WMRule()
                        WMSettingToggle(label: "Show on Log", isOn: $pinned,
                                        caption: "Pinned habits are the ones you check off on the Log tab.")
                    }
                    .padding(.top, WM.Space.l)
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(WM.Radius.sheet)
        .onAppear(perform: load)
    }

    // MARK: - Fields

    private var cadenceField: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            Text("Repeats")
                .wmOverline()
                .accessibilityAddTraits(.isHeader)
            WMSegmentedPicker(options: CadenceMode.allCases.map { (value: $0, name: $0.label) },
                              selection: $cadenceMode, label: "Repeats")
            if cadenceMode == .weekdays {
                weekdayToggles
                    .padding(.top, WM.Space.xs)
            }
            if cadenceMode == .weekly {
                WMAmountStepper(label: "Per week", value: $weeklyN, range: 1...7,
                                unit: weeklyN == 1 ? "time" : "times")
            }
        }
    }

    private var buzzField: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMSettingToggle(label: "Buzz me", isOn: $buzzOn,
                            caption: buzzOn
                                ? "Buzzes once inside the window while the strap is connected and worn. No notifications."
                                : nil)
            if buzzOn {
                WMRule()
                timeRow("From", selection: $buzzStart)
                WMRule()
                timeRow("Until", selection: $buzzEnd)
            }
        }
    }

    private func timeRow(_ title: String, selection: Binding<Date>) -> some View {
        HStack {
            Text(title)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.l)
            DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .frame(minHeight: WM.Space.row)
    }

    /// Seven day circles: ink with ground text when on, a 1.5pt `track` ring when off.
    private var weekdayToggles: some View {
        HStack(spacing: 0) {
            ForEach(1...7, id: \.self) { wd in
                let on = (weekdaysMask & (1 << wd)) != 0
                Button {
                    if on { weekdaysMask &= ~(1 << wd) } else { weekdaysMask |= (1 << wd) }
                } label: {
                    Text(Self.weekdayInitials[wd - 1])
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(on ? WM.Ground.ground : WM.Ground.inkSecondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(on ? WM.Ground.ink : Color.clear))
                        .overlay(Circle().strokeBorder(on ? Color.clear : WM.Ground.track, lineWidth: 1.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .wmAnimation(WMMotion.transition, value: on)
                .accessibilityLabel("\(Self.weekdayNames[wd - 1]), \(on ? "on" : "off")")
                .accessibilityAddTraits(on ? [.isSelected] : [])
                if wd < 7 { Spacer(minLength: 0) }
            }
        }
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
        guard !saving else { return }
        saving = true
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
