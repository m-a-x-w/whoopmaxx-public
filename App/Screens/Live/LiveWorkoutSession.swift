import SwiftUI
import StrapStore

/// The in-workout session block on the Live root (W7), shown in place of the standalone stream while a
/// manual workout records: sport + an Effort-tinted "Recording" status, a Stop capsule, elapsed time and
/// the building Effort as numerals, and the live bar stream. Renders nothing when no workout is active —
/// the idle "Start workout" button, its sport sheet and the just-saved confirmation live in `LiveScreen`'s
/// action block. Reads `WorkoutSessionController.activeWorkout`.
struct LiveWorkoutSession: View {
    @EnvironmentObject private var workout: WorkoutSessionController

    var body: some View {
        if let w = workout.activeWorkout {
            active(w)
        }
    }

    // MARK: - Active

    private func active(_ w: WorkoutSessionController.ActiveWorkout) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            HStack(alignment: .center, spacing: WM.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutSource.displaySport(w.sport))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(WM.Ground.ink)
                    // A status marker, not an accent: live HR genuinely is the Effort domain.
                    Text("Recording")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Domain.effort.color)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: WM.Space.s)
                stopButton
            }

            HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    metric(elapsedText(from: w.start, to: ctx.date), label: "Elapsed",
                           color: WM.Ground.ink)
                }
                metric(strainText(w.liveStrain), label: "Effort", color: WM.Domain.effort.color)
            }

            LiveHRStream()
        }
    }

    /// Chrome stays neutral (color = data only): the secondary capsule — ink text inside a 1.5pt `track`
    /// outline, the off-state of `WMChip` — never a domain-colored fill.
    private var stopButton: some View {
        Button { workout.endWorkout() } label: {
            Text("Stop")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(WM.Ground.ink)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .overlay(Capsule().strokeBorder(WM.Ground.track, lineWidth: 1.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop workout")
    }

    private func metric(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(label).wmOverline()
            Text(value)
                .font(WMType.numeral(40))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
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
