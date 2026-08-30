import SwiftUI
import StrapStore

/// One workout in full (037, Workout detail): back → the sport as the title over its day and time
/// span → the Effort hero in Effort → the session's heart-rate line over an Effort wash, with its time
/// axis and peak → "Time in zone" as five rows of compact bars with minutes → the captured "Session"
/// stats (avg / peak HR, duration, energy) → Edit (or Relabel) and Delete rows. Restyle of the original
/// 636-line WorkoutDetailView down to the MVP (no GPS map).
struct WorkoutDetailScreen: View {
    let row: WorkoutRow
    /// The back-link label — "Workouts" when pushed from the list, "Live" from the Live tab's recent
    /// rows, "Today" from the Today row.
    var backLabel: String = "Workouts"

    @EnvironmentObject private var root: AppRoot
    // Observed so an in-place edit (which republishes workoutRepo.workouts) re-renders the detail — the
    // pushed `row` is a fixed VALUE that never refreshes on its own. (AppRoot does NOT forward nested
    // ObservableObject changes, so observe WorkoutRepository directly.)
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    /// Per-bucket mean bpm across the workout window (the HR curve), oldest → newest.
    @State private var hrValues: [Double] = []
    /// The HR curve's time axis (start, two interior ticks, end), formatted once per load.
    @State private var axisLabels: [String] = []
    @State private var zoneMinutes: [Double]?
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    /// The live row for this detail, resolved by natural key from the observed cache — so a value-only edit
    /// (avgHr / energy / strain, same source|startTs|sport) shows fresh fields. nil once the row is gone
    /// (deleted, or a key-changing edit landed it under a new key), which drives the dismiss below.
    private var liveRow: WorkoutRow? {
        let key = WorkoutRef(row: row).id
        return workoutRepo.workouts.first { WorkoutRef(row: $0).id == key }
    }
    /// What the detail renders: the live row while it exists, else the pushed value (mid-transition).
    /// A scan of the workout cache — resolved ONCE per body pass and handed down, never re-read per
    /// subview.
    private var current: WorkoutRow { liveRow ?? row }

    var body: some View {
        let shown = current
        let detected = WorkoutSource.classify(shown.source) == .detected
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.s)

                TabHeader(WorkoutSource.displaySport(shown.sport), subtitle: timeSpan(shown))

                hero(shown, detected: detected)
                    .padding(.top, WM.Space.l)

                if hrValues.count >= 2 {
                    let peak = shown.maxHr ?? Int(hrValues.max() ?? 0)
                    HRCurve(values: hrValues, peak: peak, axis: axisLabels)
                        .padding(.top, WM.Space.sectionTight)
                }

                if let zones = zoneMinutes, zones.contains(where: { $0 > 0 }) {
                    RuleSection("Time in zone") {
                        ZoneRows(minutes: zones)
                    }
                }

                RuleSection("Session") {
                    stats(shown)
                }

                actions(detected: detected)
                    .padding(.top, WM.Space.sectionTight)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .toolbar(.hidden, for: .navigationBar)
        // Fold the window END into the reload key: a duration-only edit keeps the same natural key
        // (source|startTs|sport) but moves `current.endTs`, so without this the HR curve + zone rows keep
        // rendering the OLD window while the hero/stats already show the new duration.
        .task(id: "\(WorkoutRef(row: row).id)|\(shown.endTs)") { await load(shown) }
        // A key-changing edit (startTs/sport) relands the row under a new key and deletes the old, or a
        // delete removes it — either way liveRow goes nil. Pop instead of lingering on a phantom row.
        .onChange(of: workoutRepo.workouts) { if liveRow == nil { dismiss() } }
        .sheet(isPresented: $showingEdit) {
            ManualWorkoutSheet(editing: shown)
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await workoutRepo.deleteWorkout(shown); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(detected
                 ? "This removes the detected bout and won't suggest it again."
                 : "This removes the workout from your history.")
        }
    }

    // MARK: - Header + hero

    /// The back affordance (chrome stays neutral — no tint). The nav bar is hidden, so this IS the only
    /// exit. `backLabel` names the origin, and `WMBackLink` reads it out as "Back to <title>".
    private var backLink: some View {
        WMBackLink(title: backLabel) { dismiss() }
    }

    /// "Yesterday · 18:05 – 18:57".
    private func timeSpan(_ w: WorkoutRow) -> String {
        "\(WorkoutFormat.relativeDay(w.startTs)) · \(WorkoutFormat.time(w.startTs)) – \(WorkoutFormat.time(w.endTs))"
    }

    /// The Effort numeral in Effort when the session was scored; otherwise its duration in ink, so a
    /// session with no Effort still leads with a number it genuinely has.
    @ViewBuilder
    private func hero(_ w: WorkoutRow, detected: Bool) -> some View {
        let sport = WorkoutSource.displaySport(w.sport)
        VStack(alignment: .leading, spacing: WM.Space.s) {
            if let strain = WorkoutFormat.strainText(w.strain) {
                HeroReadout(value: strain, title: "Effort",
                            subtitle: "\(sport) · \(WorkoutFormat.duration(w))",
                            color: WM.Domain.effort.color, size: 96)
            } else {
                HeroReadout(value: "\(WorkoutFormat.durationSeconds(w) / 60)", unit: "min",
                            title: "Duration", subtitle: sport, size: 96)
            }
            if detected {
                Text("Detected from your heart rate — approximate.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
    }

    // MARK: - Session stats

    private func stats(_ w: WorkoutRow) -> some View {
        HStack(alignment: .top, spacing: WM.Space.m) {
            cell("Avg HR", w.avgHr.map(String.init), "bpm")
            cell("Peak", w.maxHr.map(String.init), "bpm")
            cell("Time", "\(WorkoutFormat.durationSeconds(w) / 60)", "min")
            cell("Energy", w.energyKcal.map { String(Int($0.rounded())) }, "kcal")
        }
    }

    private func cell(_ label: String, _ value: String?, _ unit: String) -> some View {
        SignalCell(label: label, value: value ?? "—", unit: value == nil ? nil : unit,
                   valueSize: 24, fillsWidth: true)
    }

    // MARK: - Actions

    /// Edit (a detected bout relabels instead — the same sheet, which dismisses the detected original on
    /// save) and Delete, whose destructive red carries into its confirmation dialog.
    private func actions(detected: Bool) -> some View {
        VStack(spacing: 0) {
            WMNavRow(title: detected ? "Relabel as a sport" : "Edit details",
                     hint: detected ? "Saves this bout under a sport you choose"
                                    : "Opens the workout's details to edit") { showingEdit = true }
            WMRule()
            WMNavRow(title: "Delete workout", titleColor: WM.Semantic.bad,
                     showsDisclosure: false) { confirmingDelete = true }
        }
    }

    // MARK: - Data

    private func load(_ w: WorkoutRow) async {
        let buckets = await root.repo.workoutHrBuckets(from: w.startTs, to: w.endTs)
        hrValues = buckets.map { $0.bpm }
        // Start, a third, two thirds, end — four ticks, formatted here once rather than on every pass.
        let span = w.endTs - w.startTs
        axisLabels = [0, 1, 2, 3].map { WorkoutFormat.time(w.startTs + span * $0 / 3) }
        // Prefer the strap's own time-in-zone; fall back to any imported per-workout zone percentages.
        // Bucket against the override-aware profile.hrMax the live zones use.
        if let minutes = await root.repo.workoutZoneMinutes(from: w.startTs, to: w.endTs,
                                                            age: profile.age, hrMax: profile.hrMax) {
            zoneMinutes = minutes
        } else if let pct = WorkoutZones.percents(w.zonesJSON) {
            let durMin = Double(WorkoutFormat.durationSeconds(w)) / 60.0
            zoneMinutes = pct.map { durMin * $0 / 100.0 }
        } else {
            zoneMinutes = nil
        }
    }
}

/// The session HR curve (037): a 2pt Effort line through the per-bucket means over an Effort wash,
/// the time axis under it, and the peak as a caption. The vertical scale runs from a quarter-span below
/// the lowest bucket to the peak, so the warmup → peak → cooldown arc fills the chart.
private struct HRCurve: View {
    let values: [Double]
    let peak: Int
    /// Tick labels spread evenly across the width, first flush left and last flush right.
    let axis: [String]
    var height: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Canvas { ctx, size in
                guard values.count >= 2, let lowest = values.min() else { return }
                let hi = max(Double(peak), values.max() ?? 0, lowest + 1)
                let lo = max(lowest - (hi - lowest) * 0.25, 0)
                let span = max(hi - lo, 1)
                let step = size.width / CGFloat(values.count - 1)
                var line = Path()
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step,
                                        y: size.height * (1 - CGFloat(min(max((v - lo) / span, 0), 1))))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                let effort = WM.Domain.effort.color
                ctx.fill(area, with: .color(effort.opacity(0.12)))
                ctx.stroke(line, with: .color(effort),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            if !axis.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(axis.enumerated()), id: \.offset) { i, label in
                        if i > 0 { Spacer(minLength: WM.Space.xs) }
                        Text(label)
                    }
                }
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .accessibilityHidden(true)
            }

            Text("Peak \(peak) bpm")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .accessibilityLabel("Heart rate over the session, peak \(peak) beats per minute")
        }
    }
}

/// Time in zone as five rows (037): the zone name, a `.compact` bar scale — minutes against the
/// session's biggest zone, so the zones compare with each other — and the minutes.
private struct ZoneRows: View {
    let minutes: [Double]

    var body: some View {
        let most = max(minutes.max() ?? 0, 0.0001)
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { i in
                let m = minutes[safe: i] ?? 0
                HStack(spacing: WM.Space.m) {
                    Text("Zone \(i + 1)")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                        .frame(width: 62, alignment: .leading)
                    LineScale(value: m / most, color: WM.Domain.effort.color, style: .compact,
                              showsDot: false)
                    Text(minuteText(m))
                        .font(WMType.numeral(17))
                        .foregroundStyle(m < 1 ? WM.Ground.inkTertiary : WM.Ground.ink)
                        .frame(width: 44, alignment: .trailing)
                }
                .frame(minHeight: 40)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time in zone, minutes: " +
            (0..<5).map { "Zone \($0 + 1) \(Int((minutes[safe: $0] ?? 0).rounded()))" }.joined(separator: ", "))
    }

    private func minuteText(_ m: Double) -> String {
        m < 1 ? "—" : "\(Int(m.rounded()))m"
    }
}

private extension Array where Element == Double {
    subscript(safe i: Int) -> Double? { indices.contains(i) ? self[i] : nil }
}
