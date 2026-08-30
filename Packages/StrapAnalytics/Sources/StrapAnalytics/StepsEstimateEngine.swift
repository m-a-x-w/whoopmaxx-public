import Foundation
import StrapProtocol

/// Steps estimated from wrist motion, calibrated against a trusted step source.
///
/// The strap reports orientation change, not steps. This fits a single coefficient — steps per unit
/// of accumulated motion — from days where both a motion total and a real step count exist, then
/// applies it to days where only motion does. Everything here is an ESTIMATE and the confidence is
/// carried alongside it so a surface can say how much to trust the number.
public enum StepsEstimateEngine {

    public static let minCalibrationDays = 3
    /// Days at which the size term saturates.
    public static let goodCalibrationDays = 14
    /// Motion below this is a day barely worn; a ratio from it would be noise divided by noise.
    public static let minMotionForFit = 1.0
    /// A hard ceiling. Beyond this the coefficient is wrong, not the person extraordinary.
    public static let maxDailySteps = 60_000

    public struct CalibrationPoint: Equatable, Sendable {
        public let motion: Double
        public let steps: Double
        public init(motion: Double, steps: Double) { self.motion = motion; self.steps = steps }
    }

    public struct Calibration: Equatable, Sendable {
        public let coefficient: Double
        public let sampleDays: Int
        /// 0…1. Grows with sample size, discounted by how scattered the daily ratios are.
        public let confidence: Double
        /// True when the user set the coefficient themselves.
        public let manual: Bool
        public init(coefficient: Double, sampleDays: Int, confidence: Double, manual: Bool) {
            self.coefficient = coefficient; self.sampleDays = sampleDays
            self.confidence = confidence; self.manual = manual
        }
    }

    public enum ConfidenceTier: String, Equatable, Sendable {
        case low, medium, high

        public static func from(_ confidence: Double) -> ConfidenceTier {
            if confidence < 0.34 { return .low }
            if confidence < 0.67 { return .medium }
            return .high
        }

        public var word: String {
            switch self {
            case .low: return "low confidence"
            case .medium: return "medium confidence"
            case .high: return "high confidence"
            }
        }
    }

    public enum CalibrationStatus: Equatable, Sendable {
        case needsMoreDays(have: Int, need: Int)
        case manual(coefficient: Double, sampleDays: Int)
        case calibrated(coefficient: Double, sampleDays: Int, confidence: Double)
    }

    /// What state the calibration is in, phrased so a surface can explain itself.
    ///
    /// `needsMoreDays` carries both numbers so the UI can say "2 of 3" rather than an unexplained
    /// blank — the difference between an app that looks broken and one that is waiting.
    public static func status(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> CalibrationStatus {
        let usableDays = points.filter { $0.motion >= minMotionForFit && $0.steps > 0 }.count
        if let k = manualOverride, k > 0 { return .manual(coefficient: k, sampleDays: usableDays) }
        guard let cal = calibrate(points), usableDays >= minCalibrationDays else {
            return .needsMoreDays(have: usableDays, need: minCalibrationDays)
        }
        return .calibrated(coefficient: cal.coefficient, sampleDays: cal.sampleDays,
                           confidence: cal.confidence)
    }

    /// Total orientation change across a day — the quantity the coefficient scales.
    public static func dayMotionIntensity(_ grav: [GravitySample]) -> Double {
        guard grav.count > 1 else { return 0 }
        var total = 0.0
        var prev = grav[0]
        for i in 1..<grav.count {
            let r = grav[i]
            let dx = prev.x - r.x, dy = prev.y - r.y, dz = prev.z - r.z
            total += (dx * dx + dy * dy + dz * dz).squareRoot()
            prev = r
        }
        return total
    }

    /// Fit the coefficient.
    ///
    /// A WEIGHTED MEDIAN of the per-day ratios, weighted by each day's motion volume. Median rather
    /// than mean because one mis-synced day — a step count from a phone left on a desk — would
    /// otherwise drag the coefficient for every day after it. Weighted because a busy day carries
    /// more evidence about the relationship than a mostly-still one.
    public static func calibrate(_ points: [CalibrationPoint], manualOverride: Double? = nil) -> Calibration? {
        if let k = manualOverride, k > 0 {
            return Calibration(coefficient: k, sampleDays: points.count, confidence: 1.0, manual: true)
        }
        let weighted = points
            .filter { $0.motion >= minMotionForFit && $0.steps > 0 }
            .map { (ratio: $0.steps / $0.motion, weight: $0.motion) }
        guard weighted.count >= minCalibrationDays else { return nil }

        let ratios = weighted.map(\.ratio)
        let weights = weighted.map(\.weight)
        let k = weightedMedian(ratios, weights: weights)
        guard k > 0 else { return nil }

        // Confidence is half sample size and half agreement. A tight fit from few days and a
        // scattered fit from many are both mediocre, which is the honest answer for each.
        let sizeTerm = min(1.0, Double(weighted.count) / Double(goodCalibrationDays))
        let mad = weightedMedian(ratios.map { abs($0 - k) }, weights: weights)
        let tightness = max(0.0, 1.0 - (k > 0 ? mad / k : 1.0))
        let confidence = min(max(0.5 * sizeTerm + 0.5 * tightness, 0), 1)
        return Calibration(coefficient: k, sampleDays: weighted.count,
                           confidence: confidence, manual: false)
    }

    /// Apply the coefficient to a day's motion.
    ///
    /// Nil below the motion floor: a barely-worn day has no step count, which is different from
    /// a day of zero steps.
    public static func estimate(motion: Double, calibration: Calibration) -> Int? {
        guard motion >= minMotionForFit, calibration.coefficient > 0 else { return nil }
        return min(max(Int((motion * calibration.coefficient).rounded()), 0), maxDailySteps)
    }

    /// Median of `xs` weighted by `weights` — the value where half the total weight lies either side.
    static func weightedMedian(_ xs: [Double], weights: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        guard weights.count == xs.count else { return HRVAnalyzer.median(xs) }
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return HRVAnalyzer.median(xs) }

        let half = total / 2
        var cum = 0.0
        for (pos, idx) in order.enumerated() {
            cum += max(0, weights[idx])
            if cum > half { return xs[idx] }
            if cum == half {
                // Half the mass lands exactly on a boundary; average across it rather than
                // arbitrarily taking the lower side.
                let next = pos + 1 < order.count ? order[pos + 1] : idx
                return (xs[idx] + xs[next]) / 2
            }
        }
        return xs[order[order.count - 1]]
    }
}
