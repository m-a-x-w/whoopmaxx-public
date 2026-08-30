import Foundation
import StrapProtocol

/// The read-planning and unit maths behind the raw-signal scope.
///
/// The scope draws seconds of 1 Hz data or a year of it into the same few hundred points, so the
/// question at every zoom is "how much do I actually need to fetch". Getting that wrong in one
/// direction stalls on a query returning a million rows; in the other it draws a chart from ten
/// samples and shows a flat line where the signal moved.
public enum SignalLabMath {

    /// Roughly a point per device pixel on the widest phone. More is invisible and costs a query.
    public static let maxDrawPoints = 1500

    /// Up to an hour is served raw — at 1 Hz that is 3600 points, close enough to the draw budget
    /// that bucketing would only blur it.
    public static let hrRawWindowSeconds = 3600
    public static let hrRawLimit = 4200
    public static let hrBucketLimit = 2000

    /// A ceiling on any single raw channel fetch, regardless of window. A multi-kHz channel over a
    /// long window would otherwise ask for tens of millions of rows.
    public static let rawChannelHardCap = 24_000

    /// Bucket widths, smallest first. Fixed rather than computed so the same window always picks
    /// the same width — a bucket size that drifted with the data would make the chart redraw
    /// differently for the same range.
    static let bucketLadder = [5, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    public enum HRRead: Equatable {
        case raw(limit: Int)
        case buckets(seconds: Int, limit: Int)
    }

    /// How to read heart rate for a window.
    public static func hrRead(windowSeconds: Int, maxPoints: Int = maxDrawPoints) -> HRRead {
        let w = max(1, windowSeconds)
        if w <= hrRawWindowSeconds { return .raw(limit: hrRawLimit) }
        return .buckets(seconds: bucketSeconds(windowSeconds: w, maxPoints: maxPoints),
                        limit: hrBucketLimit)
    }

    /// The narrowest ladder width that fits the window inside the point budget.
    ///
    /// KNOWN LIMIT: the ladder tops out at an hour, so a window longer than roughly a month
    /// cannot be made to fit and falls back to the widest bucket — a year returns ~8,760 points,
    /// several times the budget. That is a deliberate fallback rather than a silent one: widening
    /// the ladder past an hour would start merging separate nights into a single bar, which is a
    /// worse answer than drawing more points than intended.
    public static func bucketSeconds(windowSeconds: Int, maxPoints: Int = maxDrawPoints) -> Int {
        let w = max(1, windowSeconds)
        let budget = max(1, maxPoints)
        for b in bucketLadder where (w + b - 1) / b <= budget { return b }
        return bucketLadder.last!
    }

    /// How many samples to ask a raw channel for.
    public static func rawChannelLimit(windowSeconds: Int, nativeHz: Double,
                                       cap: Int = rawChannelHardCap) -> Int {
        let w = Double(max(1, windowSeconds))
        // +2 for the endpoints: a window that lands mid-sample still needs the points either side
        // of both edges, or the chart is clipped short of the range the user asked for.
        let want = Int((w * max(0, nativeHz)).rounded(.up)) + 2
        return max(2, min(cap, want))
    }

    /// Thin a series to at most `maxPoints`, keeping the FIRST and LAST.
    ///
    /// Index-mapped rather than every-nth: every-nth drops a variable number of trailing points
    /// depending on the remainder, so the right-hand edge of a chart moves as the window slides.
    /// Both endpoints are always present, so the drawn range matches the requested one.
    public static func decimate<T>(_ xs: [T], to maxPoints: Int) -> [T] {
        let cap = max(2, maxPoints)
        let n = xs.count
        guard n > cap else { return xs }
        var out: [T] = []
        out.reserveCapacity(cap)
        var lastIdx = -1
        for i in 0..<cap {
            let raw = (Double(i) * Double(n - 1) / Double(cap - 1)).rounded()
            let idx = min(n - 1, max(0, Int(raw)))
            if idx != lastIdx { out.append(xs[idx]); lastIdx = idx }
        }
        return out
    }

    // MARK: - Units

    /// Whether a channel is shown as a physical quantity or as the ADC counts behind it.
    ///
    /// Raw is not a debug mode: several channels have no trustworthy conversion, and showing counts
    /// is the honest rendering rather than inventing a unit for them.
    public enum ScopeUnit: Equatable, Hashable, CaseIterable {
        case physical
        case raw
    }

    /// Accelerometer scale: counts per g in the strap's 16-bit representation.
    public static let gravityI16PerG: Double = 16384.0

    public static func skinTempValue(raw: Int, family: DeviceFamily, unit: ScopeUnit) -> Double {
        switch unit {
        case .raw: return Double(raw)
        case .physical: return skinTempCelsius(raw: raw, family: family)
        }
    }

    public static func gravityValue(g: Double, unit: ScopeUnit) -> Double {
        switch unit {
        case .raw: return g * gravityI16PerG
        case .physical: return g
        }
    }

    public static func gravityMagnitude(x: Double, y: Double, z: Double, unit: ScopeUnit) -> Double {
        gravityValue(g: (x * x + y * y + z * z).squareRoot(), unit: unit)
    }

    // MARK: - Cursor lookup

    public struct ScopeSample: Equatable, Sendable {
        public let t: Double
        public let v: Double
        public init(t: Double, v: Double) { self.t = t; self.v = v }
    }

    /// Binary search for the pair bracketing `t`.
    private static func bracket(_ t: Double, _ series: [ScopeSample]) -> (Int, Int) {
        var lo = 0, hi = series.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if series[mid].t <= t { lo = mid } else { hi = mid }
        }
        return (lo, hi)
    }

    /// Linear interpolation, for a channel that genuinely varies continuously.
    ///
    /// Returns nil OUTSIDE the series rather than clamping to the nearest end. A cursor past the
    /// last sample must read as "no data here", not as a flat continuation of the final value —
    /// which is indistinguishable from a real steady reading.
    public static func interpolatedValue(at t: Double, in series: [ScopeSample]) -> Double? {
        guard let first = series.first, let last = series.last, t >= first.t, t <= last.t else { return nil }
        if series.count == 1 { return first.v }
        let (lo, hi) = bracket(t, series)
        let a = series[lo], b = series[hi]
        guard b.t > a.t else { return a.v }
        if t <= a.t { return a.v }
        if t >= b.t { return b.v }
        return a.v + ((t - a.t) / (b.t - a.t)) * (b.v - a.v)
    }

    /// Sample-and-hold, for a channel that steps rather than ramps.
    ///
    /// A step-valued channel — a sleep stage, a battery reading — has no meaningful value between
    /// samples. Interpolating one invents a state the strap never reported.
    public static func holdValue(at t: Double, in series: [ScopeSample]) -> Double? {
        guard let first = series.first, t >= first.t else { return nil }
        if series.count == 1 { return first.v }
        let (lo, hi) = bracket(t, series)
        return series[hi].t <= t ? series[hi].v : series[lo].v
    }

    /// RMSSD over a sliding beat window — the scope's live variability trace.
    public static func rollingRMSSD(_ nn: [Double], window: Int) -> [Double] {
        HRVAnalyzer.rollingRmssd(nn, window: window)
    }

    /// The live trace's single trailing value, from the most recent beats.
    ///
    /// Zero-valued intervals are dropped rather than differenced: they are a decode gap, and a
    /// difference across one is between two unrelated beats and dominates the result.
    ///
    /// nil below the beat minimum, so a just-connected strap shows nothing instead of a number
    /// built from three beats.
    public static func rollingRMSSD(_ rr: [Int], window: Int = 60, minCount: Int = 8) -> Double? {
        let valid = rr.filter { $0 > 0 }.suffix(max(1, window)).map(Double.init)
        guard valid.count >= max(2, minCount) else { return nil }
        var sum = 0.0
        for i in 1..<valid.count {
            let d = valid[i] - valid[i - 1]
            sum += d * d
        }
        return (sum / Double(valid.count - 1)).squareRoot()
    }
}
