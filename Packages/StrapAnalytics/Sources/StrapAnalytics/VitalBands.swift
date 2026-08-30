import Foundation

/// Is a vital sign normal — for this person if we know them well enough, otherwise for a population.
///
/// The BASIS is reported alongside the verdict, not hidden. "Out of range against 200 nights of
/// your own data" and "out of range against a textbook interval" are different claims, and a UI
/// that presents them identically overstates the second one.
public enum VitalBands {

    public enum Band: String, Equatable, Sendable { case inRange, outOfRange, noData }
    public enum Basis: String, Equatable, Sendable { case personal, population }

    public struct Result: Equatable, Sendable {
        public let band: Band
        public let basis: Basis
        /// Valid nights behind a personal verdict — 0 when the verdict is population-based.
        public let nights: Int
        public init(band: Band, basis: Basis, nights: Int) {
            self.band = band; self.basis = basis; self.nights = nights
        }
    }

    /// Sigmas from the personal baseline before a value is called out of range.
    ///
    /// Two, not one: this drives a health flag, and at one sigma roughly a third of perfectly
    /// ordinary nights would raise it. A warning that fires that often is one people learn to
    /// ignore.
    public static let sigmaK: Double = 2.0

    /// Band a value, preferring a personal baseline once one is trustworthy.
    ///
    /// The absolute plausibility bounds are an OUTER guard applied before the personal comparison:
    /// a value outside physiological limits is out of range however wide the personal spread has
    /// grown. Without it a user with erratic history acquires a band so broad that nothing can
    /// ever be abnormal.
    public static func band(value: Double?,
                            history: [Double?],
                            populationRange: ClosedRange<Double>,
                            cfg: Baselines.MetricCfg?) -> Result {
        guard let value else { return Result(band: .noData, basis: .population, nights: 0) }
        guard let cfg else {
            return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                          basis: .population, nights: 0)
        }
        let state = Baselines.foldHistory(history, cfg: cfg)
        guard cfg.minVal <= value, value <= cfg.maxVal else {
            return Result(band: .outOfRange, basis: .population, nights: state.nValid)
        }
        // Only a TRUSTED baseline earns a personal verdict. A provisional one would be a personal
        // claim made from a handful of nights, which is worse than an honest population range.
        if state.trusted {
            let z = Baselines.deviation(value, state: state).z
            return Result(band: abs(z) <= sigmaK ? .inRange : .outOfRange,
                          basis: .personal, nights: state.nValid)
        }
        return Result(band: populationRange.contains(value) ? .inRange : .outOfRange,
                      basis: .population, nights: state.nValid)
    }

    /// Skin temperature arrives on two different scales depending on the era of the row: an
    /// absolute °C, or a deviation from baseline. A value of 33 and a value of 0.4 are both
    /// plausible and mean completely different things.
    public static func isAbsoluteSkinTemp(_ v: Double) -> Bool { v >= 20.0 }

    /// Keep only the history entries on the SAME scale as the value being banded.
    ///
    /// Mixing the two builds a baseline around a meaningless mean — a history half in absolute °C
    /// and half in deviations centres near 16, and then every real reading is an outlier.
    public static func skinTempHistory(matching value: Double, in history: [Double?]) -> [Double?] {
        let absolute = isAbsoluteSkinTemp(value)
        return history.map { v in
            guard let v else { return nil }
            return isAbsoluteSkinTemp(v) == absolute ? v : nil
        }
    }

    /// Config for the deviation scale, which is centred on zero rather than on a body temperature.
    public static let skinTempDeviationCfg = Baselines.MetricCfg(
        minVal: -8.0, maxVal: 8.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0)

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    /// Expand day-keyed rows into a gap-free calendar series, missing days as nil.
    ///
    /// The baseline model counts nights-since-update to decide staleness, so it has to SEE the
    /// missing days. Handing it only the days with data would make a month-old baseline look
    /// current — a returning user's stale baseline would silently present itself as trustworthy.
    public static func calendarSeries(_ rows: [(day: String, value: Double?)]) -> [Double?] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = rows.compactMap { dayFormatter.date(from: $0.day) }
        guard let first = dates.min(), let last = dates.max() else { return [] }

        // Last write wins on a duplicated day key.
        var byDay: [String: Double?] = [:]
        for r in rows where dayFormatter.date(from: r.day) != nil { byDay[r.day] = r.value }

        var out: [Double?] = []
        var d = first
        while d <= last {
            out.append(byDay[dayFormatter.string(from: d)] ?? nil)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
