import SwiftUI
import StrapStore
import StrapAnalytics

/// Journal insights (007 F1), pushed from the Journal section on Today: every logged behavior
/// ranked by how strongly its logged days line up with the scores that followed. Ranking is the
/// vendored lag-aware pipeline — `EffectRanker.bestLag` (lags 0/+1/+2, group gate n≥5 per side)
/// per (behavior × outcome), with `CorrelationEngine.benjaminiHochberg` FDR applied across the
/// whole family so many tags can't stargaze one lucky pair. Nothing is persisted — the rows are
/// recomputed on demand from the repo caches + a merged-lane journal read.
struct JournalScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var journal: JournalStore
    /// 029: the weed chip lives in this row and routes through `WeedStore`, not a bare boolean —
    /// the tap writes a SESSION as well as the tag. That routing moved here with the chips; leaving
    /// it behind on Today would have quietly turned weed into an ordinary boolean.
    @EnvironmentObject private var weed: WeedStore

    /// Names the screen this was pushed from. Was hardcoded "Today" until 029 moved the journal to
    /// More, at which point a fixed label would have lied.
    var backLabel: String = "Today"

    /// Days back from the anchor day (0 = today) — Today's stepper idiom, same meaning.
    @State private var dayOffset = 0
    /// Set when clearing the weed chip would discard hand-entered detail.
    @State private var weedConfirm: JournalWeedClearRef?
    @State private var rows: [JournalInsightRow] = []
    @State private var loaded = false
    /// Stale-drop stamp: both triggers (.task on refreshSeq + the tag-change Task) funnel through
    /// `recompute`, which suspends at the async tag read; without this the older-snapshot pass could
    /// resume last and clobber a fresher ranking. Claimed synchronously at entry (main-actor serialized).
    @State private var recomputeGen = 0
    #if DEBUG
    /// Drives the `--weed` launch arg's push and nothing else — the production route into `WeedScreen`
    /// is the "Weed" row below, an ordinary `NavigationLink` that needs no state. 030 moved this seed
    /// here from `TodayScreen`, which stopped being a place weed can be reached from in 029.
    @State private var showsWeedDetail = false
    #endif

    var body: some View {
        JournalInsightsView(rows: rows, loaded: loaded, backLabel: backLabel,
                            logging: AnyView(loggingSection))
            .toolbar(.hidden, for: .navigationBar)
            .task(id: repo.refreshSeq) { await recompute() }
            // A tag toggled elsewhere re-ranks live even when the diff-guarded repo refresh
            // publishes nothing (a journal-only edit may not move any daily cache).
            .onChange(of: journal.tagsByDay) { _, _ in
                Task { await recompute() }
            }
            // `.confirmationDialog` has no `item:` form, so the optional ref drives the presented
            // binding and comes back through `presenting:` — the title has to name the count.
            .confirmationDialog(weedConfirm?.prompt ?? "", isPresented: weedConfirmPresented,
                                titleVisibility: .visible, presenting: weedConfirm) { ref in
                Button("Remove", role: .destructive) {
                    Task { await weed.setDay(ref.day, on: false) }
                }
                Button("Cancel", role: .cancel) {}
            }
            #if DEBUG
            // `--weed` (009, rehomed here by 030): push the Weed detail AFTER first render — a seed
            // set on the cold-init path is dropped by NavigationStack, which is why every one of
            // these routes waits for a `.task` rather than initializing the state to the flag.
            //
            // It pushes the SAME screen, with the same "Journal" back label, as the production row
            // further down this file. That is the point of the move: the flag used to fire from
            // `TodayScreen`, whose Weed section 029 deleted, so the photograph showed a push reachable
            // only by launch argument. Screenshot routes that diverge from the real one stop being
            // evidence. `--weed` still needs no other argument — `DebugFlags` resolves the tab to
            // `.more` and ORs the flag into `--journal`, so More pushes this screen and this screen
            // pushes Weed.
            //
            // Deliberately NOT folded into the `.task(id: repo.refreshSeq)` above: that one re-runs on
            // every refresh, so the seed would re-push Weed each time a score landed after the user
            // had walked back out of it. This task runs once per appearance of the screen.
            .navigationDestination(isPresented: $showsWeedDetail) {
                WeedScreen(backLabel: "Journal")
            }
            .task { if DebugFlags.weed { showsWeedDetail = true } }
            #endif
    }

    // MARK: - Logging (029, moved off Today)

    /// The day being tagged. A STEPPER lives here because the chips write to a specific day and the
    /// common case is logging last night's drinking this morning — moving them to a surface with no
    /// day control would have silently cost back-dating, and with it the confounder inputs the health
    /// monitor and the ranked-effect family read. How far back it may walk is `canStepBack`'s call —
    /// far enough to back-date honestly, never past the chip cache that renders the answer.
    private var selectedKey: String {
        let anchor = Repository.anchorKey(days: repo.days)
        guard dayOffset > 0, let key = ScoreEngine.shiftDay(anchor, by: -dayOffset) else { return anchor }
        return key
    }

    private var weedConfirmPresented: Binding<Bool> {
        Binding(get: { weedConfirm != nil }, set: { if !$0 { weedConfirm = nil } })
    }

    @ViewBuilder
    private var loggingSection: some View {
        let key = selectedKey
        let onTags = journal.tagsByDay[key] ?? []
        RuleSection("Log") {
            VStack(alignment: .leading, spacing: WM.Space.m) {
                HStack {
                    Text(JournalScreen.dayLabel(key))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Spacer(minLength: WM.Space.s)
                    stepper(systemName: "chevron.left", label: "Previous day",
                            enabled: canStepBack) { dayOffset += 1 }
                    stepper(systemName: "chevron.right", label: "Next day",
                            enabled: dayOffset > 0) { dayOffset -= 1 }
                }
                ChipFlow(spacing: WM.Space.s) {
                    ForEach(JournalTag.allCases) { tag in
                        chip(tag, on: onTags.contains(tag.rawValue), day: key)
                    }
                }
            }
        }
    }

    /// Whether the back chevron is live. The floor is the JOURNAL READ WINDOW, not the first
    /// `DailyMetric` row: this is a back-dating WRITE surface (see `selectedKey`), and a behavior day
    /// legitimately precedes the oldest score the strap ever produced — gating on `repo.days` would
    /// refuse to log a night the user genuinely lived through.
    ///
    /// It has to be bounded by SOMETHING, though. As shipped in 029 this arrow had no `.disabled` at
    /// all and stepped backwards forever. `JournalStore.tagsByDay` — the cache the chip row reads —
    /// only spans `readWindowDays`, so past that edge every chip rendered OFF for a day whose tags
    /// were never read (an unmeasured "not logged", which this app does not do), and a toggle there
    /// LOOKED discarded: the row was written, but the `refresh()` that follows rebuilds the cache
    /// from the window and drops the out-of-window entry, so the chip snapped straight back.
    ///
    /// `- 1` keeps the last reachable day comfortably inside the window rather than sitting on its
    /// edge, where a midnight rollover between the store's `refresh()` and this comparison would put
    /// the selected day one day outside the cache.
    private var canStepBack: Bool { dayOffset < JournalStore.readWindowDays - 1 }

    /// Today's stepper button, glyph for glyph (`TodayScreen.swift` / `RestScreen.swift`) — the 14pt
    /// semibold `.nav` chrome role, ink when live and dimmed when not, in a 44×44 hit region the
    /// glyph does not grow into. 029 hand-rolled this pair instead of copying either sibling, which
    /// left the back glyph with no `.font` and no `.foregroundStyle` at all: with `.buttonStyle(.plain)`
    /// and no ambient tint it resolved to `Color.primary` — the pure black/white the design language
    /// rules out — at the inherited body size, a visible half-step larger than its own sibling.
    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.nav))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    static func dayLabel(_ key: String) -> String {
        guard let d = DayKey.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func chip(_ tag: JournalTag, on: Bool, day: String) -> some View {
        Button {
            // Weed alone routes through `WeedStore` — the tap writes a SESSION as well as the
            // boolean, and clearing discards that day's sessions, so it asks first when one carries
            // something the user typed. Every other tag is a bare boolean.
            guard tag == .weed else {
                Task { await journal.set(tag: tag, on: !on, day: day) }
                return
            }
            if on, weed.needsClearConfirmation(on: day) {
                weedConfirm = JournalWeedClearRef(day: day, sessions: weed.sessions(on: day).count)
            } else {
                Task { await weed.setDay(day, on: !on) }
            }
        } label: {
            Text(tag.label)
                .font(WMType.label)
                .foregroundStyle(on ? WM.Ground.ground : WM.Ground.ink)
                .padding(.horizontal, WM.Space.m)
                .padding(.vertical, WM.Space.s)
                .background(Capsule().fill(on ? WM.Ground.ink : Color.clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : WM.Ground.ruleHeavy,
                                                lineWidth: WM.hairline))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.label), \(on ? "logged" : "not logged")")
        .accessibilityAddTraits(on ? [.isSelected] : [])
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

/// Pure assembly behind `JournalScreen` — behaviors × outcomes → ranked rows. Value-in/value-out
/// so tests can drive it without a store.
enum JournalInsightsModel {

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
        return [("HRV", hrv), ("Resting HR", rhr), ("Charge", charge), ("Rest", restSeries)]
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

/// The insights body over plain rows, previewable without a store. Two sections: family-corrected
/// significant effects ("What moves your recovery"), then everything logged that hasn't produced a
/// trustworthy signal ("Logged but unclear" — non-significant pairs and below-n behaviors).
struct JournalInsightsView: View {
    let rows: [JournalInsightRow]
    var loaded: Bool = true

    var backLabel: String = "Today"
    /// The day-tagging controls, injected by `JournalScreen` so this stays value-driven.
    var logging: AnyView? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let significant = rows.filter { $0.significant }
        let unclear = rows.filter { !$0.significant }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                    .padding(.top, WM.Space.m)

                header
                    .padding(.top, WM.Space.sectionTight)

                if let logging { logging }

                // 029: weed's own page, reachable UNCONDITIONALLY.
                //
                // It used to hang off weed's ranked-effect row, which only exists once weed clears
                // the n>=5 group gate — so a user who had logged a few sessions could see the Weed
                // section on Today but had no route to the screen from here at all. A page you can
                // only reach once a statistic qualifies is a page most users never find.
                RuleSection("Weed") {
                    NavigationLink {
                        WeedScreen(backLabel: "Journal")
                    } label: {
                        HStack(spacing: WM.Space.m) {
                            VStack(alignment: .leading, spacing: WM.Space.xs) {
                                Text("Sessions, effects and breaks")
                                    .font(WMType.body)
                                    .foregroundStyle(WM.Ground.ink)
                                Text("Logged sessions, density and your longest break")
                                    .font(WMType.caption)
                                    .foregroundStyle(WM.Ground.inkTertiary)
                            }
                            Spacer(minLength: WM.Space.s)
                            WMDisclosure()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, WM.Space.xs)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }

                if loaded && rows.isEmpty {
                    Text("Nothing logged yet. Tag a day above and its effects will surface here.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WM.Space.section)
                } else {
                    if !significant.isEmpty {
                        RuleSection("What moves your recovery") { list(significant) }
                    }
                    if !unclear.isEmpty {
                        RuleSection("Logged but unclear",
                                    topGap: significant.isEmpty ? WM.Space.section : WM.Space.sectionTight) {
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

    // MARK: - Header

    /// Ink back affordance (chrome stays neutral — no tint). Pushed from Today.
    private var backLink: some View {
        WMBackLink(title: backLabel) { dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Journal insights")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Text("Days you logged a behavior, lined up against the scores that followed. Association, not causation.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rows

    private func list(_ rows: [JournalInsightRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                // Weed is the one behavior with a screen of its own (009) — sessions, pattern and
                // breaks sit BEHIND this row, which the Weed screen renders verbatim, so the push
                // can never lead to a second verdict. No other insights row gains a disclosure.
                if r.key == JournalTag.weed.rawValue {
                    NavigationLink {
                        WeedScreen(backLabel: "Journal")
                    } label: {
                        HStack(spacing: WM.Space.m) {
                            InsightRow(row: r)
                            WMDisclosure()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    InsightRow(row: r)
                }
                if r.id != rows.last?.id {
                    WMRule()
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Journal insights — light") {
    JournalInsightsView(rows: JournalInsightsSpecimen.rows)
        .preferredColorScheme(.light)
}

#Preview("Journal insights — dark") {
    JournalInsightsView(rows: JournalInsightsSpecimen.rows)
        .preferredColorScheme(.dark)
}

#Preview("Journal insights — empty") {
    JournalInsightsView(rows: [])
        .preferredColorScheme(.light)
}

/// Deterministic preview rows (no store / repo needed).
private enum JournalInsightsSpecimen {
    static let rows: [JournalInsightRow] = [
        JournalInsightRow(
            key: "alcohol", label: "Alcohol", loggedDays: 9,
            effect: RankedEffect(
                behavior: "Alcohol", outcome: "HRV", lag: 1,
                effect: BehaviorEffect(behavior: "Alcohol", outcome: "HRV",
                                       meanWith: 61, meanWithout: 74, delta: -13,
                                       pctChange: -17.5, nWith: 9, nWithout: 82,
                                       cohensD: -0.92, pApprox: 0.004, significant: true),
                confidence: .building),
            qValue: 0.03, significant: true),
        JournalInsightRow(
            key: "caffeine_late", label: "Late caffeine", loggedDays: 7,
            effect: RankedEffect(
                behavior: "Late caffeine", outcome: "Rest", lag: 1,
                effect: BehaviorEffect(behavior: "Late caffeine", outcome: "Rest",
                                       meanWith: 78, meanWithout: 83, delta: -5,
                                       pctChange: -6.0, nWith: 7, nWithout: 84,
                                       cohensD: -0.34, pApprox: 0.21, significant: false),
                confidence: .building),
            qValue: 0.42, significant: false),
        JournalInsightRow(key: "sauna", label: "Sauna", loggedDays: 2,
                          effect: nil, qValue: nil, significant: false),
    ]
}

/// Identifiable ref for the clear-weed confirmation (009, moved here by 029): the day being cleared
/// and how many sessions go with it, since the prompt names the count.
private struct JournalWeedClearRef: Identifiable {
    let day: String
    let sessions: Int
    var id: String { day }
    var prompt: String {
        "Remove weed for this day? \(sessions) logged session\(sessions == 1 ? "" : "s") will be deleted."
    }
}
