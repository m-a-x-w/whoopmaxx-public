import Foundation
import StrapProtocol
import StrapStore

/// The 0–100 sleep score.
///
/// Four published components, weighted: how long you slept against your own need, how much of the
/// time in bed you were asleep, how much of that sleep was restorative, and how regular your
/// schedule is. Every sub-score is clamped, so no single component can carry or sink a night.
public enum Rest {

    /// Personal sleep need before the caller learns one.
    public static let defaultNeedHours: Double = 8.0
    /// Deep-plus-REM share of sleep that earns full restorative credit.
    public static let restorativeTarget: Double = 0.50
    /// Deep share of sleep that earns full credit within that.
    public static let deepShareTarget: Double = 0.13
    /// The most the restorative term is scaled down when deep is nearly absent — half, never zero.
    public static let deepFloorFactor: Double = 0.5
    /// One day carries no regularity signal, so with none supplied the term sits at neutral rather
    /// than at zero — an unknown must not read as a failure.
    public static let neutralConsistency: Double = 0.5

    /// Deep and REM share of sleep declines with age, so a fixed young-adult target quietly caps an
    /// older adult's score at something they cannot reach. Each target tapers between these ages.
    ///
    /// An unknown age pins every target to the young-adult constant, so a caller without a profile
    /// gets exactly the un-aged scoring rather than a guess.
    public static let ageReferenceYears: Double = 40.0
    public static let ageFloorYears: Double = 70.0
    public static let restorativeTargetFloor: Double = 0.42
    public static let deepShareTargetFloor: Double = 0.10

    static func ageTaper(_ ageYears: Double?, young: Double, old: Double) -> Double {
        guard let age = ageYears else { return young }
        if age <= ageReferenceYears { return young }
        if age >= ageFloorYears { return old }
        let t = (age - ageReferenceYears) / (ageFloorYears - ageReferenceYears)
        return young + (old - young) * t
    }

    public static func restorativeTarget(ageYears: Double?) -> Double {
        ageTaper(ageYears, young: restorativeTarget, old: restorativeTargetFloor)
    }

    public static func deepShareTarget(ageYears: Double?) -> Double {
        ageTaper(ageYears, young: deepShareTarget, old: deepShareTargetFloor)
    }

    public static let wDuration: Double = 0.50
    public static let wEfficiency: Double = 0.20
    public static let wRestorative: Double = 0.20
    public static let wConsistency: Double = 0.10

    /// Build the composite, 0…100.
    ///
    /// Deep and REM are not interchangeable, which is why `deepSeconds` exists. Pooled, a night
    /// with normal REM and almost no deep still earns nearly full restorative credit and scores in
    /// the nineties. With the split supplied, the restorative term is scaled by a deep-adequacy
    /// factor: full credit once deep clears its target share, sliding down to `deepFloorFactor` as
    /// deep approaches zero. So a near-zero-deep night loses up to half of a 20-point term — a
    /// visible dent, not a collapse, and no stages are invented to produce it.
    ///
    /// Deep unknown — an imported night carrying only a pooled total — leaves the factor at 1 and
    /// is exactly the pooled behaviour.
    public static func composite(tstSeconds: Double,
                                 inBedSeconds: Double,
                                 efficiency: Double,
                                 restorativeSeconds: Double,
                                 needHours: Double,
                                 consistency: Double?,
                                 deepSeconds: Double? = nil,
                                 ageYears: Double? = nil) -> Double {
        func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

        let needSeconds = max(needHours, 0.1) * 3600
        let durationScore = clamp01(tstSeconds / needSeconds)
        let efficiencyScore = clamp01(efficiency)
        let deepTarget = deepShareTarget(ageYears: ageYears)
        let restTarget = restorativeTarget(ageYears: ageYears)

        let deepFactor: Double = {
            guard let deep = deepSeconds, tstSeconds > 0, deepTarget > 0 else { return 1 }
            let adequacy = clamp01((deep / tstSeconds) / deepTarget)
            return deepFloorFactor + (1 - deepFloorFactor) * adequacy
        }()
        let restorativeScore = tstSeconds > 0
            ? clamp01((restorativeSeconds / tstSeconds) / restTarget) * deepFactor
            : 0
        let consistencyScore = clamp01(consistency ?? neutralConsistency)

        let weighted = wDuration * durationScore
            + wEfficiency * efficiencyScore
            + wRestorative * restorativeScore
            + wConsistency * consistencyScore
        return (weighted * 10_000).rounded() / 100
    }

    /// The same composite from a stored day, for when the raw streams are long gone but the night's
    /// totals remain. One definition, so the stored series and the Charge term can never disagree.
    public static func composite(daily d: DailyMetric, needHours: Double = defaultNeedHours,
                                 consistency: Double? = nil, ageYears: Double? = nil) -> Double? {
        guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
        let tstSec = tstMin * 60
        let deepSec = (d.deepMin ?? 0) * 60
        let restorativeSec = deepSec + (d.remMin ?? 0) * 60
        return composite(tstSeconds: tstSec, inBedSeconds: tstSec / max(eff, 0.01),
                         efficiency: eff, restorativeSeconds: restorativeSec,
                         needHours: needHours, consistency: consistency,
                         deepSeconds: deepSec, ageYears: ageYears)
    }
}

/// Nightly skin temperature, and why it so often is not available.
public enum SkinTemp {

    /// Minimum worn in-bed samples before a nightly mean is trusted — about five minutes at 1 Hz.
    /// A handful of stray samples must not become a baseline.
    public static let minSamples = 300

    /// Plausible worn range. Off-wrist and charging samples drift toward ambient, well below this.
    public static let minC = 28.0
    public static let maxC = 42.0

    /// Where a night's skin-temperature samples went.
    ///
    /// An absent reading is opaque without this: there is no way to tell "no samples at all" from
    /// "plenty, but none while worn" from "all of them outside the plausible range". Each sample is
    /// attributed to the FIRST gate that dropped it, so the buckets and `kept` sum to the total.
    public struct Funnel: Equatable, Sendable {
        public let totalSamples: Int
        public let droppedNotWorn: Int
        public let droppedOutOfWindow: Int
        public let droppedOutOfRange: Int
        public let kept: Int
        public let minSamples: Int
        public let mean: Double?

        public init(totalSamples: Int, droppedNotWorn: Int, droppedOutOfWindow: Int,
                    droppedOutOfRange: Int, kept: Int, minSamples: Int, mean: Double?) {
            self.totalSamples = totalSamples; self.droppedNotWorn = droppedNotWorn
            self.droppedOutOfWindow = droppedOutOfWindow; self.droppedOutOfRange = droppedOutOfRange
            self.kept = kept; self.minSamples = minSamples; self.mean = mean
        }

        public var isAbsent: Bool { mean == nil }

        public var summary: String {
            let m = mean.map { String(format: "%.2f°C", $0) } ?? "absent"
            return "skin temp: \(totalSamples) samples → kept \(kept)/\(minSamples) (mean=\(m)); "
                + "dropped[notWorn=\(droppedNotWorn), outOfWindow=\(droppedOutOfWindow), "
                + "outOfRange=\(droppedOutOfRange)]"
        }
    }

    /// The night's mean skin temperature, and the account of how it got there.
    ///
    /// Three gates, in order. The sample must land in a second the strap was WORN — it streams
    /// heart rate only on-wrist, so a live BPM is the wear evidence. It must fall inside a detected
    /// in-bed window. And it must read as a plausible worn temperature, or an interval spent on a
    /// charger drifting to room temperature poisons the mean.
    ///
    /// The raw→°C conversion depends on the device family: the two generations bank the field on
    /// entirely different scales, and using one for the other reads every worn night far below the
    /// worn gate, so skin temperature silently vanishes for a whole generation of strap.
    public static func funnel(sessions: [SleepSession], hr: [HRSample],
                              skinTemp: [SkinTempSample], family: DeviceFamily = .whoop5,
                              minSamples: Int = minSamples) -> Funnel {
        let total = skinTemp.count
        guard !sessions.isEmpty, !skinTemp.isEmpty else {
            return Funnel(totalSamples: total, droppedNotWorn: 0,
                          droppedOutOfWindow: sessions.isEmpty ? total : 0,
                          droppedOutOfRange: 0, kept: 0, minSamples: minSamples, mean: nil)
        }
        var wornSeconds = Set<Int>(minimumCapacity: hr.count)
        for h in hr where (30...220).contains(h.bpm) { wornSeconds.insert(h.ts) }

        var sum = 0.0, kept = 0
        var notWorn = 0, outOfWindow = 0, outOfRange = 0
        for t in skinTemp {
            if !wornSeconds.contains(t.ts) { notWorn += 1; continue }
            if !sessions.contains(where: { t.ts >= $0.start && t.ts <= $0.end }) {
                outOfWindow += 1; continue
            }
            let c = skinTempCelsius(raw: t.raw, family: family)
            if c < minC || c > maxC { outOfRange += 1; continue }
            sum += c
            kept += 1
        }
        return Funnel(totalSamples: total, droppedNotWorn: notWorn,
                      droppedOutOfWindow: outOfWindow, droppedOutOfRange: outOfRange,
                      kept: kept, minSamples: minSamples,
                      mean: kept >= minSamples ? sum / Double(kept) : nil)
    }

    /// The night's mean, or nil. A thin wrapper over `funnel`, so the number and its explanation
    /// can never come from different code.
    public static func wornNightlyMeanC(sessions: [SleepSession], hr: [HRSample],
                                        skinTemp: [SkinTempSample],
                                        family: DeviceFamily = .whoop5,
                                        minSamples: Int = minSamples) -> Double? {
        funnel(sessions: sessions, hr: hr, skinTemp: skinTemp, family: family,
               minSamples: minSamples).mean
    }
}
