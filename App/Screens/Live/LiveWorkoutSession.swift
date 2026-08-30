import SwiftUI
import StrapStore

/// The in-workout session block on the Live root (W7). Idle: a quiet "Start a workout" row that opens a
/// sport picker. Active: elapsed time, building strain in Effort, and the live HR-zone bar stream, with a
/// Stop button. Reads `WorkoutSessionController.activeWorkout`. Restyle of the original 300-line
/// LiveWorkoutView to the whoopmaxx language (no card, no GPS lane).
struct LiveWorkoutSession: View {
    @EnvironmentObject private var workout: WorkoutSessionController
    @EnvironmentObject private var profile: ProfileStore
    @State private var showingStartPicker = false

    var body: some View {
        RuleSection("Workout") {
            if let w = workout.activeWorkout {
                active(w)
            } else {
                idle
            }
        }
        .sheet(isPresented: $showingStartPicker) { StartWorkoutSheet() }
    }

    // MARK: - Active

    @ViewBuilder
    private func active(_ w: WorkoutSessionController.ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: WM.Space.xs) {
                    Text(WorkoutSource.displaySport(w.sport))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Text("Recording")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Domain.effort.color)
                }
                Spacer()
                // Chrome stays neutral ink (color = data only): ink text in a hairline outline capsule,
                // not a domain-colored fill — matching the app's other controls (Reconnect etc.).
                Button { workout.endWorkout() } label: {
                    Text("Stop")
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.ink)
                        .padding(.horizontal, WM.Space.l)
                        .padding(.vertical, WM.Space.s)
                        .overlay(Capsule().strokeBorder(WM.Ground.ruleHeavy, lineWidth: WM.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop workout")
            }

            HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    metric(elapsedText(from: w.start, to: ctx.date), label: "Elapsed",
                           color: WM.Ground.ink)
                }
                metric(strainText(w.liveStrain), label: "Effort", color: WM.Domain.effort.color)
            }

            LiveHRStream(hrMax: profile.hrMax)
        }
    }

    private func metric(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(value)
                .font(WMType.display(44))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).wmOverline()
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Button { showingStartPicker = true } label: {
                HStack(spacing: WM.Space.m) {
                    Image(systemName: "figure.run").font(.system(size: 16))
                    Text("Start a workout").font(WMType.body)
                    Spacer()
                    WMDisclosure()
                }
                .foregroundStyle(WM.Ground.ink)
                .contentShape(Rectangle())
                .padding(.vertical, WM.Space.s)
            }
            .buttonStyle(.plain)

            if let last = workout.justEndedWorkout {
                Text(savedText(last))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
    }

    private func savedText(_ row: WorkoutRow) -> String {
        var parts = ["Saved · \(WorkoutSource.displaySport(row.sport))", WorkoutFormat.duration(row)]
        if let s = WorkoutFormat.strainText(row.strain) { parts.append("Effort \(s)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    private func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func strainText(_ strain: Double) -> String { String(Int(strain.rounded())) }
}

/// Sport picker for starting a live workout: the catalogue as tappable rows on a `groundRaised` sheet.
private struct StartWorkoutSheet: View {
    @EnvironmentObject private var workout: WorkoutSessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                Spacer()
                Text("Start workout").font(WMType.title).foregroundStyle(WM.Ground.ink)
                Spacer()
                Color.clear.frame(width: 44, height: 1)   // balance the title
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.vertical, WM.Space.l)
            .overlay(alignment: .bottom) {
                WMRule()
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(WorkoutCatalog.all) { s in
                        Button {
                            workout.startWorkout(sport: s.name)
                            dismiss()
                        } label: {
                            HStack {
                                Text(s.name).font(WMType.body).foregroundStyle(WM.Ground.ink)
                                Spacer()
                            }
                            .padding(.vertical, WM.Space.m)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if s.id != WorkoutCatalog.all.last?.id {
                            WMRule()
                        }
                    }
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
    }
}
