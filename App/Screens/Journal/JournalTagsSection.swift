import SwiftUI

/// "Tags for today" on the Log tab (037; the day chips 029 moved off Today, now out of the
/// Journal screen that 037 split): the eight `JournalTag` chips for one day, as `WMChip`s in a
/// wrapping flow, with the Weed chip's clear-confirmation.
///
/// Env-driven (`JournalStore` + `WeedStore`) and self-contained — it renders its own section label, so
/// the host places it like any other section.
///
/// A DAY STEPPER stays with the chips, as a quiet ‹ › pair in the label row. The chips write to a
/// specific day and the common case is logging last night's drinking this morning — a surface with
/// no day control would silently cost back-dating, and with it the confounder inputs the health
/// monitor and the ranked-effect family read. At the anchor day the label reads "Tags for today", as
/// the mockup draws it; stepped back it names the day being tagged.
struct JournalTagsSection: View {
    /// The anchor day the section opens on (Log passes `Repository.anchorKey`).
    let anchorKey: String

    @EnvironmentObject private var journal: JournalStore
    /// 029: the weed chip routes through `WeedStore`, not a bare boolean — the tap writes a SESSION as
    /// well as the tag. Leaving it behind on a plain chip would quietly turn weed into an ordinary
    /// boolean.
    @EnvironmentObject private var weed: WeedStore

    /// Days back from the anchor day (0 = today).
    @State private var dayOffset = 0
    /// Set when clearing the weed chip would discard hand-entered detail.
    @State private var weedConfirm: JournalWeedClearRef?

    init(anchorKey: String) {
        self.anchorKey = anchorKey
    }

    var body: some View {
        let key = selectedKey
        let onTags = journal.tagsByDay[key] ?? []
        LogSection(dayOffset == 0 ? "Tags for today" : "Tags for \(Self.dayLabel(key))") {
            // Two abutting 44×44 boxes, so neither hit region reaches into the other. The negative
            // padding hands the label row back its text height (the boxes overhang it, as
            // `RuleSection`'s text action does) and lets the › glyph sit near the trailing edge, where
            // the other sections' text actions end, instead of centered 22pt inboard of it.
            HStack(spacing: 0) {
                stepper(systemName: "chevron.left", label: "Previous day",
                        enabled: canStepBack) { dayOffset += 1 }
                stepper(systemName: "chevron.right", label: "Next day",
                        enabled: dayOffset > 0) { dayOffset -= 1 }
            }
            .padding(.vertical, -14)
            .padding(.trailing, -WM.Space.l)
        } content: {
            ChipFlow(spacing: WM.Space.s) {
                ForEach(JournalTag.allCases) { tag in
                    chip(tag, on: onTags.contains(tag.rawValue), day: key)
                }
            }
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
    }

    /// The day being tagged: the anchor, stepped back `dayOffset` days.
    private var selectedKey: String {
        guard dayOffset > 0, let key = ScoreEngine.shiftDay(anchorKey, by: -dayOffset) else { return anchorKey }
        return key
    }

    private var weedConfirmPresented: Binding<Bool> {
        Binding(get: { weedConfirm != nil }, set: { if !$0 { weedConfirm = nil } })
    }

    /// Whether the back chevron is live. The floor is the JOURNAL READ WINDOW, not the first
    /// `DailyMetric` row: this is a back-dating WRITE surface, and a behavior day legitimately
    /// precedes the oldest score the strap ever produced — gating on `repo.days` would refuse to log a
    /// night the user genuinely lived through.
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

    /// A quiet day-stepper glyph in the section-label row (`WMType.icon(.inline)`), inkSecondary when
    /// live and dimmed when not, centered in its own 44×44 hit box.
    private func stepper(systemName: String, label: String, enabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(WMType.icon(.inline))
                .foregroundStyle(enabled ? WM.Ground.inkSecondary : WM.Ground.inkTertiary.opacity(0.5))
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
        WMChip(tag.label, isOn: on) {
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
        }
        .accessibilityLabel("\(tag.label), \(on ? "logged" : "not logged")")
    }
}

/// Identifiable ref for the clear-weed confirmation (009, moved with the chips by 029 and 037): the
/// day being cleared and how many sessions go with it, since the prompt names the count.
private struct JournalWeedClearRef: Identifiable {
    let day: String
    let sessions: Int
    var id: String { day }
    var prompt: String {
        "Remove weed for this day? \(sessions) logged session\(sessions == 1 ? "" : "s") will be deleted."
    }
}
