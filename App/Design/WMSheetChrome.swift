import SwiftUI

// The sheet chrome (037, "Sheets"): the Cancel / title / Save header, the full-width rounded
// segmented picker for kinds and cadences, the "When" row that opens a date-and-time wheel, the
// numeral-between-circles amount stepper, the delete row, and the `track`-capsule text field. The
// Intake, Weed-session, Habit and workout editors, the sport picker and the Data search share these,
// so the sheets cannot drift apart — the drift is exactly what 037 was asked to fix.

// MARK: - Header

/// Sheet top bar: Cancel (leading, inkSecondary), the title centered (headline semibold), Save
/// (trailing, ink; inkTertiary and inert while the draft cannot be saved). Title centering is
/// independent of the two buttons' widths, so "Cancel" / "Save" never push it off the axis.
///
/// The words ride Dynamic Type up to xxxLarge, the way a navigation bar stops growing: past that the
/// centered title would run into the buttons it sits between.
struct WMSheetHeader: View {
    let title: String
    let canSave: Bool
    let onCancel: () -> Void
    /// nil hides Save (a sheet whose rows act on tap, like the sport picker).
    let onSave: (() -> Void)?

    init(title: String, canSave: Bool = false, onCancel: @escaping () -> Void,
         onSave: (() -> Void)? = nil) {
        self.title = title
        self.canSave = canSave
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: WM.Space.l)
                if let onSave {
                    Button(action: onSave) {
                        Text("Save")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(canSave ? WM.Ground.ink : WM.Ground.inkTertiary)
                            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, WM.Space.gutter)
        .padding(.top, WM.Space.s)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

// MARK: - Segmented picker

/// Full-width rounded segmented control (037 "kind pickers use the new segmented style"): a
/// `track` capsule holding equal-width segments, the selected one filled ink with ground text.
/// `InkSegmentRow` is the labelled trailing variant; this one owns the whole row for pickers whose
/// options ARE the field (the intake kind, a habit's cadence).
struct WMSegmentedPicker<Value: Hashable>: View {
    /// (value, visible name) pairs, in display order.
    let options: [(value: Value, name: String)]
    @Binding var selection: Value
    /// VoiceOver prefix ("Kind"), read as "Kind: Caffeine".
    let label: String

    init(options: [(value: Value, name: String)], selection: Binding<Value>, label: String) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option)
            }
        }
        .padding(3)
        .background(Capsule().fill(WM.Ground.track))
    }

    private func segment(_ option: (value: Value, name: String)) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Text(option.name)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(selected ? WM.Ground.ground : WM.Ground.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 36)
                .background(Capsule().fill(selected ? WM.Ground.ink : Color.clear))
                // 42pt with its track; the invisible hit box reaches the HIG 44.
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .wmAnimation(WMMotion.transition, value: selected)
        .accessibilityLabel("\(label): \(option.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - When

/// The "When" row: the picked instant as a trailing reading ("Today · 15:40"), and a tap that opens a
/// date-and-time wheel under it. Replaces the compact system picker, whose two grey capsules were the
/// one piece of system chrome left in the sheets.
///
/// Owns the one rule every editor shares: only moving the CLOCK records a time. A date-only move
/// leaves an inexact (back-dated) entry inexact, because we still don't know when it happened.
struct WMWhenField: View {
    @Binding var when: Date
    @Binding var exact: Bool
    /// The latest instant the wheel offers (the editor's `latestAllowed`).
    let latestAllowed: Date

    @State private var expanded = false

    init(when: Binding<Date>, exact: Binding<Bool>, latestAllowed: Date) {
        self._when = when
        self._exact = exact
        self.latestAllowed = latestAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: WM.Space.m) {
                    Text("When")
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.ink)
                    Spacer(minLength: WM.Space.s)
                    Text(reading)
                        .font(WMType.label)
                        .monospacedDigit()
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .lineLimit(1)
                    WMDisclosure()
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(minHeight: WM.Space.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .wmAnimation(WMMotion.transition, value: expanded)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("When, \(reading)")
            .accessibilityHint(expanded ? "Hides the date and time picker" : "Shows the date and time picker")

            if expanded {
                DatePicker("When", selection: $when, in: ...latestAllowed,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: when) { old, new in
            if !DayKey.sameClock(old, new) { exact = true }
        }
    }

    /// The instant in words: the calendar day it falls on, then its clock — or, for a declared
    /// placeholder, that the clock was never recorded (never the invented noon / 21:00 itself).
    private var reading: String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(when) {
            day = "Today"
        } else if cal.isDateInYesterday(when) {
            day = "Yesterday"
        } else {
            day = when.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return exact ? "\(day) · \(WMFormat.timeOfDay(when))" : "\(day) · time not recorded"
    }
}

// MARK: - Amount

/// An amount as a 40pt light numeral between −/+ circle buttons (037 "amounts are a numeral 40
/// between −/+ circle buttons"): an intake's milligrams or count, a weekly habit's times per week, a
/// manual workout's minutes. The label, range, step and unit are the caller's.
///
/// A step clamps to `range`, the way the system `Stepper` did, so an off-grid value (an edited 20 mg
/// against 25 mg steps) still reaches the bound, and each button stops only AT its bound.
///
/// Zero is NOT RECORDED in every editor whose range reaches it, so it reads as words, never as "0",
/// which would claim the user had none.
///
/// One adjustable element for VoiceOver: swipe up / down steps it.
struct WMAmountStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// The unit beside the numeral for the CURRENT value ("mg", "drinks", "min"); the caller pluralises.
    let unit: String?
    /// The unit as VoiceOver should say it when the drawn one is an abbreviation ("minutes" for
    /// "min"); nil speaks `unit`.
    let spokenUnit: String?

    init(label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1,
         unit: String? = nil, spokenUnit: String? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.spokenUnit = spokenUnit
    }

    private var canDecrement: Bool { value > range.lowerBound }
    private var canIncrement: Bool { value < range.upperBound }

    private func move(by delta: Int) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: WM.Space.m) {
            Text(label)
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.s)
            HStack(spacing: WM.Space.l) {
                circle("minus", enabled: canDecrement) { move(by: -step) }
                reading
                    .frame(minWidth: 84)
                circle("plus", enabled: canIncrement) { move(by: step) }
            }
        }
        .frame(minHeight: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: step)
            case .decrement: move(by: -step)
            @unknown default: break
            }
        }
    }

    private var spokenValue: String {
        guard value != 0 else { return "Not recorded" }
        guard let spoken = spokenUnit ?? unit else { return "\(value)" }
        return "\(value) \(spoken)"
    }

    @ViewBuilder
    private var reading: some View {
        if value == 0 {
            Text("Not recorded")
                .font(WMType.label)
                .foregroundStyle(WM.Ground.inkTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: WM.Space.xs) {
                Text("\(value)")
                    .font(WMType.numeral(40))
                    .foregroundStyle(WM.Ground.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(WMType.label)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
        }
    }

    private func circle(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(WMType.icon(.inline))
                .foregroundStyle(enabled ? WM.Ground.ink : WM.Ground.inkTertiary.opacity(0.5))
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(WM.Ground.track, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Destructive row

/// The editors' delete action: a full-width bad-colored row over a hairline, inert while a save or
/// delete is already in flight.
struct WMSheetDeleteRow: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(title: String, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMRule()
            Button(action: action) {
                Text(title)
                    .font(WMType.body)
                    .foregroundStyle(WM.Semantic.bad)
                    .frame(maxWidth: .infinity, minHeight: WM.Space.row, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }
}

// MARK: - Search / name field

/// A text field on a `track` capsule (037's search-field shape): Data's metric search, the sport
/// search, and the manual workout's sport name. A clear button appears once there is text, and a tap
/// anywhere on the capsule focuses the field, not just on the text run.
struct WMSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// The leading magnifier — on for a search, off for a plain name field.
    let showsSearchGlyph: Bool
    /// `.never` for a search over fixed names; `.words` where the typed text is recorded as a name.
    let capitalization: TextInputAutocapitalization
    /// The return key's label (`.search` for a filter).
    let submitLabel: SubmitLabel
    /// VoiceOver label for the clear button ("Clear search").
    let clearLabel: String

    @FocusState private var focused: Bool

    init(placeholder: String, text: Binding<String>, showsSearchGlyph: Bool = true,
         capitalization: TextInputAutocapitalization = .never, submitLabel: SubmitLabel = .search,
         clearLabel: String = "Clear search") {
        self.placeholder = placeholder
        self._text = text
        self.showsSearchGlyph = showsSearchGlyph
        self.capitalization = capitalization
        self.submitLabel = submitLabel
        self.clearLabel = clearLabel
    }

    var body: some View {
        HStack(spacing: WM.Space.s) {
            if showsSearchGlyph {
                Image(systemName: "magnifyingglass")
                    .font(WMType.icon(.inline))
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .accessibilityHidden(true)
            }
            TextField(placeholder, text: $text,
                      prompt: Text(placeholder).foregroundStyle(WM.Ground.inkTertiary))
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
                .tint(WM.Ground.ink)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(WMType.icon(.inline))
                        .foregroundStyle(WM.Ground.inkTertiary)
                        .frame(width: 44, height: 44)   // HIG tap target; the glyph stays small
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        // The clear button's own 44pt box already insets its glyph, so the trailing pad steps down while
        // it shows and the glyph sits where the capsule's round end expects it.
        .padding(.leading, WM.Space.l)
        .padding(.trailing, text.isEmpty ? WM.Space.l : 0)
        .frame(minHeight: 44)
        .background(Capsule().fill(WM.Ground.track))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

// MARK: - Previews

#Preview("Sheet chrome — light") {
    WMSheetChromeSpecimen().preferredColorScheme(.light)
}

#Preview("Sheet chrome — dark") {
    WMSheetChromeSpecimen().preferredColorScheme(.dark)
}

private struct WMSheetChromeSpecimen: View {
    @State private var kind = "caffeine"
    @State private var when = Date()
    @State private var exact = true
    @State private var mg = 130
    @State private var drinks = 0
    @State private var minutes = 45
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMSheetHeader(title: "Log intake", canSave: true, onCancel: {}, onSave: {})
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    WMSearchField(placeholder: "Search 39 sports", text: $query)
                        .padding(.top, WM.Space.m)
                    WMSegmentedPicker(options: [("meal", "Meal"), ("caffeine", "Caffeine"),
                                                ("alcohol", "Alcohol"), ("water", "Water")],
                                      selection: $kind, label: "Kind")
                        .padding(.top, WM.Space.m)
                    WMWhenField(when: $when, exact: $exact, latestAllowed: Date())
                        .padding(.top, WM.Space.l)
                    WMRule()
                    WMAmountStepper(label: "Amount", value: $mg, range: 0...600, step: 25, unit: "mg")
                    WMRule()
                    WMAmountStepper(label: "Amount", value: $drinks, range: 0...20, unit: "drinks")
                    WMRule()
                    WMAmountStepper(label: "Duration", value: $minutes, range: 1...(24 * 60), step: 5,
                                    unit: "min", spokenUnit: "minutes")
                    WMSheetDeleteRow(title: "Delete entry", enabled: true) {}
                }
                .padding(.horizontal, WM.Space.gutter)
            }
        }
        .background(WM.Ground.groundRaised)
    }
}
