import Foundation
import StrapProtocol

/// Hour-by-hour stress across a waking day, scored against the DAY'S OWN calm.
///
/// There is no cross-day history here on purpose. A day is scored relative to its own quiet hours,
/// which makes a flat day read near baseline and a spiky day surface its tense hours, without
/// needing a personal baseline to have settled first.
public enum DaytimeStress {

    /// HR samples an hour needs before it is scored. Below this the hour is left unscored rather
    /// than scored from a handful of readings.
    public static let minHourHRSamples: Int = 300
    public static let bucketSeconds: Int = 3_600
    /// Level at or above which an hour counts as high.
    public static let highBandFloor: Double = 2.0
    /// Consecutive high hours before the day is flagged sustained.
    public static let sustainedHours: Int = 3

    public static let wakingStartHour: Int = 6
    public static let wakingEndHour: Int = 22

    public struct HourPoint: Equatable, Sendable {
        public let hour: Int
        public let startTs: Int
        /// 0…3, or nil for an hour with too little data. Nil is not zero.
        public let level: Double?
        public let meanHR: Double?
        public let rmssd: Double?
        public init(hour: Int, startTs: Int, level: Double?, meanHR: Double?, rmssd: Double?) {
            self.hour = hour; self.startTs = startTs
            self.level = level; self.meanHR = meanHR; self.rmssd = rmssd
        }
    }

    public struct Result: Equatable, Sendable {
        public let hours: [HourPoint]
        public let sustainedHigh: Bool
        public let sustainedRun: Int
        public let dayMean: Double?
        public let peak: HourPoint?
        public init(hours: [HourPoint], sustainedHigh: Bool, sustainedRun: Int,
                    dayMean: Double?, peak: HourPoint?) {
            self.hours = hours; self.sustainedHigh = sustainedHigh
            self.sustainedRun = sustainedRun; self.dayMean = dayMean; self.peak = peak
        }
        public static let empty = Result(hours: [], sustainedHigh: false, sustainedRun: 0,
                                         dayMean: nil, peak: nil)
    }

    public static func analyze(hr: [HRSample], rr: [RRInterval], tzOffsetSeconds: Int = 0) -> Result {
        guard !hr.isEmpty else { return .empty }

        // Bucket into LOCAL hours. The local shift is what makes "hour 14" mean the user's
        // afternoon rather than a UTC slot that drifts around their day.
        var hrByBucket: [Int: [Double]] = [:]
        for s in hr {
            let bucket = floorDiv(s.ts + tzOffsetSeconds, bucketSeconds) * bucketSeconds
            hrByBucket[bucket, default: []].append(Double(s.bpm))
        }
        var rrByBucket: [Int: [Double]] = [:]
        for s in rr {
            let bucket = floorDiv(s.ts + tzOffsetSeconds, bucketSeconds) * bucketSeconds
            rrByBucket[bucket, default: []].append(Double(s.rrMs))
        }

        struct HourAgg { let bucket: Int; let meanHR: Double?; let rmssd: Double? }
        let aggs: [HourAgg] = hrByBucket.keys.sorted().map { b in
            let hrs = hrByBucket[b] ?? []
            // RMSSD goes through the shared cleaner so ectopic beats cannot fabricate variability
            // and make a calm hour read as a tense one.
            return HourAgg(bucket: b,
                           meanHR: hrs.count >= minHourHRSamples ? mean(hrs) : nil,
                           rmssd: HRVAnalyzer.analyze(rrByBucket[b] ?? []).rmssd)
        }

        // The reference is built from WAKING hours only.
        //
        // Sleep is the calmest, lowest-HR and highest-HRV stretch of the day, and the analysis
        // window begins at local midnight, so a day routinely carries several hours of it. Letting
        // those into the reference drags the calm anchor far below every waking hour, which
        // inflates an ordinary day toward high and falsely trips the sustained-high nudge.
        let referenceAggs = aggs.filter { isWakingHour($0.bucket) }
        let hrMeans = referenceAggs.compactMap(\.meanHR)
        let rmssdVals = referenceAggs.compactMap(\.rmssd)
        let refHR = calmReference(hrMeans, calmIsLow: true)
        let refRMSSD = calmReference(rmssdVals, calmIsLow: false)
        let sdHR = std(hrMeans, mean: mean(hrMeans))
        let sdRMSSD = std(rmssdVals, mean: mean(rmssdVals))

        var points: [HourPoint] = []
        points.reserveCapacity(aggs.count)
        for a in aggs {
            guard isWakingHour(a.bucket) else { continue }
            // HR is the anchor; RMSSD enriches the score when there are beats for it. An hour with
            // R-R but no HR count is left unscored rather than judged on variability alone.
            let level: Double? = a.meanHR != nil
                ? squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: sdHR,
                                  rmssd: a.rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD))
                : nil
            points.append(HourPoint(hour: floorDiv(a.bucket, bucketSeconds) % 24,
                                    startTs: a.bucket - tzOffsetSeconds,
                                    level: level, meanHR: a.meanHR, rmssd: a.rmssd))
        }

        let scored = points.compactMap { p -> (HourPoint, Double)? in p.level.map { (p, $0) } }
        guard !scored.isEmpty else {
            // Still return the unscored timeline, so a surface can say "not enough data" against
            // the hours it does have rather than showing nothing at all.
            return points.isEmpty ? .empty
                : Result(hours: points, sustainedHigh: false, sustainedRun: 0, dayMean: nil, peak: nil)
        }

        // The run is counted BACKWARD from the most recent scored hour. A sustained-high flag is
        // about the state someone is in now, not the worst stretch of their morning.
        var run = 0
        for (_, lvl) in scored.reversed() {
            if lvl >= highBandFloor { run += 1 } else { break }
        }

        return Result(hours: points, sustainedHigh: run >= sustainedHours, sustainedRun: run,
                      dayMean: mean(scored.map(\.1)), peak: scored.max { $0.1 < $1.1 }?.0)
    }

    /// Sum of the two z-like terms, oriented so both point the same way.
    static func rawScore(hr: Double?, meanHR: Double?, sdHR: Double,
                         rmssd: Double?, meanRMSSD: Double?, sdRMSSD: Double) -> Double {
        var sum = 0.0
        if let h = hr, let m = meanHR, sdHR > 0.0001 { sum += (h - m) / sdHR }
        // Inverted: falling variability is rising stress.
        if let r = rmssd, let m = meanRMSSD, sdRMSSD > 0.0001 { sum += (m - r) / sdRMSSD }
        return sum
    }

    /// Squash onto 0…3 through a logistic, so an extreme hour saturates rather than running away
    /// with the day's scale.
    static func squash(_ raw: Double) -> Double {
        min(max(3.0 / (1.0 + exp(-raw)), 0), 3)
    }

    /// The day's calm anchor: the quartile at the CALM end, not the mean.
    ///
    /// A mean sits in the middle of the day, which would make half of every day read as stressed
    /// by construction. Anchoring on the quiet quartile means an ordinary day reads ordinary.
    /// Below four hours there is no quartile worth taking, so it falls back to the mean.
    static func calmReference(_ xs: [Double], calmIsLow: Bool) -> Double? {
        guard !xs.isEmpty else { return nil }
        guard xs.count >= 4 else { return mean(xs) }
        let s = xs.sorted()
        return calmIsLow ? quantile(s, 0.25) : quantile(s, 0.75)
    }

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
    }

    /// Integer division that floors toward negative infinity.
    ///
    /// Swift's `/` truncates toward zero, which puts every pre-epoch or negative-offset timestamp
    /// in the wrong hour bucket — an off-by-one that only shows up west of UTC.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    static func isWakingHour(_ bucket: Int) -> Bool {
        let hourOfDay = floorDiv(bucket, bucketSeconds) % 24
        return hourOfDay >= wakingStartHour && hourOfDay < wakingEndHour
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n == 1 { return sorted[0] }
        let pos = q * Double(n - 1)
        let lo = Int(pos), hi = min(lo + 1, n - 1)
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }
}
