import SwiftUI

/// Add or edit one intake event — a `groundRaised` sheet in the Line language (037, mockup
/// `L_Intake`): Cancel / "Log intake" / Save, the kind as a rounded segmented picker, caffeine's
/// Drink/Pill form, the "When" row, the amount as a numeral between −/+ circles, and a delete row on
/// an edit.
///
/// Presented with `.sheet(item:)` on an Identifiable ref wrapping an OPTIONAL event, because
/// nil-means-create cannot drive `item:` (the `IntakeEditorRef` / `MonitorDayRef` idiom).
///
/// Thin environment wrapper over the pure `IntakeEventEditor` (the `HealthMonitorScreen` split): the
/// store writes live here, so the layout — and both themes' previews — need nothing but values.
struct IntakeEventSheet: View {
    /// The event being edited, or nil to log a new one.
    let editing: IntakeEvent?
    /// The day key a CREATE lands on — the Log tab's anchor day (or the Intake screen's), which is
    /// already anchor-derived. Never re-derived from a clock. An edit carries its own.
    let day: String
    /// The kind a CREATE opens on — Log's quick-add circles preset it (Meal · Caffeine · Alcohol ·
    /// Water). Nil opens on the editor's own default. Ignored on an edit, which carries its own kind.
    let kind: IntakeKind?

    @EnvironmentObject private var intake: IntakeStore
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    init(editing: IntakeEvent?, day: String, kind: IntakeKind? = nil) {
        self.editing = editing
        self.day = day
        self.kind = kind
    }

    var body: some View {
        IntakeEventEditor(
            editing: editing,
            day: day,
            // The create default is `IntakeStore.stamp`, so an event logged on a PAST day carries the
            // declared placeholder clock — and therefore draws no response tape, because a window
            // around a fabricated noon is arithmetic over a guess.
            anchorKey: Repository.anchorKey(days: repo.days),
            initialKind: kind,
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
    /// rule and nothing to render, so there is no honest nil to fall back to. A create opens on the
    /// quick-add preset, else `.meal` because it is the most-logged of the four, not because it is a
    /// default we believe.
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

    /// - Parameter initialKind: the kind a CREATE opens on (Log's quick-add preset). An edit ignores
    ///   it and opens on the event's own kind.
    init(editing: IntakeEvent?, day: String, anchorKey: String,
         initialKind: IntakeKind? = nil,
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
        // `.meal` only if it was never a known kind, which a downgrade makes vanishingly rare. A
        // create opens on the quick-add circle's kind when one was tapped.
        _kind = State(initialValue: editing?.kind ?? initialKind ?? .meal)
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
            WMSheetHeader(title: editing == nil ? "Log intake" : "Edit intake",
                          canSave: draft != nil && !saving,
                          onCancel: onCancel,
                          onSave: save)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Kind is required, so the picker has no "none" segment and no tap-again-to-clear
                    // — unlike the form below, where nil is a real value.
                    WMSegmentedPicker(options: IntakeKind.allCases.map { (value: $0, name: $0.label) },
                                      selection: $kind, label: "Kind")
                        .padding(.top, WM.Space.m)
                    VStack(alignment: .leading, spacing: 0) {
                        variantField
                        whenField
                        amountField
                    }
                    .padding(.top, WM.Space.l)
                    footer
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

    /// The kind's sub-type, when it has one. Caffeine's drink-vs-pill is the only user today, and it
    /// is not decoration: it decides whether the milligram figure below is a label or an estimate.
    @ViewBuilder
    private var variantField: some View {
        if !kind.variants.isEmpty {
            InkSegmentRow(label: "Form",
                          options: kind.variants.map { (value: $0.rawValue, name: $0.label) },
                          selection: variantBinding)
            WMRule()
        }
    }

    /// Bridges `IntakeVariant?` to `InkSegmentRow`'s String selection. Tapping the selected form AGAIN
    /// clears it back to NOT RECORDED — the segment writes its value even when it is already selected,
    /// so an equal write is the re-tap. nil is a real value here (the one-tap path writes it), so it
    /// needs a way back that is not "pick something you didn't".
    private var variantBinding: Binding<String> {
        Binding(get: { variant?.rawValue ?? "" },
                set: { picked in
                    variant = picked == variant?.rawValue ? nil : IntakeVariant(rawValue: picked)
                })
    }

    private var whenField: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMWhenField(when: $when, exact: $exact, latestAllowed: latestAllowed)
            if !exact {
                // Says both halves out loud: the clock is invented, AND that is why there will be no
                // response tape. Without the second sentence the missing tape reads as a bug.
                caption("Time was not recorded, so there is no response to draw.")
            }
            if draft == nil {
                caption("That time is in the future. Save is off until it passes.")
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
            VStack(alignment: .leading, spacing: 0) {
                // 25 mg steps: a cup of filter is ~95, an espresso ~65, a common pill 200 — the grid
                // lands near all of them without implying single-milligram precision.
                WMAmountStepper(label: "Amount", value: $mg, range: 0...Self.maxMilligrams,
                                step: 25, unit: "mg")
                // What the number MEANS depends on the form, so the caveat follows the form and is
                // absent until one is chosen rather than defaulting to the flattering reading.
                if let variant {
                    caption(variant.milligramCaveat)
                } else if mg > 0 {
                    caption("Pick a form above — on a packet this is a stated dose, in a cup it is an "
                            + "estimate, and they are not the same number.")
                }
            }
        } else if kind.usesSizeOrdinal {
            VStack(alignment: .leading, spacing: 0) {
                InkSegmentRow(label: "Portion",
                              options: [("", "None"), ("1", "Light"), ("2", "Usual"), ("3", "Heavy")],
                              selection: sizeBinding)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                caption("A relative scale you set, not a measured amount.")
            }
        } else if let noun = kind.countNoun {
            VStack(alignment: .leading, spacing: 0) {
                WMAmountStepper(label: "Amount", value: $count, range: 0...Self.maxCount,
                                unit: count == 1 ? noun : (kind.countNounPlural ?? noun))
                if let caveat = kind.countCaveat {
                    caption(caveat)
                }
            }
        }
    }

    /// What the response screen will do with this entry, said before the save rather than
    /// discovered after it. Only for a kind that draws a tape and an entry with a real clock — water
    /// and a back-dated entry already say why they draw none.
    @ViewBuilder
    private var footer: some View {
        if kind.hasResponseTape && exact {
            caption("After you save, open the entry to see what your heart rate, skin temperature and "
                    + "HRV did in the hours that followed.")
                .padding(.top, WM.Space.s)
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

    /// Bridges the `MealSize?` ordinal to `InkSegmentRow`'s String selection. "" is NOT RECORDED — a
    /// real value, not a default — and `MealSize(rawValue: 0)` is nil, so no special case is needed.
    private var sizeBinding: Binding<String> {
        Binding(get: { size.map { String($0.rawValue) } ?? "" },
                set: { size = MealSize(rawValue: Int($0) ?? 0) })
    }

    @ViewBuilder
    private var deleteRow: some View {
        if let editing {
            WMSheetDeleteRow(title: "Delete entry", enabled: !saving) {
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

#Preview("Intake editor — caffeine preset, dark") {
    IntakeEventEditorSpecimen(editing: nil, preset: .caffeine).preferredColorScheme(.dark)
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
    /// The quick-add preset a create opens on (Log's circles).
    var preset: IntakeKind? = nil

    var body: some View {
        let today = TodayModel.key(from: Date())
        IntakeEventEditor(editing: editing, day: today, anchorKey: today, initialKind: preset,
                          onSave: { _ in }, onDelete: { _ in }, onCancel: {})
    }
}
