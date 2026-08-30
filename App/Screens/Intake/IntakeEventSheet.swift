import SwiftUI

/// Add or edit one intake event — a `groundRaised` sheet: what, when, how much, and a delete row on
/// an edit.
///
/// Presented with `.sheet(item:)` on an Identifiable ref wrapping an OPTIONAL event, because
/// nil-means-create cannot drive `item:` (the `WeedEditRef` / `MonitorDayRef` idiom).
///
/// Modeled on `WeedSessionSheet`, itself modeled on `ManualWorkoutSheet` — hand-rolled top bar over a
/// `WMRule()`, overline + control fields, no system `Form`.
///
/// Thin environment wrapper over the pure `IntakeEventEditor` (the `HealthMonitorScreen` split): the
/// store writes live here, so the layout — and both themes' previews — need nothing but values.
struct IntakeEventSheet: View {
    /// The event being edited, or nil to log a new one.
    let editing: IntakeEvent?
    /// The day key a CREATE lands on — the Today stepper's `selectedKey`, which is already
    /// anchor-derived. Never re-derived from a clock. An edit carries its own.
    let day: String

    @EnvironmentObject private var intake: IntakeStore
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IntakeEventEditor(
            editing: editing,
            day: day,
            // The create default is `IntakeStore.stamp`, so an event logged on a PAST day carries the
            // declared placeholder clock — and therefore draws no response tape, because a window
            // around a fabricated noon is arithmetic over a guess.
            anchorKey: Repository.anchorKey(days: repo.days),
            onSave: { event in
                Task {
                    // `add` and `update` are the same upsert underneath; calling the one that names
                    // what happened keeps the create and edit paths readable at the seam.
                    if editing == nil { await intake.add(event) } else { await intake.update(event) }
                    dismiss()
                }
            },
            onDelete: { event in
                // The event's OWN day, not `day` — an edit that moved the picker's date has already
                // left the day it opened on behind.
                Task { await intake.delete(id: event.id, day: event.day); dismiss() }
            },
            onCancel: { dismiss() })
    }
}

/// The editor itself — pure: every dependency is a value or a closure, so the previews drive it with
/// nothing but an `IntakeEvent`.
struct IntakeEventEditor: View {
    let editing: IntakeEvent?
    /// The day key a create lands on (ignored on an edit, which carries its own).
    let day: String
    let onSave: (IntakeEvent) -> Void
    let onDelete: (IntakeEvent) -> Void
    let onCancel: () -> Void

    /// The picked instant. Its DATE component can move the event to another day (`savedDay`); its
    /// CLOCK component is what `exact` tracks.
    @State private var when: Date
    /// Mirrors `IntakeEvent.tsExact` — false means the clock on screen is a placeholder we invented.
    @State private var exact: Bool
    /// Required, unlike weed's optional method: an event with no kind has no window, no projection
    /// rule and nothing to render, so there is no honest nil to fall back to. A create opens on
    /// `.meal` because it is the most-logged of the four, not because it is a default we believe.
    @State private var kind: IntakeKind
    /// 0 means NOT RECORDED — a real value here, which is why the stepper's floor is 0 and not 1.
    @State private var count: Int
    @State private var size: MealSize?
    @State private var variant: IntakeVariant?
    /// 0 means NOT RECORDED, same convention as `count`.
    @State private var mg: Int
    @State private var saving = false

    /// The instant the sheet OPENED on — the origin `savedDay` shifts from, so the day key moves by
    /// whole days the user picked and never by a re-derivation of the timestamp.
    ///
    /// `@State`, NOT a `let`. A `let` is re-derived every time SwiftUI re-creates the struct, and this
    /// sheet observes both `IntakeStore` and `Repository`, so any publish from either re-runs `init`.
    /// For a create on the anchor day `IntakeStore.stamp` returns `now`, so `openedAt` drifted forward
    /// while `@State when` stayed frozen — and a sheet left open across local midnight then had
    /// `DayKey.shifted` compute `delta == -1` and save the entry onto the PREVIOUS day.
    @State private var openedAt: Date
    /// Likewise `@State`: `draft` is a computed property re-evaluated on every render, so a `UUID()`
    /// re-minted by a re-init would hand a different id to successive evaluations.
    @State private var newId = UUID().uuidString
    @State private var createdAt: Int

    /// The most a single stepper entry can claim. Not a health judgement — it is the point past
    /// which tapping a stepper is the wrong control, and a bound has to exist so the field cannot
    /// hold an implausible number that would later look like a measurement.
    private static let maxCount = 20
    /// Ceiling for the milligram stepper. Not a health judgement — it is the point past which
    /// tapping a stepper is the wrong control, and a bound keeps the field from holding a figure
    /// that would later read as a measurement.
    private static let maxMilligrams = 600

    init(editing: IntakeEvent?, day: String, anchorKey: String,
         onSave: @escaping (IntakeEvent) -> Void,
         onDelete: @escaping (IntakeEvent) -> Void,
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
            start = IntakeStore.stamp(day: day, anchorKey: anchorKey, now: Date())
        }
        let opened = Date(timeIntervalSince1970: TimeInterval(start.ts))
        _openedAt = State(initialValue: opened)
        _createdAt = State(initialValue: editing?.createdAt ?? Int(Date().timeIntervalSince1970))
        _when = State(initialValue: opened)
        _exact = State(initialValue: start.exact)
        // An event whose stored kind this build does not know keeps its row in the list (see
        // `IntakeEvent.rawKind`) but cannot be edited into one of ours silently — it opens on
        // `.meal` only if it was never a known kind, which a downgrade makes vanishingly rare.
        _kind = State(initialValue: editing?.kind ?? .meal)
        _count = State(initialValue: editing?.countValue ?? 0)
        _size = State(initialValue: editing?.sizeOrdinal)
        _variant = State(initialValue: editing?.variant)
        _mg = State(initialValue: editing?.amountMg ?? 0)
    }

    /// The latest instant the picker offers and `draft` accepts — now, or the record's OWN stored
    /// instant when that is later. A stored ts CAN be in the future: fly west and the drink you
    /// logged this evening lands after the local clock. An already-stored instant is a fact; the
    /// sheet's job is to show it and let it be re-saved (the `WeedSessionEditor` finding).
    private var latestAllowed: Date {
        editing == nil ? Date() : max(Date(), openedAt)
    }

    /// The event the current inputs would save, or nil when they can't be — which drives Save's
    /// enabled state. An instant past `latestAllowed` is the only impossible one: every amount is
    /// legitimately absent (nil = not recorded).
    private var draft: IntakeEvent? {
        guard when <= latestAllowed else { return nil }
        return IntakeEvent(id: editing?.id ?? newId,
                           day: savedDay,
                           ts: Int(when.timeIntervalSince1970),
                           tsExact: exact,
                           kind: kind,
                           // Each kind carries exactly ONE amount shape, and the other is written
                           // nil — not merely hidden. Otherwise switching meal → alcohol mid-edit
                           // would save a portion ordinal against a drink, where it means nothing.
                           // Exactly ONE amount shape per kind; the others are written nil, not
                           // merely hidden, so switching kind mid-edit cannot save a milligram
                           // figure against a meal or a portion against a drink.
                           countValue: (kind.usesSizeOrdinal || kind.usesMilligrams)
                               ? nil : (count > 0 ? count : nil),
                           sizeOrdinal: kind.usesSizeOrdinal ? size : nil,
                           variant: kind.variants.isEmpty ? nil : variant,
                           amountMg: kind.usesMilligrams ? (mg > 0 ? mg : nil) : nil,
                           // Provenance survives an edit: a demo event stays in the demo lane, which
                           // is how `deleteIngestionEvents(deviceId:source:)` can still clear the seed.
                           source: editing?.source ?? IntakeEvent.manualSource,
                           createdAt: createdAt)
    }

    /// The day key the save lands on. NEVER re-derived from the timestamp — `DayKey.local(ts)` and
    /// `anchorKey` disagree across the 00:00-04:00 window, which is exactly where a late drink's
    /// clock lands. The ORIGINAL key is shifted by however many calendar days the picker moved.
    private var savedDay: String {
        DayKey.shifted(editing?.day ?? day, from: openedAt, to: when)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: WM.Space.section) {
                    kindField
                    variantField
                    whenField
                    amountField
                    deleteRow
                }
                .padding(WM.Space.gutter)
            }
        }
        .background(WM.Ground.groundRaised.ignoresSafeArea())
        .tint(WM.Ground.ink)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Text(editing == nil ? "New entry" : "Edit entry")
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
            Spacer()
            Button("Save") { save() }
                .font(WMType.label)
                .foregroundStyle(draft == nil || saving ? WM.Ground.inkTertiary : WM.Ground.ink)
                .disabled(draft == nil || saving)
        }
        .padding(.horizontal, WM.Space.gutter)
        .padding(.vertical, WM.Space.l)
        .overlay(alignment: .bottom) {
            WMRule()
        }
    }

    // MARK: - Fields

    private var kindField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("What").wmOverline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WM.Space.s) {
                    ForEach(IntakeKind.allCases) { k in
                        kindChip(k)
                    }
                }
            }
            WMRule()
        }
    }

    /// One kind chip — the sport-chip idiom with the kind's glyph. Ink fill when selected, hairline
    /// capsule when not; no color, this is chrome. There is deliberately no second tap to CLEAR, the
    /// way method has: kind is required.
    private func kindChip(_ k: IntakeKind) -> some View {
        let selected = kind == k
        return Button {
            kind = k
        } label: {
            HStack(spacing: WM.Space.xs) {
                Image(systemName: k.symbol)
                    .font(WMType.caption)
                Text(k.label)
                    .font(WMType.body)
            }
            .foregroundStyle(selected ? WM.Ground.ground : WM.Ground.ink)
            .padding(.horizontal, WM.Space.l)
            .padding(.vertical, WM.Space.s + 2)
            .background(
                Capsule().fill(selected ? WM.Ground.ink : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(WM.Ground.rule, lineWidth: selected ? 0 : WM.hairline)
            )
            // The capsule keeps its drawn size; only the invisible hit box grows to 44pt.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The kind's sub-type, when it has one. Caffeine's drink-vs-pill is the only user today, and it
    /// is not decoration: it decides whether the milligram figure below is a label or an estimate.
    @ViewBuilder
    private var variantField: some View {
        if !kind.variants.isEmpty {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                Text("Form").wmOverline()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: WM.Space.s) {
                        ForEach(kind.variants) { v in variantChip(v) }
                    }
                }
                WMRule()
            }
        }
    }

    /// Tapping the selected form again clears it back to NOT RECORDED — nil is a real value here
    /// (the one-tap path writes it), so it needs a way back that is not "pick something you didn't".
    private func variantChip(_ v: IntakeVariant) -> some View {
        let selected = variant == v
        return Button { variant = selected ? nil : v } label: {
            HStack(spacing: WM.Space.xs) {
                Image(systemName: v.symbol).font(WMType.caption)
                Text(v.label).font(WMType.body)
            }
            .foregroundStyle(selected ? WM.Ground.ground : WM.Ground.ink)
            .padding(.horizontal, WM.Space.l)
            .padding(.vertical, WM.Space.s + 2)
            .background(Capsule().fill(selected ? WM.Ground.ink : Color.clear))
            .overlay(Capsule().strokeBorder(WM.Ground.rule, lineWidth: selected ? 0 : WM.hairline))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(v.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var whenField: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Text("When").wmOverline()
            DatePicker("", selection: $when, in: ...latestAllowed,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("When")
                .onChange(of: when) { old, new in
                    // Only moving the CLOCK records a time. A date-only move leaves the event
                    // declared-inexact, because we still don't know when it happened.
                    if !DayKey.sameClock(old, new) { exact = true }
                }
            if !exact {
                // Says both halves out loud: the clock is invented, AND that is why there will be no
                // response tape. Without the second sentence the missing tape reads as a bug.
                Text("Time was not recorded, so there is no response to draw.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft == nil {
                Text("That time is in the future. Save is off until it passes.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WMRule()
        }
    }

    /// The amount control, which is a different KIND of control per kind — not a styling choice.
    /// A count of discrete things the user consumed is a tally they can give exactly; a meal portion
    /// is not, so it gets an ordinal and says so. Collapsing the two into one numeric field is what
    /// would turn "2" on a meal into a measurement.
    @ViewBuilder
    private var amountField: some View {
        if kind.usesMilligrams {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                HStack {
                    Text(mg > 0 ? "\(mg) mg" : "Not recorded")
                        .font(WMType.body)
                        .foregroundStyle(mg > 0 ? WM.Ground.ink : WM.Ground.inkTertiary)
                        .monospacedDigit()
                    Spacer(minLength: WM.Space.l)
                    // 25 mg steps: a cup of filter is ~95, an espresso ~65, a common pill 200 — the
                    // grid lands near all of them without implying single-milligram precision.
                    Stepper("", value: $mg, in: 0...Self.maxMilligrams, step: 25)
                        .labelsHidden()
                        .accessibilityLabel("Caffeine milligrams")
                }
                .frame(minHeight: 44)
                // What the number MEANS depends on the form, so the caveat follows the form and is
                // absent until one is chosen rather than defaulting to the flattering reading.
                if let variant {
                    Text(variant.milligramCaveat)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mg > 0 {
                    Text("Pick a form above — on a packet this is a stated dose, in a cup it is an "
                         + "estimate, and they are not the same number.")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if kind.usesSizeOrdinal {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                InkSegmentRow(label: "Portion",
                              options: [("", "None"), ("1", "Light"), ("2", "Usual"), ("3", "Heavy")],
                              selection: sizeBinding)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("A relative scale you set, not a measured amount.")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let noun = kind.countNoun {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                HStack {
                    Text(countLabel(noun))
                        .font(WMType.body)
                        .foregroundStyle(count > 0 ? WM.Ground.ink : WM.Ground.inkTertiary)
                        .monospacedDigit()
                    Spacer(minLength: WM.Space.l)
                    Stepper("", value: $count, in: 0...Self.maxCount)
                        .labelsHidden()
                        .accessibilityLabel(countLabel(noun))
                }
                .frame(minHeight: 44)
                if let caveat = kind.countCaveat {
                    Text(caveat)
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Not recorded" at zero — never "0 drinks", which claims you had none rather than that you
    /// didn't say.
    private func countLabel(_ noun: String) -> String {
        guard count > 0 else { return "Not recorded" }
        let word = count == 1 ? noun : (kind.countNounPlural ?? noun)
        return "\(count) \(word)"
    }

    /// Bridges the `MealSize?` ordinal to `InkSegmentRow`'s String selection. "" is NOT RECORDED — a
    /// real value, not a default — and `MealSize(rawValue: 0)` is nil, so no special case is needed.
    private var sizeBinding: Binding<String> {
        Binding(get: { size.map { String($0.rawValue) } ?? "" },
                set: { size = MealSize(rawValue: Int($0) ?? 0) })
    }

    @ViewBuilder
    private var deleteRow: some View {
        if let editing {
            VStack(alignment: .leading, spacing: 0) {
                WMRule()
                Button {
                    guard !saving else { return }
                    saving = true
                    onDelete(editing)
                } label: {
                    Text("Delete entry")
                        .font(WMType.body)
                        .foregroundStyle(WM.Semantic.bad)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(saving)
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
}

private extension IntakeKind {
    /// The one thing a count does NOT say, per kind.
    ///
    /// Caffeine used to carry "Cups, not milligrams." here — a fence against sliding from a tally to
    /// a dose. 027 removed the need for it by moving caffeine to milligrams outright and making the
    /// FORM carry the honesty instead (`IntakeVariant.milligramCaveat`): a pill's mg is printed on
    /// the packet, a drink's is an estimate. Drinks and glasses never needed a fence — nobody
    /// mistakes them for a measured dose — so this is nil for every kind today, and kept because the
    /// next countable kind may well need one.
    var countCaveat: String? { nil }
}

// MARK: - Previews

#Preview("Intake editor — new, light") {
    IntakeEventEditorSpecimen(editing: nil).preferredColorScheme(.light)
}

#Preview("Intake editor — new, dark") {
    IntakeEventEditorSpecimen(editing: nil).preferredColorScheme(.dark)
}

#Preview("Intake editor — editing a drink") {
    IntakeEventEditorSpecimen(editing: IntakeSpecimen.day.first { $0.kind == .alcohol })
        .preferredColorScheme(.light)
}

#Preview("Intake editor — back-dated, no clock") {
    IntakeEventEditorSpecimen(editing: IntakeSpecimen.day.first { !$0.tsExact })
        .preferredColorScheme(.light)
}

private struct IntakeEventEditorSpecimen: View {
    let editing: IntakeEvent?

    var body: some View {
        let today = TodayModel.key(from: Date())
        IntakeEventEditor(editing: editing, day: today, anchorKey: today,
                          onSave: { _ in }, onDelete: { _ in }, onCancel: {})
    }
}
