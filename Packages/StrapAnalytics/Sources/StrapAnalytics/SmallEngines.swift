import Foundation
import StrapProtocol

/// Baevsky's stress index — how CONCENTRATED the beat-interval histogram is.
///
/// A tense autonomic state produces beats clustered tightly around one interval; a relaxed one
/// spreads them out. That is a different question from RMSSD, which measures beat-to-beat change:
/// a series can be tightly clustered and still jittery, or wide and smooth. The two disagree
/// usefully, which is why both are kept.
public enum StressIndex {
    /// Histogram bin width in seconds — Baevsky's 50 ms convention.
    public static let binWidthSec: Double = 0.05
    public static let minBeats: Int = 20

    public struct Components: Equatable, Sendable {
        /// Mode: the modal bin's CENTRE, in seconds.
        public let moSec: Double
        /// Amplitude of the mode: percent of intervals in the modal bin.
        public let aMoPercent: Double
        /// Variation range, in seconds.
        public let mxDMnSec: Double
        public let si: Double
        public init(moSec: Double, aMoPercent: Double, mxDMnSec: Double, si: Double) {
            self.moSec = moSec; self.aMoPercent = aMoPercent
            self.mxDMnSec = mxDMnSec; self.si = si
        }
    }

    public static func stressIndex(rr: [RRInterval]) -> Double? { components(rr: rr)?.si }
    public static func stressIndex(rawRR: [Double]) -> Double? { components(rawRR: rawRR)?.si }
    public static func components(rr: [RRInterval]) -> Components? {
        components(rawRR: rr.map { Double($0.rrMs) })
    }

    public static func components(rawRR: [Double]) -> Components? {
        // Cleaned first: the index divides by the variation RANGE, so a single ectopic beat widens
        // the range and drives the result toward zero — the opposite of what the artefact implies.
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }

        let sec = clean.map { $0 / 1000.0 }
        let minV = sec.min()!, maxV = sec.max()!
        let mxDMn = maxV - minV
        // Perfectly equal beats give a zero range and an infinite index. Undefined, not enormous.
        guard mxDMn > 0 else { return nil }

        let binCount = max(1, Int((mxDMn / binWidthSec).rounded(.down)) + 1)
        var counts = [Int](repeating: 0, count: binCount)
        for v in sec {
            counts[min(binCount - 1, max(0, Int(((v - minV) / binWidthSec).rounded(.down))))] += 1
        }

        // Ties resolve to the LOWEST bin index, so the same beats give the same answer on every
        // platform rather than depending on iteration order.
        var modeIdx = 0, modeCount = counts[0]
        for i in 1..<binCount where counts[i] > modeCount { modeCount = counts[i]; modeIdx = i }

        let mo = minV + (Double(modeIdx) + 0.5) * binWidthSec
        guard mo > 0 else { return nil }
        let aMo = Double(modeCount) / Double(sec.count) * 100.0
        return Components(moSec: mo, aMoPercent: aMo, mxDMnSec: mxDMn,
                          si: aMo / (2.0 * mo * mxDMn))
    }
}

/// Whole-hour clock shift between two zones.
public enum TimeZoneShift {
    public static func shiftHours(homeOffsetSeconds: Int, destOffsetSeconds: Int) -> Double {
        normalizedShift(Double(destOffsetSeconds - homeOffsetSeconds) / 3600.0)
    }

    /// Fold a shift into −12…12.
    ///
    /// Flying east 20 hours is flying west 4. Reported unwrapped, every long-haul trip would claim
    /// an adaptation burden roughly twice what the body actually faces.
    public static func normalizedShift(_ raw: Double) -> Double {
        var s = raw.truncatingRemainder(dividingBy: 24.0)
        if s > 12.0 { s -= 24.0 }
        if s < -12.0 { s += 24.0 }
        return s
    }
}

/// Daily fluid target, and how to render progress toward it.
public enum HydrationGoal {
    public static let baselineMaleML = 3700
    public static let baselineFemaleML = 2700
    /// Used for anything else, including unset. The midpoint rather than a default sex.
    public static let baselineOtherML = 3200

    /// The most a maximal day adds. Bounded because the baseline already includes ordinary
    /// activity, and an unbounded bump would prescribe implausible volumes after one hard session.
    public static let maxEffortBumpML = 700
    public static let roundToML = 50

    public static let sipML = 30
    public static let cupML = 237
    public static let bottleML = 500

    public static func baselineForSex(_ sex: String) -> Int {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male", "m": return baselineMaleML
        case "female", "f": return baselineFemaleML
        default: return baselineOtherML
        }
    }

    /// Extra fluid for the day's effort, scaled linearly and clamped.
    ///
    /// A non-finite or missing effort adds nothing rather than propagating — a NaN here would make
    /// the whole goal unrenderable.
    public static func effortBump(effort: Double?) -> Int {
        guard let effort, effort.isFinite else { return 0 }
        return min(maxEffortBumpML, max(0, Int((effort / 100.0 * Double(maxEffortBumpML)).rounded())))
    }

    public static func roundToNearest(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return ((value + step / 2) / step) * step
    }

    /// Rounded to 50 ml, because a target of 3,847 ml implies a precision nobody has.
    public static func dailyGoalML(sex: String, effort: Double?) -> Int {
        roundToNearest(baselineForSex(sex) + effortBump(effort: effort), step: roundToML)
    }

    public static func litres(fromML ml: Double) -> Double { ml / 1000.0 }

    public static func cardValueString(totalML: Double, goalML: Int) -> String {
        String(format: "%.1f / %.1f L", litres(fromML: totalML), litres(fromML: Double(goalML)))
    }

    /// Progress, clamped to 0…1 so a ring cannot overfill or invert.
    public static func fraction(totalML: Double, goalML: Int) -> Double {
        guard goalML > 0 else { return 0 }
        return min(1.0, max(0.0, totalML / Double(goalML)))
    }
}
