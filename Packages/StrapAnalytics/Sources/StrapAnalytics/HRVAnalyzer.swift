import Foundation
import StrapProtocol

/// Heart-rate variability from beat-to-beat intervals.
///
/// Every metric here is a published time-domain measure computed over NN intervals — "normal-to-
/// normal", meaning the ectopic and artefact beats have already been removed. The cleaning is the
/// part that matters: RMSSD is a root-mean-square of DIFFERENCES between consecutive beats, so one
/// missed beat contributes a difference roughly the size of a whole interval and can move a night's
/// number more than any real physiological change. Feeding raw intervals to these formulas produces
/// a confident number that is mostly artefact.
public enum HRVAnalyzer {

    /// Physiologically possible interval bounds, ms. 2000 ms = 30 bpm, 300 ms = 200 bpm.
    public static let rrMinMs: Double = 300
    public static let rrMaxMs: Double = 2000

    /// Fewer clean beats than this and no metric is reported. A short window's RMSSD is dominated
    /// by whichever beats happened to survive cleaning.
    public static let minBeats: Int = 20

    /// How far an interval may deviate from its local neighbours before it is called ectopic.
    public static let ectopicThreshold: Double = 0.20
    /// Beats either side used to form that local reference.
    public static let ectopicWindowRadius: Int = 2

    /// Above this rejected fraction a spot reading is refused outright.
    ///
    /// Cleaning that removes a third of the beats has not tidied the signal, it has replaced it.
    /// The result would still compute, and would still look like a measurement.
    public static let defaultSpotMaxRejectedFraction: Double = 0.35

    public struct HRVResult: Equatable, Sendable {
        public let rmssd: Double?
        public let sdnn: Double?
        public let meanNN: Double?
        public let pnn50: Double?
        /// Beats offered.
        public let nInput: Int
        /// Beats that survived cleaning.
        public let nClean: Int

        public init(rmssd: Double?, sdnn: Double?, meanNN: Double?, pnn50: Double?,
                    nInput: Int, nClean: Int) {
            self.rmssd = rmssd; self.sdnn = sdnn; self.meanNN = meanNN
            self.pnn50 = pnn50; self.nInput = nInput; self.nClean = nClean
        }

        public static let empty = HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                                            nInput: 0, nClean: 0)

        /// Share of offered beats that cleaning discarded. A caller decides what is tolerable;
        /// this only reports it.
        public var rejectedFraction: Double {
            nInput > 0 ? Double(nInput - nClean) / Double(nInput) : 0
        }
    }

    // MARK: - Raw formulas
    //
    // These assume ALREADY-CLEAN input. They are separate from the cleaning so a caller that has
    // done its own filtering is not forced through this one.

    /// Root mean square of successive differences.
    public static func rmssdRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sum = 0.0
        for i in 1..<nn.count {
            let d = nn[i] - nn[i - 1]
            sum += d * d
        }
        return (sum / Double(nn.count - 1)).squareRoot()
    }

    /// Standard deviation of the intervals themselves. Uses the SAMPLE deviation (n-1): these
    /// beats are a sample of the night, not the whole population of them.
    public static func sdnnRaw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        let mean = nn.reduce(0, +) / Double(nn.count)
        let ss = nn.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / Double(nn.count - 1)).squareRoot()
    }

    /// Share of successive pairs differing by more than 50 ms, as a fraction of 0…1.
    public static func pnn50Raw(_ nn: [Double]) -> Double? {
        guard nn.count >= 2 else { return nil }
        var over = 0
        for i in 1..<nn.count where abs(nn[i] - nn[i - 1]) > 50 { over += 1 }
        return Double(over) / Double(nn.count - 1)
    }

    public static func meanNNRaw(_ nn: [Double]) -> Double? {
        guard !nn.isEmpty else { return nil }
        return nn.reduce(0, +) / Double(nn.count)
    }

    // MARK: - Cleaning

    /// Drop intervals outside the physiologically possible range.
    public static func rangeFilter(_ rr: [Double]) -> [Double] {
        rr.filter { $0 >= rrMinMs && $0 <= rrMaxMs }
    }

    /// Drop beats that differ too far from their local neighbours.
    ///
    /// The reference is the MEDIAN of a small window either side, not the mean: a mean is pulled
    /// by the very outlier being tested, so an ectopic beat partly hides itself.
    ///
    /// Neighbours are taken from the ORIGINAL sequence rather than the partly-cleaned one, so the
    /// verdict on each beat does not depend on the order they happen to be examined in.
    /// Which beats survive the local-median rule.
    ///
    /// The beat under test is excluded from its own neighbourhood BY POSITION, not by value: with
    /// duplicates in the window, removing "the first equal value" drops a different beat and shifts
    /// the median away from the one this beat should be judged against.
    ///
    /// A beat the neighbourhood cannot judge — too few neighbours, or a non-positive median — is
    /// KEPT. Rejection needs evidence; absence of evidence is not evidence of an ectopic beat.
    static func ectopicKeepMask(_ nn: [Double]) -> [Bool] {
        guard nn.count > ectopicWindowRadius else {
            return [Bool](repeating: true, count: nn.count)
        }
        var mask = [Bool](repeating: false, count: nn.count)
        for i in 0..<nn.count {
            let lo = max(0, i - ectopicWindowRadius)
            let hi = min(nn.count - 1, i + ectopicWindowRadius)
            var neighbours: [Double] = []
            neighbours.reserveCapacity(hi - lo)
            for j in lo...hi where j != i { neighbours.append(nn[j]) }
            guard neighbours.count >= 2 else { mask[i] = true; continue }
            let med = median(neighbours)
            guard med > 0 else { mask[i] = true; continue }
            mask[i] = abs(nn[i] - med) / med <= ectopicThreshold
        }
        return mask
    }

    /// Drop beats that differ too far from their local neighbours.
    ///
    /// The reference is the MEDIAN of a small window either side, not the mean: a mean is pulled by
    /// the very outlier being tested, so an ectopic beat partly hides itself.
    public static func rejectEctopic(_ nn: [Double]) -> [Double] {
        let mask = ectopicKeepMask(nn)
        var kept: [Double] = []
        kept.reserveCapacity(nn.count)
        for (i, v) in nn.enumerated() where mask[i] { kept.append(v) }
        return kept
    }

    /// Range filter then ectopic rejection.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        rejectEctopic(rangeFilter(rr))
    }

    /// A surviving beat with its position in the ORIGINAL sequence.
    ///
    /// The index is what lets a caller line a clean beat back up with its timestamp. Without it,
    /// cleaning silently destroys the mapping between beats and the clock.
    public struct KeptBeat: Equatable, Sendable {
        public let index: Int
        public let value: Double
        public init(index: Int, value: Double) { self.index = index; self.value = value }
    }

    /// Clean, keeping each survivor's original position.
    public static func cleanRRIndexed(_ rr: [Double]) -> [KeptBeat] {
        let inRange = rr.enumerated().filter { $0.element >= rrMinMs && $0.element <= rrMaxMs }
        let mask = ectopicKeepMask(inRange.map(\.element))
        var out: [KeptBeat] = []
        out.reserveCapacity(inRange.count)
        for (i, pair) in inRange.enumerated() where mask[i] {
            out.append(KeptBeat(index: pair.offset, value: pair.element))
        }
        return out
    }

    // MARK: - Analysis

    /// Clean, then compute every time-domain metric.
    ///
    /// Below `minBeats` the metrics come back nil while the counts still report what happened —
    /// "not enough clean beats" and "no data at all" are different facts, and a caller has to be
    /// able to tell them apart to explain a blank night.
    public static func analyze(_ rr: [Double]) -> HRVResult {
        analyze(rawRR: rr, maxRejectedFraction: nil, ts: nil)
    }

    /// Clean, then compute every time-domain metric.
    ///
    /// The cleaning is INDEX-PRESERVING, so the difference-based metrics can skip pairs that bracket
    /// a removed beat. Concatenating the survivors and differencing them would invent a beat-to-beat
    /// change across every hole the cleaner just made — the largest differences in the series, and
    /// exactly the ones that are not real.
    ///
    /// `maxRejectedFraction` refuses the whole reading when cleaning removed too much. A spot
    /// capture is short, so one bad stretch is a large share of it: past the bar the cleaner has
    /// replaced the signal rather than tidied it, and the number would still look measured. Nil
    /// means no ceiling, which is the nightly path — a long window can afford to lose a stretch.
    ///
    /// `ts` additionally lets the difference metrics skip a pair separated by a stream dropout.
    public static func analyze(rawRR: [Double],
                               maxRejectedFraction: Double? = defaultSpotMaxRejectedFraction,
                               ts: [Int]? = nil) -> HRVResult {
        let nInput = rawRR.count
        let kept = cleanRRIndexed(rawRR)
        guard kept.count >= minBeats else {
            return HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                             nInput: nInput, nClean: kept.count)
        }
        if let maxRejectedFraction, nInput > 0 {
            let rejected = 1.0 - Double(kept.count) / Double(nInput)
            if rejected > maxRejectedFraction {
                return HRVResult(rmssd: nil, sdnn: nil, meanNN: nil, pnn50: nil,
                                 nInput: nInput, nClean: kept.count)
            }
        }
        let clean = kept.map(\.value)
        return HRVResult(rmssd: rmssdExcludingSplices(kept, ts: ts),
                         sdnn: sdnnRaw(clean),
                         meanNN: meanNNRaw(clean),
                         pnn50: pnn50ExcludingSplices(kept, ts: ts),
                         nInput: nInput, nClean: clean.count)
    }

    /// pNN50 over the same truly-successive pairs RMSSD uses. A splice inflates it for the same
    /// reason: a fabricated difference is almost always over 50 ms.
    public static func pnn50ExcludingSplices(_ kept: [KeptBeat], ts: [Int]? = nil,
                                             maxGapSec: Int = defaultMaxBeatGapSec) -> Double? {
        guard kept.count >= 2 else { return nil }
        var over = 0, pairs = 0
        for k in 1..<kept.count {
            let a = kept[k - 1], b = kept[k]
            guard b.index == a.index + 1 else { continue }
            if let ts, a.index < ts.count, b.index < ts.count,
               ts[b.index] - ts[a.index] > maxGapSec { continue }
            if abs(b.value - a.value) > 50 { over += 1 }
            pairs += 1
        }
        guard pairs >= 1 else { return nil }
        return Double(over) / Double(pairs)
    }

    /// RMSSD over a sliding window of beats, one value per step.
    public static func rollingRmssd(_ rr: [Double], window: Int, step: Int = 1) -> [Double] {
        guard window >= 2, step >= 1, rr.count >= window else { return [] }
        var out: [Double] = []
        var i = 0
        while i + window <= rr.count {
            if let v = rmssdRaw(cleanRR(Array(rr[i..<(i + window)]))) { out.append(v) }
            i += step
        }
        return out
    }

    /// Median of a set of values. Used wherever a mean would be dragged by one bad window.
    public static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// RMSSD that refuses to bridge a recording gap.
    ///
    /// A successive difference is only meaningful between beats that actually followed one another.
    /// Across a gap — the strap off the wrist, a dropped connection — the "difference" is between
    /// two unrelated moments, and it is large, so a handful of splices can dominate the result. The
    /// pairs spanning `spliceIndices` are excluded rather than the beats themselves, so no real
    /// beat is lost.
    public static func rmssdExcludingSplices(_ nn: [Double], spliceIndices: Set<Int>) -> Double? {
        guard nn.count >= 2 else { return nil }
        var sum = 0.0
        var pairs = 0
        for i in 1..<nn.count where !spliceIndices.contains(i) {
            let d = nn[i] - nn[i - 1]
            sum += d * d
            pairs += 1
        }
        guard pairs > 0 else { return nil }
        return (sum / Double(pairs)).squareRoot()
    }

    /// Longest wall-clock gap (seconds) between two R-R rows that may still be called successive.
    ///
    /// A stored R-R series does not tile the clock — rows drop out, so two adjacent ROWS are often
    /// not adjacent BEATS even before any beat is rejected. 3 s sits above even a bradycardic 2 s
    /// interval and below any real dropout.
    public static let defaultMaxBeatGapSec: Int = 3

    /// Splice-safe RMSSD over cleaned beats that still know where they came from.
    ///
    /// A pair counts only when the two beats were adjacent in the RAW series (nothing was rejected
    /// between them) and, when `ts` is supplied, when the clock did not jump between them. Both
    /// kinds of splice fabricate a large ΔNN out of two unrelated moments, and RMSSD squares it.
    public static func rmssdExcludingSplices(_ kept: [KeptBeat], ts: [Int]? = nil,
                                             maxGapSec: Int = defaultMaxBeatGapSec) -> Double? {
        guard kept.count >= 2 else { return nil }
        var sumSq = 0.0
        var pairs = 0
        for k in 1..<kept.count {
            let a = kept[k - 1], b = kept[k]
            guard b.index == a.index + 1 else { continue }
            if let ts, a.index < ts.count, b.index < ts.count,
               ts[b.index] - ts[a.index] > maxGapSec { continue }
            let d = b.value - a.value
            sumSq += d * d
            pairs += 1
        }
        guard pairs >= 1 else { return nil }
        return (sumSq / Double(pairs)).squareRoot()
    }

    /// One point of a rolling RMSSD trace.
    public struct RollingRmssdPoint: Equatable, Sendable {
        /// The window's RIGHT edge — the last beat folded into it.
        public let ts: Int
        public let rmssd: Double
        public init(ts: Int, rmssd: Double) { self.ts = ts; self.rmssd = rmssd }
    }

    /// Rolling RMSSD over a timestamped beat series.
    ///
    /// The window is a trailing span of CLOCK time, not a count of beats: a fixed beat count is a
    /// longer window at a low heart rate than at a high one, so the statistic would quietly change
    /// meaning across the night.
    ///
    /// Each window is cleaned, and a point is emitted only when enough beats survive — a sparse or
    /// artefact-heavy window produces NOTHING rather than a spike. The RMSSD is splice-safe, so a
    /// beat rejected inside a window cannot manufacture a difference across the hole it left.
    ///
    /// `stepSec` thins the output to at most one point per stride; the windows themselves still
    /// slide beat by beat.
    public static func rollingRmssd(rr: [RRInterval],
                                    windowSec: Int,
                                    stepSec: Int = 0,
                                    minBeatsPerWindow: Int = 8) -> [RollingRmssdPoint] {
        guard windowSec > 0, rr.count >= minBeatsPerWindow else { return [] }
        let sorted = rr.sorted { $0.ts < $1.ts }
        var out: [RollingRmssdPoint] = []
        var lastEmitTs: Int?
        var left = 0
        for right in 0..<sorted.count {
            let edgeTs = sorted[right].ts
            while left < right && edgeTs - sorted[left].ts > windowSec { left += 1 }
            if stepSec > 0, let last = lastEmitTs, edgeTs - last < stepSec { continue }
            let windowRaw = sorted[left...right].map { Double($0.rrMs) }
            let windowTs = sorted[left...right].map(\.ts)
            let kept = cleanRRIndexed(windowRaw)
            guard kept.count >= minBeatsPerWindow,
                  let r = rmssdExcludingSplices(kept, ts: windowTs) else { continue }
            out.append(RollingRmssdPoint(ts: edgeTs, rmssd: r))
            lastEmitTs = edgeTs
        }
        return out
    }
}
