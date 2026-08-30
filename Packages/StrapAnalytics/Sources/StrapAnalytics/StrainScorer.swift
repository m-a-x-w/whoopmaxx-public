import Foundation
import StrapProtocol

/// Cardiovascular load for a day — the app's Effort score.
///
/// Built on TRIMP (training impulse): time spent at a heart rate, weighted by how hard that rate
/// is FOR THIS PERSON. "Hard" is percent of heart-rate reserve — the span between resting and
/// maximum — not raw bpm, so the same 140 bpm counts differently for two people with different
/// resting rates, which is the entire point of a personal score.
public enum StrainScorer {

    /// A dense day's worth of samples.
    public static let minReadings: Int = 600
    /// A sparse stream still counts if it spans long enough — some straps report every ~30 s.
    public static let minSparseReadings: Int = 20
    public static let minSpanSeconds: Int = 600

    public static let maxStrain: Double = 100.0
    /// The TRIMP that maps to the top of the scale.
    public static let strainDenominator: Double = 7201.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Banister's exponential weighting constants, which differ by sex.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Longest gap credited as continuous effort. A longer one is a wear gap, not a hard stretch.
    public static let mergeGapS: Double = 150.0
    /// Duration assumed when a stream is too short to measure its own cadence.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public enum Method: Sendable, Hashable { case edwards, banister }

    /// Edwards' five zones, as percent of heart-rate reserve and the weight each minute earns.
    /// Ordered high-to-low so the first match wins.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    // MARK: - Intensity

    /// Percent of heart-rate reserve, clamped to 0…100.
    ///
    /// Clamped rather than allowed to run negative or past 100: below resting is not negative
    /// effort, and a reading above the assumed maximum means the assumption is wrong, not that the
    /// person exceeded their own physiology.
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        guard hrReserve > 0 else { return 0 }
        return max(0, min(100, (bpm - restingHR) / hrReserve * 100.0))
    }

    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        guard hrReserve > 0 else { return 0 }
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - Durations

    /// The stream's own cadence, from its first interval.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        let deltaS = abs(Double(hr[1].ts - hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    /// How long each sample represents, in minutes.
    ///
    /// Every interval is CAPPED at `mergeGapS`. Without the cap, a sample either side of a
    /// six-hour wear gap would be credited with six hours of load at whatever rate it happened to
    /// read, which can single-handedly max out a day.
    ///
    /// The final sample has no successor and takes the stream's representative cadence — capped by
    /// the same bound. That cap is in SECONDS while the cadence is in minutes, so the conversion
    /// before comparing is load-bearing: comparing minutes against 150 would never trigger.
    static func intervalMinutes(_ hr: [HRSample]) -> [Double] {
        guard !hr.isEmpty else { return [] }
        let tail = min(sampleDurationMinutes(hr) * 60.0, mergeGapS) / 60.0
        return hr.indices.map { i in
            guard i < hr.count - 1 else { return tail }
            let gap = Double(hr[i + 1].ts - hr[i].ts)
            return gap > 0 ? min(gap, mergeGapS) / 60.0 : fallbackSampleMin
        }
    }

    // MARK: - TRIMP

    /// Edwards: minutes in each zone times that zone's integer weight.
    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double) -> Double {
        let durs = intervalMinutes(hr)
        var acc = 0.0
        for (i, s) in hr.enumerated() {
            acc += Double(zoneWeight(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve)) * durs[i]
        }
        return acc
    }

    /// Banister: a continuous exponential weighting rather than five steps.
    ///
    /// Smoother than Edwards near a zone boundary, where a single bpm can otherwise change a
    /// minute's contribution by a whole weight.
    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double, b: Double) -> Double {
        let durs = intervalMinutes(hr)
        var acc = 0.0
        for (i, s) in hr.enumerated() {
            let x = pctHRR(Double(s.bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 { acc += durs[i] * x * banisterScale * exp(b * x) }
        }
        return acc
    }

    /// Map accumulated TRIMP onto the 0…100 scale, logarithmically.
    ///
    /// Log rather than linear because load accumulates without bound while a score has to stay
    /// readable: the difference between an easy day and a hard one should be visible, and the
    /// difference between a hard day and an extreme one should not flatten everything else.
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        guard trimp > 0 else { return 0 }
        return min(maxStrain, maxStrain * log(trimp + 1.0) / log(denominator))
    }

    // MARK: - Score

    /// The day's Effort score, or nil when there is not enough heart rate to say.
    ///
    /// Nil rather than zero. A day with no data and a day spent resting are different facts, and a
    /// zero would be indistinguishable from "you did nothing" in a chart.
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .edwards,
                              sex: String = "male",
                              denominator: Double = strainDenominator) -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())

        // Enough to trust: a dense stream, OR a sparse one that still spans a real window. The
        // second case exists because some straps report every ~30 s, and rejecting those would
        // blank the score for a whole device family.
        let enoughData: Bool
        if hr.count >= minReadings {
            enoughData = true
        } else if hr.count >= minSparseReadings {
            let tss = hr.map(\.ts)
            enoughData = ((tss.max() ?? 0) - (tss.min() ?? 0)) >= minSpanSeconds
        } else {
            enoughData = false
        }
        guard enoughData, effMax > restingHR else { return nil }

        let hrReserve = effMax - restingHR
        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve, b: b)
        case .edwards:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve)
        }
        return trimpToStrain(trimp, denominator: denominator)
    }

    public static let hrmaxMinSamples: Int = 600
    public static let hrmaxPercentile: Double = 99.5

    /// Tanaka's age estimate, shared with the zone builder.
    public static func tanakaHRmax(age: Double) -> Double { HRZones.tanakaMaxHR(age: age) }

    /// Best available maximum heart rate, and where it came from.
    ///
    /// An OBSERVED maximum only wins when it exceeds the age estimate. A strap that has never seen
    /// hard effort reports a 99.5th percentile far below the person's real ceiling, and adopting it
    /// would compress every zone upward and inflate their whole training history. The formula is
    /// the safer floor; a genuinely observed higher value is the better ceiling.
    ///
    /// The source string travels with the number so a surface can say whether zones rest on a
    /// measurement or an assumption.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let tanaka = age.map { tanakaHRmax(age: $0) }
        if hrHistory.count >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    /// Linear-interpolated percentile over pre-sorted values.
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        return sortedValues[lower] + (position - Double(lower)) * (sortedValues[upper] - sortedValues[lower])
    }
}
