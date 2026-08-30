import Foundation
import StrapStore

/// What was consumed. Raw values are the STABLE lowercase strings persisted in
/// `IngestionEventRow.kind`, so display copy can change without a migration (the `WeedMethod` /
/// `HabitKind` pattern).
///
/// Deliberately a CLOSED set of four. It is closed so that every downstream rule below is TOTAL —
/// the journal projection, the response window, and the "is there a tape at all" question each
/// have an answer for every case, checked by the compiler. An open type would also invite
/// medication and supplement logging, which is a different liability class entirely.
enum IntakeKind: String, CaseIterable, Identifiable {
    case meal
    case caffeine
    case alcohol
    case water

    var id: String { rawValue }

    /// Display label for the log buttons and event rows (the stored key never changes; copy can).
    var label: String {
        switch self {
        case .meal:     return "Meal"
        case .caffeine: return "Caffeine"
        case .alcohol:  return "Alcohol"
        case .water:    return "Water"
        }
    }

    /// SF Symbol for the log affordance and the event row.
    var symbol: String {
        switch self {
        case .meal:     return "fork.knife"
        case .caffeine: return "cup.and.saucer"
        case .alcohol:  return "wineglass"
        case .water:    return "drop"
        }
    }

    /// The noun `countValue` counts, singular — drinks, cups, glasses. Nil for `meal`, whose amount
    /// is an ordinal instead: a portion is not a count of discrete things, and giving it one would
    /// dress a guess as a tally. Exactly one of `countNoun` / `usesSizeOrdinal` is non-nil per case.
    var countNoun: String? {
        switch self {
        case .alcohol:  return "drink"
        case .water:    return "glass"
        // Caffeine moved from cups to MILLIGRAMS in 027 (`usesMilligrams`). Rows written before that
        // still hold cups here and still render as cups — see the v28 migration comment.
        case .caffeine: return "cup"
        case .meal:     return nil
        }
    }

    /// The plural of `countNoun`. Explicit rather than `noun + "s"`, which rendered "2 glasss" —
    /// English sibilants take -es, and a blind suffix is wrong for exactly the noun water uses.
    var countNounPlural: String? {
        switch self {
        case .alcohol:  return "drinks"
        case .water:    return "glasses"
        case .caffeine: return "cups"
        case .meal:     return nil
        }
    }

    /// Whether this kind's amount is recorded in milligrams.
    ///
    /// Caffeine only, and it is a narrower claim than it looks. 024 decision 7 refused milligrams
    /// because "a self-reported dose the app cannot verify is an ordinal, and dressing it as a
    /// measured amount would be the claim". That reasoning holds for a brewed drink and NOT for a
    /// pill: the tin states 200 mg, so entering 200 is reading a label, not estimating a dose. The
    /// form picker is what keeps the two apart, and the editor labels the drink case as an estimate.
    var usesMilligrams: Bool { self == .caffeine }

    /// The closed set of sub-types this kind offers, or empty when it offers none. Closed per kind
    /// on purpose: `variant` is a typed field with a small vocabulary, not free text.
    var variants: [IntakeVariant] {
        self == .caffeine ? [.drink, .pill] : []
    }

    /// Whether this kind's amount is the 1|2|3 size ordinal rather than a count.
    var usesSizeOrdinal: Bool { self == .meal }
}

/// A kind's sub-type. Raw values are the STABLE lowercase strings persisted in
/// `IngestionEventRow.variant`.
///
/// Caffeine's two forms are not cosmetic — they decide whether the milligram figure beside them is a
/// LABEL or an ESTIMATE, which is the whole reason 027 could add milligrams at all without
/// re-opening what 024 decision 7 actually refused.
enum IntakeVariant: String, CaseIterable, Identifiable {
    case drink
    case pill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .drink: return "Drink"
        case .pill:  return "Pill"
        }
    }

    var symbol: String {
        switch self {
        case .drink: return "cup.and.saucer"
        case .pill:  return "pills"
        }
    }

    /// What the milligram figure means for this form. Shown under the amount control, because the
    /// same "200 mg" is a fact in one case and a guess in the other.
    var milligramCaveat: String {
        switch self {
        case .pill:  return "As printed on the packet."
        case .drink: return "An estimate — brewed strength varies a lot."
        }
    }
}

// MARK: - Response window

/// How far past an event the response tape reads, per kind. The three shapes are different because
/// the time courses are different, not for variety — see 024 decision 10.
enum IntakeWindow: Equatable {
    /// A fixed span from the event. `meal` resolves in ~3 h; `caffeine`'s half-life is ~5 h, so a
    /// 3 h window would truncate it at roughly half.
    case fixed(seconds: Int)
    /// Read to sleep onset, capped. Alcohol's legible signature is overnight — elevated sleeping HR,
    /// suppressed HRV, raised skin temp — all of which the app already computes per night, so the
    /// tape runs to the boundary and hands off to that night's Rest rather than guessing across it.
    case toSleepOnset(capSeconds: Int)
    /// No window, because there is no response to draw. `water` only: the strap records nothing that
    /// answers hydration, and a tape over the noise would be read as meaning. See 024 decision 11.
    case none
}

extension IntakeKind {
    var window: IntakeWindow {
        switch self {
        case .meal:     return .fixed(seconds: 3 * 3_600)
        case .caffeine: return .fixed(seconds: 6 * 3_600)
        case .alcohol:  return .toSleepOnset(capSeconds: 10 * 3_600)
        case .water:    return .none
        }
    }

    /// Whether this kind renders a response tape at all. The one `false` is not an omission — it is
    /// the refusal, and the screen says so in words rather than rendering an empty lane.
    var hasResponseTape: Bool { window != .none }
}

// MARK: - Journal projection

/// The hour at/after which a caffeine event raises `caffeine_late`. NOT a new definition — it is the
/// one already written down at `JournalStore.swift:13` ("Caffeine after ~14:00"), read out of the
/// comment and into code so the projection cannot drift from the tag's stated meaning.
private let caffeineLateHour = 14

extension IntakeKind {
    /// The tag this event raises, or nil for none. RAISE-ONLY: a nil here means "write nothing", and
    /// there is deliberately no inverse — see `IntakeStore.project`.
    ///
    /// - `alcohol` raises `alcohol` at any hour.
    /// - `caffeine` raises `caffeine_late` only from `caffeineLateHour` local, per the tag's own
    ///   definition. An 09:00 coffee raises nothing, which is correct and not a gap.
    /// - `meal` raises NOTHING. `late_meal` has no threshold anywhere in this codebase — "late" is
    ///   whatever the user meant when they tapped the chip — and inventing one here would silently
    ///   restate the meaning of every such tap they have ever made. 024 decision 5.
    /// - `water` raises nothing; no tag exists.
    ///
    /// `calendar` is injected so the boundary is testable without moving the device clock.
    func journalTag(at ts: Int, calendar: Calendar = .current) -> JournalTag? {
        switch self {
        case .alcohol:
            return .alcohol
        case .caffeine:
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return hour >= caffeineLateHour ? .caffeineLate : nil
        case .meal, .water:
            return nil
        }
    }
}

// MARK: - Amount

/// Relative portion for a MEAL — explicitly not grams or calories, and explicitly not a count.
/// Stored as the 1|2|3 ordinal so the ORDER is the data. Nothing in 024 wave A analyses it; it
/// exists so a later wave can fit the user's OWN dose-response rather than borrow a population
/// prior.
enum MealSize: Int, CaseIterable, Identifiable {
    case light = 1
    case usual = 2
    case heavy = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .usual: return "Usual"
        case .heavy: return "Heavy"
        }
    }
}

// MARK: - Event

/// One logged intake event — the app-side domain twin of the flat v27 `IngestionEventRow`.
///
/// `day` is the key the CALLER wrote (`Repository.anchorKey` for a live log, the Today stepper's
/// `selectedKey` for a back-date) and is NEVER re-derived from `ts`: `DayKey.local` and
/// `DayKey.logicalKey` disagree with `anchorKey` across the 00:00-04:00 window, which is exactly
/// where a post-midnight drink lives. `ts` is the response window's origin and the display clock.
struct IntakeEvent: Identifiable, Equatable {
    /// Client-generated, the table's whole PK — no natural key, because two events at the same
    /// minute are legal (two drinks in one minute is a thing that happens).
    let id: String
    /// yyyy-MM-dd, the caller's day key (see type doc).
    var day: String
    var ts: Int
    /// False marks a DECLARED placeholder clock (a back-dated log), so the UI says "Time not
    /// recorded" — and renders NO tape, because a response window needs a real origin.
    var tsExact: Bool
    /// The stored kind string, always. Kept verbatim alongside `kind` so an event written by a
    /// LATER build survives a downgrade as a logged moment with an honest label instead of
    /// vanishing from the list — the `JournalStore.displayLabel(forQuestion:)` precedent for
    /// imported question keys, applied here.
    var rawKind: String
    /// Nil when `rawKind` is not one of this build's four. Nil renders no tape and no amount: we
    /// know something was logged and not what, which is exactly what gets shown.
    var kind: IntakeKind? { IntakeKind(rawValue: rawKind) }
    /// Drinks / cups / glasses. Nil = not recorded. Meaningless (and always nil) for `meal`.
    var countValue: Int?
    /// Meal portion ordinal. Nil = not recorded. Always nil for the other kinds.
    var sizeOrdinal: MealSize?
    /// Sub-type, where the kind offers one (caffeine's drink|pill). Nil = not recorded.
    var variant: IntakeVariant?
    /// Milligrams, where milligrams are knowable. Nil = not recorded — and for a caffeine row logged
    /// before 027 this is nil while `countValue` holds cups, which is why both render.
    var amountMg: Int?
    /// `manualSource` for an event the user logged, `"demo"` for a seeded one.
    var source: String
    var createdAt: Int

    /// Provenance of an event the user logged themselves. The demo seed writes `"demo"` and clears
    /// itself by lane (`deleteIngestionEvents(deviceId:source:)`), so the two never collide.
    static let manualSource = "manual"

    /// Display label, falling back to a humanized raw for a kind this build does not know.
    var label: String {
        if let kind { return kind.label }
        let words = rawKind.replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return rawKind }
        return String(first).uppercased() + words.dropFirst()
    }

    /// Whether the event carries anything the user TYPED beyond its existence and clock.
    var hasRecordedDetail: Bool {
        countValue != nil || sizeOrdinal != nil || variant != nil || amountMg != nil
    }

    /// Whether a response tape can be drawn for this event at all — before any question of whether
    /// the SAMPLES are still on disk, which is the horizon's business (`IntakeTapeAvailability`).
    /// False for water (no signal answers it), for an unknown kind (no window defined), and for an
    /// inexact clock (no origin to draw around).
    var supportsResponseTape: Bool {
        guard let kind, kind.hasResponseTape else { return false }
        return tsExact
    }

    // MARK: Mapping

    init(id: String = UUID().uuidString, day: String, ts: Int, tsExact: Bool = true,
         kind: IntakeKind, countValue: Int? = nil, sizeOrdinal: MealSize? = nil,
         variant: IntakeVariant? = nil, amountMg: Int? = nil,
         source: String = IntakeEvent.manualSource,
         createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id; self.day = day; self.ts = ts; self.tsExact = tsExact
        self.rawKind = kind.rawValue
        self.countValue = countValue; self.sizeOrdinal = sizeOrdinal
        self.variant = variant; self.amountMg = amountMg
        self.source = source; self.createdAt = createdAt
    }

    init(_ row: IngestionEventRow) {
        self.id = row.id
        self.day = row.day
        self.ts = row.ts
        self.tsExact = row.tsExact
        self.rawKind = row.kind
        self.countValue = row.countValue
        // An out-of-range ordinal carries no order we can honour, so it reads as unrecorded rather
        // than being clamped into a portion the user never chose (the `WeedPotency` decision).
        self.sizeOrdinal = row.sizeOrdinal.flatMap(MealSize.init(rawValue:))
        // An unrecognised stored variant reads as NOT RECORDED rather than being coerced — a later
        // build's new form must not decode as one of ours.
        self.variant = row.variant.flatMap(IntakeVariant.init(rawValue:))
        self.amountMg = row.amountMg
        self.source = row.source
        self.createdAt = row.createdAt
    }

    /// The flat storage row. `deviceId` is always `StrapStore.intakeSourceId` — ONE constant lane,
    /// so it is not carried on the domain type: this table is native-only and has no imported or
    /// strap-CSV counterpart to merge with.
    var row: IngestionEventRow {
        IngestionEventRow(id: id, deviceId: StrapStore.intakeSourceId, day: day, ts: ts,
                          tsExact: tsExact, kind: rawKind, countValue: countValue,
                          sizeOrdinal: sizeOrdinal?.rawValue, variant: variant?.rawValue,
                          amountMg: amountMg, source: source, createdAt: createdAt)
    }
}
