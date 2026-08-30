import SwiftUI
import StrapStore
import StrapAnalytics

/// The Weed detail (009 F3), pushed from the Journal screen: days since the last session, a
/// trailing-30-day density strip, the effect verdict, descriptive pattern counts and the session
/// history. It was reachable from Today's Weed section too until 029 moved that section to Journal;
/// 030 removed the last Today route (a DEBUG screenshot seed that outlived it), so every push now
/// arrives from one screen.
///
/// EVERY number on this screen is either a COUNT of what was logged or the ranked effect Journal
/// insights already renders — there is no weed-only statistic anywhere. The verdict is the SAME
/// `InsightRow` over the SAME `JournalInsightsModel` family, which is why `recompute` ranks the
/// whole behavior × outcome family and then picks weed out of it: the Benjamini-Hochberg correction
/// is family-wide, so ranking weed alone (m ≈ 6 vs ≈ 32) would make its own q-values LOOSER on
/// identical data. Below the n≥5-per-group gate no number is shown at all, and
/// `RankedEffect.confidence` is deliberately never rendered — `pairs = min(nWith, nWithout)` and
/// `nWithout` ≈ 100 over a 120-day window, so the tier is driven purely by logged-day count and
/// would print "Solid" at ten self-reported nights, on the screen where overclaiming costs most.
///
/// Keeps `backLabel` as a parameter even though every current caller passes "Journal": the label
/// names the screen the push CAME from, and baking one in is exactly the lie 030 had to unpick when
/// the Today route was still passing "Today" from a screen that no longer mentioned weed (the
/// `WorkoutDetailScreen(row:backLabel:)` precedent). Takes NO day: the pattern and the history are
/// window-global; per-day logging lives on the Journal screen, where 029 moved it.
struct WeedScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var journal: JournalStore
    @EnvironmentObject private var weed: WeedStore

    /// Names the screen this was pushed from — both the visible back label and its VoiceOver one.
    let backLabel: String

    /// Weed's row in the shared journal insights family, nil until the first pass lands (or when
    /// weed carries no row in it at all).
    @State private var insight: JournalInsightRow?
    @State private var loaded = false
    /// The session the editor sheet is open on, or a session-less ref for a fresh log. This screen
    /// presents its OWN editor (the `HabitsDetailScreen` pattern) rather than borrowing Today's, so
    /// the header's "+" and the history rows work identically from the Journal-insights entry.
    @State private var editingSession: WeedSessionRef?
    /// Stale-drop stamp, `JournalScreen`'s: both triggers funnel through `recompute`, which suspends
    /// at the async tag read, so without this the older-snapshot pass could resume last and clobber a
    /// fresher ranking. Claimed synchronously at entry (main-actor serialized).
    @State private var recomputeGen = 0

    var body: some View {
        // The anchor day, once: the counts are taken against it and a "+" logs onto it.
        let today = Repository.anchorKey(days: repo.days)
        WeedContent(
            model: WeedScreenModel.compute(
                weedDays: weed.weedDays,
                sessionsByDay: weed.sessionsByDay,
                // Days the app has a DailyMetric row for — the honest denominator for a run
                // (`WeedPattern.compute`): a day with no data neither breaks nor extends one.
                coveredDays: repo.days.map(\.day),
                latestSession: weed.latestSession,
                everLogged: weed.everLogged,
                insight: insight, insightLoaded: loaded,
                today: today),
            backLabel: backLabel,
            onAddSession: { editingSession = WeedSessionRef(day: today, session: nil) },
            // The session's OWN day, never the anchor: an edit must land back where it was logged.
            onEditSession: { editingSession = WeedSessionRef(day: $0.day, session: $0) })
            .toolbar(.hidden, for: .navigationBar)
            .task(id: repo.refreshSeq) { await recompute() }
            // A session logged elsewhere projects a boolean, which re-ranks live even when the
            // diff-guarded repo refresh publishes nothing (a journal-only edit may move no daily row).
            .onChange(of: journal.tagsByDay) { _, _ in
                Task { await recompute() }
            }
            .sheet(item: $editingSession) { ref in
                WeedSessionSheet(editing: ref.session, day: ref.day)
            }
    }

    private func recompute() async {
        recomputeGen &+= 1
        let myGen = recomputeGen
        let now = Date()
        let from = Repository.localDayKey(now.addingTimeInterval(-120 * 86_400))
        let to = Repository.localDayKey(now.addingTimeInterval(86_400))
        let tags = await journal.tagDays(from: from, to: to)
        // The WHOLE family, then weed out of it — see the type doc. Never `tagDays` filtered to weed.
        let rows = JournalInsightsModel.compute(tagDays: tags, days: repo.days,
                                                restSeries: repo.restSeries)
        guard myGen == recomputeGen else { return }   // a newer pass superseded us — don't clobber
        let mine = rows.first { $0.key == JournalTag.weed.rawValue }
        if insight != mine { insight = mine }
        loaded = true
    }
}

/// Identifiable wrapper driving the editor's `sheet(item:)` — nil-means-create cannot drive `item:`
/// (the `MonitorDayRef` idiom; `WeedSessionSheet`'s ref lives with whichever screen presents it).
private struct WeedSessionRef: Identifiable {
    /// The day a CREATE lands on — the anchor day, since this screen has no stepper. An edit carries
    /// its own session's day instead.
    let day: String
    let session: WeedSession?
    var id: String { session?.id ?? "new-\(day)" }
}

// MARK: - Model (pure)

/// Everything the Weed body renders, assembled from the stores by `WeedScreen`. Value-in /
/// value-out so previews drive it without a store.
struct WeedScreenModel: Equatable {

    /// One cell of the trailing-30-day strip.
    struct DayCell: Equatable, Identifiable {
        let day: String
        /// The journal boolean — the single truth for whether this is a weed day.
        let logged: Bool
        /// Sessions on it. A legacy chip-only day is `logged` with zero sessions.
        let sessions: Int
        var id: String { day }
    }

    /// One day of the session history.
    struct DayGroup: Equatable, Identifiable {
        let day: String
        /// Rendered day label ("Today" / "Wednesday, July 15"), resolved at assembly so the view
        /// holds no clock.
        let title: String
        /// Newest first — the history reads newest-first throughout, including within a day.
        let sessions: [WeedSession]
        var id: String { day }
    }

    let pattern: WeedPattern
    /// The trailing 30 days, oldest first (left → right into today).
    let recent: [DayCell]
    /// Days carrying sessions, newest first. A legacy chip-only history is EMPTY here and the
    /// section is omitted — absence, never a fabricated zero.
    let groups: [DayGroup]
    /// Whether anything was ever logged. Reads the boolean too, so a legacy chip-only user is never
    /// told "Nothing logged yet".
    let everLogged: Bool
    /// Hero value: days since the last weed day, or "120+" when the newest session predates the
    /// caches. Nil only when nothing was ever logged (the hero is omitted).
    let daysSinceLastText: String?
    /// Weed's row in the shared insights family, or nil when it carries none.
    let insight: JournalInsightRow?
    /// False until the first ranking pass lands — the below-gate copy must not flash during it.
    let insightLoaded: Bool

    /// How far back the app's caches reach (`JournalStore`, `WeedStore` and `HabitsStore` each read
    /// a 120-day window behind their own private constant). The hero declares it as a FLOOR —
    /// "120+" — when the newest session predates it: that session is real, its exact age is simply
    /// not in memory to count, and a floor is honest where an invented number is not.
    static let historyWindowDays = 120

    static func compute(weedDays: Set<String>, sessionsByDay: [String: [WeedSession]],
                        coveredDays: [String], latestSession: WeedSession?, everLogged: Bool,
                        insight: JournalInsightRow?, insightLoaded: Bool,
                        today: String) -> WeedScreenModel {
        let pattern = WeedPattern.compute(weedDays: weedDays, sessionsByDay: sessionsByDay,
                                          coveredDays: coveredDays, today: today)

        // The strip spans `WeedPattern.windowDays`, so it and the "/30 d" tiles can never disagree
        // about which days they counted. Oldest first, the app's history-strip direction.
        let recent: [DayCell] = (0..<WeedPattern.windowDays).reversed().compactMap { back in
            guard let day = ScoreEngine.shiftDay(today, by: -back) else { return nil }
            return DayCell(day: day, logged: weedDays.contains(day),
                           sessions: sessionsByDay[day]?.count ?? 0)
        }

        let groups: [DayGroup] = sessionsByDay.keys.sorted(by: >).compactMap { day in
            guard let list = sessionsByDay[day], !list.isEmpty else { return nil }
            return DayGroup(day: day,
                            title: TodayModel.headerTitle(key: day, isToday: day == today),
                            sessions: list.sorted { ($0.ts, $0.id) > ($1.ts, $1.id) })
        }

        let sinceText: String?
        if let since = pattern.daysSinceLast {
            sinceText = "\(since)"
        } else if latestSession != nil {
            sinceText = "\(historyWindowDays)+"
        } else {
            sinceText = nil
        }

        return WeedScreenModel(pattern: pattern, recent: recent, groups: groups,
                               everLogged: everLogged, daysSinceLastText: sinceText,
                               insight: insight, insightLoaded: insightLoaded)
    }

    /// The Pattern wall. Counts only — no statistic reaches this block.
    ///
    /// Sessions and DAYS are separate tiles because they are separate facts: a legacy chip-only day
    /// carries no session row, so a user who logged nine days before 009 reads "0 sessions,
    /// 9 days logged" instead of a lone zero that looks like nothing happened.
    var tiles: [MetricTileModel] {
        [MetricTileModel(label: "Sessions", value: "\(pattern.sessions30d)", unit: "30 d"),
         MetricTileModel(label: "Days logged", value: "\(pattern.loggedDays30d)", unit: "30 d"),
         MetricTileModel(label: "Days since last", value: daysSinceLastText ?? "—"),
         MetricTileModel(label: "Longest break", value: "\(pattern.longestFreeRun)", unit: "days")]
    }

    /// Method + potency as one caption, or nil when the session records neither (the one-tap path).
    /// An unrecorded field is ABSENT here, never a placeholder that could read as a value.
    ///
    /// Potency prints as the WORD here and on Today's session row — never a dot count, which on
    /// screen is indistinguishable from the iOS "…" overflow affordance (the More tab's own glyph)
    /// and names nothing it counts. Type is this app's register; keep both rows on it.
    static func detailText(_ session: WeedSession) -> String? {
        let parts = [session.method?.label, session.potency?.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken stand-in for the strip (its cells are decorative — see `recentStrip`).
    var recentSummary: String {
        "Last \(WeedPattern.windowDays) days: \(pattern.loggedDays30d) days logged, "
            + "\(pattern.sessions30d) sessions"
    }
}

// MARK: - View (pure)

/// The Weed body over a plain model, previewable without a store.
struct WeedContent: View {
    let model: WeedScreenModel
    let backLabel: String
    var onAddSession: (() -> Void)? = nil
    var onEditSession: ((WeedSession) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                    .padding(.top, WM.Space.m)

                header
                    .padding(.top, WM.Space.sectionTight)

                if model.everLogged {
                    hero
                        .padding(.top, WM.Space.section)

                    RuleSection("Recent") { recentStrip }

                    RuleSection("Effects") { effects }

                    RuleSection("Pattern") { patternBlock }

                    // Omitted entirely for a chip-only history: an empty list would read as "no
                    // sessions on these days" rather than "sessions were never recorded".
                    if !model.groups.isEmpty {
                        RuleSection("Sessions") { sessionsList }
                    }
                } else {
                    emptyState
                        .padding(.top, WM.Space.section)
                }

                footer
                    .padding(.top, WM.Space.section)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }

    // MARK: Header

    /// Back affordance + the add glyph (the workouts-list header idiom). Chrome stays neutral ink.
    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            WMBackLink(title: backLabel) { dismiss() }

            Spacer()

            if let onAddSession {
                Button(action: onAddSession) {
                    Image(systemName: "plus")
                        .font(WMType.icon(.action))
                        .foregroundStyle(WM.Ground.ink)
                        // ≥44×44 hit region (HIG); the glyph keeps its size, only the invisible box grows.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log a session")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Weed")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Text("Sessions logged, lined up against the nights that followed. Association, not causation.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: WM.Space.s) {
            Text(model.daysSinceLastText ?? "—")
                .font(WMType.display(64))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: WM.Space.s)
            Text("Days since last session").wmOverline()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.daysSinceLastText ?? "no") days since the last logged session")
    }

    // MARK: Recent

    /// 30 cells, one per day, oldest → newest. Weight is session DENSITY, not a value: a day with
    /// two or more sessions reads full ink, one reads half, and a day that is not a weed day is an
    /// outline. A legacy chip-only day renders at the one-session weight — it IS a weed day, we just
    /// don't know how many.
    private var recentStrip: some View {
        HStack(spacing: 2) {
            ForEach(model.recent) { cell in
                recentCell(cell)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.recentSummary)
    }

    private func recentCell(_ cell: WeedScreenModel.DayCell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        return shape
            .fill(cell.logged ? WM.Ground.ink.opacity(cell.sessions >= 2 ? 1 : 0.45) : Color.clear)
            .frame(width: 8, height: 16)
            .overlay {
                if !cell.logged { shape.strokeBorder(WM.Ground.rule, lineWidth: WM.hairline) }
            }
            .frame(width: 10, height: 32)   // the strip's own row height (the habits-strip cell)
            .accessibilityHidden(true)
    }

    // MARK: Effects

    /// The one thing this screen says when no effect cleared the gate — one string, both paths.
    private static let belowGateText = "Not enough sessions yet — keep logging."

    /// The one verdict: the SAME row Journal insights renders for weed, so the two surfaces are
    /// structurally incapable of disagreeing. No row at all in the family means weed carries no
    /// logged day in the window it ranks over.
    @ViewBuilder
    private var effects: some View {
        if let insight = model.insight {
            // Same below-gate wording as the no-row case below it: a row that exists but failed the
            // n≥5 gate at every lag and no row at all are the SAME thing to the reader, and the
            // shared row's default ("data") would say it two different ways on one screen.
            InsightRow(row: insight, emptyText: Self.belowGateText)
        } else if model.insightLoaded {
            Text(Self.belowGateText)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pattern

    private var patternBlock: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            MetricWall(items: model.tiles)
            Text("Counted over days whoopmaxx has data for.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // Display only, by decision (009 Not-in-this-wave): the share crosses this threshold
            // with zero user action, so gating the confounder on it would silently rewrite banked
            // levels on the next pass. It is still the honest thing to tell a daily logger.
            if model.pattern.isHabitual {
                Text("You log weed most nights, so your baseline already includes it — it can't "
                    + "explain a night that stands out from your own normal.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sessions

    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title).wmOverline()
                        .padding(.bottom, WM.Space.xs)
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.vertical, WM.Space.s)
                if group.id != model.groups.last?.id {
                    WMRule()
                }
            }
        }
    }

    /// One session: its clock (or the declared "not recorded" stand-in) and whatever detail the user
    /// typed. Tappable only when the caller owns an editor.
    @ViewBuilder
    private func sessionRow(_ session: WeedSession) -> some View {
        if let onEditSession {
            Button { onEditSession(session) } label: { sessionRowBody(session) }
                .buttonStyle(.plain)
        } else {
            sessionRowBody(session)
        }
    }

    private func sessionRowBody(_ session: WeedSession) -> some View {
        HStack(spacing: WM.Space.m) {
            Text(session.tsExact ? WMFormat.timeOfDay(session.ts) : "Time not recorded")
                .font(WMType.body)
                .foregroundStyle(session.tsExact ? WM.Ground.ink : WM.Ground.inkTertiary)
            Spacer(minLength: WM.Space.s)
            if let detail = WeedScreenModel.detailText(session) {
                Text(detail)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        // ≥44 pt row (HIG): the text keeps its size, only the invisible box grows.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        Text("Nothing logged yet. Log a session on Today and its effects will surface here.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        Text("Potency is a relative scale you set, not a measured amount. Association, not causation.")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews

#Preview("Weed — effect, light") {
    WeedContent(model: WeedSpecimen.effect, backLabel: "Today",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.light)
}

#Preview("Weed — effect, dark") {
    WeedContent(model: WeedSpecimen.effect, backLabel: "Today",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.dark)
}

#Preview("Weed — below gate, light") {
    WeedContent(model: WeedSpecimen.belowGate, backLabel: "Today",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.light)
}

#Preview("Weed — below gate, dark") {
    WeedContent(model: WeedSpecimen.belowGate, backLabel: "Today",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.dark)
}

#Preview("Weed — habitual, dark") {
    WeedContent(model: WeedSpecimen.habitual, backLabel: "Journal insights",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.dark)
}

#Preview("Weed — nothing logged, light") {
    WeedContent(model: WeedSpecimen.blank, backLabel: "Journal insights",
                onAddSession: {}, onEditSession: { _ in })
        .preferredColorScheme(.light)
}

/// Deterministic preview models (no store / repo needed). Every case goes through
/// `WeedScreenModel.compute`, so the previews exercise the real assembly rather than a hand-posed
/// screen — a pattern that stopped matching its inputs would show up here.
private enum WeedSpecimen {
    static let today = "2026-07-15"

    /// `count` day keys ending today, oldest first — the covered-days list (a strap that was worn).
    static func covered(_ count: Int) -> [String] {
        Array((0..<count).compactMap { ScoreEngine.shiftDay(today, by: -$0) }.reversed())
    }

    static func day(_ back: Int) -> String { ScoreEngine.shiftDay(today, by: -back) ?? today }

    static func session(_ day: String, hour: Int, minute: Int = 0,
                        method: WeedMethod? = nil, potency: WeedPotency? = nil,
                        exact: Bool = true) -> WeedSession {
        let midnight = DayKey.date(from: day) ?? Date()
        return WeedSession(id: "\(day)-\(hour)-\(minute)", day: day,
                           ts: Int(midnight.timeIntervalSince1970) + hour * 3_600 + minute * 60,
                           tsExact: exact, method: method, potency: potency,
                           createdAt: Int(midnight.timeIntervalSince1970))
    }

    static func byDay(_ sessions: [WeedSession]) -> [String: [WeedSession]] {
        var out: [String: [WeedSession]] = [:]
        for s in sessions { out[s.day, default: []].append(s) }
        return out
    }

    /// A real, family-corrected Rest effect — the shipped shape of a weed row.
    static let restEffect = JournalInsightRow(
        key: "weed", label: "Weed", loggedDays: 11,
        effect: RankedEffect(
            behavior: "Weed", outcome: "Rest", lag: 1,
            effect: BehaviorEffect(behavior: "Weed", outcome: "Rest",
                                   meanWith: 78, meanWithout: 83, delta: -5,
                                   pctChange: -6.0, nWith: 11, nWithout: 82,
                                   cohensD: -0.58, pApprox: 0.008, significant: true),
            confidence: .building),
        qValue: 0.04, significant: true)

    /// Eleven logged days — a dense block, a deliberate break, then a lighter tail.
    static let effect: WeedScreenModel = {
        let days = [2, 3, 4, 5, 12, 13, 14, 15, 23, 24, 25]
        let sessions = days.flatMap { back -> [WeedSession] in
            var out = [session(day(back), hour: 21, minute: 30,
                               method: back.isMultiple(of: 2) ? .vape : .flower,
                               potency: back.isMultiple(of: 3) ? .heavy : .usual)]
            if back.isMultiple(of: 4) { out.append(session(day(back), hour: 23, minute: 5)) }
            return out
        }
        return WeedScreenModel.compute(weedDays: Set(days.map(day)), sessionsByDay: byDay(sessions),
                                       coveredDays: covered(90), latestSession: sessions.first,
                                       everLogged: true, insight: restEffect, insightLoaded: true,
                                       today: today)
    }()

    /// Three sessions — under the n≥5-per-group gate, so no number is shown at all. The one
    /// back-dated tap carries no clock.
    static let belowGate: WeedScreenModel = {
        let sessions = [session(day(1), hour: 22, minute: 10, method: .edible, potency: .light),
                        session(day(6), hour: 21, exact: false),
                        session(day(9), hour: 20, minute: 45, method: .flower)]
        return WeedScreenModel.compute(weedDays: Set(sessions.map(\.day)),
                                       sessionsByDay: byDay(sessions), coveredDays: covered(30),
                                       latestSession: sessions.first, everLogged: true,
                                       insight: nil, insightLoaded: true, today: today)
    }()

    /// Logged on 18 of 21 covered days — over the habitual share, so the baseline note applies.
    static let habitual: WeedScreenModel = {
        let days = Array(0..<21).filter { $0 != 7 && $0 != 8 && $0 != 16 }
        let sessions = days.map { session(day($0), hour: 22, potency: .usual) }
        return WeedScreenModel.compute(weedDays: Set(days.map(day)), sessionsByDay: byDay(sessions),
                                       coveredDays: covered(21), latestSession: sessions.first,
                                       everLogged: true, insight: nil, insightLoaded: true,
                                       today: today)
    }()

    /// Nothing ever logged — hero, pattern and history all omitted.
    static let blank = WeedScreenModel.compute(weedDays: [], sessionsByDay: [:],
                                               coveredDays: covered(60), latestSession: nil,
                                               everLogged: false, insight: nil, insightLoaded: true,
                                               today: today)
}
