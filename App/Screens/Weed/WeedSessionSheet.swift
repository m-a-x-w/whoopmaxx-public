import SwiftUI

/// Add or edit one weed session — a `groundRaised` sheet in the Line language (037 "Sheets"):
/// Cancel / "Log session" / Save, the "When" row, the method as toggle chips, potency as a rounded
/// segmented row, and a delete row on an edit. It shares its chrome with the other editors
/// (`WMSheetChrome.swift`).
///
/// Presented with `.sheet(item:)` on an Identifiable ref wrapping an OPTIONAL session, because
/// nil-means-create cannot drive `item:` (the `MonitorDayRef` idiom; the ref itself lives with the
/// screen that presents it, like every other `*Ref` in the app) — or, for Log's Weed circle, which
/// only ever creates, with `.sheet(isPresented:)`.
///
/// Thin environment wrapper over the pure `WeedSessionEditor` (the `HealthMonitorScreen` split): the
/// store writes live here, so the layout — and both themes' previews — need nothing but values.
struct WeedSessionSheet: View {
    /// The session being edited, or nil to log a new one.
    let editing: WeedSession?
    /// The day key a CREATE lands on — the Log tab's (or Weed screen's) anchor day, which is already
    /// anchor-derived. Never re-derived from a clock (`WeedSession.day`). An edit carries its own.
    let day: String

    @EnvironmentObject private var weed: WeedStore
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WeedSessionEditor(
            editing: editing,
            day: day,
            // The create default is the CHIP's own one-tap stamp (`WeedStore.stamp`), so a session
            // logged through the editor on a past day carries the same declared placeholder clock a
            // tap would have — one rule for what a session's timestamp means, not two.
            anchorKey: Repository.anchorKey(days: repo.days),
            onSave: { session in
                Task {
                    // `add` and `update` are the same upsert underneath; calling the one that names
                    // what happened keeps the create and edit paths readable at the seam.
                    if editing == nil { await weed.add(session) } else { await weed.update(session) }
                    dismiss()
                }
            },
            onDelete: { session in
                // The session's OWN day, not `day`: `delete` projects that day's boolean, and an edit
                // that moved the picker's date has already left the day it opened on behind.
                Task { await weed.delete(id: session.id, day: session.day); dismiss() }
            },
            onCancel: { dismiss() })
    }
}

/// The editor itself — pure: every dependency is a value or a closure, so the previews drive it with
/// nothing but a `WeedSession`.
struct WeedSessionEditor: View {
    /// The session being edited, or nil for a fresh log.
    let editing: WeedSession?
    /// The day key a create lands on (ignored on an edit, which carries its own).
    let day: String
    let onSave: (WeedSession) -> Void
    let onDelete: (WeedSession) -> Void
    let onCancel: () -> Void

    /// The picked instant. Its DATE component can move the session to another day (`savedDay`); its
    /// CLOCK component is what `exact` tracks.
    @State private var when: Date
    /// Mirrors `WeedSession.tsExact` — false means the clock on screen is a placeholder we invented,
    /// not a time anyone recorded.
    @State private var exact: Bool
    @State private var method: WeedMethod?
    @State private var potency: WeedPotency?
    @State private var saving = false

    /// The instant the sheet OPENED on — the origin `savedDay` shifts from, so the day key moves by
    /// whole days the user picked and never by a re-derivation of the timestamp.
    /// `@State`, NOT a `let` — see the twin in `IntakeEventEditor`. A `let` is re-derived on every
    /// struct re-init (this sheet observes `WeedStore` and `Repository`, so any publish triggers one),
    /// which drifts a create's `openedAt` forward while `@State when` stays put; across local midnight
    /// `shiftDay` then computes `delta == -1` and saves onto the previous day. Found by the 024 audit.
    @State private var openedAt: Date
    /// Minted once and KEPT: `draft` is a computed property re-evaluated on every render, so a
    /// `UUID()` re-minted by a re-init would hand a different id to each evaluation.
    @State private var newId = UUID().uuidString
    /// Likewise fixed at open — a create's `createdAt` is when the sheet was opened, not whenever
    /// SwiftUI last rebuilt the body.
    @State private var createdAt: Int

    /// - Parameter anchorKey: the resolved today key. Init-only, so it is not stored: it decides
    ///   nothing but whether a CREATE's default clock is an observation (`now`) or a declared
    ///   placeholder, and an edit never consults it at all.
    init(editing: WeedSession?, day: String, anchorKey: String,
         onSave: @escaping (WeedSession) -> Void,
         onDelete: @escaping (WeedSession) -> Void,
         onCancel: @escaping () -> Void) {
        self.editing = editing
        self.day = day
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel

        let start: (ts: Int, exact: Bool)
        if let editing {
            start = (ts: editing.ts, exact: editing.tsExact)
        } else {
            start = WeedStore.stamp(day: day, anchorKey: anchorKey, now: Date())
        }
        let opened = Date(timeIntervalSince1970: TimeInterval(start.ts))
        _openedAt = State(initialValue: opened)
        _createdAt = State(initialValue: editing?.createdAt ?? Int(Date().timeIntervalSince1970))
        _when = State(initialValue: opened)
        _exact = State(initialValue: start.exact)
        _method = State(initialValue: editing?.method)
        _potency = State(initialValue: editing?.potency)
    }

    /// The latest instant the picker offers and `draft` accepts — now, or the record's OWN stored
    /// instant when that is later.
    ///
    /// A stored ts CAN be in the future: fly west and the session you logged this evening lands after
    /// the local clock. Pinning the bound at `Date()` broke that record twice over — the picker
    /// display-clamped to now while `when` still held the stored value, so the sheet showed a time it
    /// was not editing, and `draft` went nil, so Save was dead with only Delete and Cancel left. An
    /// already-stored instant is a fact; the sheet's job is to show it and let it be re-saved. A
    /// CREATE has no stored instant (`openedAt` is `stamp`'s, never ahead of now), so it still cannot
    /// invent a session in the future.
    private var latestAllowed: Date {
        editing == nil ? Date() : max(Date(), openedAt)
    }

    /// The session the current inputs would save, or nil when they can't be — which drives Save's
    /// enabled state, so an impossible entry can never be written. A session past `latestAllowed` is
    /// the only impossible one: method and potency are both legitimately absent (nil = not recorded).
    private var draft: WeedSession? {
        guard when <= latestAllowed else { return nil }
        return WeedSession(id: editing?.id ?? newId,
                           day: savedDay,
                           ts: Int(when.timeIntervalSince1970),
                           tsExact: exact,
                           method: method,
                           potency: potency,
                           // Provenance survives an edit: a demo session stays in the demo lane, which
                           // is how `deleteWeedSessions(deviceId:source:)` can still clear the seed.
                           source: editing?.source ?? WeedSession.manualSource,
                           createdAt: createdAt)
    }

    /// The day key the save lands on.
    ///
    /// NEVER re-derived from the timestamp: `DayKey.local(ts)` and the chip's `anchorKey` disagree
    /// across the 00:00-04:00 window, which is exactly where a late session's clock lands, so a
    /// re-derive would let a session and its own boolean land on different days. Instead the ORIGINAL
    /// key is shifted by however many calendar days the picker moved — an explicit date change is
    /// honoured (`WeedStore.upsert` projects both the day left and the day joined), a minute nudge on
    /// a 01:00 session is not.
    private var savedDay: String {
        DayKey.shifted(editing?.day ?? day, from: openedAt, to: when)
    }

    var body: some View {
        VStack(spacing: 0) {
            WMSheetHeader(title: editing == nil ? "Log session" : "Edit session",
                          canSave: draft != nil && !saving,
                          onCancel: onCancel,
                          onSave: save)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    whenField
                        .padding(.top, WM.Space.m)
                    methodField
                        .padding(.top, WM.Space.l)
                    potencyField
                        .padding(.top, WM.Space.l)
                    deleteRow
                        .padding(.top, WM.Space.sectionTight)
                }
                .padding(.horizontal, WM.Space.gutter)
                .padding(.bottom, WM.Space.sectionLoose)
            }
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(WM.Radius.sheet)
    }

    // MARK: - Fields

    private var whenField: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only moving the CLOCK records a time (`WMWhenField` owns the rule). A date-only move —
            // back-dating a session whose placeholder clock we invented — leaves it declared-inexact,
            // because we still don't know when it happened; rendering a fabricated 21:00 as an
            // observation is the one thing `tsExact` exists to prevent.
            WMWhenField(when: $when, exact: $exact, latestAllowed: latestAllowed)
            if !exact {
                caption("Time was not recorded.")
            }
            // The picker's range makes this all but unreachable — but a dead Save with no reason on
            // screen is exactly the trap this sheet just came out of, so the one state that disables
            // it always says so rather than relying on the control to hold the line.
            if draft == nil {
                caption("That time is in the future. Save is off until it passes.")
            }
            WMRule()
        }
    }

    private var methodField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("Method")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            ChipFlow(spacing: WM.Space.s) {
                ForEach(WeedMethod.allCases) { m in
                    methodChip(m)
                }
            }
        }
    }

    /// One method chip — `WMChip`, text only (a method has no glyph). A second tap on the selected chip
    /// clears it back to NOT RECORDED. nil is a real value here — the one-tap paths write it — so it
    /// needs a way back that isn't "pick something you didn't do".
    private func methodChip(_ m: WeedMethod) -> some View {
        let selected = method == m
        return WMChip(m.label, isOn: selected) {
            method = selected ? nil : m
        }
        .accessibilityLabel(m.label)
    }

    private var potencyField: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMRule()
            // "None", not "Not set": four options plus a label is the widest this row gets in the
            // app, and at 0.85 the longer word truncated to "Not…" on a 393pt phone — an ellipsis
            // reading as an overflow affordance, the exact thing the potency dots were dropped for.
            InkSegmentRow(label: "Potency",
                          options: [("", "None"), ("1", "Light"), ("2", "Usual"), ("3", "Heavy")],
                          selection: potencyBinding)
                // Let the names shrink a touch on a narrow phone rather than wrap the row into two
                // lines.
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            caption("A relative scale you set, not a measured amount.")
        }
    }

    /// One explanatory line under a field — caption, inkTertiary, wrapping.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, WM.Space.m)
    }

    /// Bridges the `WeedPotency?` ordinal to `InkSegmentRow`'s String selection. "" is NOT RECORDED —
    /// a real value, not a default — and `WeedPotency(rawValue: 0)` is nil, so the mapping needs no
    /// special case.
    private var potencyBinding: Binding<String> {
        Binding(get: { potency.map { String($0.rawValue) } ?? "" },
                set: { potency = WeedPotency(rawValue: Int($0) ?? 0) })
    }

    @ViewBuilder
    private var deleteRow: some View {
        if let editing {
            WMSheetDeleteRow(title: "Delete session", enabled: !saving) {
                guard !saving else { return }
                saving = true
                onDelete(editing)
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard let draft, !saving else { return }
        saving = true
        // The host dismisses once the write lands (the `ManualWorkoutSheet.save` shape): the sheet
        // stays up with Save disabled rather than closing over an in-flight store call.
        onSave(draft)
    }

    // MARK: - Day / clock arithmetic
    //
    // Both rules moved to `DayKey.shifted` / `DayKey.sameClock` when 024's editor started asking the
    // same question. Same arithmetic, same caveats (the junk-key and midnight-DST fallbacks), one
    // copy — see the MARK there.
}

// MARK: - Previews

#Preview("Weed session — new, back-dated") {
    WeedSessionSpecimen(session: nil).preferredColorScheme(.light)
}

#Preview("Weed session — new, back-dated — dark") {
    WeedSessionSpecimen(session: nil).preferredColorScheme(.dark)
}

#Preview("Weed session — edit") {
    WeedSessionSpecimen(session: WeedSessionSpecimen.logged).preferredColorScheme(.light)
}

#Preview("Weed session — edit — dark") {
    WeedSessionSpecimen(session: WeedSessionSpecimen.logged).preferredColorScheme(.dark)
}

#Preview("Weed session — edit, future ts") {
    WeedSessionSpecimen(session: WeedSessionSpecimen.flownWest).preferredColorScheme(.light)
}

#Preview("Weed session — edit, future ts — dark") {
    WeedSessionSpecimen(session: WeedSessionSpecimen.flownWest).preferredColorScheme(.dark)
}

/// Storeless preview driver: the editor takes only values and closures, so nothing here touches a
/// `Repository`, a `WeedStore` or the database. Keys are derived from the clock rather than hardcoded
/// so the picker's range is always satisfiable.
private struct WeedSessionSpecimen: View {
    let session: WeedSession?

    private static let today = DayKey.local(Date())
    private static let yesterday = DayKey.local(Date().addingTimeInterval(-86_400))

    /// An edited session: a real clock, both optional fields recorded.
    static let logged = WeedSession(
        id: "specimen", day: yesterday,
        ts: Int(Date().addingTimeInterval(-14 * 3_600).timeIntervalSince1970),
        tsExact: true, method: .vape, potency: .usual)

    /// The flown-west case: a stored instant AHEAD of the local clock. The picker must show that
    /// instant, not now, and Save must be live.
    static let flownWest = WeedSession(
        id: "specimen-future", day: today,
        ts: Int(Date().addingTimeInterval(11 * 3_600).timeIntervalSince1970),
        tsExact: true, method: .edible, potency: .light)

    var body: some View {
        // A create on YESTERDAY (the anchor is today), so the default clock is the declared
        // placeholder and the "Time was not recorded." caption is on screen.
        WeedSessionEditor(editing: session, day: Self.yesterday, anchorKey: Self.today,
                          onSave: { _ in }, onDelete: { _ in }, onCancel: {})
    }
}
