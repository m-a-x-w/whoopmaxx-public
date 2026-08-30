import SwiftUI

/// Sport picker for starting a live workout (037, the Start workout sheet): Cancel / title header
/// (`WMSheetHeader`, no Save — a row starts the session), a `WMSearchField`, and the catalogue as rows
/// that start the session on tap. A search that names no catalogue sport offers it as free text — the
/// catalogue is the suggestion set, not a whitelist (`WorkoutCatalog`), and `startWorkout(sport:)`
/// records any name it is handed.
struct StartWorkoutSheet: View {
    @EnvironmentObject private var workout: WorkoutSessionController
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    var body: some View {
        // Filtered once per pass (the catalogue is ~40 names; the pass runs on a keystroke, not a frame).
        let term = query.trimmingCharacters(in: .whitespaces)
        let rows = term.isEmpty
            ? WorkoutCatalog.all
            : WorkoutCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(term) }
        let offersFreeText = !term.isEmpty
            && !rows.contains { $0.name.caseInsensitiveCompare(term) == .orderedSame }

        return VStack(spacing: 0) {
            WMSheetHeader(title: "Start workout", onCancel: { dismiss() })

            // `.words`, not a search's `.never`: a free-text search is recorded as the sport's name.
            WMSearchField(placeholder: "Search \(WorkoutCatalog.all.count) sports", text: $query,
                          capitalization: .words, submitLabel: .return, clearLabel: "Clear")
                .padding(.horizontal, WM.Space.gutter)
                .padding(.top, WM.Space.s)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(term.isEmpty ? "Sports" : "Matches")
                        .wmOverline()
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, WM.Space.xs)

                    if offersFreeText {
                        WMNavRow(title: "Start “\(term)”",
                                 subtitle: "Not in the list — recorded under this name",
                                 showsDisclosure: false) { start(term) }
                        if !rows.isEmpty {
                            WMRule()
                        }
                    }
                    ForEach(rows) { sport in
                        WMNavRow(title: sport.name, showsDisclosure: false) { start(sport.name) }
                        if sport.id != rows.last?.id {
                            WMRule()
                        }
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.top, WM.Space.l)
                .padding(.bottom, WM.Space.sectionLoose)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(WM.Radius.sheet)
    }

    private func start(_ sport: String) {
        workout.startWorkout(sport: sport)
        dismiss()
    }
}

#Preview("Start workout — light") {
    StartWorkoutSheetSpecimen().preferredColorScheme(.light)
}

#Preview("Start workout — dark") {
    StartWorkoutSheetSpecimen().preferredColorScheme(.dark)
}

private struct StartWorkoutSheetSpecimen: View {
    private let root = AppRoot()

    var body: some View {
        StartWorkoutSheet()
            .environmentObject(root.workout)
    }
}
