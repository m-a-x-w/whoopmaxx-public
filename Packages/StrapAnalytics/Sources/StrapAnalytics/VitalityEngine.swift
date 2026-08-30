import Foundation

/// A "body age" from habits and vitals — deliberately hedged.
///
/// Each factor's coefficient is a published population hazard ratio, and the whole sum is shrunk
/// before use because those coefficients OVERLAP: fitness, resting heart rate and HRV are three
/// views of one cardiovascular state, and adding their independent hazards as if they were
/// separate causes double-counts the same thing. The output carries a ±5-year band for the same
/// reason — a body age quoted to the year would claim a precision this method does not have.
public enum VitalityEngine {

    /// A hazard doubling is treated as eight years of ageing.
    static let lnHazardPerYear = 0.6931471805599453 / 8.0
    /// Shrinkage applied to the summed log-hazard, for the overlap described above.
    static let overlapShrink = 0.75
    static let minBodyAge = 20.0, maxBodyAge = 90.0
    /// Each year younger than chronological age is worth this many Vitality points.
    static let vitalityPerYear = 2.5

    /// Factors required before anything is reported.
    ///
    /// Three, because a body age computed from one habit is an opinion about that habit dressed
    /// as a measurement of a person.
    public static let minFactors = 3
    public static let bandYears = 5.0

    public struct Inputs: Equatable, Sendable {
        public var chronoAge: Double
        public var restingHR: Double?
        public var vo2max: Double?
        /// The age/sex-expected VO2max this is judged against.
        public var expectedVO2max: Double?
        public var sleepHours: Double?
        /// 0…1, where 1 is perfectly regular.
        public var sleepConsistency: Double?
        public var rmssd: Double?
        public var rmssdNorm: Double?
        public var steps: Double?

        public init(chronoAge: Double, restingHR: Double? = nil, vo2max: Double? = nil,
                    expectedVO2max: Double? = nil, sleepHours: Double? = nil,
                    sleepConsistency: Double? = nil, rmssd: Double? = nil,
                    rmssdNorm: Double? = nil, steps: Double? = nil) {
            self.chronoAge = chronoAge; self.restingHR = restingHR; self.vo2max = vo2max
            self.expectedVO2max = expectedVO2max; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.rmssd = rmssd
            self.rmssdNorm = rmssdNorm; self.steps = steps
        }
    }

    /// One factor's contribution, in log-hazard. Negative is protective.
    public struct Contribution: Equatable, Sendable {
        public let key: String
        public let label: String
        public let lnHazard: Double
        public init(key: String, label: String, lnHazard: Double) {
            self.key = key; self.label = label; self.lnHazard = lnHazard
        }
    }

    public struct Result: Equatable, Sendable {
        /// 0–100, where 50 is typical for the person's age.
        public let vitality: Double
        public let bodyAge: Double
        public let chronoAge: Double
        /// Positive means younger than chronological age.
        public let deltaYears: Double
        /// The uncertainty band the body age should always be shown with.
        public let bandYears: Double
        public let contributions: [Contribution]
        public let factorsUsed: Int

        public init(vitality: Double, bodyAge: Double, chronoAge: Double, deltaYears: Double,
                    bandYears: Double, contributions: [Contribution], factorsUsed: Int) {
            self.vitality = vitality; self.bodyAge = bodyAge; self.chronoAge = chronoAge
            self.deltaYears = deltaYears; self.bandYears = bandYears
            self.contributions = contributions; self.factorsUsed = factorsUsed
        }
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// Age-normative nocturnal RMSSD, interpolated between published anchors.
    ///
    /// HRV falls steeply with age, so judging a 60-year-old against a 25-year-old's normal would
    /// report every older user as ageing badly.
    public static func rmssdNorm(forAge age: Double) -> Double {
        let anchors: [(Double, Double)] = [(20, 47), (30, 40), (40, 33), (50, 29),
                                           (60, 25), (70, 22), (80, 20)]
        if age <= anchors[0].0 { return anchors[0].1 }
        if age >= anchors[anchors.count - 1].0 { return anchors[anchors.count - 1].1 }
        for i in 1..<anchors.count where age <= anchors[i].0 {
            let (a0, v0) = anchors[i - 1], (a1, v1) = anchors[i]
            return v0 + (v1 - v0) * (age - a0) / (a1 - a0)
        }
        return anchors[anchors.count - 1].1
    }

    /// Sleep regularity as 1 minus the coefficient of variation.
    ///
    /// Relative rather than absolute: an hour of night-to-night swing means something different
    /// for a five-hour sleeper than a nine-hour one.
    public static func sleepConsistency(nightlyHours: [Double]) -> Double? {
        let xs = nightlyHours.filter { $0 > 0 }
        guard xs.count >= 3 else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        guard mean > 0 else { return nil }
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return clamp(1 - variance.squareRoot() / mean, 0, 1)
    }

    /// Each available factor's log-hazard. Absent inputs contribute NOTHING rather than a neutral
    /// value, so a missing factor cannot quietly pull the result toward average.
    public static func contributions(_ inputs: Inputs) -> [Contribution] {
        var out: [Contribution] = []

        if let rhr = inputs.restingHR {
            out.append(Contribution(key: "rhr", label: "Resting heart rate",
                                    lnHazard: ((rhr - 65) / 10) * 0.100))
        }
        if let vo2 = inputs.vo2max, let exp = inputs.expectedVO2max, exp > 0 {
            // Fitter than expected makes this negative, hence protective.
            out.append(Contribution(key: "vo2max", label: "Cardio fitness",
                                    lnHazard: clamp((exp - vo2) / 3.5, -4, 4) * 0.130))
        }
        if let sh = inputs.sleepHours {
            // Deviation in EITHER direction, with a neutral half-hour either side of the optimum.
            // Both too little and too much sleep carry risk, and a signed term would let one
            // cancel the other.
            let dev = max(0, abs(sh - 7.5) - 0.5)
            out.append(Contribution(key: "sleep", label: "Sleep duration",
                                    lnHazard: clamp(dev, 0, 3) * 0.110))
        }
        if let c = inputs.sleepConsistency {
            out.append(Contribution(key: "consistency", label: "Sleep regularity",
                                    lnHazard: (0.75 - clamp(c, 0, 1)) * 0.450))
        }
        if let h = inputs.rmssd, let norm = inputs.rmssdNorm, norm > 0 {
            out.append(Contribution(key: "hrv", label: "Heart-rate variability",
                                    lnHazard: clamp((norm - h) / norm, -1, 1) * 0.160))
        }
        if let s = inputs.steps {
            // Protection caps around 11k: the benefit flattens, and an uncapped term would let a
            // very high step count offset everything else.
            let deficit = (7000 - clamp(s, 0, 11000)) / 1000
            out.append(Contribution(key: "steps", label: "Daily steps",
                                    lnHazard: clamp(deficit, -4, 4) * 0.064))
        }
        return out
    }

    /// Compute a body age, or nil when there is not enough to say.
    public static func compute(_ inputs: Inputs) -> Result? {
        guard inputs.chronoAge > 0 else { return nil }
        let contribs = contributions(inputs)
        guard contribs.count >= minFactors else { return nil }

        let sumLn = contribs.reduce(0) { $0 + $1.lnHazard } * overlapShrink
        let bodyAge = clamp(inputs.chronoAge + sumLn / lnHazardPerYear, minBodyAge, maxBodyAge)
        let delta = inputs.chronoAge - bodyAge
        return Result(vitality: clamp(50 + delta * vitalityPerYear, 0, 100),
                      bodyAge: bodyAge, chronoAge: inputs.chronoAge, deltaYears: delta,
                      bandYears: bandYears, contributions: contribs, factorsUsed: contribs.count)
    }
}

/// Which behaviour a dose-response prior describes.
public enum DosedBehavior: String, Equatable, Sendable, Codable { case alcohol, caffeine }

/// A published expectation for how a dose moves an outcome.
public struct DoseResponsePrior: Equatable, Sendable {
    public let behavior: DosedBehavior
    public let outcome: String
    public let slopePerUnit: Double
    public let clampLow: Double
    public let clampHigh: Double
    public init(behavior: DosedBehavior, outcome: String, slopePerUnit: Double,
                clampLow: Double, clampHigh: Double) {
        self.behavior = behavior; self.outcome = outcome; self.slopePerUnit = slopePerUnit
        self.clampLow = clampLow; self.clampHigh = clampHigh
    }
}

/// Priors for shrinking a thin personal dose-response fit toward a documented expectation.
///
/// A pair with no documented prior returns nil, and the engine then cannot shrink — so a personal
/// fit from a handful of days is reported unshrunk or not at all, rather than being pulled toward
/// a number nobody published.
public enum DoseResponsePriors {
    static let table: [DoseResponsePrior] = [
        DoseResponsePrior(behavior: .alcohol, outcome: "Charge",
                          slopePerUnit: -5.0, clampLow: -15.0, clampHigh: 2.0),
        DoseResponsePrior(behavior: .caffeine, outcome: "HRV",
                          slopePerUnit: -4.0, clampLow: -20.0, clampHigh: 4.0),
    ]

    public static func defaultOutcome(for behavior: DosedBehavior) -> String {
        switch behavior {
        case .alcohol: return "Charge"
        case .caffeine: return "HRV"
        }
    }

    public static func prior(for behavior: DosedBehavior, outcome: String) -> DoseResponsePrior? {
        table.first { $0.behavior == behavior && $0.outcome == outcome }
    }

    public static func prior(for behavior: DosedBehavior) -> DoseResponsePrior? {
        prior(for: behavior, outcome: defaultOutcome(for: behavior))
    }
}
