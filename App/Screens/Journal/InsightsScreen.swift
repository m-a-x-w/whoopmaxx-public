import SwiftUI
import StrapStore
import StrapAnalytics

/// Insights (007 F1; the journal insights, pushed from the Log tab's "Insights" row since 037): every
/// logged behavior ranked by how strongly its logged days line up with the scores that followed.
/// Ranking is the vendored lag-aware pipeline — `EffectRanker.bestLag` (lags 0/+1/+2, group gate n≥5
/// per side) per (behavior × outcome), with `CorrelationEngine.benjaminiHochberg` FDR applied across
/// the whole family so many tags can't stargaze one lucky pair. Nothing is persisted — the rows are
/// recomputed on demand from the repo caches + a merged-lane journal read.
///
/// Tag LOGGING is not here any more: the eight day chips (and weed's clear-confirmation) live in
/// `JournalTagsSection` on Log, and Weed's own page is a Log row. This screen reads; Log writes.
struct InsightsScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var journal: JournalStore

    /// Names the screen this was pushed from — both the visible back label and its VoiceOver one.
    var backLabel: String = "Log"

    @State private var rows: [JournalInsightRow] = []
    @State private var loaded = false
    /// Stale-drop stamp: both triggers (.task on refreshSeq + the tag-change Task) funnel through
    /// `recompute`, which suspends at the async tag read; without this the older-snapshot pass could
    /// resume last and clobber a fresher ranking. Claimed synchronously at entry (main-actor serialized).
    @State private var recomputeGen = 0

    var body: some View {
        InsightsContent(rows: rows, loaded: loaded, backLabel: backLabel)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: repo.refreshSeq) { await recompute() }
            // A tag toggled on Log re-ranks live even when the diff-guarded repo refresh publishes
            // nothing (a journal-only edit may not move any daily cache).
            .onChange(of: journal.tagsByDay) { _, _ in
                Task { await recompute() }
            }
    }

    private func recompute() async {
        recomputeGen &+= 1
        let myGen = recomputeGen
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-120 * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let tags = await journal.tagDays(from: from, to: to)
        let computed = JournalInsightsModel.compute(tagDays: tags, days: repo.days,
                                                    restSeries: repo.restSeries)
        guard myGen == recomputeGen else { return }   // a newer pass superseded us — don't clobber
        if rows != computed { rows = computed }
        loaded = true
    }
}

// MARK: - Model (pure)

/// One insights row: a logged behavior and, when computable, its strongest honest effect.
struct JournalInsightRow: Identifiable, Equatable {
    /// The stored question key ("alcohol", or an imported behavior's own key).
    let key: String
    let label: String
    /// Days this behavior was logged YES in the window.
    let loggedDays: Int
    /// The best (behavior × outcome) effect that cleared the n≥5-per-group gate, or nil — below
    /// `BehaviorInsights.minGroupForSignificance` no effect (and no number) is ever shown.
    let effect: RankedEffect?
    /// Benjamini–Hochberg q-value of the chosen effect within the behavior×outcome family.
    let qValue: Double?
    /// Family-corrected significance: q < 0.05 (the group gate is already enforced upstream).
    let significant: Bool
    var id: String { key }
}

/// Pure assembly behind `InsightsScreen` (and Weed's verdict) — behaviors × outcomes → ranked rows.
/// Value-in/value-out so tests can drive it without a store.
enum JournalInsightsModel {

    /// The outcome labels, in family order. Each one's reading rules (`unit`, `higherIsBetter`) sit
    /// right beside it so a renamed outcome cannot leave its unit or its polarity behind.
    static let hrvLabel = "HRV"
    static let restingHRLabel = "Resting HR"
    static let chargeLabel = "Charge"
    static let restLabel = "Rest"

    /// The screen's one-line statement of what the family is tested against.
    static let familySummary = "Tested against HRV, resting HR, Charge and Rest"

    /// The outcome family, labelled with the app's score names: next-morning vitals (HRV /
    /// Resting HR), Charge (recovery), and Rest (the `sleep_performance` series). Lag alignment is
    /// EffectRanker's job — these are the plain day-keyed series.
    static func outcomes(days: [DailyMetric],
                         restSeries: [String: Double]) -> [(label: String, byDay: [String: Double])] {
        var hrv: [String: Double] = [:]
        var rhr: [String: Double] = [:]
        var charge: [String: Double] = [:]
        for d in days {
            if let v = d.avgHrv { hrv[d.day] = v }
            if let v = d.restingHr { rhr[d.day] = Double(v) }
            if let v = d.recovery { charge[d.day] = v }
        }
        return [(hrvLabel, hrv), (restingHRLabel, rhr), (chargeLabel, charge), (restLabel, restSeries)]
    }

    /// The unit an outcome's delta is read in, or nil for a 0–100 score (points need no unit).
    static func unit(forOutcome outcome: String) -> String? {
        switch outcome {
        case hrvLabel: return "ms"
        case restingHRLabel: return "bpm"
        default: return nil
        }
    }

    /// Which way is the better way for an outcome to move: up for HRV, Charge and Rest, DOWN for
    /// resting heart rate. Decides only the semantic color of a significant effect's line.
    static func higherIsBetter(outcome: String) -> Bool {
        outcome != restingHRLabel
    }

    /// Rank every logged behavior: best lag per (behavior × outcome), BH-corrected across the whole
    /// family, then ONE row per behavior (its strongest surviving pair). Behaviors whose every pair
    /// fails the group gate keep a row with `effect: nil` — the "not enough data yet" state.
    static func compute(tagDays: [String: Set<String>], days: [DailyMetric],
                        restSeries: [String: Double]) -> [JournalInsightRow] {
        let outcomes = outcomes(days: days, restSeries: restSeries)

        // Every (behavior × outcome) best-lag effect — the FAMILY the FDR correction runs across.
        // Behavior keys iterate sorted so the family order (and thus tie-broken q-values) is
        // deterministic regardless of dictionary order.
        var candidates: [(tag: String, effect: RankedEffect)] = []
        for tag in tagDays.keys.sorted() {
            let behaviorDays = tagDays[tag]!
            for o in outcomes {
                if let e = EffectRanker.bestLag(behaviorDays: behaviorDays, outcomeByDay: o.byDay,
                                                behavior: JournalTag.displayLabel(forQuestion: tag),
                                                outcome: o.label) {
                    candidates.append((tag: tag, effect: e))
                }
            }
        }
        let q = CorrelationEngine.benjaminiHochberg(candidates.map { $0.effect.effect.pApprox })

        var rows: [JournalInsightRow] = []
        for tag in tagDays.keys.sorted() {
            let label = JournalTag.displayLabel(forQuestion: tag)
            let logged = tagDays[tag]!.count
            let mine = candidates.indices.filter { candidates[$0].tag == tag }
            // The behavior's headline pair: family-corrected significance first, then |d|.
            let best = mine.min { a, b in
                let sa = q[a] < BehaviorInsights.alpha
                let sb = q[b] < BehaviorInsights.alpha
                if sa != sb { return sa }
                return abs(candidates[a].effect.effect.cohensD) > abs(candidates[b].effect.effect.cohensD)
            }
            if let i = best {
                rows.append(JournalInsightRow(key: tag, label: label, loggedDays: logged,
                                              effect: candidates[i].effect, qValue: q[i],
                                              significant: q[i] < BehaviorInsights.alpha))
            } else {
                rows.append(JournalInsightRow(key: tag, label: label, loggedDays: logged,
                                              effect: nil, qValue: nil, significant: false))
            }
        }
        // Mirror BehaviorInsights.rank's ordering: significant first, |d| descending, stable name
        // tiebreak. Effect-less rows carry |d| = 0 so they sink to the bottom of "unclear".
        return rows.sorted { a, b in
            if a.significant != b.significant { return a.significant }
            let da = abs(a.effect?.effect.cohensD ?? 0)
            let db = abs(b.effect?.effect.cohensD ?? 0)
            if da != db { return da > db }
            return a.label < b.label
        }
    }
}

// MARK: - View (pure)

/// The insights body over plain rows, previewable without a store (mockup `L_Insights`): back link,
/// title with what the family is tested against, one paragraph, then two sections — family-corrected
/// significant effects ("What moves your recovery"), then everything logged that hasn't produced a
/// trustworthy signal ("Logged but unclear" — non-significant pairs and below-n behaviors).
struct InsightsContent: View {
    let rows: [JournalInsightRow]
    var loaded: Bool = true
    var backLabel: String = "Log"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let significant = rows.filter { $0.significant }
        let unclear = rows.filter { !$0.significant }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WMBackLink(title: backLabel) { dismiss() }
                    .padding(.top, WM.Space.s)

                TabHeader("Insights", subtitle: JournalInsightsModel.familySummary)

                Text("Days you logged a behavior, lined up against the scores that followed. "
                     + "Association, not causation.")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WM.Space.l)

                if loaded && rows.isEmpty {
                    Text("Nothing logged yet. Tag a day on Log and its effects will surface here.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.sectionTight)
                } else {
                    if !significant.isEmpty {
                        RuleSection("What moves your recovery", topGap: WM.Space.sectionTight) { list(significant) }
                    }
                    if !unclear.isEmpty {
                        RuleSection("Logged but unclear",
                                    topGap: significant.isEmpty ? WM.Space.sectionTight : WM.Space.section) {
                            list(unclear)
                        }
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: - Rows

    private func list(_ rows: [JournalInsightRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                if r.id != rows.first?.id {
                    WMRule()
                }
                // Weed is the one behavior with a screen of its own (009) — sessions, pattern and
                // breaks sit BEHIND this row, which the Weed screen renders verbatim, so the push
                // can never lead to a second verdict. No other insights row gains a disclosure.
                if r.key == JournalTag.weed.rawValue {
                    NavigationLink {
                        WeedScreen(backLabel: "Insights")
                    } label: {
                        HStack(spacing: WM.Space.m) {
                            InsightRow(row: r)
                            WMDisclosure()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Weed: sessions, pattern and breaks")
                } else {
                    InsightRow(row: r)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Insights — light") {
    NavigationStack {
        InsightsContent(rows: InsightsSpecimen.rows)
    }
    .preferredColorScheme(.light)
}

#Preview("Insights — dark") {
    NavigationStack {
        InsightsContent(rows: InsightsSpecimen.rows)
    }
    .preferredColorScheme(.dark)
}

#Preview("Insights — empty") {
    InsightsContent(rows: [])
        .preferredColorScheme(.light)
}

/// Deterministic preview rows (no store / repo needed): two significant effects (one per polarity),
/// one logged-but-unclear effect, and one behavior still under the group gate.
private enum InsightsSpecimen {
    static let rows: [JournalInsightRow] = [
        JournalInsightRow(
            key: "alcohol", label: "Alcohol", loggedDays: 12,
            effect: RankedEffect(
                behavior: "Alcohol", outcome: "HRV", lag: 1,
                effect: BehaviorEffect(behavior: "Alcohol", outcome: "HRV",
                                       meanWith: 58, meanWithout: 74, delta: -16,
                                       pctChange: -21.6, nWith: 12, nWithout: 82,
                                       cohensD: -1.2, pApprox: 0.001, significant: true),
                confidence: .building),
            qValue: 0.01, significant: true),
        JournalInsightRow(
            key: "weed", label: "Weed", loggedDays: 11,
            effect: RankedEffect(
                behavior: "Weed", outcome: "Resting HR", lag: 1,
                effect: BehaviorEffect(behavior: "Weed", outcome: "Resting HR",
                                       meanWith: 61, meanWithout: 58, delta: 3,
                                       pctChange: 5.2, nWith: 11, nWithout: 83,
                                       cohensD: 0.61, pApprox: 0.006, significant: true),
                confidence: .building),
            qValue: 0.03, significant: true),
        JournalInsightRow(
            key: "caffeine_late", label: "Late caffeine", loggedDays: 9,
            effect: RankedEffect(
                behavior: "Late caffeine", outcome: "Rest", lag: 1,
                effect: BehaviorEffect(behavior: "Late caffeine", outcome: "Rest",
                                       meanWith: 78, meanWithout: 81, delta: -3,
                                       pctChange: -3.7, nWith: 9, nWithout: 84,
                                       cohensD: -0.28, pApprox: 0.24, significant: false),
                confidence: .building),
            qValue: 0.42, significant: false),
        JournalInsightRow(key: "sauna", label: "Sauna", loggedDays: 2,
                          effect: nil, qValue: nil, significant: false),
    ]
}
