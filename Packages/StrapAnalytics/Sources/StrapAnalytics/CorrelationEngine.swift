import Foundation

/// One relationship between two day-keyed series.
public struct Correlation: Equatable, Sendable {
    /// Pearson r, in −1…1.
    public let r: Double
    /// Pairs the correlation was computed over — not the length of either input.
    public let n: Int
    /// Two-sided p for the null of no correlation.
    ///
    /// Named approximate because it assumes both variables are normal and the observations
    /// independent. Consecutive days of a physiological series are neither, so this ranks
    /// candidates rather than establishing anything.
    public let pApprox: Double
    /// Least-squares fit, for drawing the line.
    public let slope: Double
    public let intercept: Double

    public init(r: Double, n: Int, pApprox: Double, slope: Double, intercept: Double) {
        self.r = r; self.n = n; self.pApprox = pApprox
        self.slope = slope; self.intercept = intercept
    }
}

/// Correlations between day-keyed series, with the multiple-comparison correction that makes them
/// worth reporting.
///
/// Everything here exists to answer "does X track Y for me". Scanning dozens of metric pairs
/// guarantees some will look significant by chance — with 50 pairs at p < 0.05 roughly two or
/// three spurious hits are EXPECTED — so a raw p from this engine is not a finding until it has
/// been through one of the corrections below.
public enum CorrelationEngine {

    /// Pearson correlation with its regression line.
    ///
    /// Fewer than three pairs has no residual degrees of freedom; two points fit a line exactly
    /// and would report r = ±1 for any data at all.
    public static func pearson(_ xy: [(Double, Double)]) -> Correlation? {
        let n = xy.count
        guard n >= 3 else { return nil }
        let nD = Double(n)

        var sumX = 0.0, sumY = 0.0
        for p in xy { sumX += p.0; sumY += p.1 }
        let meanX = sumX / nD, meanY = sumY / nD

        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in xy {
            let dx = p.0 - meanX, dy = p.1 - meanY
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        // A constant series has no correlation to measure — not a correlation of zero.
        guard sxx > 0, syy > 0 else { return nil }

        // Clamped: floating-point error can push a perfect fit a hair past 1, and |r| > 1 breaks
        // every consumer that trusts the range.
        let r = max(-1.0, min(1.0, sxy / (sxx.squareRoot() * syy.squareRoot())))
        let slope = sxy / sxx
        return Correlation(r: r, n: n, pApprox: pValue(r: r, n: n),
                           slope: slope, intercept: meanY - slope * meanX)
    }

    /// Two-sided p via the t transform of r.
    static func pValue(r: Double, n: Int) -> Double {
        guard n > 2 else { return 1.0 }
        let oneMinusR2 = 1.0 - r * r
        if oneMinusR2 <= 0 { return 0.0 }
        let df = Double(n - 2)
        let t = r * (df / oneMinusR2).squareRoot()
        return regularizedIncompleteBeta(df / (df + t * t), df / 2.0, 0.5)
    }

    // MARK: - Alignment

    /// Pair two series on the days they share.
    ///
    /// An INNER join: a day present in only one series is dropped rather than filled. Filling it
    /// with a mean or a zero would manufacture agreement on exactly the days with no evidence.
    public static func alignByDay(_ a: [(day: String, value: Double)],
                                  _ b: [(day: String, value: Double)]) -> [(Double, Double)] {
        var mapA: [String: Double] = [:]
        for row in a { mapA[row.day] = row.value }
        var mapB: [String: Double] = [:]
        for row in b { mapB[row.day] = row.value }
        return mapA.keys.filter { mapB[$0] != nil }.sorted().map { (mapA[$0]!, mapB[$0]!) }
    }

    /// Correlate x against y shifted by whole days.
    ///
    /// A lag is how the question "did last night's sleep affect today" is actually asked. Days are
    /// shifted through the calendar rather than by index, so a gap in either series does not
    /// silently slide the alignment.
    public static func lagged(x: [(day: String, value: Double)],
                              y: [(day: String, value: Double)],
                              lagDays: Int) -> Correlation? {
        var mapY: [String: Double] = [:]
        for row in y { mapY[row.day] = row.value }
        var pairs: [(Double, Double)] = []
        for row in x.sorted(by: { $0.day < $1.day }) {
            guard let shifted = shiftDay(row.day, by: lagDays), let yv = mapY[shifted] else { continue }
            pairs.append((row.value, yv))
        }
        return pearson(pairs)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Move a day key by whole days through the calendar.
    static func shiftDay(_ day: String, by days: Int) -> String? {
        guard let d = dayFormatter.date(from: day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let shifted = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        return dayFormatter.string(from: shifted)
    }

    // MARK: - Multiple comparisons

    /// Benjamini–Hochberg, controlling the false-discovery rate.
    ///
    /// The right correction for this kind of exploration: it accepts a known proportion of false
    /// positives among the hits rather than guarding against any at all, which keeps real effects
    /// visible in a scan where Bonferroni would hide everything.
    ///
    /// Results are returned in INPUT order, and the step-up ceiling keeps them monotone — without
    /// it a smaller raw p can come back with a larger adjusted value, which reads as nonsense next
    /// to its neighbour.
    public static func benjaminiHochberg(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let mD = Double(m)
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var adjusted = [Double](repeating: 0, count: m)
        var ceiling = 1.0
        for rank in stride(from: m, through: 1, by: -1) {
            let idx = order[rank - 1]
            ceiling = min(ceiling, min(1.0, pValues[idx] * mD / Double(rank)))
            adjusted[idx] = ceiling
        }
        return adjusted
    }

    /// Bonferroni. Strict, and kept for the cases where one false positive is worse than missing
    /// a real effect.
    public static func bonferroni(_ pValues: [Double]) -> [Double] {
        let m = Double(pValues.count)
        return pValues.map { min(1.0, $0 * m) }
    }

    /// Standard normal CDF, via the error function.
    ///
    /// Used where a t-distribution would be marginally more correct but the difference is far
    /// smaller than the assumptions already being made about independence.
    public static func normalCDF(_ x: Double) -> Double {
        0.5 * (1.0 + erf(x / 2.0.squareRoot()))
    }

    // MARK: - Incomplete beta

    /// Regularised incomplete beta I_x(a, b), by continued fraction.
    static func regularizedIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }

        let logBeta: Double = lgamma(a + b) - lgamma(a) - lgamma(b)
        let logX: Double = a * log(x)
        let logY: Double = b * log(1 - x)
        let front: Double = exp(logBeta + logX + logY)

        // The continued fraction converges quickly only on one side of the distribution; the
        // symmetry relation moves the other side across rather than iterating into the tail.
        let pivot: Double = (a + 1) / (a + b + 2)
        if x < pivot {
            return front * betaContinuedFraction(x, a, b) / a
        }
        let mirrored: Double = front * betaContinuedFraction(1 - x, b, a) / b
        return 1 - mirrored
    }

    /// Lentz's algorithm for the beta continued fraction.
    private static func betaContinuedFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-30
        let epsilon = 3e-12
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d

        for m in 1...200 {
            let mD = Double(m)
            let m2 = 2 * mD

            // Even step.
            var numerator = mD * (b - mD) * x / ((a + m2 - 1) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c

            // Odd step.
            numerator = -(a + mD) * (a + b + mD) * x / ((a + m2) * (a + m2 + 1))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
        }
        return h
    }
}
