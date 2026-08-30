import Foundation

/// The PROVENANCE half of a published glance: which day the snapshot's Charge and Rest actually came
/// from, stamped with the publish it belongs to. Written beside `WidgetSnapshot` in the same App Group,
/// by the same `WidgetSnapshot.publish` call, and read by exactly one consumer — the read-side
/// `GlanceReadingIntent`, which has to say the source day out loud because a spoken answer has no room
/// for Today's "carried · Tue" caption.
///
/// **WHY A SIBLING RECORD AND NOT TWO MORE FIELDS ON `WidgetSnapshot`.** `sameValues(as:)` is the gate
/// that decides whether a publish spends one of WidgetKit's rationed background-refresh reloads
/// (`WidgetSnapshot.publish` — the Perf2 note there). That gate works because every field on
/// `WidgetSnapshot` is DRAWN: if one moves, pixels move, and the reload is earned. Carry provenance is
/// drawn by no glance surface at all — `WidgetDayFields.chargeCarriedFrom` says so in its own doc ("The
/// glance surfaces ignore it") — so folding it into the snapshot would make the carry source rolling
/// from Mon to Tue, with the number itself unchanged, burn a reload for a widget that renders exactly
/// the same picture. Keeping it out preserves the gate's meaning instead of quietly widening it.
///
/// **WHY IT STORES A RENDERED LABEL, NOT A DAY KEY.** The writer maps the key through
/// `TodayModel.shortDayLabel` — the same function that produces Today's "carried · Tue" caption — so
/// the app and the spoken answer cannot name a day differently. Storing the raw `yyyy-MM-dd` key would
/// need a second date parser over here, because the widget extension compiles no `Core/` (project.yml:
/// "the extension compiles only Shared/ + Widgets/") and `DayKey` lives in `Core/`. A second parser is
/// a second opinion about how a day is named; there is nothing to gain from having one.
///
/// **WHY IT CARRIES ITS OWN STAMP.** Two records mean two writes, and a reader must be able to tell
/// whether they describe the same publish. `updatedUnix` is `WidgetSnapshot.updated` truncated to whole
/// seconds — an Int on both sides, so the comparison is exact rather than a float round-trip — and a
/// mismatch (or a missing record, which is what an install that upgraded but has not re-published yet
/// looks like) resolves to `.unknown`. `.unknown` makes the intent SAY the day is unconfirmed. It never
/// falls back to "assume it's today's own", because that is the one wrong answer available here: it
/// would present a two-day-old recovery as this morning's measurement, which is the #977 failure the
/// carry cap exists to prevent, re-introduced in words.
public struct GlanceCarry: Codable, Equatable {
    /// The publish this record describes — `WidgetSnapshot.updated` in whole unix seconds.
    public var updatedUnix: Int
    /// Short source-day label ("Tue") of a CARRIED Charge, or nil when the answered day's own row is
    /// scored. Same contract as `WidgetDayFields.chargeCarriedFrom`, one step further down the pipe.
    public var chargeCarriedFrom: String?
    /// Short source-day label of a carried Rest — same contract.
    public var restCarriedFrom: String?

    public init(updated: Date, chargeCarriedFrom: String?, restCarriedFrom: String?) {
        self.updatedUnix = GlanceCarry.stamp(updated)
        self.chargeCarriedFrom = chargeCarriedFrom
        self.restCarriedFrom = restCarriedFrom
    }

    /// Lives in the same App Group suite as the snapshot (`WidgetSnapshot.suiteName`), so provisioning
    /// is one problem and not two — `WidgetSnapshot.assertGroupProvisioned()` covers both records.
    public static let storageKey = "wm.widget.carry"

    /// Whole unix seconds. Truncation, not rounding, on both the write and the compare, so the two
    /// sides agree by construction.
    public static func stamp(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    public static func load() -> GlanceCarry? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey),
              let carry = try? JSONDecoder().decode(GlanceCarry.self, from: data) else { return nil }
        return carry
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: GlanceCarry.storageKey)
    }

    /// Where one of the snapshot's two carryable scores came from.
    ///
    /// Pure and total: any state that is not provably "this publish's own row" or "this publish's
    /// carry from day X" is `.unknown`, and the caller has to say so.
    public static func source(for snapshot: WidgetSnapshot, carry: GlanceCarry?,
                              _ field: KeyPath<GlanceCarry, String?>) -> GlanceSource {
        guard let carry, carry.updatedUnix == stamp(snapshot.updated) else { return .unknown }
        if let day = carry[keyPath: field] { return .carried(day) }
        return .own
    }
}

/// The provenance of a single glance score. Three states, not two: "we know it is carried", "we know
/// it is not", and "we cannot tell" — the third being the honest reading of a snapshot published
/// before this record existed. Collapsing `.unknown` into `.own` is the failure mode this type exists
/// to make impossible to write by accident.
public enum GlanceSource: Equatable {
    /// The answered day's own scored row.
    case own
    /// Carried from an earlier day, named by its short label ("Tue").
    case carried(String)
    /// No provenance record matches this snapshot, so the value's day cannot be stated.
    case unknown
}
