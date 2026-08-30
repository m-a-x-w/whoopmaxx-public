import SwiftUI
import StrapStore

/// Add or edit a workout by hand (037 "Sheets"): the `WMSheetHeader`, the sport as a
/// `WMSearchField` name field over the catalogue as chips (free text allowed), then the details as rows
/// between hairlines — start, duration (a `WMAmountStepper`), and optional avg HR / energy. Save builds the row through `WorkoutSource.buildManualRow` and persists via
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

    /// The duration control's step and range (a day at most).
    private static let durationStep = 5
    private static let durationRange = 1...(24 * 60)

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
        // `draft` builds a row — resolve it once per pass for both of Save's states.
        let canSave = draft != nil && !saving
        return VStack(spacing: 0) {
            WMSheetHeader(title: editing == nil ? "New workout" : "Edit workout",
                          canSave: canSave,
                          onCancel: { dismiss() },
                          onSave: { save() })
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sportField
                    VStack(spacing: 0) {
                        startRow
                        WMRule()
                        durationRow
                        WMRule()
                        numberRow(label: "Avg HR", unit: "bpm", text: $avgHrText)
                        WMRule()
                        numberRow(label: "Energy", unit: "kcal", text: $kcalText)
                    }
                    .padding(.top, WM.Space.sectionTight)
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.top, WM.Space.s)
                .padding(.bottom, WM.Space.sectionLoose)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(WM.Radius.sheet)
    }

    // MARK: - Sport

    private var sportField: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            Text("Sport")
                .wmOverline()
                .accessibilityAddTraits(.isHeader)
            WMSearchField(placeholder: "e.g. Running", text: $sport, showsSearchGlyph: false,
                          capitalization: .words, submitLabel: .return, clearLabel: "Clear")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WM.Space.s) {
                    ForEach(WorkoutCatalog.all) { s in
                        WMChip(s.name, isOn: sport.caseInsensitiveCompare(s.name) == .orderedSame) {
                            sport = s.name
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail rows

    private var startRow: some View {
        HStack(spacing: WM.Space.m) {
            rowLabel("Start")
            Spacer(minLength: WM.Space.s)
            DatePicker("Start", selection: $start, in: ...Date(),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .frame(minHeight: WM.Space.row + 8)
    }

    /// The minutes between −/+ circles; VoiceOver reads "Duration, 45 minutes" and steps it by swipe.
    private var durationRow: some View {
        WMAmountStepper(label: "Duration", value: $durationMin, range: Self.durationRange,
                        step: Self.durationStep, unit: "min", spokenUnit: "minutes")
    }

    private func numberRow(label: String, unit: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.m) {
            rowLabel(label)
            Spacer(minLength: WM.Space.s)
            TextField(label, text: text,
                      prompt: Text("optional").foregroundStyle(WM.Ground.inkTertiary))
                .font(WMType.numeral(22))
                .foregroundStyle(WM.Ground.ink)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .frame(maxWidth: 140)
            Text(unit)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .frame(minWidth: 28, alignment: .leading)
        }
        .frame(minHeight: WM.Space.row + 8)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.ink)
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
