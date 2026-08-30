import Foundation
import StrapAnalytics

/// Descriptive counts for the Weed screen (009 F3). Pure — no clock, no store: `today` is injected
/// and every key is compared as a string, so previews and tests drive it directly.
///
/// DELIBERATELY NO STATISTICS. Effect analysis reuses the existing shared journal family
/// (`JournalInsightsModel`) unchanged — weed already ranks there, against the same four outcomes,
/// behind the same n>=5 group gate and the same Benjamini-Hochberg correction across the whole
/// behavior x outcome family. Splitting weed into a family of its own would make its q-values LOOSER
/// on identical data, which is the exact stargazing that pipeline exists to prevent. Everything here
/// is a count of what was logged, never a claim about effect.
struct WeedPattern: Equatable {
    /// Sessions — not days — in the trailing window ending `today`. A day with four sessions
    /// contributes four; a legacy chip-only day contributes zero, because we genuinely don't know.
    let sessions30d: Int
    /// Weed DAYS in the same trailing window, off the boolean, so a legacy chip-only day counts.
    let loggedDays30d: Int
    /// Days from the newest weed day back to `today`, or nil when the caller's window holds none.
    ///
    /// Measured off the BOOLEAN, not the newest session row: the boolean is the truth and a chip-only
    /// day is a real weed day. Every session day is a weed day by projection, so this is never later
    /// than the newest session. The screen renders "120+" — from `WeedStore.latestSession` — when
    /// this is nil but a session exists outside the window. nil is absence, never a fabricated 0.
    let daysSinceLast: Int?
    /// Longest run of consecutive COVERED days carrying no weed boolean (see `compute`).
    let longestFreeRun: Int
    /// Days in the caller's window the app has a `DailyMetric` row for.
    let coveredDays: Int
    /// Weed days AMONG those covered days — the numerator `isHabitual` compares. Restricted to
    /// covered days so the share can never exceed 1.
    let loggedCoveredDays: Int

    /// The trailing window the "/30 d" counts are taken over.
    static let windowDays = 30

    /// Share of covered days at which weed stops being a distinguishable event and becomes part of
    /// the baseline.
    static let habitualShare = 0.8

    /// Whether weed is logged on most of the nights there is data for.
    ///
    /// DISPLAY ONLY — one caption on the Weed screen saying the baseline already includes it. It is
    /// deliberately not a score input: the share crosses this threshold with zero user action, so
    /// gating the confounder on it would be a time-varying, non-local input that silently rewrites
    /// banked `strain_level` on the next pass (009 Not-in-this-wave). Gated on
    /// `Baselines.minNightsTrust` for the same reason every other baseline claim is — under 14
    /// covered days the share is noise.
    var isHabitual: Bool {
        coveredDays >= Baselines.minNightsTrust
            && Double(loggedCoveredDays) >= Self.habitualShare * Double(coveredDays)
    }

    /// - Parameters:
    ///   - weedDays: day keys whose merged journal boolean is YES — the single truth for whether a
    ///     day is a weed day.
    ///   - sessionsByDay: sessions per day. DETAIL only: never consulted for whether a day counts,
    ///     only for how many sessions it holds.
    ///   - coveredDays: day keys the app has a `DailyMetric` row for. This is the honest resolution
    ///     of the absence problem — `tagsByDay` cannot tell "logged no" from "logged nothing" (a
    ///     false row exists only where the user explicitly toggled OFF), so a run is counted over the
    ///     days there is evidence for. A no-data day is simply absent from this list, so it neither
    ///     BREAKS nor EXTENDS a run, and the screen's caption says so.
    ///   - today: the anchor day key. Keys after it are dropped everywhere below: the daily read
    ///     window admits rows keyed up to TOMORROW (#547 tz-ahead import / clock skew), and a future
    ///     covered day would extend a free run by a night that has not happened.
    static func compute(weedDays: Set<String>, sessionsByDay: [String: [WeedSession]],
                        coveredDays: [String], today: String) -> WeedPattern {
        // Fixed-UTC stepping (`ScoreEngine.shiftDay`), the same arithmetic the insights family joins
        // on, so the window bound is timezone-free and exact across month/year/leap boundaries.
        let windowStart = ScoreEngine.shiftDay(today, by: -(windowDays - 1)) ?? today
        var sessions = 0
        for (day, list) in sessionsByDay where day >= windowStart && day <= today {
            sessions += list.count
        }
        let logged = weedDays.filter { $0 >= windowStart && $0 <= today }.count

        let since = weedDays.filter { $0 <= today }.max().flatMap { daysBetween($0, today) }

        // De-duplicated and sorted: a repeated key would double-count a run, and the run is defined
        // over the covered days IN ORDER.
        let covered = Set(coveredDays).filter { $0 <= today }.sorted()
        var run = 0
        var longest = 0
        for day in covered {
            if weedDays.contains(day) { run = 0 } else { run += 1; longest = max(longest, run) }
        }
        let loggedCovered = covered.filter { weedDays.contains($0) }.count

        return WeedPattern(sessions30d: sessions, loggedDays30d: logged, daysSinceLast: since,
                           longestFreeRun: longest, coveredDays: covered.count,
                           loggedCoveredDays: loggedCovered)
    }

    /// Calendar days from `from` to `to`, both `yyyy-MM-dd`, or nil if either doesn't parse.
    ///
    /// The counting complement to `ScoreEngine.shiftDay`: the app has day STEPPERS (three of them, a
    /// module boundary apart) and no day COUNTER over two keys — `JournalStore.daysBack` counts from
    /// a `Date`, which this pure type deliberately has none of. Fixed-UTC with the same parse and
    /// validity checks as the stepper, so the two agree on which keys are junk, and exact across the
    /// 23/25-hour DST days an 86_400 s subtraction gets wrong by one.
    private static func daysBetween(_ from: String, _ to: String) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let a = utcMidnight(from, cal), let b = utcMidnight(to, cal) else { return nil }
        return cal.dateComponents([.day], from: a, to: b).day
    }

    private static func utcMidnight(_ day: String, _ cal: Calendar) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1 else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        return cal.date(from: comps)
    }
}
