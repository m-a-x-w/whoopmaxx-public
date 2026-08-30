import SwiftUI
import StrapStore

/// Add or edit a workout by hand — a `groundRaised` sheet (one of the rare contained surfaces): sport
/// (catalogue suggestions + free text), start, duration, and optional avg HR / energy. Save builds the
/// row through `WorkoutSource.buildManualRow` and persists via
/// `WorkoutRepository.saveManualWorkout(_:replacing:)`.
/// Editing a DETECTED bout relabels it (the detected original is dismissed on save). Restyle of the original
/// 446-line ManualWorkoutSheet.
struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a fresh add.
    let editing: WorkoutRow?

    @EnvironmentObject private var workoutRepo: WorkoutRepository
    @Environment(\.dismiss) private var dismiss

    @State private var sport: String
    @State private var start: Date
    @State private var durationMin: Int
    @State private var avgHrText: String
    @State private var kcalText: String
    @State private var saving = false

    init(editing: WorkoutRow?) {
        self.editing = editing
        if let e = editing {
            _sport = State(initialValue: WorkoutSource.editableSport(e.sport))
            _start = State(initialValue: Date(timeIntervalSince1970: TimeInterval(e.startTs)))
            _durationMin = State(initialValue: max(1, Int((e.durationS ?? Double(e.endTs - e.startTs)) / 60)))
            _avgHrText = State(initialValue: e.avgHr.map(String.init) ?? "")
            _kcalText = State(initialValue: e.energyKcal.map { String(Int($0.rounded())) } ?? "")
        } else {
            _sport = State(initialValue: "")
            _start = State(initialValue: Date().addingTimeInterval(-3600))
            _durationMin = State(initialValue: 45)
            _avgHrText = State(initialValue: "")
            _kcalText = State(initialValue: "")
        }
    }

    /// The row the current inputs would produce, or nil if invalid — drives the Save button's enabled
    /// state so an impossible entry can never be saved.
    private var draft: WorkoutRow? {
        WorkoutSource.buildManualRow(start: start, durationMin: durationMin, sport: sport,
                                     avgHr: Int(avgHrText.trimmingCharacters(in: .whitespaces)),
                                     energyKcal: Double(kcalText.trimmingCharacters(in: .whitespaces)))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: WM.Space.section) {
                    sportField
                    startField
                    durationField
                    optionalField(label: "Avg HR", unit: "bpm", text: $avgHrText, placeholder: "optional")
                    optionalField(label: "Energy", unit: "kcal", text: $kcalText, placeholder: "optional")
                }
                .padding(WM.Space.gutter)
            }
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Text(editing == nil ? "New workout" : "Edit workout")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Button("Save") { save() }
                .font(WMType.label)
                .foregroundStyle(draft == nil || saving ? WM.Ground.inkTertiary : WM.Ground.ink)
                .disabled(draft == nil || saving)
        }
        .padding(.horizontal, WM.Space.gutter)
        .padding(.vertical, WM.Space.l)
        .overlay(alignment: .bottom) {
            WMRule()
        }
    }

    // MARK: - Fields

    private var sportField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Sport").wmOverline()
            TextField("e.g. Running", text: $sport)
                .font(WMType.numeral(22))
                .foregroundStyle(WM.Ground.ink)
                .textInputAutocapitalization(.words)
            WMRule()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WM.Space.s) {
                    ForEach(WorkoutCatalog.all) { s in
                        chip(s)
                    }
                }
                .padding(.top, WM.Space.xs)
            }
        }
    }

    private func chip(_ s: WorkoutCatalog.Sport) -> some View {
        let selected = sport.caseInsensitiveCompare(s.name) == .orderedSame
        return Button { sport = s.name } label: {
            HStack(spacing: WM.Space.xs) {
                Image(systemName: s.icon)
                    .font(.system(size: 14, weight: .medium))
                Text(s.name)
                    .font(WMType.body)
            }
            .foregroundStyle(selected ? WM.Ground.ground : WM.Ground.ink)
            .padding(.horizontal, WM.Space.l)
            .padding(.vertical, WM.Space.s + 2)
            .background(
                Capsule().fill(selected ? WM.Ground.ink : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(WM.Ground.rule, lineWidth: selected ? 0 : WM.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    private var startField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Start").wmOverline()
            DatePicker("", selection: $start, in: ...Date(),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }

    private var durationField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Duration").wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                Text("\(durationMin)")
                    .font(WMType.numeral(28))
                    .foregroundStyle(WM.Ground.ink)
                    .monospacedDigit()
                Text("min")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                Spacer()
                Stepper("", value: $durationMin, in: 1...(24 * 60), step: 5)
                    .labelsHidden()
                    // The value numeral is a separate Text, so name the control + speak its value.
                    .accessibilityLabel("Duration")
                    .accessibilityValue("\(durationMin) minutes")
            }
        }
    }

    private func optionalField(label: String, unit: String,
                               text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(label).wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                TextField(placeholder, text: text)
                    .font(WMType.numeral(22))
                    .foregroundStyle(WM.Ground.ink)
                    .keyboardType(.numberPad)
                Text(unit)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            WMRule()
        }
    }

    // MARK: - Save

    private func save() {
        guard var row = draft, !saving else { return }
        saving = true
        // Carry the captured fields the sheet doesn't expose (maxHr/strain/zones/notes) on an edit.
        if let editing { row = WorkoutSource.preservingCaptured(row, from: editing) }
        Task {
            await workoutRepo.saveManualWorkout(row, replacing: editing)
            dismiss()
        }
    }
}
