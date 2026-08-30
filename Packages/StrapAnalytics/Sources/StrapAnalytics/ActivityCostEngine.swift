import Foundation

/// How confident a derived score is, in the shared vocabulary.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating, building, solid
}

/// What one kind of session costs the next morning.
public struct ActivityCost: Equatable, Sendable {
    public let sport: String
    /// Charge points LOST. Positive is a cost; negative means the sport leaves you better off.
    public let delta: Double
    public let meanNextMorning: Double
    public let baselineMean: Double
    /// Days until the mornings after a session are back within tolerance of baseline, or nil when
    /// they never are inside the lookahead.
    public let daysToBaseline: Int?
    public let n: Int
    public let confidence: ScoreConfidence

    public init(sport: String, delta: Double, meanNextMorning: Double, baselineMean: Double,
                daysToBaseline: Int?, n: Int, confidence: ScoreConfidence) {
        self.sport = sport; self.delta = delta; self.meanNextMorning = meanNextMorning
        self.baselineMean = baselineMean; self.daysToBaseline = daysToBaseline
        self.n = n; self.confidence = confidence
    }

    /// A plain-language line. Always carries `n`, so a reader can weigh it.
    public func sentence() -> String {
        let mag = abs(delta)
        let points = Int(mag.rounded())
        if mag < ActivityCostEngine.barelyMovesPoints {
            return "Sessions like this barely move your next-day Charge (n=\(n))."
        }
        let direction = delta >= 0 ? "cost you" : "lift"
        let head = "Sessions like this usually \(direction) about \(points) Charge "
            + "point\(points == 1 ? "" : "s") the next morning"
        if let days = daysToBaseline {
            return head + " and take about \(days) day\(days == 1 ? "" : "s") to bounce back (n=\(n))."
        }
        return head + " (n=\(n))."
    }
}

/// What each sport costs, measured against genuinely untouched days.
public enum ActivityCostEngine {

    /// Sessions before a sport is reported at all.
    public static let minSessions: Int = 4
    public static let solidSessions: Int = 8
    /// How far forward recovery is traced.
    public static let maxLookahead: Int = 7
    /// Charge points within which a morning counts as back to baseline.
    public static let tolerance: Double = 3.0
    /// Below this the effect is reported as negligible rather than as a number.
    public static let barelyMovesPoints: Double = 1.0

    public static func evaluate(activityDaysBySport: [String: Set<String>],
                                recoveryByDay: [String: Double]) -> [ActivityCost] {
        guard !activityDaysBySport.isEmpty, !recoveryByDay.isEmpty else { return [] }

        // The baseline is days that are neither tagged with ANY sport NOR inside the forward
        // recovery window of one.
        //
        // Excluding that window is the crux. The mornings AFTER a session are exactly the days a
        // cost suppresses, so counting them as rest contaminates the baseline with the very thing
        // being measured — and every cost comes out understated, uniformly, in a way no single
        // number looks wrong.
        var activeUnion: Set<String> = []
        for (_, days) in activityDaysBySport { activeUnion.formUnion(days) }
        var affected = activeUnion
        for day in activeUnion {
            for k in 1...maxLookahead {
                if let d = CorrelationEngine.shiftDay(day, by: k) { affected.insert(d) }
            }
        }

        let restValues = recoveryByDay.filter { !affected.contains($0.key) }.map(\.value)
        // No untouched days means no baseline, and nothing honest to say about any sport.
        guard !restValues.isEmpty else { return [] }
        let baselineMean = mean(restValues)

        var results: [ActivityCost] = []
        // Sorted so the build order is deterministic whatever the dictionary's iteration order.
        for sport in activityDaysBySport.keys.sorted() {
            let taggedDays = activityDaysBySport[sport]!
            let nextMornings = taggedDays.compactMap { day -> Double? in
                CorrelationEngine.shiftDay(day, by: 1).flatMap { recoveryByDay[$0] }
            }
            // A thin sport is omitted ENTIRELY rather than shown with a caveat. Four sessions is
            // already generous for a claim about how a workout affects you.
            guard nextMornings.count >= minSessions else { continue }

            let meanNextMorning = mean(nextMornings)
            results.append(ActivityCost(
                sport: sport,
                delta: baselineMean - meanNextMorning,
                meanNextMorning: meanNextMorning,
                baselineMean: baselineMean,
                daysToBaseline: forwardDaysToBaseline(taggedDays: taggedDays,
                                                      recoveryByDay: recoveryByDay,
                                                      baselineMean: baselineMean),
                n: nextMornings.count,
                confidence: nextMornings.count >= solidSessions ? .solid : .building))
        }
        return rank(results)
    }

    /// The first day after a session whose mean Charge is back within tolerance.
    ///
    /// Days with no data are SKIPPED rather than treated as unrecovered, so a gap in the history
    /// does not turn a two-day bounce-back into "never recovers".
    static func forwardDaysToBaseline(taggedDays: Set<String>,
                                      recoveryByDay: [String: Double],
                                      baselineMean: Double) -> Int? {
        let target = baselineMean - tolerance
        for k in 1...maxLookahead {
            let vals = taggedDays.compactMap { day -> Double? in
                CorrelationEngine.shiftDay(day, by: k).flatMap { recoveryByDay[$0] }
            }
            guard !vals.isEmpty else { continue }
            if mean(vals) >= target { return k }
        }
        return nil
    }

    /// Most impactful first, by ABSOLUTE delta.
    ///
    /// Absolute rather than signed: a session that reliably LIFTS the next morning is as worth
    /// surfacing as one that costs, and a signed sort would bury it at the bottom under every
    /// mild cost. Ties break on confidence, then name, so the order is stable across launches.
    static func rank(_ costs: [ActivityCost]) -> [ActivityCost] {
        costs.sorted { a, b in
            let da = abs(a.delta), db = abs(b.delta)
            if da != db { return da > db }
            let ra = confidenceRank(a.confidence), rb = confidenceRank(b.confidence)
            if ra != rb { return ra > rb }
            return a.sport < b.sport
        }
    }

    static func confidenceRank(_ c: ScoreConfidence) -> Int {
        switch c {
        case .calibrating: return 0
        case .building: return 1
        case .solid: return 2
        }
    }

    static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
}
