import SwiftUI

/// The Today "Intake" section (024): what was logged on the SELECTED day, a row to log more, and the
/// chevron pushing the Intake detail. Env-driven (the `HabitsTodaySection` idiom) since the rows
/// come from `IntakeStore`'s event cache.
///
/// This mounts on EVERY day rather than only on days that already carry something — the decision
/// that kept it on Today when the Weed section, which HAD gated that way, left in 029. Weed could
/// gate on the day's boolean because its chip creates the first session; intake has no chip, so a
/// section that appears only once an event exists offers no way to log the first one. The kept corpus is the argument: 3 journal entries in 17 days, 0 habit logs, 0 lab markers.
/// A logging surface behind a gate is a logging surface nobody reaches.
struct IntakeTodaySection: View {
    let selectedKey: String
    /// Opens the editor sheet: an existing event to edit, nil to log a new one on `selectedKey`.
    var onEditEvent: ((IntakeEvent?) -> Void)? = nil
    /// Pushes the Intake detail (owned by Today's NavigationStack).
    var onOpenDetail: (() -> Void)? = nil

    @EnvironmentObject private var intake: IntakeStore

    var body: some View {
        IntakeTodayContent(events: intake.events(on: selectedKey),
                           onEditEvent: onEditEvent,
                           onOpenDetail: onOpenDetail)
    }
}

/// The section body over plain data, so both previews drive it without an `IntakeStore` (the
/// TodayScreen / TodayContent split).
struct IntakeTodayContent: View {
    /// The selected day's events, oldest first.
    let events: [IntakeEvent]
    var onEditEvent: ((IntakeEvent?) -> Void)? = nil
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { idx, event in
                if idx > 0 { WMRule() }
                eventRow(event)
            }
            if !events.isEmpty { WMRule() }
            logRow
            WMRule()
            detailLink
        }
    }

    // MARK: - Rows

    /// One event: clock · kind · amount, the whole row a ≥44pt button into the editor.
    private func eventRow(_ event: IntakeEvent) -> some View {
        Button { onEditEvent?(event) } label: {
            HStack(spacing: WM.Space.m) {
                // An inexact clock is a DECLARED placeholder (a back-dated log), so it says so in
                // tertiary ink rather than rendering a fabricated noon as an observation. It is also
                // why such an event draws no response tape — see `IntakeEvent.supportsResponseTape`.
                // The cell reserves a fixed clock column so the labels beside it align; see
                // `IntakeClockCell`.
                IntakeClockCell(event: event)
                Text(event.label)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                Spacer(minLength: WM.Space.s)
                // Amount in the row's secondary-detail role. Not-recorded draws NOTHING at all,
                // never a placeholder that implies a value the user never gave.
                if let amount = amountText(event) {
                    Text(amount)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
            // ≥44pt hit region (the day steppers' rule): the row's marks keep their size, only the
            // invisible tap box grows, so a low tap can't land on the next event.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel(event))
    }

    /// Plain ink text row (not a CTA) opening the editor on a fresh event.
    private var logRow: some View {
        Button { onEditEvent?(nil) } label: {
            Text(events.isEmpty ? "Log intake" : "Log more")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Chevron link row pushing the Intake detail — `WMNavRow`, the house primitive for exactly this
    /// shape, rather than the hand-rolled copy this used to be.
    ///
    /// The copy was not merely duplicated, it had DRIFTED: it padded itself `WM.Space.xs` (4pt)
    /// vertically where `WMNavRow` pads `WM.Space.m` (12pt), so the title sat almost against the rule
    /// above it while every other disclosure row in the app breathed. Its own doc comment claimed the
    /// "Journal insights row idiom" — the tell, per `WMNavRow`'s note, that the primitive was there
    /// and simply not reached for.
    private var detailLink: some View {
        WMNavRow(title: "Intake",
                 subtitle: "What you logged, and what followed",
                 hint: "Opens your logged intake and what followed it") {
            onOpenDetail?()
        }
    }

    // MARK: - Amount copy

    /// Shared with the Intake screen and the response header via `IntakeAmountCopy` — three surfaces
    /// showing the same event must never word its amount differently.
    private func amountText(_ event: IntakeEvent) -> String? { IntakeAmountCopy.text(event) }

    /// What the row speaks. Not-recorded detail is simply ABSENT from the label rather than spoken
    /// as a dash — a fabricated "no amount" is a claim we can't make.
    private func a11yLabel(_ event: IntakeEvent) -> String {
        var parts = [event.tsExact ? WMFormat.timeOfDay(event.ts) : "Time not recorded"]
        parts.append(event.label)
        if let amount = amountText(event) { parts.append(amount) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("Intake section — light") {
    IntakeTodaySpecimen(events: IntakeSpecimen.day).preferredColorScheme(.light)
}

#Preview("Intake section — dark") {
    IntakeTodaySpecimen(events: IntakeSpecimen.day).preferredColorScheme(.dark)
}

#Preview("Intake section — nothing logged") {
    IntakeTodaySpecimen(events: []).preferredColorScheme(.light)
}

/// The section as Today mounts it — inside its own `RuleSection`, on the app canvas.
private struct IntakeTodaySpecimen: View {
    let events: [IntakeEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RuleSection("Intake", topGap: 0) {
                    IntakeTodayContent(events: events)
                }
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}

/// Storeless specimen events — one day covering every row state: a bare one-tap log with no amount,
/// a singular count (so the "1 drink" / "2 drinks" pluralisation is visible in the preview), a meal
/// ordinal, a water event, and a back-dated log whose clock was never recorded.
enum IntakeSpecimen {
    static let day: [IntakeEvent] = {
        let day = TodayModel.key(from: Date())
        let base = Calendar.current.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int) -> Int {
            Int(base.timeIntervalSince1970) + hour * 3600 + minute * 60
        }
        return [
            IntakeEvent(id: "specimen-1", day: day, ts: at(8, 10), kind: .caffeine, countValue: 1),
            IntakeEvent(id: "specimen-2", day: day, ts: at(13, 5), kind: .meal, sizeOrdinal: .usual),
            IntakeEvent(id: "specimen-3", day: day, ts: at(15, 30), kind: .water, countValue: 2),
            IntakeEvent(id: "specimen-4", day: day, ts: at(19, 40), kind: .meal, sizeOrdinal: .heavy),
            IntakeEvent(id: "specimen-5", day: day, ts: at(21, 15), kind: .alcohol, countValue: 2),
            IntakeEvent(id: "specimen-6", day: day, ts: at(IntakeStore.placeholderHour, 0),
                        tsExact: false, kind: .caffeine),
        ]
    }()
}
