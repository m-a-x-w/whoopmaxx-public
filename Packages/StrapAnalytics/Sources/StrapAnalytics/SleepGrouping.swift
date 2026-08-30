import Foundation

/// Which of a day's sleep blocks are THE night.
///
/// A day can hold several sleep blocks — a night broken by a real awakening, an afternoon nap, a
/// morning doze. Exactly one group of them is the main sleep and the rest are naps, and every
/// consumer has to agree on which, or the same minutes get counted twice (once in the night total,
/// once as nap credit) or fall through both.
///
/// The circadian-alignment scoring and the circular-mean habitual midsleep are ported from
/// OpenStrap/analytics `segment.dart` (MIT).
public enum SleepGrouping {

    // MARK: - Constants

    /// Local hours the overnight band spans — 20:00 through 11:00.
    public static let overnightStartHour = 20
    public static let overnightEndHour = 11
    public static let secondsPerDay = 86_400

    /// Minutes of credit a block gets for starting near the user's habitual midsleep.
    ///
    /// It is added to the block's duration, so 90 minutes means timing can outweigh up to an hour
    /// and a half of extra length — enough for a well-placed 6-hour night to beat a badly-placed
    /// 7-hour one, not enough for a 20-minute nap to beat anything.
    public static let alignmentBonusMin: Double = 90.0
    /// Within this distance of the anchor the bonus is full; past `alignmentZeroSec` it is nothing.
    public static let alignmentFullWindowSec = 2 * 3600
    public static let alignmentZeroSec = 5 * 3600

    /// Wake gaps shorter than this always bridge. A brief awakening does not end a sleep period.
    public static let gapBridgeMaxMin = 60
    /// A longer gap still bridges when the later fragment STARTS in the overnight band — a real
    /// mid-night waking, not an isolated nap.
    public static let nightTailBridgeMaxMin = 90
    /// A later overnight fragment at least this long is the second half of a split night, however
    /// long the person was up between the halves.
    ///
    /// Keyed on the FRAGMENT'S own length, not on the gap. Widening the gap tier instead would
    /// swallow a genuine half-hour morning doze taken well after a complete night; a half-hour
    /// fragment can never clear this bar.
    public static let splitNightMinFragmentMin = 120
    /// Past about four hours awake the sleep period has genuinely ended, and the next block is a
    /// separate sleep no matter how long it runs.
    public static let splitNightBridgeMaxMin = 240

    /// Nights of history before a habitual midsleep is trusted. Roughly two weeks is the floor the
    /// sleep-timing literature uses for a stable midpoint.
    public static let habitualMinDays = 14

    // MARK: - Blocks

    /// One candidate sleep block. `start` is the effective onset — a wake-time edit moves the end,
    /// never the detected onset.
    public struct NightBlock: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationS: Int { max(0, end - start) }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    /// One past night, keyed to the local day it belongs to.
    public struct HistoryBlock: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let dayKey: String
        public init(start: Int, end: Int, dayKey: String) {
            self.start = start; self.end = end; self.dayKey = dayKey
        }
        public var durationS: Int { max(0, end - start) }
        public var midpointSec: Int { start + (end - start) / 2 }
    }

    // MARK: - Local clock

    public static func localSecOfDay(_ ts: Int, offsetSec: Int) -> Int {
        let local = ts + offsetSec
        return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay
    }

    /// Distance between two times of day the short way round the clock, so 23:30 and 00:30 are an
    /// hour apart rather than twenty-three.
    public static func circularDistanceSec(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b) % secondsPerDay
        return min(raw, secondsPerDay - raw)
    }

    /// Does this onset fall inside the overnight band?
    public static func isOvernightOnset(_ ts: Int, offsetSec: Int) -> Bool {
        let sec = localSecOfDay(ts, offsetSec: offsetSec)
        let start = overnightStartHour * 3600
        let end = overnightEndHour * 3600
        return sec >= start || sec < end          // the band wraps midnight
    }

    /// The cold-start anchor: the middle of the overnight band, used until enough history exists.
    public static var coldStartAnchorSec: Int {
        let span = ((overnightEndHour - overnightStartHour) * 3600 + secondsPerDay) % secondsPerDay
        return (overnightStartHour * 3600 + span / 2) % secondsPerDay
    }

    /// Credit for a block whose midpoint sits near the anchor: full inside the near window, fading
    /// linearly to nothing at the far one.
    public static func alignmentBonusMinutes(blockMidSec: Int, targetMidSec: Int) -> Double {
        let dist = circularDistanceSec(blockMidSec, targetMidSec)
        if dist <= alignmentFullWindowSec { return alignmentBonusMin }
        if dist >= alignmentZeroSec { return 0 }
        let numerator = Double(alignmentZeroSec - dist)
        let denominator = Double(alignmentZeroSec - alignmentFullWindowSec)
        return alignmentBonusMin * (numerator / denominator)
    }

    // MARK: - Selection

    /// The main night's index among already-bridged blocks.
    ///
    /// Score is duration plus the alignment bonus. There is deliberately NO hard overnight gate and
    /// no minimum length: a nap-only day still resolves to a main block, and a genuine long daytime
    /// sleep — a night shift — can win on score. Ties break toward the EARLIER onset so the answer
    /// does not depend on input order.
    public static func mainNightIndex(_ blocks: [NightBlock], offsetSec: Int,
                                      habitualMidsleepSec: Int? = nil) -> Int? {
        guard !blocks.isEmpty else { return nil }
        let target = habitualMidsleepSec ?? coldStartAnchorSec
        func score(_ b: NightBlock) -> Double {
            let mid = localSecOfDay(b.midpointSec, offsetSec: offsetSec)
            return Double(b.durationS) / 60.0 + alignmentBonusMinutes(blockMidSec: mid,
                                                                     targetMidSec: target)
        }
        var winner = 0
        var best = score(blocks[0])
        for i in 1..<blocks.count {
            let s = score(blocks[i])
            if s > best || (s == best && blocks[i].start < blocks[winner].start) {
                winner = i
                best = s
            }
        }
        return winner
    }

    /// The indices of every block that makes up the day's main night.
    ///
    /// Blocks are bridged into groups first, then the groups compete. Three tiers, each harder to
    /// clear than the last:
    ///
    ///   1. A gap under `gapBridgeMaxMin` always bridges.
    ///   2. Out to `nightTailBridgeMaxMin`, only when the later fragment STARTS overnight — a real
    ///      mid-night waking rather than a nap hours later.
    ///   3. Out to `splitNightBridgeMaxMin`, only for an overnight fragment at least
    ///      `splitNightMinFragmentMin` long — the second half of a split night.
    ///
    /// A daytime onset, or a gap past the widest tier, always stands alone.
    ///
    /// This is the ONE selector. Everything that sums a night and everything that counts naps has
    /// to use it, because naps are defined as the complement: any other answer double-counts the
    /// same minutes or drops them from both.
    public static func mainNightGroupIndices(_ blocks: [NightBlock], offsetSec: Int,
                                             habitualMidsleepSec: Int? = nil) -> [Int]? {
        guard !blocks.isEmpty else { return nil }
        let order = blocks.indices.sorted { blocks[$0].start < blocks[$1].start }
        let tier1 = gapBridgeMaxMin * 60
        let tier2 = nightTailBridgeMaxMin * 60
        let tier3 = splitNightBridgeMaxMin * 60
        let minFragment = splitNightMinFragmentMin * 60

        var bridged: [NightBlock] = []
        var groups: [[Int]] = []
        for idx in order {
            let b = blocks[idx]
            if let last = bridged.last {
                let gap = b.start - last.end
                let overnight = isOvernightOnset(b.start, offsetSec: offsetSec)
                let longFragment = b.durationS >= minFragment
                // A negative gap means the two blocks overlap, which the detector cannot
                // produce — its periods are disjoint by construction. Such a pair is left
                // unbridged rather than guessed at.
                // ponytail: bridge on overlap if a source of overlapping blocks ever appears.
                let bridges = gap >= 0 && (gap < tier1
                    || (gap < tier2 && overnight)
                    || (gap < tier3 && overnight && longFragment))
                if bridges {
                    bridged[bridged.count - 1] = NightBlock(start: last.start,
                                                            end: max(last.end, b.end))
                    groups[groups.count - 1].append(idx)
                    continue
                }
            }
            bridged.append(b)
            groups.append([idx])
        }
        guard let winner = mainNightIndex(bridged, offsetSec: offsetSec,
                                          habitualMidsleepSec: habitualMidsleepSec) else {
            return nil
        }
        return groups[winner].sorted()
    }

    // MARK: - Habitual midsleep

    /// The user's usual midsleep as a local time of day, or nil under `minDays` of history.
    ///
    /// Taken over the LONGEST block of each local day, which is independent of main-night
    /// selection — otherwise the anchor would be learned from the picks it is used to make.
    ///
    /// The average is CIRCULAR. An arithmetic mean of clock seconds puts a sleeper who alternates
    /// 23:30 and 00:30 at midday.
    public static func habitualMidsleepSec(_ history: [HistoryBlock], offsetSec: Int,
                                           minDays: Int = habitualMinDays) -> Int? {
        guard !history.isEmpty else { return nil }
        var longestByDay: [String: HistoryBlock] = [:]
        for block in history {
            guard let cur = longestByDay[block.dayKey] else {
                longestByDay[block.dayKey] = block
                continue
            }
            if block.durationS > cur.durationS
                || (block.durationS == cur.durationS && block.start < cur.start) {
                longestByDay[block.dayKey] = block
            }
        }
        guard longestByDay.count >= minDays else { return nil }
        let mids = longestByDay.values.map { localSecOfDay($0.midpointSec, offsetSec: offsetSec) }
        return circularMeanSec(mids)
    }

    /// Mean direction of a set of times of day.
    ///
    /// nil when the vectors cancel — times spread evenly round the clock have no mean time, and
    /// returning the arbitrary angle that falls out of `atan2` would present noise as an anchor.
    public static func circularMeanSec(_ secs: [Int]) -> Int? {
        guard !secs.isEmpty else { return nil }
        let k = 2.0 * Double.pi / Double(secondsPerDay)
        var sumSin = 0.0, sumCos = 0.0
        for s in secs {
            let a = Double(s) * k
            sumSin += sin(a)
            sumCos += cos(a)
        }
        let resultant = (sumSin * sumSin + sumCos * sumCos).squareRoot() / Double(secs.count)
        guard resultant >= 1e-9 else { return nil }
        var ang = atan2(sumSin, sumCos)
        if ang < 0 { ang += 2.0 * Double.pi }
        let sec = Int((ang / k).rounded()) % secondsPerDay
        return ((sec % secondsPerDay) + secondsPerDay) % secondsPerDay
    }

    /// Out-of-bed seconds BETWEEN the fragments of one bridged night.
    ///
    /// The gap belongs to no fragment's span, so without this it is in no total at all: twenty
    /// minutes of real awake vanish, and efficiency reports a night that was never that good.
    public static func interFragmentAwakeSeconds(_ spans: [(start: Int, end: Int)]) -> Double {
        guard spans.count > 1 else { return 0 }
        let sorted = spans.sorted { $0.start < $1.start }
        var gap = 0
        for i in 1..<sorted.count {
            let g = sorted[i].start - sorted[i - 1].end
            if g > 0 { gap += g }
        }
        return Double(gap)
    }
}
