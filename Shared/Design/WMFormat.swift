import Foundation

/// The value-formatting primitives that were genuinely duplicated across screens — clock-style
/// durations, spoken durations, a clock-hour label, and a time-of-day stamp. Lives in `Shared/` so
/// the widget extension gets the same strings as the app.
///
/// SCOPE, deliberately narrow. Only shapes that were BYTE-IDENTICAL in two or more places moved here.
/// Formatters that merely LOOK alike stayed where they were, because they are different functions:
///   • `hmm` has two entry points, not one — the Rest screens pass MINUTES and clamp negatives to
///     zero; the Data catalogue passes DECIMAL HOURS and takes `abs()` (it renders the sign itself).
///     Collapsing them would silently mis-scale one caller by 60×.
///   • `duration` has two SPELLINGS, not one — workout rows read "1 h 12 min", strap-health gap rows
///     read "2h 35m". Both are shipped copy; `DurationStyle` keeps them apart instead of picking one.
///   • Arousal rows' "35 min" (`ArousalForensicsSection.durationLabel`, which floors at 1 min) is a
///     third spelling and stays local — one caller, no duplication to remove.
///
/// Day-key formatting (`yyyy-MM-dd`) is NOT here — `Core/Data/DayKey.swift` owns it.
enum WMFormat {

    // MARK: - Clock-style duration ("h:mm")

    /// MINUTES → "h:mm" (432 → "7:12"). Negative input clamps to zero — the Rest screens' sleep
    /// totals, need, debt and nap credits are all non-negative magnitudes.
    static func hmm(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// DECIMAL HOURS → "h:mm" (7.2 → "7:12"). The sign is dropped (`abs`); callers that render deltas
    /// prepend their own "−", so folding a clamp in here instead would print "0:00" for every
    /// negative delta.
    static func hmm(hours: Double) -> String {
        let total = Int((abs(hours) * 60).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: - Spoken duration

    /// The two shipped duration spellings. Both are live copy — see the type doc.
    enum DurationStyle {
        /// "2h 35m" / "45m" — the tight gap-row / seismograph spelling.
        case compact
        /// "58 min" / "1 h 12 min" / "1 h" — the workout-row spelling (an exact hour drops the minutes).
        case spelled
    }

    /// Seconds → a minute-floored duration in the requested spelling. Negative input clamps to zero.
    static func duration(seconds: Int, style: DurationStyle) -> String {
        let m = max(0, seconds) / 60
        switch style {
        case .compact:
            return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
        case .spelled:
            if m < 60 { return "\(m) min" }
            let h = m / 60, rem = m % 60
            return rem == 0 ? "\(h) h" : "\(h) h \(rem) min"
        }
    }

    // MARK: - Clock hour

    /// Locale-aware HH:mm for a clock hour in [0, 24) — 23.5 → "23:30" (or "11:30 PM"). Wraps out-of-
    /// range hours and carries a rounded-up 60th minute into the next hour.
    static func clockLabel(_ hour: Double) -> String {
        var h = hour.truncatingRemainder(dividingBy: 24); if h < 0 { h += 24 }
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        var c = DateComponents(); c.hour = hh; c.minute = mm
        let d = Calendar.current.date(from: c) ?? Date()
        return d.formatted(.dateTime.hour().minute())
    }

    // MARK: - Time of day

    /// Locale-aware time-of-day in the DEVICE's zone — "13:05", or "1:05 PM" under a 12-hour locale.
    /// The formatter is built once; `DateFormatter` construction is expensive (the `DayKey.formatter`
    /// precedent).
    static func timeOfDay(_ date: Date) -> String {
        timeOfDayFormatter.string(from: date)
    }

    /// Same, from unix seconds.
    static func timeOfDay(_ unixSeconds: Int) -> String {
        timeOfDay(Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    /// Time-of-day rendered in an EXPLICIT zone — the arousal rows read the night's recorded zone, not
    /// the device's, so a night logged abroad still reads in local-at-the-time clock terms.
    ///
    /// Keyed by zone identifier rather than folded into the shared static above: the zone is injected
    /// per view instance, and mutating one shared formatter's `timeZone` per row would make the label
    /// depend on which row formatted last. The template is `j:mm` (the arousal rows' own), kept
    /// verbatim so no rendered string moves.
    static func timeOfDay(_ date: Date, in timeZone: TimeZone) -> String {
        zonedFormatter(for: timeZone).string(from: date)
    }

    // MARK: - Cached formatters

    private static let timeOfDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()

    private static let zonedLock = NSLock()
    private static var zonedFormatters: [String: DateFormatter] = [:]

    private static func zonedFormatter(for timeZone: TimeZone) -> DateFormatter {
        zonedLock.lock()
        defer { zonedLock.unlock() }
        if let cached = zonedFormatters[timeZone.identifier] { return cached }
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("j:mm")
        zonedFormatters[timeZone.identifier] = f
        return f
    }
}
