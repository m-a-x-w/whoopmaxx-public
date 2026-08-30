import Foundation
import StrapProtocol

/// One detected bout of exercise.
public struct ExerciseSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let avgHR: Double
    public let peakHR: Int
    public let strain: Double?
    public let durationS: Double
    /// Share of the bout's samples in each Edwards zone, 0…5.
    public let zoneTimePct: [Int: Double]
    public let avgHRRPct: Double?
    public let hrmax: Double?
    /// Where `hrmax` came from — "caller", "observed", "tanaka" or "unknown". Carried so a surface
    /// never presents an assumed ceiling as a measured one.
    public let hrmaxSource: String
    public let caloriesKcal: Double?
    public let caloriesKJ: Double?

    public init(start: Int, end: Int, avgHR: Double, peakHR: Int, strain: Double?,
                durationS: Double, zoneTimePct: [Int: Double], avgHRRPct: Double?,
                hrmax: Double?, hrmaxSource: String, caloriesKcal: Double?, caloriesKJ: Double?) {
        self.start = start; self.end = end; self.avgHR = avgHR; self.peakHR = peakHR
        self.strain = strain; self.durationS = durationS; self.zoneTimePct = zoneTimePct
        self.avgHRRPct = avgHRRPct; self.hrmax = hrmax; self.hrmaxSource = hrmaxSource
        self.caloriesKcal = caloriesKcal; self.caloriesKJ = caloriesKJ
    }
}

/// Finds workouts from heart rate and motion together.
///
/// Both signals are required, ANDed. Heart rate alone flags a stressful meeting; motion alone flags
/// a bumpy drive. Requiring elevated HR *and* movement is what makes a bout a workout rather than
/// either of those.
public enum WorkoutDetector {

    public static let minExerciseMin: Double = 5.0
    /// How far above resting a sample must sit to count.
    public static let hrMarginBPM: Double = 15.0
    public static let motionThreshold: Double = 0.20
    public static let motionSmoothS: Double = 10.0
    /// Gap below which two active runs are one bout.
    public static let mergeGapS: Double = 150.0
    /// Share of a bout's samples that must reach zone 2+ for it to qualify on density.
    public static let minIntensityZ2Plus: Double = 0.30
    /// Absolute dose that qualifies a bout regardless of density.
    public static let minZone3PlusMinutes: Double = 5.0
    public static let zone3HRRPct: Double = 70.0

    /// The motion requirement ramps DOWN between these two reserve fractions.
    public static let motionScaleLoHRR: Double = 50.0
    public static let motionScaleHiHRR: Double = 70.0
    public static let motionThresholdFloor: Double = 0.02

    public static let alignToleranceS: Double = 5.0
    public static let restingPercentile: Double = 10.0
    public static let bridgeGapS: Double = 300.0
    /// Fraction of heart-rate reserve a lull must hold to bridge two runs.
    public static let bridgeHRRFraction: Double = 0.50

    public typealias ActivityPoint = Motion.ActivityPoint

    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        Motion.activitySeries(gravity)
    }

    static func smoothedIntensity(_ motion: [ActivityPoint], windowS: Double) -> [Double] {
        Motion.smoothedIntensity(motion, windowS: windowS)
    }

    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              restingHR: Double? = nil,
                              maxHR: Double? = nil,
                              age: Double? = nil,
                              profile: UserProfile? = nil) -> [ExerciseSession] {
        let hrSeg = cleanHR(hr)
        let motion = activitySeries(gravity)
        guard !hrSeg.isEmpty, !motion.isEmpty else { return [] }

        let restHR = restingHR ?? deriveRestingHR(hrSeg)
        let hrFloor = restHR + hrMarginBPM

        let effMaxHR: Double?
        let hrmaxSource: String
        if let m = maxHR {
            effMaxHR = m; hrmaxSource = "caller"
        } else {
            let (est, src) = StrainScorer.estimateHRmax(hrSeg.map(\.bpm), age: age)
            effMaxHR = est == 0.0 ? nil : est
            hrmaxSource = src
        }

        // The bridge test needs an EXERCISE-level floor, not the detection floor: a lull only
        // counts as "still working" if HR stayed genuinely high, otherwise ordinary waking heart
        // rate would weld a whole day into one workout.
        let bridgeFloor = effMaxHR.map { m in
            m > restHR ? restHR + bridgeHRRFraction * (m - restHR) : hrFloor
        } ?? hrFloor
        // nil when the ceiling is unknown or degenerate; the load-scaled motion gate and the dose
        // gate both fall back to fixed behaviour there rather than dividing by a bad reserve.
        let hrReserve: Double? = effMaxHR.flatMap { $0 > restHR ? $0 - restHR : nil }

        let hrTs = hrSeg.map(\.ts)
        let hrBpm = hrSeg.map(\.bpm)
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)

        var activeTs: [Int] = []
        for (p, inten) in zip(motion, smooth) {
            guard let bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS), bpm > hrFloor else { continue }
            if inten <= motionRequirement(bpm: bpm, restingHR: restHR, hrReserve: hrReserve) { continue }
            activeTs.append(p.ts)
        }
        guard !activeTs.isEmpty else { return [] }

        var runs: [(Int, Int)] = []
        var runStart = activeTs[0]
        var prev = activeTs[0]
        for ts in activeTs.dropFirst() {
            if Double(ts - prev) > mergeGapS { runs.append((runStart, prev)); runStart = ts }
            prev = ts
        }
        runs.append((runStart, prev))
        runs = bridgeRuns(runs, hrSeg: hrSeg, bridgeFloor: bridgeFloor)

        let minDurS = minExerciseMin * 60.0
        var sessions: [ExerciseSession] = []
        for (start, end) in runs {
            // The smoothing window costs a bout its first seconds, so the duration floor is
            // relaxed by exactly that much rather than penalising every bout for the filter.
            guard Double(end - start) >= minDurS - motionSmoothS else { continue }
            let window = hrSeg.filter { $0.ts >= start && $0.ts <= end }
            guard !window.isEmpty else { continue }
            let bpms = window.map(\.bpm)
            let hrSamples = window.map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

            var zonePct: [Int: Double] = [:]
            var avgHRR: Double?
            if let m = effMaxHR, m > restHR {
                (zonePct, avgHRR) = boutIntensity(window, restingHR: restHR, maxHR: m)
            }

            // Qualify on DENSITY or on absolute DOSE. Density alone is structurally blind to
            // set-and-rest work, which is low-density by construction — an hour of heavy lifting
            // would be rejected while a gentle jog passes.
            if !zonePct.isEmpty {
                let z2plus = (2...5).reduce(0.0) { $0 + (zonePct[$1] ?? 0) } / 100.0
                if z2plus < minIntensityZ2Plus,
                   zone3PlusMinutes(window, restingHR: restHR, hrReserve: hrReserve) < minZone3PlusMinutes {
                    continue
                }
            }

            var kcal: Double?, kj: Double?
            if let profile {
                (kcal, kj) = Calories.estimateBoutCalories(hrSamples, profile: profile,
                                                           hrmax: effMaxHR, restingHR: restHR)
            }

            sessions.append(ExerciseSession(
                start: start, end: end,
                avgHR: bpms.reduce(0, +) / Double(bpms.count),
                peakHR: Int(bpms.max()!.rounded()),
                strain: StrainScorer.strain(hrSamples, maxHR: effMaxHR, restingHR: restHR),
                durationS: Double(end - start), zoneTimePct: zonePct, avgHRRPct: avgHRR,
                hrmax: effMaxHR, hrmaxSource: hrmaxSource, caloriesKcal: kcal, caloriesKJ: kj))
        }
        return sessions
    }

    static func cleanHR(_ hr: [HRSample]) -> [(ts: Int, bpm: Double)] {
        hr.map { (ts: $0.ts, bpm: Double($0.bpm)) }.sorted { $0.ts < $1.ts }
    }

    /// Resting heart rate as a low PERCENTILE of the day, not the minimum.
    ///
    /// The minimum of a day is a dropout beat. The tenth percentile is a real quiet reading.
    static func deriveRestingHR(_ hrSeg: [(ts: Int, bpm: Double)]) -> Double {
        let bpms = hrSeg.map(\.bpm).sorted()
        guard !bpms.isEmpty else { return 60 }
        let rank = max(1, Int(ceil(restingPercentile / 100.0 * Double(bpms.count))))
        return bpms[rank - 1]
    }

    /// Nearest heart-rate sample within tolerance, by binary search.
    ///
    /// Returns nil rather than the closest-at-any-distance: motion and HR arrive on different
    /// cadences, and pairing a movement with a reading from a minute away would attribute effort
    /// to the wrong moment.
    static func nearest(_ sortedTs: [Int], _ values: [Double], _ ts: Int, _ tol: Double) -> Double? {
        guard !sortedTs.isEmpty else { return nil }
        var lo = 0, hi = sortedTs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedTs[mid] < ts { lo = mid + 1 } else { hi = mid }
        }
        var bestV: Double?
        var bestD = tol
        for j in [lo - 1, lo] where j >= 0 && j < sortedTs.count {
            let d = abs(Double(sortedTs[j] - ts))
            if d <= bestD { bestD = d; bestV = values[j] }
        }
        return bestV
    }

    /// How much movement a sample must show, scaled by how hard the heart is working.
    ///
    /// A hard effort with little wrist movement is still exercise — a spin bike, a rower, a heavy
    /// carry. Holding the motion bar fixed rejects all of them. The requirement ramps down toward
    /// a floor as %HRR rises, so intensity can substitute for movement but never eliminate it.
    static func motionRequirement(bpm: Double, restingHR: Double, hrReserve: Double?) -> Double {
        guard let reserve = hrReserve, reserve > 0 else { return motionThreshold }
        let span = motionScaleHiHRR - motionScaleLoHRR
        guard span > 0 else { return motionThreshold }
        let hrr = StrainScorer.pctHRR(bpm, restingHR: restingHR, hrReserve: reserve)
        let t = min(1.0, max(0.0, (hrr - motionScaleLoHRR) / span))
        return motionThreshold + t * (motionThresholdFloor - motionThreshold)
    }

    /// Minutes at or above zone 3, assuming roughly one sample a second.
    static func zone3PlusMinutes(_ hrSeries: [(ts: Int, bpm: Double)],
                                 restingHR: Double, hrReserve: Double?) -> Double {
        guard let reserve = hrReserve, reserve > 0 else { return 0 }
        let n = hrSeries.filter {
            StrainScorer.pctHRR($0.bpm, restingHR: restingHR, hrReserve: reserve) >= zone3HRRPct
        }.count
        return Double(n) / 60.0
    }

    static func boutIntensity(_ hrSeries: [(ts: Int, bpm: Double)],
                              restingHR: Double, maxHR: Double) -> ([Int: Double], Double?) {
        guard !hrSeries.isEmpty, maxHR > restingHR else { return ([:], nil) }
        let hrReserve = maxHR - restingHR
        var zoneCounts = [Int: Int]()
        for z in 0...5 { zoneCounts[z] = 0 }
        var hrrVals: [Double] = []
        for r in hrSeries {
            zoneCounts[StrainScorer.zoneWeight(r.bpm, restingHR: restingHR, hrReserve: hrReserve), default: 0] += 1
            hrrVals.append(StrainScorer.pctHRR(r.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
        let n = Double(hrSeries.count)
        var zonePct = [Int: Double]()
        for (z, c) in zoneCounts { zonePct[z] = ((Double(c) / n * 100.0) * 10).rounded() / 10 }
        return (zonePct, ((hrrVals.reduce(0, +) / n) * 10).rounded() / 10)
    }

    /// Weld runs separated by a brief lull that still held exercise-level heart rate.
    ///
    /// A sustained effort should not shatter into fragments because of coasting, a junction, or a
    /// sensor dropout. An EMPTY gap bridges — no readings mid-effort is a dropout, not a rest —
    /// while a gap carrying ordinary waking heart rate does not.
    static func bridgeRuns(_ runs: [(Int, Int)], hrSeg: [(ts: Int, bpm: Double)],
                           bridgeFloor: Double) -> [(Int, Int)] {
        guard runs.count > 1 else { return runs }
        var merged: [(Int, Int)] = []
        var curStart = runs[0].0
        var curEnd = runs[0].1
        for next in runs.dropFirst() {
            var bridge = false
            if Double(next.0 - curEnd) <= bridgeGapS {
                let gapHR = hrSeg.filter { $0.ts > curEnd && $0.ts < next.0 }.map(\.bpm)
                bridge = gapHR.isEmpty
                    || (gapHR.reduce(0, +) / Double(gapHR.count)) > bridgeFloor
            }
            if bridge {
                curEnd = max(curEnd, next.1)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.0
                curEnd = next.1
            }
        }
        merged.append((curStart, curEnd))
        return merged
    }
}
