import Foundation
import StrapProtocol

/// The person the estimates are about. Defaults are population averages, used only when a field
/// is genuinely unset — a zero weight is treated as "unknown", not as a weightless user.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double
    public var age: Double
    /// "male" | "female" | "nonbinary"
    public var sex: String
    /// Raw accelerometer ticks the strap reports per real step.
    public var stepTicksPerStep: Double

    public init(weightKg: Double = 70.0, heightCm: Double = 170.0, age: Double = 30.0,
                sex: String = "nonbinary", stepTicksPerStep: Double = 1.0) {
        self.weightKg = weightKg; self.heightCm = heightCm; self.age = age
        self.sex = sex; self.stepTicksPerStep = stepTicksPerStep
    }
}

/// Energy expenditure from heart rate.
///
/// Two published equations, both fitted on populations rather than on this person: Harris–Benedict
/// for basal metabolism and Keytel for the heart-rate-driven active rate. Every number out of here
/// is an ESTIMATE, and the column it feeds is named `activeKcalEst` for that reason.
public enum Calories {

    struct Coeffs {
        let restingAlpha: Double
        let restingWeight: Double
        /// Applied to height in METRES, not centimetres.
        let restingHeight: Double
        let restingAge: Double
        let workoutHR: Double
        let workoutWeight: Double
        let workoutAge: Double
        let workoutAlpha: Double
    }

    static let male = Coeffs(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9,
                             restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988,
                             workoutAge: 0.2017, workoutAlpha: -55.0969)
    static let female = Coeffs(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8,
                               restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263,
                               workoutAge: 0.0740, workoutAlpha: -20.4022)
    /// The midpoint of the two published sets. Not a fitted equation — no such study exists — but
    /// preferable to silently assigning someone one of the other two.
    static let nonbinary = Coeffs(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85,
                                  restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625,
                                  workoutAge: 0.13785, workoutAlpha: -37.74955)

    /// Fraction of heart-rate reserve above which a BOUT sample counts as active.
    public static let activeHRRFraction = 0.30
    /// The whole-day gate, deliberately HIGHER. Over a day, ordinary standing and walking would
    /// otherwise be billed at an exercise rate and inflate the total substantially.
    public static let dayActiveHRRFraction = 0.50
    /// 60 s/min × 4.184 kJ/kcal — Keytel returns kJ per minute.
    static let workoutDivisor = 251.04
    /// Longest gap credited as continuous effort.
    public static let mergeGapS: Double = 150.0

    static func resolveCoeffs(_ sex: String) -> Coeffs {
        switch sex.lowercased() {
        case "male": return male
        case "female": return female
        default: return nonbinary
        }
    }

    /// Basal metabolic rate, per second.
    static func restingKcalPerS(_ c: Coeffs, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let bmr = c.restingAlpha + c.restingWeight * weightKg
                + c.restingHeight * (heightCm / 100.0) - c.restingAge * age
        return max(0, bmr) / 86_400.0
    }

    /// Keytel's heart-rate rate, per second.
    ///
    /// Heart rate is capped at the assumed maximum: a reading above it is an artefact or a wrong
    /// maximum, and extrapolating the fit past its range produces a very confident large number.
    static func activeKcalPerS(_ c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double) -> Double {
        let eeKjMin = c.workoutHR * min(hr, hrmax) + c.workoutWeight * weightKg
                    + c.workoutAge * age + c.workoutAlpha
        return max(0, eeKjMin) / workoutDivisor
    }

    static func resolved(_ profile: UserProfile) -> (w: Double, h: Double, a: Double, c: Coeffs) {
        (profile.weightKg > 0 ? profile.weightKg : 70.0,
         profile.heightCm > 0 ? profile.heightCm : 170.0,
         profile.age > 0 ? profile.age : 30.0,
         resolveCoeffs(profile.sex))
    }

    /// Energy for one bout, as (kcal, kJ).
    ///
    /// Each sample is weighted by the ACTUAL elapsed time to the next one, not a flat second. The
    /// rates are per-second, so summing one per sample is only correct at exactly 1 Hz — a sparse
    /// stream would undercount roughly in proportion to its coverage gap, collapsing a real
    /// session toward a kcal or two. Intervals are capped at `mergeGapS`, so a brief dropout is
    /// fully counted while a wear gap cannot inflate a single reading.
    public static func estimateBoutCalories(_ hrSamples: [HRSample],
                                            profile: UserProfile,
                                            hrmax: Double?,
                                            restingHR: Double?) -> (Double, Double) {
        let (weightKg, heightCm, age, coeffs) = resolved(profile)
        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)
        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)

        let ordered = hrSamples.sorted { $0.ts < $1.ts }
        var totalKcal = 0.0
        for i in ordered.indices {
            let bpm = Double(ordered[i].bpm)
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, mergeGapS) : 1.0
            } else {
                dur = 1.0
            }
            totalKcal += bpm < activeThreshold
                ? restingRate * dur
                : activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age) * dur
        }
        return (totalKcal, totalKcal * 4.184)
    }

    /// Whole-day energy in kcal.
    ///
    /// Samples are counted one second each rather than gap-weighted: over a day the gaps are
    /// mostly the strap being off, and crediting those at any rate would bill hours nobody wore it.
    public static func estimateDayCalories(_ hrSamples: [HRSample],
                                           profile: UserProfile,
                                           hrmax: Double?,
                                           restingHR: Double?) -> Double {
        guard !hrSamples.isEmpty else { return 0 }
        let (weightKg, heightCm, age, coeffs) = resolved(profile)
        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + dayActiveHRRFraction * (effHRmax - effResting)
        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)

        var totalKcal = 0.0
        for s in hrSamples {
            let bpm = Double(s.bpm)
            if bpm < activeThreshold {
                totalKcal += restingRate
            } else {
                // Floored at the basal rate: a worn second never burns LESS than resting
                // metabolism, and the Keytel fit dips below it for some profiles just above the
                // gate — which would make a moderately active minute cost less than lying still.
                totalKcal += max(restingRate,
                                 activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax,
                                                weightKg: weightKg, age: age))
            }
        }
        return totalKcal
    }
}
