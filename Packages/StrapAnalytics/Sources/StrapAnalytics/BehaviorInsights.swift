import Foundation

/// What one logged behaviour did to one outcome, on the days it was logged.
public struct BehaviorEffect: Equatable, Sendable {
    public let behavior: String
    public let outcome: String
    public let meanWith: Double
    public let meanWithout: Double
    public let delta: Double
    public let pctChange: Double?
    /// Group sizes, carried so a reader can see how thin the comparison is.
    public let nWith: Int
    public let nWithout: Int
    /// Standardised effect size — the difference in pooled standard deviations. Reported alongside
    /// p because a tiny effect can be significant with enough days, and a large one can miss
    /// significance with few. They answer different questions and neither replaces the other.
    public let cohensD: Double
    public let pApprox: Double
    public let significant: Bool

    public init(behavior: String, outcome: String, meanWith: Double, meanWithout: Double,
                delta: Double, pctChange: Double?, nWith: Int, nWithout: Int,
                cohensD: Double, pApprox: Double, significant: Bool) {
        self.behavior = behavior; self.outcome = outcome
        self.meanWith = meanWith; self.meanWithout = meanWithout
        self.delta = delta; self.pctChange = pctChange
        self.nWith = nWith; self.nWithout = nWithout
        self.cohensD = cohensD; self.pApprox = pApprox; self.significant = significant
    }
}

/// Does a logged behaviour move an outcome.
///
/// This is observational and self-reported on both sides — the behaviour and the day it is
/// attributed to — so nothing here establishes cause. Someone logs "late meal" on the days they
/// were out late, and being out late is the thing that moved their sleep. The output is phrased
/// as an association throughout for that reason.
public enum BehaviorInsights {

    /// Days needed in the SMALLER group before an effect may be called significant.
    ///
    /// Without it, one logged day against ninety produces a tiny p and a confident sentence from a
    /// single evening.
    public static let minGroupForSignificance: Int = 5
    public static let alpha: Double = 0.05

    /// Compare the days a behaviour was logged against the days it was not.
    public static func effect(behaviorDays: Set<String>,
                              outcomeByDay: [String: Double],
                              behavior: String,
                              outcome: String) -> BehaviorEffect? {
        var withVals: [Double] = []
        var withoutVals: [Double] = []
        for (day, value) in outcomeByDay {
            if behaviorDays.contains(day) { withVals.append(value) } else { withoutVals.append(value) }
        }

        let n1 = withVals.count, n2 = withoutVals.count
        // Both groups must exist, and there must be enough points for a variance estimate at all.
        guard n1 >= 1, n2 >= 1, n1 + n2 >= 3 else { return nil }

        let m1 = withVals.reduce(0, +) / Double(n1)
        let m2 = withoutVals.reduce(0, +) / Double(n2)
        let delta = m1 - m2
        // Absolute denominator, so an outcome that can go negative does not invert its own change.
        let pct: Double? = m2 != 0 ? (delta / abs(m2) * 100.0) : nil

        let v1 = sampleVariance(withVals, mean: m1)
        let v2 = sampleVariance(withoutVals, mean: m2)
        let p = welchP(m1: m1, v1: v1, n1: n1, m2: m2, v2: v2, n2: n2)

        return BehaviorEffect(behavior: behavior, outcome: outcome,
                              meanWith: m1, meanWithout: m2, delta: delta, pctChange: pct,
                              nWith: n1, nWithout: n2,
                              cohensD: cohensD(m1: m1, m2: m2, n1: n1, v1: v1, n2: n2, v2: v2),
                              pApprox: p,
                              significant: p < alpha && Swift.min(n1, n2) >= minGroupForSignificance)
    }

    /// Every behaviour against one outcome, strongest first.
    ///
    /// Ordered by significance, then by absolute effect SIZE, then by name. Size before p because a
    /// long history makes trivial differences significant, and a list sorted by p alone puts the
    /// least interesting findings at the top. The name tiebreak keeps the order stable across
    /// launches — a dictionary's iteration order would otherwise reshuffle equal rows.
    public static func rank(behaviors: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [BehaviorEffect] {
        behaviors.compactMap { name, days in
            effect(behaviorDays: days, outcomeByDay: outcomeByDay, behavior: name, outcome: outcome)
        }.sorted { a, b in
            if a.significant != b.significant { return a.significant }
            let la = abs(a.cohensD), lb = abs(b.cohensD)
            if la != lb { return la > lb }
            return a.behavior < b.behavior
        }
    }

    /// A plain-language sentence.
    ///
    /// Always quotes BOTH group sizes. A reader shown "18% lower" with no n cannot tell a season
    /// of evidence from a fortnight, and the sentence would carry more authority than the data.
    public static func sentence(_ e: BehaviorEffect) -> String {
        let directionWord = e.delta > 0 ? "higher" : (e.delta < 0 ? "lower" : "unchanged")
        let magnitude: String
        if e.delta == 0 {
            magnitude = "no different"
        } else if let pct = e.pctChange {
            magnitude = "\(Int(abs(pct).rounded()))% \(directionWord)"
        } else {
            magnitude = "\((abs(e.delta) * 10).rounded() / 10) \(directionWord)"
        }
        return "On days you logged '\(e.behavior)', \(e.outcome) was \(magnitude) "
            + "(avg \(Int(e.meanWith.rounded())) vs \(Int(e.meanWithout.rounded())), "
            + "n=\(e.nWith) vs \(e.nWithout))."
    }

    static func sampleVariance(_ values: [Double], mean: Double) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        return values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
    }

    /// Cohen's d over the pooled standard deviation.
    ///
    /// KNOWN EDGE: with zero variance in BOTH groups the pooled deviation is zero and d is
    /// mathematically undefined. This returns 0, which means a PERFECTLY separated effect — every
    /// "with" day identical, every "without" day identical — sorts last in any ranking by |d|,
    /// even though its p is 0 and it is flagged significant. Real physiological data always
    /// carries variance so this does not arise in practice, but a synthetic or heavily rounded
    /// series can hit it. Ranking consumers should treat significance as the primary key, which
    /// `rank` does.
    static func cohensD(m1: Double, m2: Double, n1: Int, v1: Double, n2: Int, v2: Double) -> Double {
        let df = n1 + n2 - 2
        guard df > 0 else { return 0 }
        let sp = ((Double(n1 - 1) * v1 + Double(n2 - 1) * v2) / Double(df)).squareRoot()
        guard sp > 0 else { return 0 }
        return (m1 - m2) / sp
    }

    /// Welch's t-test, which does NOT assume the two groups share a variance.
    ///
    /// That matters here: the "with" group is usually far smaller and often more variable —
    /// people log unusual days — and the equal-variance form would understate the p exactly where
    /// the evidence is thinnest.
    static func welchP(m1: Double, v1: Double, n1: Int, m2: Double, v2: Double, n2: Int) -> Double {
        let se2 = v1 / Double(n1) + v2 / Double(n2)
        guard se2 > 0 else {
            // No spread in either group: identical means prove nothing, differing ones are
            // certain. Both are degenerate, and returning NaN would poison every sort.
            return m1 == m2 ? 1.0 : 0.0
        }
        return 2.0 * (1.0 - CorrelationEngine.normalCDF(abs((m1 - m2) / se2.squareRoot())))
    }
}
