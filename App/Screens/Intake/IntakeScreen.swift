import SwiftUI

/// The Intake history (024), pushed from the Log tab's "Today" section ("History"): everything logged
/// in the trailing window, newest day first, each entry opening its response.
///
/// DELIBERATELY NO STATISTICS, the `WeedPattern` stance. Nothing here ranks, correlates or scores —
/// it is a log you can read back, and the only derived thing in the whole wave is the per-event
/// response tape, which draws measured signal and states its own n. There is no "your usual dinner
/// time", no streak, no adherence: none of those are things the app measured.
///
/// Takes `backLabel` (the `WorkoutDetailScreen` / `WeedScreen` precedent) so the back row names the
/// screen it was actually pushed from. Takes NO day: the history is window-global, and per-day
/// logging lives on the Log tab.
struct IntakeScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intake: IntakeStore
    @Environment(\.dismiss) private var dismiss

    let backLabel: String

    /// The event whose response is open.
    @State private var openEvent: IntakeEventRef?
    /// The event the editor sheet is open on, or a nil-event ref for a fresh log. This screen
    /// presents its OWN editor (the `WeedScreen` / `HabitsDetailScreen` pattern) rather than
    /// borrowing Log's, so the header's "+" works from here too.
    @State private var editingEvent: IntakeEditorRef?
    #if DEBUG
    /// One-shot latch for the `--intake-response` seed: popping back from the response re-runs this
    /// screen's `.task`, and without it the seed pushed the same entry again.
    @State private var seeded = false
    #endif

    var body: some View {
        let today = Repository.anchorKey(days: repo.days)
        IntakeContent(days: IntakeScreen.grouped(eventsByDay: intake.eventsByDay),
                      backLabel: backLabel,
                      onBack: { dismiss() },
                      onAdd: { editingEvent = IntakeEditorRef(day: today, event: nil) },
                      onOpen: { openEvent = IntakeEventRef(event: $0) })
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openEvent) { ref in
                IntakeResponseScreen(pushed: ref.event, backLabel: "Intake")
            }
            .sheet(item: $editingEvent) { ref in
                IntakeEventSheet(editing: ref.event, day: ref.day)
            }
            #if DEBUG
            // `--intake-response`: push the newest entry that has a tape to draw, AFTER first render
            // (a cold-init path seed is dropped by NavigationStack) — the `--weed` idiom. Newest
            // FIRST so it picks the demo's pinned dinner rather than an aged-out entry.
            .task {
                guard DebugFlags.intakeResponse, !seeded, openEvent == nil else { return }
                seeded = true
                // The event cache loads from the launch `.task`, which can still be in flight when
                // this screen first appears — a single read here found it empty and pushed nothing.
                // Poll briefly rather than racing it.
                for _ in 0..<20 {
                    let all = Array(intake.eventsByDay.values.joined()).filter(\.supportsResponseTape)
                    // Prefer the seed's PINNED specimen — the one entry the demo plants 1 Hz streams
                    // under. Simply taking the newest landed on an ordinary drink whose window has
                    // almost nothing in it, and screenshotted a near-empty tape as if that were the
                    // feature. Falls back to the newest on a real user's store, which has no seed.
                    let candidate = all.first { $0.id.hasSuffix(DemoSeed.intakeTapeSuffix) }
                        ?? all.max { $0.ts < $1.ts }
                    if let candidate {
                        openEvent = IntakeEventRef(event: candidate)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            #endif
    }

    /// Days carrying at least one event, NEWEST first, each with its events oldest-first within the
    /// day (the store's own order). A day with no events is simply absent — there is no empty row
    /// for it, because "nothing logged" and "nothing consumed" are not the same statement and the
    /// screen must not make the second one.
    static func grouped(eventsByDay: [String: [IntakeEvent]]) -> [(day: String, events: [IntakeEvent])] {
        eventsByDay
            .filter { !$0.value.isEmpty }
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, events: $0.value) }
    }
}

/// Identifiable ref for the response push (`navigationDestination(item:)` needs one).
struct IntakeEventRef: Identifiable, Hashable {
    let event: IntakeEvent
    var id: String { event.id }

    static func == (a: IntakeEventRef, b: IntakeEventRef) -> Bool { a.event.id == b.event.id }
    func hash(into hasher: inout Hasher) { hasher.combine(event.id) }
}

/// Identifiable ref for the editor sheet — wraps an OPTIONAL event, because nil-means-create cannot
/// drive `sheet(item:)` on its own. `kind` is the create's preset (Log's quick-add circles); an edit
/// carries its own kind and leaves it nil.
struct IntakeEditorRef: Identifiable {
    let day: String
    let event: IntakeEvent?
    var kind: IntakeKind? = nil
    var id: String { event?.id ?? "new-\(day)-\(kind?.rawValue ?? "any")" }
}

/// The screen body over plain data, so both themes' previews drive it without any store.
struct IntakeContent: View {
    let days: [(day: String, events: [IntakeEvent])]
    let backLabel: String
    var onBack: () -> Void = {}
    var onAdd: () -> Void = {}
    var onOpen: (IntakeEvent) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if days.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                        RuleSection(Self.heading(group.day),
                                    topGap: index == 0 ? WM.Space.sectionTight : WM.Space.section) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(group.events.enumerated()), id: \.element.id) { idx, e in
                                    if idx > 0 { WMRule() }
                                    IntakeEventRow(event: e) { onOpen(e) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        .tint(WM.Ground.ink)
    }

    /// Day-key → section heading, the `RestScreen.swift:242` shape (abbreviated weekday, day, month).
    /// Falls back to the raw key rather than a fabricated date when the key will not parse.
    static func heading(_ dayKey: String) -> String {
        guard let date = DayKey.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Back link, then the screen title in the tab-header shape with the "+" in its trailing slot.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMBackLink(title: backLabel) { onBack() }
            TabHeader("Intake", subtitle: "What you logged, and what followed") {
                WMIconButton(systemName: "plus", label: "Log intake") { onAdd() }
            }
        }
        .padding(.top, WM.Space.s)
    }

    /// Says only what is true: nothing has been logged. It does NOT say "start tracking to see
    /// insights" — there are no insights in this wave, and promising them would be the claim.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Nothing logged yet.")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Text("Log a meal, a coffee or a drink and this shows what your heart rate and skin "
                 + "temperature did over the hours after it.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.sectionTight)
    }
}

/// One intake entry as a list row — clock · kind · amount, and a disclosure when there is a response
/// to open. Shared by this screen and the Log tab's "Today" section, so the two lists of the same
/// events cannot drift into two shapes.
///
/// The whole row opens the response. A water row and a clock-less row still open it (the response
/// screen states why it draws nothing, and carries "Edit entry"), but carry no chevron, because the
/// tape it would promise does not exist for them.
struct IntakeEventRow: View {
    let event: IntakeEvent
    let onOpen: () -> Void

    init(event: IntakeEvent, onOpen: @escaping () -> Void) {
        self.event = event
        self.onOpen = onOpen
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: WM.Space.m) {
                IntakeClockCell(event: event)
                HStack(spacing: WM.Space.xs) {
                    Text(event.label)
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // Amount in the row's secondary-detail role. Not-recorded draws NOTHING at all,
                    // never a placeholder that implies a value the user never gave.
                    if let amount = IntakeAmountCopy.text(event) {
                        Text("· " + amount)
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: WM.Space.s)
                // A row with no response to open still RESERVES the disclosure's width, hidden. Drawn
                // conditionally, the chevron's absence let a water row's amount run further right than
                // every other row's, so the trailing column was ragged on exactly the rows that carry
                // no chevron. Hidden rather than dimmed: the promise must not be made, but the column
                // it sits in is shared. `.hidden()` also drops it from the accessibility tree.
                if event.supportsResponseTape {
                    WMDisclosure()
                } else {
                    WMDisclosure().hidden()
                }
            }
            .frame(minHeight: WM.Space.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    /// What the row speaks. Not-recorded detail is simply ABSENT from the label rather than spoken
    /// as a dash — a fabricated "no amount" is a claim we can't make.
    private var a11yLabel: String {
        var parts = [event.tsExact ? WMFormat.timeOfDay(event.ts) : "Time not recorded"]
        parts.append(event.label)
        if let amount = IntakeAmountCopy.text(event) { parts.append(amount) }
        return parts.joined(separator: ", ")
    }
}

/// The clock cell every intake row opens with (`IntakeEventRow`, on this screen and on Log): the
/// time in the label role, inkTertiary, so the kind beside it carries the row.
///
/// It exists to hold a COLUMN. The clock was previously a bare `Text` in an `HStack`, so its width
/// tracked the string: "7:52 AM" is a digit narrower than "11:06 AM", which pushed the kind label
/// left and right from row to row and left the list visibly ragged down its second column. The
/// numerals were already tabular; the cell around them was not.
///
/// The width is reserved by an INVISIBLE sample string rather than a literal point value, so it
/// tracks Dynamic Type and the locale together — a 24-hour locale reserves a narrower column than a
/// 12-hour one instead of both getting one designer's guess. The visible clock is leading-aligned
/// inside it (the mockup's clock column), and the fixed width is what puts the kind labels on a
/// common left edge.
///
/// A clock-less (back-dated) event is deliberately EXEMPT: "Time not recorded" is a sentence, not a
/// clock, and squeezing it into the clock column would truncate a declaration the user made. That
/// row is a different shape and reads as one.
struct IntakeClockCell: View {
    let event: IntakeEvent

    /// The widest clock the current locale can print: 22:58 — two-digit hour, and PM where the
    /// locale uses one. Every digit is the same width under `monospacedDigit`, so this one sample
    /// bounds every real time of day.
    private static var widestClock: String {
        let ref = Calendar.current.date(bySettingHour: 22, minute: 58, second: 0, of: Date()) ?? Date()
        return WMFormat.timeOfDay(ref)
    }

    var body: some View {
        if event.tsExact {
            Text(Self.widestClock)
                .font(WMType.label)
                .monospacedDigit()
                .hidden()
                .overlay(alignment: .leading) {
                    Text(WMFormat.timeOfDay(event.ts))
                        .font(WMType.label)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
        } else {
            Text("Time not recorded")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkTertiary)
                .lineLimit(1)
        }
    }
}

/// The one place an amount becomes words, shared by the event row (Log and this screen) and the
/// response header — surfaces that must never describe the same event differently.
enum IntakeAmountCopy {
    /// The amount, or nil when nothing was recorded. Counts carry their noun and pluralise it, so a
    /// bare "2" can never be read as whichever unit the reader assumed; a meal carries its ordinal's
    /// word. These are the only two shapes, which is what the closed `IntakeKind` set buys.
    static func text(_ event: IntakeEvent) -> String? {
        var parts: [String] = []
        if let variant = event.variant { parts.append(variant.label) }
        // Milligrams where they were recorded; cups only for caffeine rows written before 027, which
        // are never converted. Both are true statements about what the user entered.
        if let mg = event.amountMg {
            parts.append("\(mg) mg")
        } else if let size = event.sizeOrdinal {
            parts.append(size.label)
        } else if let count = event.countValue, let kind = event.kind,
                  let noun = count == 1 ? kind.countNoun : kind.countNounPlural {
            parts.append("\(count) \(noun)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Previews

#Preview("Intake screen — light") {
    IntakeContent(days: IntakeScreen.grouped(eventsByDay: IntakeScreenSpecimen.week), backLabel: "Log")
        .preferredColorScheme(.light)
}

#Preview("Intake screen — dark") {
    IntakeContent(days: IntakeScreen.grouped(eventsByDay: IntakeScreenSpecimen.week), backLabel: "Log")
        .preferredColorScheme(.dark)
}

#Preview("Intake screen — nothing logged") {
    IntakeContent(days: [], backLabel: "Log").preferredColorScheme(.light)
}

private enum IntakeScreenSpecimen {
    /// Two days, so the day grouping and its newest-first order are both visible.
    static let week: [String: [IntakeEvent]] = {
        let today = TodayModel.key(from: Date())
        let yesterday = DayKey.local(Date().addingTimeInterval(-86_400))
        let base = Calendar.current.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Int {
            Int(base.timeIntervalSince1970) + dayOffset * 86_400 + hour * 3600 + minute * 60
        }
        return [
            today: [
                IntakeEvent(id: "s1", day: today, ts: at(0, 8, 10), kind: .caffeine, countValue: 1),
                IntakeEvent(id: "s2", day: today, ts: at(0, 13, 5), kind: .meal, sizeOrdinal: .usual),
                IntakeEvent(id: "s3", day: today, ts: at(0, 15, 0), kind: .water, countValue: 2),
            ],
            yesterday: [
                IntakeEvent(id: "s4", day: yesterday, ts: at(-1, 19, 40), kind: .meal, sizeOrdinal: .heavy),
                IntakeEvent(id: "s5", day: yesterday, ts: at(-1, 21, 15), kind: .alcohol, countValue: 2),
                IntakeEvent(id: "s6", day: yesterday, ts: at(-1, 12, 0), tsExact: false, kind: .meal),
            ],
        ]
    }()
}

/// Storeless specimen events — one day covering every row state: a caffeine drink with its form and
/// milligrams, a meal ordinal, a water count, a heavier dinner, a pluralised drink count, and a
/// back-dated log whose clock was never recorded. Drives the Log, response and editor previews.
enum IntakeSpecimen {
    static let day: [IntakeEvent] = {
        let day = TodayModel.key(from: Date())
        let base = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int) -> Int {
            Int(base.timeIntervalSince1970) + hour * 3600 + minute * 60
        }
        return [
            IntakeEvent(id: "specimen-1", day: day, ts: at(7, 10), kind: .caffeine,
                        variant: .drink, amountMg: 95),
            IntakeEvent(id: "specimen-2", day: day, ts: at(8, 40), kind: .meal, sizeOrdinal: .usual),
            IntakeEvent(id: "specimen-3", day: day, ts: at(13, 30), kind: .water, countValue: 2),
            IntakeEvent(id: "specimen-4", day: day, ts: at(19, 40), kind: .meal, sizeOrdinal: .heavy),
            IntakeEvent(id: "specimen-5", day: day, ts: at(21, 15), kind: .alcohol, countValue: 2),
            IntakeEvent(id: "specimen-6", day: day, ts: at(IntakeStore.placeholderHour, 0),
                        tsExact: false, kind: .caffeine),
        ]
    }()
}
