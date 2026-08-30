import SwiftUI
import StrapStore
import StrapAnalytics

/// The Live tab's workouts list — a slim, open-editorial roll of every logged session (strap-detected +
/// manual), newest first: sport, when, duration, a strain spark in Effort, and avg/peak HR. '+' adds a
/// manual workout; tapping a row pushes the detail. Restyle of the original ~1600-line WorkoutsView down to the
/// MVP list only (spec cut line).
///
/// Below the roll sits the ranked "Recovery cost" block (011 W1.6) — what a session of each sport costs
/// the next morning, over the same sessions the list shows.
struct WorkoutsListScreen: View {
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    @EnvironmentObject private var repo: Repository

    @State private var selection: WorkoutRef?
    @State private var showingAdd = false
    /// nil until the first fold lands, so the block never flashes an empty line before it has read
    /// anything. Recomputed off the frame path — see `costKey`.
    @State private var cost: ActivityCostFold.Readout?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, WM.Space.m)

                if workoutRepo.workouts.isEmpty {
                    emptyState
                        .padding(.top, WM.Space.sectionLoose)
                } else {
                    VStack(spacing: 0) {
                        // Key the ForEach off the UNIQUE `WorkoutRef.id` ("source|startTs|sport"), not the
                        // bare `startTs`: two workouts that share a start-second (different source / sport)
                        // collide under one id, silently dropping a row and misfiring the divider guard.
                        let refs = workoutRepo.workouts.map { WorkoutRef(row: $0) }
                        ForEach(refs) { ref in
                            Button { selection = ref } label: {
                                WorkoutListRow(row: ref.row)
                            }
                            .buttonStyle(.plain)
                            if ref.id != refs.last?.id {
                                WMRule()
                            }
                        }
                    }
                    .padding(.top, WM.Space.l)

                    if let cost {
                        ActivityCostSection(readout: cost)
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
        // Fold + engine once per real data change, never per frame — the workout cache spans years and
        // the fold walks every session's D+1…D+7 window.
        .task(id: costKey) {
            cost = ActivityCostFold.readout(workouts: workoutRepo.workouts, days: repo.days)
        }
        // This screen draws its OWN "‹ Live" header; hide the system nav bar so a push doesn't stack a
        // duplicate system bar + a second back button above the custom header.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selection) { ref in
            WorkoutDetailScreen(row: ref.row)
        }
        .sheet(isPresented: $showingAdd) {
            ManualWorkoutSheet(editing: nil)
        }
        #if DEBUG
        .task {
            if DebugFlags.manualWorkout { showingAdd = true }
            if DebugFlags.workoutDetail {
                // The demo seed refreshes the cache asynchronously; poll briefly so the deep-link lands
                // on the newest row once it appears.
                for _ in 0..<20 {
                    if let first = workoutRepo.workouts.first { selection = WorkoutRef(row: first); break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            WMBackLink(title: "Live") { dismiss() }

            Spacer()

            Button { showingAdd = true } label: {
                Image(systemName: "plus")
                    .font(WMType.icon(.action))
                    .foregroundStyle(WM.Ground.ink)
                    // ≥44×44 hit region (HIG); the glyph keeps its size, only the invisible box grows.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a workout")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Workouts").font(WMType.title).foregroundStyle(WM.Ground.ink)
            Text("No workouts yet. Start one from the Live tab, or add one by hand with +. Detected bouts appear here after the strap syncs and scores.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Refold when EITHER input actually changed. Both caches carry their own diff-guarded counter and
    /// they move independently — a new workout bumps only `WorkoutRepository.refreshSeq`, a rescore only
    /// `Repository.refreshSeq` — so keying on one alone would leave the block stale.
    private var costKey: String { "\(repo.refreshSeq)|\(workoutRepo.refreshSeq)" }
}

/// One editorial row: sport + when on the left, a strain spark / HR on the right.
private struct WorkoutListRow: View {
    let row: WorkoutRow

    var body: some View {
        HStack(alignment: .center, spacing: WM.Space.m) {
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(WorkoutSource.displaySport(row.sport))
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: WM.Space.s)

            if let strain = WorkoutFormat.strainText(row.strain) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(strain)
                        .font(WMType.numeral(26))
                        .foregroundStyle(WM.Domain.effort.color)
                    Text("EFFORT").wmOverline()
                }
            } else if let hr = row.avgHr {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(hr)")
                        .font(WMType.numeral(26))
                        .foregroundStyle(WM.Ground.ink)
                    Text("AVG BPM").wmOverline()
                }
            }

            WMDisclosure()
        }
        .padding(.vertical, WM.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["\(WorkoutFormat.relativeDay(row.startTs)) · \(WorkoutFormat.time(row.startTs))",
                     WorkoutFormat.duration(row)]
        if WorkoutSource.classify(row.source) == .detected { parts.append("Detected") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Recovery cost (011 W1.6)

/// The ranked "what a session costs you the next morning" block, per sport. Pure over an injected
/// `ActivityCostFold.Readout` so it previews without a Repository — the screen owns the fold.
///
/// Both empty states are SENTENCES, not a blank section: the engine answers "your baseline is
/// contaminated" and "you haven't logged four of anything yet" with the same `[]`, and a user who trains
/// every day would otherwise stare at an eyebrow with nothing under it forever.
private struct ActivityCostSection: View {
    let readout: ActivityCostFold.Readout

    var body: some View {
        RuleSection("Recovery cost") {
            switch readout {
            case .ranked(let rows):
                VStack(alignment: .leading, spacing: 0) {
                    Text("Each sport's next-morning Charge against the days you neither trained nor "
                        + "spent recovering from a session. Association, not causation.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows) { item in
                        ActivityCostRow(item: item)
                        if item.id != rows.last?.id {
                            WMRule()
                        }
                    }
                }
            case .noRestDays:
                line("Every day with a Charge score is a session day, or sits in the week after one, so "
                    + "there is no untouched day left to measure a session against.")
            case .tooFewPairs:
                line("No sport has \(ActivityCostEngine.minSessions) sessions with a Charge score the "
                    + "next morning yet.")
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One sport's row: label + the signed next-morning move, a Charge magnitude bar, and the engine's own
/// hedged sentence (which already carries "usually" and the n — it is printed verbatim).
private struct ActivityCostRow: View {
    let item: ActivityCostFold.SportCost

    /// Charge points the magnitude bar tops out at. 15 points is a very large next-morning move on a
    /// 0–100 scale, so a routine 6 still reads as a partial bar rather than a full one.
    private static let barCapPoints = 15.0

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            HStack(spacing: WM.Space.s) {
                Text(item.label)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                Spacer(minLength: WM.Space.s)
                if let chip = Self.deltaChip(item.cost) {
                    Text(chip)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            magnitudeBar
            Text(item.cost.sentence())
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WM.Space.m)
        .accessibilityElement(children: .combine)
    }

    /// Magnitude only, in Charge ember — the row plots a Charge outcome, so it borrows Charge's existing
    /// domain color and no new one is minted. The SIGN lives in the chip and in the sentence; a
    /// one-directional bar cannot carry it.
    private var magnitudeBar: some View {
        WMTrackBar(segments: [(min(abs(item.cost.delta) / Self.barCapPoints, 1.0),
                               WM.Domain.charge.color)],
                   track: WM.Ground.rule)
            .frame(height: 3)
            .accessibilityHidden(true)
    }

    /// The signed next-morning move, which is the engine's delta INVERTED: `ActivityCost.delta` is
    /// POSITIVE when the morning after sits BELOW the rest baseline, and printing that as "+6" would read
    /// as a gain. Nil under `barelyMovesPoints`, where `sentence()` prints no number either — a rounded
    /// "−0" would be a number the app did not measure.
    private static func deltaChip(_ cost: ActivityCost) -> String? {
        guard abs(cost.delta) >= ActivityCostEngine.barelyMovesPoints else { return nil }
        let points = Int(abs(cost.delta).rounded())
        return (cost.delta >= 0 ? "−" : "+") + "\(points) Charge"
    }
}

// MARK: - Previews

#Preview("Recovery cost — ranked, light") {
    ActivityCostSpecimen(readout: ActivityCostSpecimen.ranked).preferredColorScheme(.light)
}

#Preview("Recovery cost — ranked, dark") {
    ActivityCostSpecimen(readout: ActivityCostSpecimen.ranked).preferredColorScheme(.dark)
}

#Preview("Recovery cost — no rest days, light") {
    ActivityCostSpecimen(readout: .noRestDays).preferredColorScheme(.light)
}

#Preview("Recovery cost — too few pairs, dark") {
    ActivityCostSpecimen(readout: .tooFewPairs).preferredColorScheme(.dark)
}

private struct ActivityCostSpecimen: View {
    let readout: ActivityCostFold.Readout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ActivityCostSection(readout: readout)
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }

    /// Three synthetic sports in the engine's own rank order (|delta| descending) — a solid cost, a
    /// building-confidence cost, and a sport that leaves the user higher than a rest day.
    static let ranked = ActivityCostFold.Readout.ranked([
        .init(label: "Running",
              cost: ActivityCost(sport: "running", delta: 6.2, meanNextMorning: 58.1,
                                 baselineMean: 64.3, daysToBaseline: 2, n: 9, confidence: .solid)),
        .init(label: "Traditional Strength Training",
              cost: ActivityCost(sport: "traditional strength training", delta: 3.4,
                                 meanNextMorning: 60.9, baselineMean: 64.3, daysToBaseline: 1,
                                 n: 5, confidence: .building)),
        .init(label: "Yoga",
              cost: ActivityCost(sport: "yoga", delta: -2.1, meanNextMorning: 66.4,
                                 baselineMean: 64.3, daysToBaseline: 1, n: 6, confidence: .building))
    ])
}
