import Foundation

/// Strap capture-health primitives (007 F4, pure). The strap trims acked history and never
/// re-sends, so a capture gap is a PERMANENT fact in the store — gap scanning is a read-side
/// computation over banked HR timestamps, never a re-sync trigger.
enum GapScan {

    /// An HR silence longer than this, while not off-wrist, is a reported capture gap. 15 min is
    /// far past any legitimate banked-HR cadence, so a gap here means the strap genuinely wasn't
    /// capturing (dead battery, left on the charger, BLE lost mid-wear).
    static let gapThresholdS: Int = 15 * 60

    /// The local waking window the coverage fraction weighs (08:00–22:00). Overnight silences are
    /// dominated by legitimate non-wear/charging habits, so day coverage grades only the hours the
    /// user plausibly expects capture.
    static let wakingStartHour: Int = 8
    static let wakingEndHour: Int = 22

    /// One capture gap: a `[start, end)` unix-seconds interval with HR silence while worn.
    struct Gap: Equatable {
        let start: Int
        let end: Int
        var durationS: Int { end - start }
    }

    /// One day's capture health: worn-waking coverage fraction + the reported gaps.
    struct DayCoverage: Equatable {
        /// 0–1 fraction of the worn waking window that was covered by HR capture (1 − gap share).
        /// 0 when the day had no worn waking time at all.
        let coverage: Double
        /// The >15-min worn HR silences, clipped to the waking window, oldest first.
        let gaps: [Gap]
    }

    /// Scan one local calendar day's banked HR timestamps for capture gaps.
    ///
    /// - Parameters:
    ///   - dayKey: "yyyy-MM-dd" local day (same keyer as dailyMetric rows).
    ///   - hrTimestamps: banked HR sample timestamps (unix seconds); any order, any surplus
    ///     outside the day is ignored.
    ///   - offWrist: paired off-wrist `[start, end)` intervals (from
    ///     `DayEngine.offWristIntervals`) — silence while off-wrist is expected, not a gap.
    ///   - offsetSec: seconds east of UTC for the local day bounds.
    ///   - clampEnd: optional hard end (e.g. "now" for today) so the still-unwritten remainder of
    ///     the current day never reads as a gap.
    static func dayCoverage(dayKey: String, hrTimestamps: [Int],
                            offWrist: [(start: Int, end: Int)],
                            offsetSec: Int = TimeZone.current.secondsFromGMT(),
                            clampEnd: Int? = nil,
                            clampStart: Int? = nil) -> DayCoverage {
        guard let dayStart = localDayStart(dayKey, offsetSec: offsetSec) else {
            return DayCoverage(coverage: 0, gaps: [])
        }
        // `clampStart` is the symmetric twin of `clampEnd`: the earliest instant this store has ANY data
        // for. Without it the waking window always opens at 08:00, so a store whose first sample landed at
        // 15:00 — a fresh install paired mid-afternoon — is graded over seven hours that could not have
        // been captured, and reported as a multi-hour "gap while worn". Days entirely before the floor
        // collapse to a zero-width window and return no coverage and no gaps at all.
        var wStart = dayStart + wakingStartHour * 3_600
        var wEnd = dayStart + wakingEndHour * 3_600
        if let clampEnd { wEnd = Swift.min(wEnd, clampEnd) }
        if let clampStart { wStart = Swift.max(wStart, clampStart) }
        guard wEnd > wStart else { return DayCoverage(coverage: 0, gaps: []) }

        // HR silences inside the window: spans between consecutive samples (window edges count as
        // marks needing a sample within threshold) longer than the gap threshold.
        let marks = hrTimestamps.filter { $0 >= wStart - gapThresholdS && $0 <= wEnd }.sorted()
        var silences: [(start: Int, end: Int)] = []
        var prev = wStart
        for t in marks {
            if t - prev > gapThresholdS { silences.append((start: prev, end: t)) }
            prev = Swift.max(prev, t)
        }
        if wEnd - prev > gapThresholdS { silences.append((start: prev, end: wEnd)) }

        // Off-wrist time explains silence away: subtract it from each silence, and report only the
        // WORN remainders still longer than the threshold as genuine capture gaps.
        var gaps: [Gap] = []
        for s in silences {
            for r in subtract((Swift.max(s.start, wStart), Swift.min(s.end, wEnd)), offWrist)
            where r.1 - r.0 > gapThresholdS {
                gaps.append(Gap(start: r.0, end: r.1))
            }
        }

        // Coverage = 1 − (gap share of the WORN waking window). Off-wrist time is out of scope on
        // both sides — a fully off-wrist day has no worn window and grades 0 (nothing captured).
        let windowS = wEnd - wStart
        let offS = offWrist.reduce(0) { acc, o in
            acc + Swift.max(0, Swift.min(o.end, wEnd) - Swift.max(o.start, wStart))
        }
        let wornS = windowS - offS
        guard wornS > 0 else { return DayCoverage(coverage: 0, gaps: gaps) }
        let gapS = gaps.reduce(0) { $0 + $1.durationS }
        let coverage = Swift.max(0.0, Swift.min(1.0, 1.0 - Double(gapS) / Double(wornS)))
        return DayCoverage(coverage: coverage, gaps: gaps)
    }

    /// True when `clampEnd` (e.g. "now" for today) sits at/before the day's waking-window start —
    /// the graded 08:00–22:00 window HASN'T BEGUN, which is a different fact from a genuinely
    /// uncovered day. Callers should render "window not started" (nil coverage), never 0 %.
    static func windowNotStarted(dayKey: String,
                                 offsetSec: Int = TimeZone.current.secondsFromGMT(),
                                 clampEnd: Int) -> Bool {
        guard let dayStart = localDayStart(dayKey, offsetSec: offsetSec) else { return false }
        return clampEnd <= dayStart + wakingStartHour * 3_600
    }

    /// Unix seconds of local midnight for a "yyyy-MM-dd" key: the inverse of
    /// `DayEngine.dayString(_:offsetSec:)` (UTC-parse the key, then shift west by the local
    /// offset). Nil for an unparseable key.
    static func localDayStart(_ dayKey: String, offsetSec: Int) -> Int? {
        let parts = dayKey.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let utcMidnight = cal.date(from: comps) else { return nil }
        return Int(utcMidnight.timeIntervalSince1970) - offsetSec
    }

    /// Subtract a set of `[start, end)` intervals from one interval, returning the ordered
    /// remainders. Intervals need not be sorted or disjoint.
    private static func subtract(_ interval: (Int, Int),
                                 _ minus: [(start: Int, end: Int)]) -> [(Int, Int)] {
        var remainders: [(Int, Int)] = [interval]
        for m in minus.sorted(by: { $0.start < $1.start }) {
            var next: [(Int, Int)] = []
            for r in remainders {
                if m.end <= r.0 || m.start >= r.1 {           // no overlap
                    next.append(r)
                } else {
                    if m.start > r.0 { next.append((r.0, m.start)) }
                    if m.end < r.1 { next.append((m.end, r.1)) }
                }
            }
            remainders = next
        }
        return remainders.filter { $0.1 > $0.0 }
    }
}
