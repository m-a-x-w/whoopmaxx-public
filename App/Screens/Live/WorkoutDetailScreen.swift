import SwiftUI
import StrapStore

/// One workout in full: a strain hero in Effort, the session's HR curve (the bar-motif over the strap's
/// own samples), time-in-zone bars, the captured signals (avg / peak HR, duration, energy), and
/// Edit / Delete actions. Restyle of the original 636-line WorkoutDetailView down to the MVP (no GPS map).
struct WorkoutDetailScreen: View {
    let row: WorkoutRow
    /// The back-link label — "Workouts" when pushed from the list, "Today" from the Today row.
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
    private var current: WorkoutRow { liveRow ?? row }

    private var isDetected: Bool { WorkoutSource.classify(current.source) == .detected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.m)

                hero
                    .padding(.top, WM.Space.sectionTight)

                if hrValues.count >= 2 {
                    RuleSection("Heart rate") {
                        HRCurve(values: hrValues, peak: current.maxHr ?? Int(hrValues.max() ?? 0))
                    }
                }

                if let zones = zoneMinutes, zones.contains(where: { $0 > 0 }) {
                    RuleSection("Time in zone") {
                        ZoneBars(minutes: zones, hrMax: profile.hrMax)
                    }
                }

                RuleSection("Session") {
                    signals
                }

                RuleSection("Edit") {
                    actions
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        .toolbar(.hidden, for: .navigationBar)
        // Fold the window END into the reload key: a duration-only edit keeps the same natural key
        // (source|startTs|sport) but moves `current.endTs`, so without this the HR curve + zone bars keep
        // rendering the OLD window while the hero/signals already show the new duration.
        .task(id: "\(WorkoutRef(row: row).id)|\(current.endTs)") { await load() }
        // A key-changing edit (startTs/sport) relands the row under a new key and deletes the old, or a
        // delete removes it — either way liveRow goes nil. Pop instead of lingering on a phantom row.
        .onChange(of: workoutRepo.workouts) { if liveRow == nil { dismiss() } }
        .sheet(isPresented: $showingEdit) {
            ManualWorkoutSheet(editing: current)
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await workoutRepo.deleteWorkout(current); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isDetected
                 ? "This removes the detected bout and won't suggest it again."
                 : "This removes the workout from your history.")
        }
    }

    // MARK: - Header + hero

    /// Ink back affordance (chrome stays neutral — no tint). The nav bar is hidden, so this IS the only
    /// exit — and the hand-rolled Button it replaces had neither the ≥44pt hit region nor a
    /// `contentShape`, so the tap target was bare text height. `backLabel` still names the origin, and
    /// `WMBackLink` reads it out as "Back to <title>" — the same VoiceOver label as before.
    private var backLink: some View {
        WMBackLink(title: backLabel) { dismiss() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(WorkoutSource.displaySport(current.sport)).wmOverline()
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
                if let strain = WorkoutFormat.strainText(current.strain) {
                    Text(strain)
                        .font(WMType.display(72))
                        .foregroundStyle(WM.Domain.effort.color)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("effort")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkTertiary)
                } else {
                    Text(WorkoutFormat.duration(current))
                        .font(WMType.display(56))
                        .foregroundStyle(WM.Ground.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            Text("\(WorkoutFormat.longDateTime(current.startTs)) · \(WorkoutFormat.duration(current))")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
            if isDetected {
                Text("Detected from your heart rate — approximate.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Signals

    private var signals: some View {
        HStack(alignment: .top, spacing: WM.Space.m) {
            cell("Avg HR", current.avgHr.map(String.init), "bpm")
            cell("Peak HR", current.maxHr.map(String.init), "bpm")
            cell("Duration", "\(WorkoutFormat.durationSeconds(current) / 60)", "min")
            cell("Energy", current.energyKcal.map { String(Int($0.rounded())) }, "kcal")
        }
    }

    private func cell(_ label: String, _ value: String?, _ unit: String) -> some View {
        SignalCell(label: label, value: value ?? "—", unit: value == nil ? nil : unit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 0) {
            actionRow(isDetected ? "Relabel as a sport…" : "Edit details…") { showingEdit = true }
            WMRule()
            actionRow("Delete workout", destructive: true) { confirmingDelete = true }
        }
    }

    private func actionRow(_ title: String, destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(WMType.body)
                    .foregroundStyle(destructive ? WM.Semantic.bad : WM.Ground.ink)
                Spacer()
                if !destructive {
                    WMDisclosure()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, WM.Space.m)
    }

    // MARK: - Data

    private func load() async {
        let buckets = await root.repo.workoutHrBuckets(from: current.startTs, to: current.endTs)
        hrValues = buckets.map { $0.bpm }
        // Prefer the strap's own time-in-zone; fall back to any imported per-workout zone percentages.
        // Bucket against the override-aware profile.hrMax the on-screen ZoneBars + live zones use.
        if let minutes = await root.repo.workoutZoneMinutes(from: current.startTs, to: current.endTs,
                                                            age: profile.age, hrMax: profile.hrMax) {
            zoneMinutes = minutes
        } else if let pct = WorkoutZones.percents(current.zonesJSON) {
            let durMin = Double(WorkoutFormat.durationSeconds(current)) / 60.0
            zoneMinutes = pct.map { durMin * $0 / 100.0 }
        } else {
            zoneMinutes = nil
        }
    }
}

/// The session HR curve in the bar motif: one thin Effort bar per bucket, filling the available width
/// (a static twin of the live stream). Normalized 40…max so the warmup→peak→cooldown arc reads clearly.
private struct HRCurve: View {
    let values: [Double]
    let peak: Int
    var height: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Canvas { ctx, size in
                guard !values.isEmpty else { return }
                let lo = 40.0
                let hi = Swift.max(Double(peak), values.max() ?? 0, lo + 1)
                let span = Swift.max(hi - lo, 1)
                let slot = size.width / CGFloat(values.count)
                let gap = Swift.min(1.5, slot * 0.3)
                let bw = Swift.max(slot - gap, 1)
                for (i, v) in values.enumerated() {
                    let frac = Swift.min(Swift.max((v - lo) / span, 0), 1)
                    let bh = Swift.max(CGFloat(frac) * size.height, 2)
                    let rect = CGRect(x: CGFloat(i) * slot, y: size.height - bh, width: bw, height: bh)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2),
                             with: .color(WM.Domain.effort.color))
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                WMRule()
            }
            .accessibilityHidden(true)
            Text("Peak \(peak) bpm")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }
}

/// Five time-in-zone columns in the bar motif: bar height ∝ minutes, Effort color stepped by zone (the
/// App-local `EffortZoneRamp.ramp`), a "Zx" overline and a minute caption under each.
private struct ZoneBars: View {
    let minutes: [Double]
    let hrMax: Int
    var height: CGFloat = 140

    var body: some View {
        let maxMin = max(minutes.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: WM.Space.m) {
            ForEach(0..<5, id: \.self) { i in
                VStack(spacing: WM.Space.s) {
                    GeometryReader { geo in
                        let frac = CGFloat(minutes[safe: i] ?? 0) / CGFloat(maxMin)
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(WM.Domain.effort.color.opacity(EffortZoneRamp.ramp[i]))
                                .frame(height: max(geo.size.height * frac, 2))
                        }
                    }
                    .frame(height: height)
                    Text("Z\(i + 1)").wmOverline()
                    Text(minuteText(minutes[safe: i] ?? 0))
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
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
