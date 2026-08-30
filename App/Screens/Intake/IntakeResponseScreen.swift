import SwiftUI

/// What the body did after one logged event (024) — the response tape, its reference line, and the
/// two places this wave refuses to draw one.
///
/// THE REFUSALS ARE THE POINT, not an edge case. Two of the three states this screen can be in are
/// "there is nothing honest to draw here, and here is why":
///
///  1. **Water.** The strap records no signal that answers hydration. `HydrationGoal` was already
///     refused as this app's first purely prescriptive number, and
///     drawing HR over the hours after a glass of water would be worse: the noise would be read as
///     an effect. So the screen says what it cannot see. This is the shape W1.4 already shipped for
///     SpO2 — name the limit rather than produce a number to fill the space.
///  2. **Past the raw horizon.** `SampleRetention` sweeps `hrSample` and its siblings at
///     `retentionDays`, so an event from three months ago has no signal left behind it. An empty
///     tape would read as "nothing happened" — a claim nothing measured (014 decision 5). The line
///     is phrased off the constant via `RawHorizon`, never a literal 28.
///
/// Critically, the aged-out line is only printed when the tape ALSO came back empty. `RawHorizon`'s
/// own header says it is "deliberately NOT sufficient on its own" — the sweep's scored-day gate
/// holds an unscored day's samples all the way to `hardCapDays`, so a 40-day-old event can still be
/// sitting on its raw. Claiming otherwise over a window that did in fact read would be a second
/// false statement in the place built to prevent the first.
struct IntakeResponseScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intake: IntakeStore
    @Environment(\.dismiss) private var dismiss

    /// The entry this screen was PUSHED with. Only its `id` is trusted past the first render — the
    /// live row is re-resolved from the store below, because this screen presents an editor that can
    /// change or delete it.
    let pushed: IntakeEvent
    let backLabel: String

    /// The loaded lanes, or nil until the first read lands. Empty-but-non-nil is a real answer: the
    /// window was read and held nothing.
    @State private var tape: IntakeTape?
    @State private var loaded = false
    @State private var editing = false
    /// That night's already-scored figures, when an alcohol window ran into sleep.
    @State private var night: IntakeNightSummary?
    @State private var typical: IntakeTypicalBand?

    /// The row as it stands NOW, or nil once it has been deleted.
    ///
    /// The pushed value is a snapshot. Held as a `let` and rendered directly, an edit through this
    /// screen's own sheet left the header printing the old clock and the tape drawing the old window,
    /// and — worse — "Delete entry" dismissed only the sheet, leaving a screen showing an entry that
    /// no longer existed whose Edit → Save re-inserted the deleted row via the `upsert` path.
    private var live: IntakeEvent? {
        intake.eventsByDay.values.joined().first { $0.id == pushed.id }
    }

    var body: some View {
        // Fall back to the pushed snapshot for the instant between a delete landing and the dismiss
        // below firing, so the view never has nothing to render.
        let event = live ?? pushed
        // `night` and `typical` MUST be passed explicitly. Both carry defaults on
        // `IntakeResponseContent` so the previews can omit them — which means forgetting them here
        // compiles clean and silently renders neither. That is exactly what happened: wave B shipped
        // a band and a night hand-off that were structurally unreachable, and the build was green
        // the whole time. If a third optional is ever added, add it here in the same commit.
        return IntakeResponseContent(event: event, tape: tape, night: night, typical: typical,
                                     loaded: loaded, backLabel: backLabel,
                                     onBack: { dismiss() },
                                     onEdit: { editing = true })
            .navigationBarBackButtonHidden(true)
            .sheet(isPresented: $editing) {
                IntakeEventSheet(editing: event, day: event.day)
            }
            // Deleted out from under us — leave rather than show a phantom that can be re-saved.
            .onChange(of: live == nil) { _, gone in if gone { dismiss() } }
            // Keyed on everything that moves the WINDOW, not just the id: the id is stable across an
            // edit, so an id-keyed task never re-fired and the tape stayed on the old hours.
            .task(id: tapeKey(event)) {
                tape = nil
                typical = nil
                loaded = false
                guard event.supportsResponseTape else { loaded = true; return }
                tape = await IntakeTapeLoader.load(event: event, repo: repo)
                // Only when the window actually handed off to sleep — a meal at lunchtime has no
                // night to speak of, and a capped alcohol window never reached one.
                night = (tape?.endedAtSleepOnset ?? false)
                    ? IntakeNightSummary.make(afterSleepOnset: tape!.windowEnd, repo: repo)
                    : nil
                if let tape {
                    typical = await IntakeTypicalBandLoader.load(event: event, tape: tape, repo: repo)
                }
                loaded = true
            }
    }

    /// Identity of the WINDOW an event implies. Changing the clock moves it, changing the kind
    /// changes its length (meal 3 h vs caffeine 6 h), and losing the exact clock removes it entirely.
    private func tapeKey(_ event: IntakeEvent) -> String {
        "\(event.id)|\(event.ts)|\(event.rawKind)|\(event.tsExact)"
    }
}

/// The screen body over plain data — every state drives from values, so both themes' previews cover
/// the tape, the water refusal, the aged-out refusal and the still-loading pass without a store.
struct IntakeResponseContent: View {
    let event: IntakeEvent
    let tape: IntakeTape?
    var night: IntakeNightSummary? = nil
    var typical: IntakeTypicalBand? = nil
    let loaded: Bool
    let backLabel: String
    var onBack: () -> Void = {}
    var onEdit: () -> Void = {}

    /// Injected so the previews and tests can place an event either side of the horizon without
    /// moving the device clock.
    var now: Date = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                body(for: state)
            }
            .padding(.horizontal, WM.Space.gutter)
            .padding(.bottom, WM.Space.sectionLoose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
        .tint(WM.Ground.ink)
    }

    // MARK: - State

    /// What this screen is showing. Resolved in one place so the copy and the tape can never
    /// disagree about which case the event is in.
    enum State: Equatable {
        /// Water — nothing the strap records answers it.
        case unmeasurable
        /// A kind this build does not know, written by a later one. We know something was logged and
        /// not what, so there is no window to draw and — crucially — nothing was ever READ.
        case unknownKind
        /// The clock was never recorded, so there is no origin to draw a window around.
        case noOrigin
        /// Still reading.
        case loading
        /// The window read and held signal.
        case drawn
        /// The window read and held nothing, and the event is past the raw-sample horizon.
        case agedOut
        /// The window read and held nothing, and the event is INSIDE the horizon — the strap was
        /// off, or out of range, or not yet synced. Distinct from `agedOut` on purpose: the reasons
        /// are different and only one of them is permanent.
        case noCoverage
    }

    var state: State {
        // `kind == nil` FIRST, and as its own case. It used to fall through here — `nil == false` is
        // false — down to the empty-tape guard, and printed "the strap banked no samples over these
        // hours", which is a statement about a read that never happened. The downgrade path is
        // deliberately supported (`IntakeEvent.rawKind`), so this was reachable, and a false claim on
        // the one screen built to prevent them.
        guard let kind = event.kind else { return .unknownKind }
        if !kind.hasResponseTape { return .unmeasurable }
        if !event.tsExact { return .noOrigin }
        if !loaded { return .loading }
        guard let tape, !tape.isEmpty else {
            return RawHorizon.hasAgedOut(dayKey: event.day, now: now) ? .agedOut : .noCoverage
        }
        _ = tape
        return .drawn
    }

    @ViewBuilder
    private func body(for state: State) -> some View {
        switch state {
        case .unmeasurable:  refusal(title: "No response to show",
                                     detail: "The strap measures heart rate, skin temperature and "
                                           + "movement. None of them answer hydration, so there is "
                                           + "nothing here that would be about the water. It is "
                                           + "still logged, and it still shows on other entries' "
                                           + "tapes so you can see what else was going on.")
        case .unknownKind:   refusal(title: "Logged by a newer version",
                                     detail: "This entry records something this version does not "
                                           + "know how to read, so it cannot say what response to "
                                           + "draw. The entry itself is kept exactly as written.")
        case .noOrigin:      refusal(title: "No time recorded",
                                     detail: "This was logged onto the day without a clock, so "
                                           + "there is no point to draw the hours around. Edit it "
                                           + "and set a time to see the response.")
        case .loading:       loadingRow
        case .agedOut:       refusal(title: "Past the raw horizon",
                                     detail: "The second-by-second signal behind this window is "
                                           + "kept for \(SampleRetention.retentionDays) days and "
                                           + "has since been swept. The entry itself is kept.")
        case .noCoverage:    refusal(title: "Nothing recorded in this window",
                                     detail: "The strap banked no samples over these hours — it was "
                                           + "off the wrist, out of range, or has not synced yet.")
        case .drawn:         drawnBody
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            WMBackLink(title: backLabel) { onBack() }
            VStack(alignment: .leading, spacing: WM.Space.xs) {
                Text(event.label)
                    .font(WMType.title)
                    .foregroundStyle(WM.Ground.ink)
                HStack(spacing: WM.Space.s) {
                    Text(event.tsExact ? WMFormat.timeOfDay(event.ts) : "Time not recorded")
                        .font(WMType.body)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkSecondary)
                    if let amount = IntakeAmountCopy.text(event) {
                        Text("·").foregroundStyle(WM.Ground.inkTertiary)
                        Text(amount)
                            .font(WMType.body)
                            .foregroundStyle(WM.Ground.inkSecondary)
                    }
                }
                Text(IntakeResponseContent.dayLine(event))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            editRow
        }
        .padding(.top, WM.Space.m)
    }

    private var editRow: some View {
        Button { onEdit() } label: {
            Text("Edit entry")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The event's own day, spelled out — a post-midnight drink belongs to the previous logical day
    /// and the header has to say which day it landed on, or the tape looks misfiled.
    static func dayLine(_ event: IntakeEvent) -> String {
        IntakeContent.heading(event.day)
    }

    // MARK: - Bodies

    private var loadingRow: some View {
        Text("Reading the window…")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .padding(.top, WM.Space.section)
    }

    /// One shape for every "no tape, and here is why". Deliberately plain type on the ground, not a
    /// card or an alert — the design language has no containers, and a refusal is information, not
    /// an error.
    private func refusal(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text(title)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Text(detail)
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, WM.Space.section)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var drawnBody: some View {
        if let tape {
            IntakeTapeView(tape: tape, event: event, night: night, typical: typical)
        }
    }
}

// MARK: - Previews

#Preview("Response — water refusal") {
    IntakeResponseContent(event: IntakeSpecimen.day.first { $0.kind == .water }!,
                          tape: nil, loaded: true, backLabel: "Intake")
        .preferredColorScheme(.light)
}

#Preview("Response — no clock recorded") {
    IntakeResponseContent(event: IntakeSpecimen.day.first { !$0.tsExact }!,
                          tape: nil, loaded: true, backLabel: "Intake")
        .preferredColorScheme(.light)
}

#Preview("Response — past the raw horizon") {
    // Dated well past the horizon, with an empty tape — BOTH conditions, which is what the aged-out
    // line requires (see the type doc).
    IntakeResponseContent(event: IntakeEvent(id: "old", day: "2020-01-05",
                                             ts: 1_578_240_000, kind: .meal),
                          tape: IntakeTape.empty, loaded: true, backLabel: "Intake")
        .preferredColorScheme(.light)
}

#Preview("Response — inside the horizon, no coverage") {
    IntakeResponseContent(event: IntakeSpecimen.day.first { $0.kind == .alcohol }!,
                          tape: IntakeTape.empty, loaded: true, backLabel: "Intake")
        .preferredColorScheme(.dark)
}
