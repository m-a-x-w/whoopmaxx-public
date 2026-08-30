import Foundation

/// Whether a night's RAW 1 Hz signal is still on disk — the one thing the Rest screen has to know before
/// it renders an absence as a finding (014 decision 5).
///
/// `sleepSession`, `dailyMetric` and `metricSeries` are the durable record and are never pruned, so a
/// night from March still re-renders its score, its duration, its hypnogram and its regularity. The raw
/// streams behind the OTHER two Rest clusters do not: `SampleRetention` sweeps `hrSample` /
/// `gravitySample` and their siblings at `retentionDays`, and the arousal ledger and the wrist-orientation
/// tape are derived from exactly those. Past the horizon they have nothing to read — and an empty ledger
/// renders as "Slept through — no awakenings over 2 minutes" while an empty tape renders as no section at
/// all. The first is a claim nothing measured; the second silently drops a lane that used to be there.
///
/// This is the ONE place the horizon is stated for the UI, and it is stated in terms of
/// `SampleRetention.retentionDays` — never a literal 28 — so moving the retention window moves the copy
/// and the gate together.
enum RawHorizon {

    /// True when the night keyed `dayKey` starts strictly BEFORE the oldest local day the sweep keeps.
    ///
    /// The boundary is `SampleRetention.sweep`'s own, to the day: `keepFrom = today − retentionDays`, and
    /// a day is prunable only when it starts strictly before that (`SampleRetention.swift:205`,
    /// `SampleRetentionTests.testPrunesScoredDaysPastTheHorizonAndKeepsTheBoundaryDay`). So the day
    /// exactly `retentionDays` back is INSIDE, and the one after it is the first that is out. Stepped with
    /// `date(byAdding: .day:)` rather than 86 400 s for the same reason the sweep is: the 23- and 25-hour
    /// DST days are not 86 400 s, and the two must agree on which day they mean.
    ///
    /// Deliberately DAY-grained, like the sweep — and deliberately NOT sufficient on its own. A night
    /// keyed D spans the evening of D−1, so a boundary night can lose its first hours a day before the
    /// rest; and the sweep's scored-day gate HOLDS an unscored day's samples all the way to `hardCapDays`,
    /// so a 40-day-old night can still be sitting on its raw. Both callers therefore pair this with a
    /// corroborating read of the night's own streams (`capture == nil` / `night == nil`), so the aged-out
    /// line is only ever printed over a window nothing was in fact read from.
    ///
    /// - Parameters:
    ///   - dayKey: the night's `yyyy-MM-dd` key (`DailyMetric.day`). nil or unparseable ⇒ false — an
    ///     unknown night gets today's behaviour rather than a claim about what is stored.
    ///   - now: injected by the tests; production takes the default.
    ///   - calendar: injected by the tests; production takes the device calendar, the zone `DayKey` parses
    ///     the key in.
    static func hasAgedOut(dayKey: String?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let dayKey, let day = DayKey.date(from: dayKey) else { return false }
        guard let keepFrom = calendar.date(byAdding: .day, value: -SampleRetention.retentionDays,
                                           to: calendar.startOfDay(for: now))
        else { return false }
        return day < keepFrom
    }
}
