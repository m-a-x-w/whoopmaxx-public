import Foundation

/// Summary statistics for one stretch of a series.
public struct SeriesStat: Equatable, Sendable {
    public let mean: Double
    /// Carried alongside the mean because they disagree exactly when it matters — a fortnight of
    /// good nights and two terrible ones has a mean that describes neither.
    public let median: Double
    public let min: Double
    public let max: Double
    public let stdev: Double
    public let n: Int
    /// Least-squares trend per position. Direction within the period, which a mean cannot show:
    /// a month that started badly and ended well has the same mean as its reverse.
    public let slopePerDay: Double

    public init(mean: Double, median: Double, min: Double, max: Double,
                stdev: Double, n: Int, slopePerDay: Double) {
        self.mean = mean; self.median = median; self.min = min; self.max = max
        self.stdev = stdev; self.n = n; self.slopePerDay = slopePerDay
    }

    public static let empty = SeriesStat(mean: 0, median: 0, min: 0, max: 0,
                                         stdev: 0, n: 0, slopePerDay: 0)
}

public struct PeriodComparison: Equatable, Sendable {
    public let current: SeriesStat
    public let previous: SeriesStat
    public let delta: Double
    /// nil when the previous period has no data or a zero mean — a percentage against nothing is
    /// not a large change, it is an undefined one.
    public let pctChange: Double?
    /// -1, 0 or +1. Zero also means "cannot say", which is why the caller is given `n` too.
    public let direction: Int

    public init(current: SeriesStat, previous: SeriesStat, delta: Double,
                pctChange: Double?, direction: Int) {
        self.current = current; self.previous = previous
        self.delta = delta; self.pctChange = pctChange; self.direction = direction
    }
}

/// Comparing one stretch of a metric against another.
public enum ComparisonEngine {

    public static func stat(_ values: [Double]) -> SeriesStat {
        let n = values.count
        guard n > 0 else { return .empty }
        let mean = values.reduce(0, +) / Double(n)
        // Sample deviation (n−1): these days are a sample of the person's behaviour, not the
        // whole population of it.
        let sd: Double = n >= 2
            ? (values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)).squareRoot()
            : 0
        return SeriesStat(mean: mean, median: HRVAnalyzer.median(values),
                          min: values.min()!, max: values.max()!,
                          stdev: sd, n: n, slopePerDay: leastSquaresSlope(values))
    }

    public static func compare(current: [Double], previous: [Double]) -> PeriodComparison {
        let cur = stat(current)
        let prev = stat(previous)
        let delta = cur.mean - prev.mean

        // Percent change is against the ABSOLUTE previous mean, so a metric that can go negative
        // — a temperature deviation — does not flip the sign of its own change.
        let pct: Double? = (prev.n > 0 && prev.mean != 0)
            ? (cur.mean - prev.mean) / abs(prev.mean) * 100.0
            : nil

        // Direction needs BOTH periods. An empty previous period is not a decline from it.
        let direction: Int
        if cur.n == 0 || prev.n == 0 { direction = 0 }
        else if delta > 0 { direction = 1 }
        else if delta < 0 { direction = -1 }
        else { direction = 0 }

        return PeriodComparison(current: cur, previous: prev, delta: delta,
                                pctChange: pct, direction: direction)
    }

    /// This calendar month against the previous one.
    ///
    /// Matched on the day-key PREFIX rather than by date arithmetic: the keys are already local
    /// day strings, and re-parsing them into dates would reintroduce the timezone question they
    /// were flattened to avoid.
    public static func monthOverMonth(byDay: [(day: String, value: Double)],
                                      referenceDay: String) -> PeriodComparison {
        guard let (curYear, curMonth) = yearMonth(of: referenceDay) else {
            return compare(current: [], previous: [])
        }
        let (prevYear, prevMonth) = previousMonth(year: curYear, month: curMonth)
        let curPrefix = monthPrefix(year: curYear, month: curMonth)
        let prevPrefix = monthPrefix(year: prevYear, month: prevMonth)

        // Sorted so the slope is chronological whatever order the rows arrived in.
        var curVals: [Double] = []
        var prevVals: [Double] = []
        for row in byDay.sorted(by: { $0.day < $1.day }) {
            if row.day.hasPrefix(curPrefix + "-") { curVals.append(row.value) }
            else if row.day.hasPrefix(prevPrefix + "-") { prevVals.append(row.value) }
        }
        return compare(current: curVals, previous: prevVals)
    }

    /// Least-squares slope against position.
    static func leastSquaresSlope(_ values: [Double]) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        let meanX = Double(n - 1) / 2.0
        let meanY = values.reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0
        for i in 0..<n {
            let dx = Double(i) - meanX
            sxy += dx * (values[i] - meanY)
            sxx += dx * dx
        }
        guard sxx > 0 else { return 0 }
        return sxy / sxx
    }

    static func yearMonth(of day: String) -> (year: Int, month: Int)? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        return (y, m)
    }

    static func previousMonth(year: Int, month: Int) -> (year: Int, month: Int) {
        month == 1 ? (year - 1, 12) : (year, month - 1)
    }

    static func monthPrefix(year: Int, month: Int) -> String {
        "\(year)-\(month < 10 ? "0\(month)" : "\(month)")"
    }
}
