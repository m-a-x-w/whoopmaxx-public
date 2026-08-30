import SwiftUI
import StrapStore

/// The Log tab (037 IA-1, mockup `L_Log`): everything the user WRITES, in one place, for the
/// anchor day. Top to bottom: `TabHeader` ("Log" + the date) → quick add (Meal · Caffeine · Alcohol ·
/// Water · Weed circles) → "Your day" (the day strip with a dot per logged intake) → "Today" (the
/// day's intake entries, each opening its response, with "History" → `IntakeScreen`) → "Tags for
/// today" (`JournalTagsSection`) → "Habits · x of y" (`HabitsTodaySection`, "Manage" →
/// `HabitsDetailScreen`) → nav rows to `InsightsScreen` and `WeedScreen`.
///
/// It is the tab root inside `AppShell`'s per-tab `NavigationStack` (system bar hidden there), so
/// every push is a `.navigationDestination` on this view — one `LogRoute` drives all of them.
///
/// Observes `Repository` only for the anchor day. Each section observes its own store (intake,
/// journal + weed, habits), so a tag toggle re-renders the chips, not the whole tab.
struct LogScreen: View {
    @EnvironmentObject private var repo: Repository

    /// The one pushed destination, if any.
    @State private var route: LogRoute?
    /// The intake editor, opened by a quick-add circle with its kind preset.
    @State private var intakeDraft: IntakeEditorRef?
    /// The weed-session editor for a fresh session (the Weed circle — `WeedScreen`'s "+", one tap
    /// closer).
    @State private var showsWeedSheet = false
    #if DEBUG
    /// One-shot latch for the launch-argument seeds below: popping back to this root re-runs its
    /// `.task`, and without the latch the seed pushed the same screen again.
    @State private var seeded = false
    #endif

    init() {}

    var body: some View {
        // The anchor day, once: every section reads and writes against it. Log has no day stepper of
        // its own — only the tag chips step back, inside `JournalTagsSection`, to back-date a tag.
        let today = Repository.anchorKey(days: repo.days)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabHeader("Log", subtitle: Self.dateLine(today))

                LogQuickAdd(onIntake: { kind in
                                intakeDraft = IntakeEditorRef(day: today, event: nil, kind: kind)
                            },
                            onWeed: { showsWeedSheet = true })
                    .padding(.top, WM.Space.gutter)

                RuleSection("Your day") {
                    LogDayStrip(dayKey: today)
                }

                LogIntakeToday(dayKey: today,
                               onOpen: { route = .response(IntakeEventRef(event: $0)) },
                               onHistory: { route = .intakeHistory })

                JournalTagsSection(anchorKey: today)

                HabitsTodaySection(selectedKey: today, onOpenDetail: { route = .habits })

                LogMoreRows(today: today,
                            onInsights: { route = .insights },
                            onWeed: { route = .weed })
                    .padding(.top, WM.Space.sectionTight)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.top, WM.Space.s)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        .tint(WM.Ground.ink)
        .navigationDestination(item: $route) { destination($0) }
        .sheet(item: $intakeDraft) { ref in
            IntakeEventSheet(editing: ref.event, day: ref.day, kind: ref.kind)
        }
        .sheet(isPresented: $showsWeedSheet) {
            WeedSessionSheet(editing: nil, day: today)
        }
        #if DEBUG
        // `--weed` / `--journal` / `--intake` / `--intake-response` (routed to this tab by
        // `DebugFlags.tab`): push AFTER first render — a seed set on the cold-init path is dropped by
        // NavigationStack. Each pushes the SAME destination, with the same back label, as the
        // production row it stands in for, so a screenshot photographs the route a user walks. Weed
        // is checked first because `DebugFlags.journal` ORs `--weed` in, and on Log Weed is its own
        // row rather than a push beyond Insights. `--intake-response` goes on from `IntakeScreen`,
        // which consumes it itself.
        .task {
            guard !seeded else { return }
            seeded = true
            if DebugFlags.weed {
                route = .weed
            } else if DebugFlags.journal {
                route = .insights
            } else if DebugFlags.intake || DebugFlags.intakeResponse {
                route = .intakeHistory
            }
        }
        #endif
    }

    @ViewBuilder
    private func destination(_ route: LogRoute) -> some View {
        switch route {
        case .intakeHistory:
            IntakeScreen(backLabel: "Log")
        case .response(let ref):
            IntakeResponseScreen(pushed: ref.event, backLabel: "Log")
        case .habits:
            HabitsDetailScreen(backLabel: "Log")
        case .insights:
            InsightsScreen(backLabel: "Log")
        case .weed:
            WeedScreen(backLabel: "Log")
        }
    }

    /// The header's date line for the anchor day ("Tuesday 29 September" in an en-GB locale; the
    /// order follows the user's locale). Falls back to the raw key rather than a fabricated date.
    static func dateLine(_ key: String) -> String {
        guard let date = DayKey.date(from: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Where the Log tab pushes. One optional route drives the tab's single `navigationDestination`.
enum LogRoute: Hashable {
    case intakeHistory
    case response(IntakeEventRef)
    case habits
    case insights
    case weed
}

// MARK: - Section chrome

/// A Log section whose label row carries a VIEW: `RuleSection`'s shape (sentence-case label, 12pt to
/// the content, 40pt above) plus a trailing view slot — the tag day stepper. A text action ("History",
/// "Manage") goes through `RuleSection(action:actionHint:)` instead.
struct LogSection<Trailing: View, Content: View>: View {
    let title: String
    private let trailing: Trailing
    private let content: Content

    init(_ title: String,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: WM.Space.s) {
                Text(title)
                    .wmOverline()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: WM.Space.s)
                trailing
            }
            .padding(.bottom, WM.Space.m)
            content
        }
        .padding(.top, WM.Space.section)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Quick add

/// Five 52pt circles — Meal · Caffeine · Alcohol · Water open the intake editor preset to that kind,
/// Weed opens a fresh session. A 1.5pt `track` ring, an inkSecondary glyph, the name under it.
/// Chrome, not data: no color.
struct LogQuickAdd: View {
    let onIntake: (IntakeKind) -> Void
    let onWeed: () -> Void

    init(onIntake: @escaping (IntakeKind) -> Void, onWeed: @escaping () -> Void) {
        self.onIntake = onIntake
        self.onWeed = onWeed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(IntakeKind.allCases) { kind in
                circle(symbol: kind.symbol, title: kind.label,
                       a11y: "Log \(kind.label.lowercased())") { onIntake(kind) }
                Spacer(minLength: 0)
            }
            circle(symbol: "leaf", title: "Weed", a11y: "Log a weed session", action: onWeed)
        }
    }

    private func circle(symbol: String, title: String, a11y: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: WM.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(WM.Ground.inkSecondary)
                    .frame(width: 52, height: 52)
                    .overlay(Circle().strokeBorder(WM.Ground.track, lineWidth: 1.5))
                Text(title)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }
}

// MARK: - Your day

/// The anchor day as the `TimelineStrip` rail: last night's sleep and the day's workouts inside it,
/// a dot above it per logged intake (charge; water in rest), and the "now" dot.
///
/// The spans come from caches already in memory (`Repository.sleeps`, `WorkoutRepository.workouts`) —
/// no store read — and are re-derived once per data change (`refreshSeq` on either repository), not
/// on every body pass. The HR-intensity shading Today once drew is not here: it needs an HR bucket
/// read, and the Log tab adds none.
struct LogDayStrip: View {
    let dayKey: String

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var workoutRepo: WorkoutRepository
    @EnvironmentObject private var intake: IntakeStore

    @State private var spans = LogDaySpans()

    init(dayKey: String) {
        self.dayKey = dayKey
    }

    var body: some View {
        if let bounds = LogDaySpans.bounds(dayKey) {
            let entries = LogDaySpans.entries(intake.events(on: dayKey))
            TimelineStrip(dayStart: bounds.start, dayEnd: bounds.end,
                          sleep: spans.sleep, workouts: spans.workouts,
                          entries: entries, now: Date())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LogDaySpans.summary(spans, entryCount: entries.count))
                .task(id: LogDaySpans.Stamp(day: dayKey, rest: repo.refreshSeq,
                                            workouts: workoutRepo.refreshSeq)) {
                    spans = LogDaySpans.make(sleeps: repo.sleeps, workouts: workoutRepo.workouts,
                                             dayKey: dayKey, bounds: bounds)
                }
        }
    }
}

/// The strip's layers for one day, derived from in-memory caches. Pure.
struct LogDaySpans {
    var sleep: [(start: Date, end: Date)] = []
    var workouts: [(start: Date, end: Date)] = []

    /// What the spans are derived from: the day, and each repository's publish counter (both bump
    /// exactly when their caches change).
    struct Stamp: Equatable {
        let day: String
        let rest: Int
        let workouts: Int
    }

    /// Local midnight → the next local midnight for a day key (DST-correct via `Calendar`).
    static func bounds(_ key: String) -> (start: Date, end: Date)? {
        guard let start = DayKey.date(from: key),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start: start, end: end)
    }

    static func make(sleeps: [CachedSleepSession], workouts: [WorkoutRow], dayKey: String,
                     bounds: (start: Date, end: Date)) -> LogDaySpans {
        LogDaySpans(sleep: TodayModel.sleepSpans(sleeps, dayKey: dayKey,
                                                 dayStart: bounds.start, dayEnd: bounds.end),
                    workouts: TodayTimeline.workoutSpans(workouts, dayStart: bounds.start,
                                                         dayEnd: bounds.end))
    }

    /// One dot per intake entry with a RECORDED clock — charge, water in rest. A back-dated entry's
    /// placeholder clock is not a time anything happened, so it gets no position on the day.
    static func entries(_ events: [IntakeEvent]) -> [(date: Date, color: Color)] {
        events.compactMap { event -> (date: Date, color: Color)? in
            guard event.tsExact else { return nil }
            let color = event.kind == .water ? WM.Domain.rest.color : WM.Domain.charge.color
            return (date: Date(timeIntervalSince1970: TimeInterval(event.ts)), color: color)
        }
    }

    /// The strip is decorative to VoiceOver; this is its spoken stand-in.
    static func summary(_ spans: LogDaySpans, entryCount: Int) -> String {
        var parts = [entryCount == 0
                     ? "no timed entries logged"
                     : "\(entryCount) timed entr\(entryCount == 1 ? "y" : "ies") logged"]
        if let wake = spans.sleep.map({ $0.end }).max() {
            parts.append("slept until \(WMFormat.timeOfDay(wake))")
        }
        if !spans.workouts.isEmpty {
            parts.append("\(spans.workouts.count) workout\(spans.workouts.count == 1 ? "" : "s")")
        }
        return "Your day: " + parts.joined(separator: ", ")
    }
}

// MARK: - Today (intake)

/// The anchor day's intake entries, env-driven (`IntakeStore`'s event cache).
private struct LogIntakeToday: View {
    let dayKey: String
    let onOpen: (IntakeEvent) -> Void
    let onHistory: () -> Void

    @EnvironmentObject private var intake: IntakeStore

    var body: some View {
        LogIntakeList(events: intake.events(on: dayKey), onOpen: onOpen, onHistory: onHistory)
    }
}

/// "Today": the day's entries as `IntakeEventRow`s (time · kind · amount → the response), with
/// "History" → the Intake screen in the label row. Mounted on EVERY day, empty or not — History is
/// the only route into the full log, so it must not hide behind the first entry. Pure, previewable.
struct LogIntakeList: View {
    /// The day's events, oldest first (the store's own order).
    let events: [IntakeEvent]
    let onOpen: (IntakeEvent) -> Void
    let onHistory: () -> Void

    init(events: [IntakeEvent], onOpen: @escaping (IntakeEvent) -> Void,
         onHistory: @escaping () -> Void) {
        self.events = events
        self.onOpen = onOpen
        self.onHistory = onHistory
    }

    var body: some View {
        RuleSection("Today",
                    action: (title: "History", handler: onHistory),
                    actionHint: "Opens everything you've logged") {
            if events.isEmpty {
                // "Nothing logged", never "nothing consumed" — the second is a claim the app cannot make.
                Text("Nothing logged today. Tap a circle above to log a meal, a coffee, a drink or water.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                        if idx > 0 { WMRule() }
                        IntakeEventRow(event: event) { onOpen(event) }
                    }
                }
            }
        }
    }
}

// MARK: - Insights / Weed rows

/// The two pushed pages that hang off Log: Insights, and Weed with its days-since reading.
///
/// Watches `JournalStore` as well as `WeedStore` because `WeedStore.weedDays` is read straight off the
/// journal cache — a weed chip toggled above changes the reading through a journal publish, not a
/// weed one (`WeedScreen` holds both for the same reason).
///
/// The Weed subtitle is derived once per publish of either store (or change of day), never on a body
/// pass: `weedDays` rebuilds a set off the whole tag cache and the pattern walks it, and this row
/// re-renders on every journal publish — each tag toggle on the chips above.
private struct LogMoreRows: View {
    let today: String
    let onInsights: () -> Void
    let onWeed: () -> Void

    @EnvironmentObject private var weed: WeedStore
    @EnvironmentObject private var journal: JournalStore

    /// The Weed row's subtitle, derived by the `.onChange` below.
    @State private var weedSubtitle: String?
    /// Bumped on every publish of either store. `objectWillChange` fires BEFORE the store writes, but
    /// the re-render it schedules runs after the write lands, so the derivation reads the new values.
    @State private var journalRevision = 0
    @State private var weedRevision = 0

    /// What the subtitle depends on: both stores' contents (behind their revisions) and the day.
    private struct Stamp: Equatable {
        let journal: Int
        let weed: Int
        let today: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMNavRow(title: "Insights",
                     subtitle: "What moves your recovery",
                     hint: "Opens what your logged tags line up with",
                     action: onInsights)
            WMRule()
            WMNavRow(title: "Weed",
                     subtitle: weedSubtitle,
                     hint: "Opens weed sessions, pattern and effects",
                     action: onWeed)
        }
        .onReceive(journal.objectWillChange) { _ in journalRevision &+= 1 }
        .onReceive(weed.objectWillChange) { _ in weedRevision &+= 1 }
        // `initial` derives it on first appearance too — Data builds its rows the same way
        // (`onChange(of: refreshSeq, initial: true)`).
        .onChange(of: Stamp(journal: journalRevision, weed: weedRevision, today: today), initial: true) {
            weedSubtitle = WeedScreenModel.logRowSubtitle(weedDays: weed.weedDays,
                                                          latestSession: weed.latestSession,
                                                          today: today)
        }
    }
}

// MARK: - Previews

#Preview("Log — light") {
    LogSpecimen().preferredColorScheme(.light)
}

#Preview("Log — dark") {
    LogSpecimen().preferredColorScheme(.dark)
}

#Preview("Log — nothing logged") {
    LogSpecimen(events: []).preferredColorScheme(.light)
}

/// The store-free parts of the tab over specimen intake. The tags and habits sections read their
/// stores, so they are left out here (neither has a specimen of its own).
private struct LogSpecimen: View {
    var events: [IntakeEvent] = IntakeSpecimen.day

    var body: some View {
        let today = TodayModel.key(from: Date())
        let bounds = LogDaySpans.bounds(today)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TabHeader("Log", subtitle: LogScreen.dateLine(today))
                LogQuickAdd(onIntake: { _ in }, onWeed: {})
                    .padding(.top, WM.Space.gutter)
                if let bounds {
                    RuleSection("Your day") {
                        TimelineStrip(dayStart: bounds.start, dayEnd: bounds.end,
                                      sleep: [(bounds.start.addingTimeInterval(-50 * 60),
                                               bounds.start.addingTimeInterval(6.8 * 3600))],
                                      workouts: [(bounds.start.addingTimeInterval(7.5 * 3600),
                                                  bounds.start.addingTimeInterval(8.25 * 3600))],
                                      entries: LogDaySpans.entries(events), now: Date())
                    }
                }
                LogIntakeList(events: events, onOpen: { _ in }, onHistory: {})
                VStack(alignment: .leading, spacing: 0) {
                    WMNavRow(title: "Insights", subtitle: "What moves your recovery") {}
                    WMRule()
                    WMNavRow(title: "Weed", subtitle: "3 days since last session · pattern & effects") {}
                }
                .padding(.top, WM.Space.sectionTight)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
        }
        .background(WM.Ground.ground)
    }
}
