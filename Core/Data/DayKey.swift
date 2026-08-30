import Foundation

/// The ONE `yyyy-MM-dd` day-key formatter + logical-day rule for the app. Everything keyed off
/// `DailyMetric.day` funnels through here: `Repository` forwards its `localDayKey`/`logicalDay*`
/// helpers to these, and the nonisolated call sites (Today derivations, the metric catalog, Rest,
/// the Signal Lab assembly) that used to hand-roll a private twin — because Repository is
/// `@MainActor` and they aren't — now share this one.
enum DayKey {
    /// `yyyy-MM-dd` in the device's local zone, matching how `DailyMetric.day` is stored.
    ///
    /// Shared across actors because the formatter is FULLY configured inside this closure and never
    /// mutated afterwards — every use is a read, so one instance is safe (`DateFormatter` is
    /// `Sendable`, so no `nonisolated(unsafe)` is needed or accepted here). Anything that must
    /// reassign a field per call (e.g. `HealthExport.noon(ofDay:)` refreshing `.timeZone`) keeps its
    /// own formatter and must not fold into this one.
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// The local-zone `yyyy-MM-dd` key for `date`.
    nonisolated static func local(_ date: Date) -> String { formatter.string(from: date) }

    /// Same shape as `formatter`, but parses an explicit hour — fully configured here and never
    /// mutated, so it is shared safely for the same reason `formatter` is.
    static let hourFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// The local first-instant `Date` a `yyyy-MM-dd` key names, or nil when the key doesn't parse.
    ///
    /// The strict midnight parse is the fast path, but it CANNOT be the only one: in the zones whose
    /// DST springs forward AT midnight — America/Havana, America/Santiago, Africa/Cairo, Asia/Beirut,
    /// Atlantic/Azores, one date a year each — local 00:00 does not exist, and `DateFormatter` returns
    /// nil for a key `local(_:)` itself produced. Because every app-layer day-key parse funnels through
    /// here, that nil took out the whole day: `TodayModel.daysBetween` is the age gate inside both score
    /// carries, so Charge and Rest published nil to the Today screen, the widget and the Live Activity;
    /// `shiftKey` returned nil so the day-browser chevron became a no-op; habit history read empty.
    ///
    /// Noon always exists, so parse there and snap back to the day's real first instant (01:00 on those
    /// dates). Only ever turns a nil into a valid Date, never the reverse, and a junk key still fails the
    /// strict y/m/d parse of the appended hour — `isLenient` stays false, so "2026-13-01" is still nil.
    /// Snapping uses `hourFormatter`'s OWN zone rather than `Calendar.current`: like `formatter`, it
    /// resolves its zone once, and reading a different zone here could land the snap on a different
    /// civil day than the parse. Same zone in, same zone out.
    nonisolated static func date(from key: String) -> Date? {
        if let d = formatter.date(from: key) { return d }
        guard let noon = hourFormatter.date(from: key + " 12") else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = hourFormatter.timeZone
        return cal.startOfDay(for: noon)
    }

    /// The hour the LOGICAL day rolls (04:00 local). Between midnight and this hour, "Today" stays put.
    nonisolated static let rolloverHour = 4

    /// The LOGICAL local day for `now` — the calendar date of `now − rolloverHour hours` (#144).
    /// Presentation-only: used solely to pick which stored row is Today; row keys are never rewritten.
    nonisolated static func logical(_ now: Date, rolloverHour: Int = rolloverHour) -> Date {
        now.addingTimeInterval(-Double(rolloverHour) * 3_600)
    }

    /// `yyyy-MM-dd` key for the logical day of `now` (see `logical`).
    nonisolated static func logicalKey(_ now: Date, rolloverHour: Int = rolloverHour) -> String {
        local(logical(now, rolloverHour: rolloverHour))
    }

    // MARK: - Editor day arithmetic
    //
    // Both of these belong to the SAME question, asked by every sheet that edits a timestamped
    // record: the user moved a date picker — did they move the record to another day, and did they
    // tell us a clock? They live here rather than on one editor because two editors now ask it
    // (`WeedSessionEditor` 009, `IntakeEventEditor` 024) and a second private copy is exactly the
    // drift this codebase avoids elsewhere ("two different ways to move through days in one app").

    /// `day` moved by the whole calendar days between `from` and `to`.
    ///
    /// The record's key is SHIFTED, never re-derived from the new timestamp: `DayKey.local(ts)` and
    /// the anchor key disagree across the 00:00-04:00 window, which is exactly where a late-evening
    /// record's clock lands, so a re-derive would let a record and the boolean it drives land on
    /// different days. An explicit date change is honoured; a minute nudge on a 01:00 record is not.
    ///
    /// Falls back to `day` unchanged when it has no local midnight to shift — the junk-key case, and
    /// the handful of zones whose DST springs forward AT midnight. Leaving a record on the key it
    /// already has is always the safe direction; the alternative fabricates one.
    nonisolated static func shifted(_ day: String, from: Date, to: Date) -> String {
        let cal = Calendar.current
        let delta = cal.dateComponents([.day], from: cal.startOfDay(for: from),
                                       to: cal.startOfDay(for: to)).day ?? 0
        guard delta != 0,
              let midnight = date(from: day),
              let moved = cal.date(byAdding: .day, value: delta, to: midnight) else { return day }
        return local(moved)
    }

    /// Whether two instants name the same wall-clock minute, whatever their dates. A date-only move
    /// leaves a declared-placeholder clock declared: we learned which day, not what time.
    nonisolated static func sameClock(_ a: Date, _ b: Date) -> Bool {
        let cal = Calendar.current
        let x = cal.dateComponents([.hour, .minute], from: a)
        let y = cal.dateComponents([.hour, .minute], from: b)
        return x.hour == y.hour && x.minute == y.minute
    }
}
