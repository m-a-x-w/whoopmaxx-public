import Foundation
import StrapStore

/// The Sleep Regularity Index (011 W2.1): how often you were in the SAME state — asleep or awake — at
/// the same clock minute on two CONSECUTIVE days, pooled over a trailing window.
///
/// Built on `sleepSession(startTs, endTs)` and on nothing else, because the two obvious inputs are not
/// there: `sleepStateSample` holds 0 rows in both real stores (`SampleRetention.swift:88-95` records it
/// as empty on WHOOP 4.0) and `sleepSession.sleepStateJSON` is NULL on every session in the newer store.
/// Session BOUNDS are the durable record — `SampleRetention.swift:48-50` never prunes them — so the
/// index stays computable for as far back as the user has nights, long after the raw streams behind
/// those nights have aged out.
///
/// **Method.** A local minute-of-day matrix, 1440 slots per day, NAPS INCLUDED — the index is over
/// sleep/wake state, not over "the main night". Each day is walked with `Calendar` rather than by
/// stepping 86 400 s, so a 23 h spring-forward day simply has 60 slots that never occur and a 25 h
/// fall-back day has 60 that occur twice; both kinds are marked UNAVAILABLE and dropped from the
/// comparison rather than fabricated. A day is usable only when its `DailyMetric.totalSleepMin` is
/// non-nil, and a pair needs BOTH of its days usable, so the day the strap missed takes its two pairs
/// with it instead of scoring them as a night spent awake. SRI = 200 × (agreeing minute-pairs ÷
/// compared minute-pairs) − 100, pooled over the window's consecutive usable pairs and withheld
/// entirely under `minimumPairs` (011 decision 4 — an em-dash with a reason beats a plausible number).
///
/// **READ-ONLY** (011 decision 2). Nothing here reaches `AnalyticsEngine`: the Rest composite's
/// consistency term is still `VitalityEngine.sleepConsistency`'s duration CV (`ScoreEngine.swift:391`),
/// no Charge/Effort/Rest score moves, and no historical value changes. Swapping this in for that term
/// is a separate, deliberate change with a full rescore.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string this type produces — *thermoregulation, vasodilation,
/// impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should", "talk
/// to"*.
enum SleepRegularity {

    // MARK: - Constants

    /// Local minute-of-day slots in an ordinary day.
    static let slotsPerDay = 1440

    /// Nights a reading looks back over. Fourteen is the canonical SRI window: long enough that a
    /// single odd night cannot swing it, short enough that it still describes the CURRENT pattern
    /// rather than a quarter-long average that never moves.
    static let defaultWindowDays = 14

    /// Comparable night-to-night pairs below which there is no number to print. The window can hold at
    /// most `defaultWindowDays − 1`, so this is a little over half a full window.
    static let minimumPairs = 7

    /// Hard ceiling on the days one span walks, so a malformed key range can never loop forever.
    private static let maxSpanDays = 400

    /// The calendar every derivation walks by default: GREGORIAN, in the device's zone. Deliberately
    /// NOT `Calendar.current` — under a Buddhist/Japanese region that calendar's `year` component is an
    /// era year, and keys built from it would not be the `yyyy-MM-dd` `DailyMetric.day` is stored under.
    static var deviceCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    // MARK: - Values

    /// One night-to-night comparison: the later day it is filed under, and the minute counts behind it.
    struct Pair: Equatable {
        /// `yyyy-MM-dd` of the LATER of the two days.
        let dayKey: String
        /// Minute slots where both days were in the same state.
        let agreeing: Int
        /// Minute slots that existed unambiguously on BOTH days — 1440 away from a DST boundary, 1380
        /// against one.
        let compared: Int

        /// This pair's own value on the index scale.
        var sri: Double { SleepRegularity.index(agreeing: agreeing, compared: compared) }
    }

    /// The window's reading.
    struct Reading: Equatable {
        /// Pooled index over `pairs`: 100 = the same state at every compared minute of every pair.
        let sri: Double
        /// Every comparison in the window, oldest → newest — one thin bar each.
        let pairs: [Pair]
        /// Nights in the window that carried a banked total (i.e. cleared the usability gate).
        let nightsUsable: Int
        /// Nights in the window at all.
        let nightsConsidered: Int

        /// The index restated as the share of the day's minutes that agreed, 0…1.
        var agreementFraction: Double { (sri + 100) / 200 }
    }

    /// What the window has to say. There is deliberately no "empty" case: a window holding no usable
    /// night at all returns `nil` from `analyze`, and nothing is drawn — an eyebrow over an em-dash
    /// would assert that the section has something to say about nights that were never recorded.
    enum Outcome: Equatable {
        case reading(Reading)
        /// Usable nights exist, but the window holds fewer than `minimumPairs` comparisons.
        case calibrating(pairs: Int, needed: Int)
    }

    // MARK: - The index

    /// 200 × agreement − 100, so 100 is the same state at every compared minute and 0 is agreement on
    /// half of them. Zero compared minutes has no index at all; callers gate before they ask.
    static func index(agreeing: Int, compared: Int) -> Double {
        guard compared > 0 else { return 0 }
        return 200 * Double(agreeing) / Double(compared) - 100
    }

    // MARK: - Entry points

    /// The Rest screen's reading: the trailing `windowDays` ending on `endKey` (nil = the newest day in
    /// `days` that carries a banked night, so "Regularity" ends where "Last night" does).
    ///
    /// nil when there is nothing measured to describe — no usable night in the window, a day range that
    /// will not resolve, or a window this CALLER cannot vouch for (see `recordFloor`).
    ///
    /// - Parameter daysReachRecordStart: whether `days` BEGINS at the start of the user's record, as
    ///   opposed to at the edge of a bounded cache.
    ///
    ///   `days` is normally `repo.days`, the trailing 120-day publish window, whose oldest entry is
    ///   indistinguishable from the start of the user's history. A window clamped to it therefore means
    ///   either "the record begins here" or "the cache does", and those demand opposite answers.
    ///   Getting it wrong is not a rounding error: a night 112 days back printed "Calibrating — 2 of 7
    ///   night-to-night comparisons so far" over a night with thirteen fully recorded predecessors,
    ///   asserting a limitation of the record that does not exist. Harmless while Rest only ever read
    ///   the newest night, whose window sits ~106 days clear of the floor; 014 made every cached night
    ///   reachable and nothing told this function which floor it had hit.
    ///
    ///   A Bool rather than the floor's own key deliberately: the caller states the FACT it can vouch
    ///   for, and a comparison that could be written backwards lives in one place instead of here.
    static func analyze(days: [DailyMetric], sleeps: [CachedSleepSession],
                        endKey: String? = nil,
                        windowDays: Int = defaultWindowDays,
                        now: Date = Date(),
                        calendar: Calendar = deviceCalendar,
                        daysReachRecordStart: Bool) -> Outcome? {
        guard windowDays >= 2 else { return nil }
        guard let end = endKey ?? days.last(where: { $0.totalSleepMin != nil })?.day,
              let oldest = days.map(\.day).min(),
              let windowStart = shift(end, by: -(windowDays - 1), calendar: calendar),
              let span = buildSpan(days: days, sleeps: sleeps,
                                   from: Swift.max(windowStart, oldest), to: end,
                                   now: Int(now.timeIntervalSince1970),
                                   calendar: calendar) else { return nil }
        // The window was CLAMPED — it wanted nights older than the array holds. That is honest only if
        // the array reaches the start of the record; otherwise the missing nights exist and we simply
        // were not given them, and every outcome below would misdescribe the user's history. Say
        // nothing rather than report a short window as a 14-night index, or a truncation as calibration.
        if windowStart < oldest, !daysReachRecordStart { return nil }
        let usable = span.usable.filter { $0 }.count
        guard usable > 0 else { return nil }
        let pairs = span.pairs.compactMap { $0 }
        guard pairs.count >= minimumPairs else {
            return .calibrating(pairs: pairs.count, needed: minimumPairs)
        }
        let agreeing = pairs.reduce(0) { $0 + $1.agreeing }
        let compared = pairs.reduce(0) { $0 + $1.compared }
        guard compared > 0 else { return .calibrating(pairs: 0, needed: minimumPairs) }
        return .reading(Reading(sri: index(agreeing: agreeing, compared: compared),
                                pairs: pairs,
                                nightsUsable: usable,
                                nightsConsidered: span.dayKeys.count))
    }

    /// The persisted `sleep_regularity` series: the SAME rolling reading evaluated on each of
    /// `dayKeys`, keyed by day. One span is walked for all of them, so the per-day cost is the
    /// window's ≤ 13 additions rather than a fresh 14-day matrix each time.
    ///
    /// A day whose window holds fewer than `minimumPairs` comparisons is simply ABSENT from the result
    /// — never a zero, which would chart as perfect coin-flip irregularity.
    static func series(days: [DailyMetric], sleeps: [CachedSleepSession],
                       dayKeys: [String],
                       windowDays: Int = defaultWindowDays,
                       now: Date = Date(),
                       calendar: Calendar = deviceCalendar) -> [String: Double] {
        guard windowDays >= 2,
              let newest = dayKeys.max(), let requested = dayKeys.min(),
              let oldest = days.map(\.day).min(),
              let windowStart = shift(requested, by: -(windowDays - 1), calendar: calendar),
              let span = buildSpan(days: days, sleeps: sleeps,
                                   from: Swift.max(windowStart, oldest), to: newest,
                                   now: Int(now.timeIntervalSince1970),
                                   calendar: calendar) else { return [:] }
        var indexOfDay: [String: Int] = [:]
        for (i, k) in span.dayKeys.enumerated() { indexOfDay[k] = i }

        var out: [String: Double] = [:]
        for key in dayKeys {
            guard let t = indexOfDay[key], t >= 1 else { continue }
            var agreeing = 0, compared = 0, n = 0
            // `windowDays − 1` pair indices ending at `t`, NOT `windowDays`. `pairs[i]` compares day
            // `i−1` with day `i`, so summing `windowDays` of them would reach back to day `t − windowDays`
            // and pool a 15-night window against `analyze`'s 14 — the two surfaces would then print
            // different numbers for the same day, the Rest hero disagreeing with the Data tab.
            for i in Swift.max(1, t - windowDays + 2)...t {
                guard let p = span.pairs[i] else { continue }
                agreeing += p.agreeing; compared += p.compared; n += 1
            }
            guard n >= minimumPairs, compared > 0 else { continue }
            out[key] = index(agreeing: agreeing, compared: compared)
        }
        return out
    }

    // MARK: - The walked span

    /// One stretch of consecutive local days: the keys, which of them cleared the usability gate, and
    /// the pair at each index (`pairs[i]` compares day `i−1` with day `i`, so `pairs[0]` is always nil,
    /// and so is any pair whose two days were not BOTH usable).
    private struct Span {
        let dayKeys: [String]
        let usable: [Bool]
        let pairs: [Pair?]
    }

    /// Walk `[startKey, endKey]` a calendar day at a time, gridding each day and comparing it with the
    /// one before. Only the PREVIOUS day's grid is held, so the walk costs one day of memory however
    /// long the span is.
    private static func buildSpan(days: [DailyMetric], sleeps: [CachedSleepSession],
                                  from startKey: String, to endKey: String,
                                  now: Int, calendar: Calendar) -> Span? {
        guard startKey <= endKey, let startDate = dayStart(startKey, calendar: calendar) else { return nil }
        var usableKeys: Set<String> = []
        for d in days where d.totalSleepMin != nil { usableKeys.insert(d.day) }
        let intervals = mergedIntervals(sleeps)

        var dayKeys: [String] = []
        var usable: [Bool] = []
        var pairs: [Pair?] = []
        var cursor = startDate
        var previous: DayGrid?
        // Monotonic pointer into `intervals`: `t` only ever moves forward across the whole walk, so the
        // sweep is O(minutes + intervals) rather than a search per minute.
        var intervalCursor = 0

        while dayKeys.count < maxSpanDays {
            let dayKey = key(cursor, calendar: calendar)
            guard dayKey <= endKey else { break }
            // The NEXT day's true start, not this one's wall clock plus 24 h. On a spring-forward-at-
            // midnight date `cursor` is 01:00, and `+1 day` would land on 01:00 tomorrow — running the
            // grid an hour past the date it is labelling and into the next one.
            guard let nextCursor = calendar.date(byAdding: .day, value: 1, to: cursor)
                .map({ calendar.startOfDay(for: $0) }) else { break }
            let dayGrid = grid(dayStart: cursor, nextStart: nextCursor, now: now, calendar: calendar,
                               intervals: intervals, intervalCursor: &intervalCursor)
            let isUsable = usableKeys.contains(dayKey)
            if let previous, usable.last == true, isUsable {
                pairs.append(pair(dayKey: dayKey, earlier: previous, later: dayGrid))
            } else {
                pairs.append(nil)
            }
            dayKeys.append(dayKey)
            usable.append(isUsable)
            previous = dayGrid
            cursor = nextCursor
        }
        guard !dayKeys.isEmpty else { return nil }
        return Span(dayKeys: dayKeys, usable: usable, pairs: pairs)
    }

    /// Compare two days over the slots that unambiguously existed on both. nil when nothing did.
    private static func pair(dayKey: String, earlier: DayGrid, later: DayGrid) -> Pair? {
        var agreeing = 0, compared = 0
        for m in 0..<slotsPerDay where earlier.available[m] && later.available[m] {
            compared += 1
            if earlier.asleep[m] == later.asleep[m] { agreeing += 1 }
        }
        guard compared > 0 else { return nil }
        return Pair(dayKey: dayKey, agreeing: agreeing, compared: compared)
    }

    // MARK: - One day's minute grid

    /// A day as 1440 local minute-of-day slots: was it sleep, and did that minute exist exactly once.
    private struct DayGrid {
        var asleep: [Bool]
        var available: [Bool]
    }

    /// Grid `dayStart`'s local day against the merged sleep intervals.
    ///
    /// The walk is over REAL minutes from local midnight to the next local midnight, and each one is
    /// mapped to the wall-clock slot it carries. That is what makes the DST cases honest without a
    /// special case for either: on a 23 h day the walk emits 1380 minutes whose slots skip the hour
    /// that never happened, leaving those 60 unavailable; on a 25 h day it emits 1500 whose slots
    /// revisit an hour, and a revisited slot is marked unavailable because which of the two passes a
    /// sleep belongs to is not knowable from a bare timestamp.
    private static func grid(dayStart: Date, nextStart: Date, now: Int, calendar: Calendar,
                             intervals: [(start: Int, end: Int)],
                             intervalCursor: inout Int) -> DayGrid {
        var asleep = [Bool](repeating: false, count: slotsPerDay)
        var available = [Bool](repeating: false, count: slotsPerDay)
        var seen = [Bool](repeating: false, count: slotsPerDay)
        let s0 = Int(dayStart.timeIntervalSince1970)
        let s1 = Int(nextStart.timeIntervalSince1970)
        let zone = calendar.timeZone
        let off0 = zone.secondsFromGMT(for: dayStart)
        // FAST PATH: an ordinary 24 h day that genuinely BEGINS at midnight maps slot m straight to
        // s0 + m·60. The `startSlot == 0` term is load-bearing: in the zones that spring forward AT
        // midnight (America/Havana, America/Santiago, Africa/Cairo, Asia/Beirut, Atlantic/Azores)
        // local 00:00 does not exist on the transition date, so `dayStart` is 01:00 and the elapsed
        // span to the next midnight is still exactly 24 h — the old test passed, took this path, and
        // labelled 01:00 as slot 0, shifting the entire day an hour early and spilling its last hour
        // into the next date.
        let startSlot = slotOfDay(s0, calendar: calendar)
        let uniform = (s1 - s0) == slotsPerDay * 60 && startSlot == 0
            && zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s1 - 1))) == off0
        let minutes = Swift.max(0, (s1 - s0) / 60)

        for n in 0..<minutes {
            let t = s0 + n * 60
            // A minute that has not happened yet is not a measured minute of wakefulness. Without
            // this the newest day grids as awake from `now` to midnight, and today's pair reports a
            // night the user has not lived through — the same treatment the missing DST hour gets.
            guard t < now else { break }
            let slot = uniform ? n : slotOfDay(t, calendar: calendar)
            guard slot >= 0, slot < slotsPerDay else { continue }
            if seen[slot] { available[slot] = false; continue }   // the repeated hour of a 25 h day
            seen[slot] = true
            available[slot] = true
            while intervalCursor < intervals.count && intervals[intervalCursor].end <= t { intervalCursor += 1 }
            if intervalCursor < intervals.count && intervals[intervalCursor].start <= t { asleep[slot] = true }
        }
        return DayGrid(asleep: asleep, available: available)
    }

    /// The wall-clock minute-of-day an instant carries, 0…1439 — asked of the calendar rather than
    /// derived from an offset, so it is right on both DST days and in every zone.
    private static func slotOfDay(_ t: Int, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(t)))
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Sleep sessions folded into sorted, non-overlapping `[start, end)` second ranges — NAPS AND ALL,
    /// because the index is over sleep/wake state and a nap is sleep. Reads `effectiveStartTs`, the
    /// same onset every other read-side surface resolves.
    private static func mergedIntervals(_ sleeps: [CachedSleepSession]) -> [(start: Int, end: Int)] {
        let raw = sleeps
            .filter { $0.endTs > $0.effectiveStartTs }
            .map { (start: $0.effectiveStartTs, end: $0.endTs) }
            .sorted { $0.start < $1.start }
        var out: [(start: Int, end: Int)] = []
        for r in raw {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1].end = Swift.max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: - Zone-explicit day keys
    //
    // `DayKey` resolves its zone once into a shared formatter, which is right for the app and wrong for
    // a test that has to drive a specific DST transition. These are the same rules, taking their zone
    // from the injected calendar.

    /// The local FIRST INSTANT of a `yyyy-MM-dd` key in `calendar`'s zone. Parses noon and snaps back —
    /// the trick `DayKey.date(from:)` documents, because in the zones whose DST springs forward at
    /// midnight local 00:00 does not exist at all.
    static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        guard let noon = calendar.date(from: c) else { return nil }
        return calendar.startOfDay(for: noon)
    }

    /// `yyyy-MM-dd` for `date` in `calendar`'s zone. Built from components rather than a
    /// `DateFormatter` so it costs nothing per day of a long walk.
    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2)
    }

    /// `key` moved by `delta` calendar days — DST-safe, because the step is a day and never 86 400 s.
    static func shift(_ key: String, by delta: Int, calendar: Calendar) -> String? {
        guard let start = dayStart(key, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: delta, to: start) else { return nil }
        return self.key(moved, calendar: calendar)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

// MARK: - Copy

extension SleepRegularity.Outcome {

    /// The hero numeral. An em-dash while calibrating: a partial window has no index, and 011
    /// decision 4 is that an honest refusal beats a plausible-looking value.
    var numeral: String {
        switch self {
        case .reading(let r):
            let v = Int(r.sri.rounded())
            return v < 0 ? "\u{2212}\(abs(v))" : "\(v)"
        case .calibrating:
            return "\u{2014}"
        }
    }

    /// The line under the numeral — what was measured, in the user's own terms.
    ///
    /// `isNewest` moves the TENSE with the browse (014). Every other number on Rest is re-derived as of
    /// the selected night, and so is this one — but its WORDS were not: "so far" means "up to now",
    /// which is a claim about today printed under a night in March. Regularity was the last section on
    /// the screen whose copy still assumed it described the present.
    func summaryLine(isNewest: Bool) -> String {
        switch self {
        case .reading(let r):
            let pct = Int((r.agreementFraction * 100).rounded())
            return isNewest
                ? "Your sleep and wake times matched the night before across \(pct)% of the day's minutes."
                : "Sleep and wake times matched the night before across \(pct)% of that day's minutes."
        case .calibrating(let pairs, let needed):
            return isNewest
                ? "Calibrating \u{2014} \(pairs) of \(needed) night-to-night comparisons so far."
                : "Only \(pairs) of \(needed) night-to-night comparisons in the nights up to it."
        }
    }

    /// The closing footnote: how much of the window was actually comparable, and the two rules that
    /// decided it. nil while calibrating, where `summaryLine` already carries the count.
    var detailLine: String? {
        guard case .reading(let r) = self else { return nil }
        return "\(r.nightsUsable) of \(r.nightsConsidered) nights compared. "
            + "Naps count; a night with no banked sleep is left out."
    }
}
