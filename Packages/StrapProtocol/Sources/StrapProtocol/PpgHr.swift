import Foundation

/// Heart rate from the raw PPG waveform, by autocorrelation.
///
/// The waveform arrives as one record per second, each holding `sampleRateHz` samples. A pulse is
/// periodic, so the lag at which the signal best correlates with itself is the beat interval.
public enum PpgHr {
    /// Samples per one-second record.
    public static let sampleRateHz = 24
    /// Autocorrelation window. Long enough to hold several beats at a low resting rate — a short
    /// window cannot resolve 40 bpm at all.
    public static let windowSeconds = 8
    public static let hrLoBpm = 30.0
    public static let hrHiBpm = 220.0
    /// Below this peak strength the window is noise, and reporting a number from it would be
    /// inventing a heart rate.
    public static let minConfidence = 0.3

    /// Subtract the mean of each within-record sample position.
    ///
    /// Records are concatenated end to end, and the seam between them repeats at exactly the
    /// record rate. That artifact is strongly periodic, so autocorrelation locks onto it in
    /// preference to the pulse — it has to come out before the search, not be filtered after.
    static func removeRecordRateComponent(_ x: [Double], fs: Int) -> [Double] {
        guard fs > 0, !x.isEmpty else { return x }
        var sum = [Double](repeating: 0, count: fs)
        var count = [Int](repeating: 0, count: fs)
        for (i, v) in x.enumerated() { sum[i % fs] += v; count[i % fs] += 1 }
        let mean = (0..<fs).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : 0 }
        return x.enumerated().map { $0.element - mean[$0.offset % fs] }
    }

    /// Remove the mean. A DC offset dominates the autocorrelation at every lag and flattens the
    /// contrast the peak search depends on.
    static func detrend(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Double(x.count)
        return x.map { $0 - mean }
    }

    /// Normalised autocorrelation at one lag: 1.0 is a perfect repeat, 0 is none.
    static func acf(_ x: [Double], _ lag: Int) -> Double {
        guard lag > 0, lag < x.count else { return 0 }
        var num = 0.0, den = 0.0
        for i in 0..<(x.count - lag) { num += x[i] * x[i + lag] }
        for v in x { den += v * v }
        return den > 0 ? num / den : 0
    }

    /// Estimate one heart rate from a concatenated sample window.
    public static func estimate(_ samples: [Int],
                                fs: Int = sampleRateHz,
                                loBpm: Double = hrLoBpm,
                                hiBpm: Double = hrHiBpm,
                                minConf: Double = minConfidence) -> (bpm: Double, conf: Double)? {
        guard samples.count >= fs * 3 else { return nil }   // under 3 s cannot resolve a low rate
        let x = detrend(removeRecordRateComponent(samples.map(Double.init), fs: fs))
        let fsD = Double(fs)
        let loLag = max(2, Int((fsD * 60 / hiBpm).rounded()))
        let hiLag = min(x.count - 2, Int((fsD * 60 / loBpm).rounded()))
        guard hiLag > loLag else { return nil }

        var vals: [Int: Double] = [:]
        var peak = -Double.infinity
        for lag in loLag...hiLag {
            let v = acf(x, lag)
            vals[lag] = v
            if v > peak { peak = v }
        }
        guard peak >= minConf else { return nil }

        // Take the FIRST local maximum within 15% of the global peak, not the global peak itself.
        // Autocorrelation is nearly as strong at two and three beat intervals as at one, so the
        // global maximum lands on a multiple about as often as on the true period — and a
        // half-rate reading looks entirely plausible in a chart. The first qualifying peak is the
        // fundamental.
        var bestLag: Int?
        if loLag + 1 <= hiLag - 1 {
            for lag in (loLag + 1)...(hiLag - 1) {
                let v = vals[lag]!
                if v >= 0.85 * peak && v >= vals[lag - 1]! && v >= vals[lag + 1]! {
                    bestLag = lag
                    break
                }
            }
        }
        let lag = bestLag ?? vals.max { $0.value < $1.value }!.key
        return ((fsD * 60 / Double(lag)).rounded(), (vals[lag]! * 1000).rounded() / 1000)
    }

    /// One estimate per second, over a sliding window.
    ///
    /// Windows are built only from CONSECUTIVE seconds. Straddling a gap would splice two
    /// unrelated stretches of waveform together and autocorrelate the join — which produces a
    /// confident number describing nothing.
    public static func derivePpgHr(records: [(ts: Int, samples: [Int])],
                                   fs: Int = sampleRateHz,
                                   windowSeconds: Int = windowSeconds) -> [PpgHrSample] {
        guard !records.isEmpty else { return [] }
        var secs: [Int: [Int]] = [:]
        for r in records { secs[r.ts] = r.samples }

        // Split into runs of consecutive seconds.
        let order = secs.keys.sorted()
        var runs: [[Int]] = []
        var cur = [order[0]]
        for u in order.dropFirst() {
            if u - cur.last! == 1 { cur.append(u) } else { runs.append(cur); cur = [u] }
        }
        runs.append(cur)

        let half = windowSeconds / 2
        var out: [PpgHrSample] = []
        for run in runs where run.count >= 3 {
            let runSet = Set(run)
            for t in run {
                let window = ((t - half)...(t + half)).filter { runSet.contains($0) }
                guard window.count >= 3 else { continue }
                let signal = window.flatMap { secs[$0]! }
                if let est = estimate(signal, fs: fs) {
                    out.append(PpgHrSample(ts: t, bpm: Int(est.bpm), conf: est.conf))
                }
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }
}
