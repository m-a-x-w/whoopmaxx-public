import Foundation
import StrapProtocol

/// The Charge score: how recovered the body looks this morning.
///
/// A weighted blend of z-scores against the user's OWN baselines, squashed through a logistic onto
/// 0…100. Every driver is a deviation, never an absolute — a resting heart rate of 55 is good news
/// for one person and a warning for another, and the score only means anything relative to what
/// that person usually does.
public enum RecoveryScorer {

    /// Driver weights. HRV dominates deliberately: it is the earliest and most responsive signal
    /// of autonomic recovery, and the others largely corroborate it.
    public static let wHRV: Double = 0.55
    public static let wRHR: Double = 0.20
    public static let wResp: Double = 0.05
    public static let wSleep: Double = 0.15
    public static let wSkinTemp: Double = 0.05

    /// Degrees of skin-temperature deviation that count as one unit of penalty.
    public static let skinTempScaleC: Double = 1.0

    /// Logistic steepness and centre.
    ///
    /// The centre sits slightly BELOW zero so an exactly average day lands a little above 50 —
    /// most days are ordinary, and a scale where the typical morning reads as a failing grade is
    /// not one anyone can act on.
    public static let logisticK: Double = 1.6
    public static let logisticZ0: Double = -0.20

    public static let populationMean: Double = 58.0
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep performance is scored against a fixed centre rather than a personal baseline: unlike
    /// HRV there is a defensible external target, and baselining it would quietly normalise a
    /// chronic shortfall into "fine".
    public static let sleepPerfCenter: Double = 0.85
    public static let sleepPerfScale: Double = 0.12

    /// Resting-HR search: bin width, and the bar a bin must clear to win.
    public static let restingHRWindowS: Int = 5 * 60
    public static let restingHRMinBinSamples: Int = 5
    public static let restingHRMinPlausibleBpm: Double = 25.0

    /// A driver's baseline centre and spread. Spread is a mean absolute deviation, as everywhere.
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) { self.mean = mean; self.spread = spread }
        public init(_ state: Baselines.BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        (value - mean) / max(Baselines.sigmaPerMAD * spread, 1e-9)
    }

    /// The night's resting heart rate: the lowest well-populated five-minute mean.
    ///
    /// A minimum over BINS rather than over samples. A single dropout beat is the lowest sample of
    /// any night, so a raw minimum reports a resting rate of whatever the worst artefact was.
    ///
    /// A bin only wins if it is well populated AND physiologically plausible. A thin bin is one
    /// artefact wearing a mean, and a sub-physiological one is a dropout. When no bin clears that
    /// bar — a sparse night — the search falls back to the lowest bin of any size rather than
    /// returning nothing, since a rough resting rate beats a blank row.
    ///
    /// KNOWN LIMIT: binning BOUNDS an artefact's influence, it does not remove it. On a stream
    /// reporting once a minute a bin holds five readings, so a single dropout is 20% of its bin
    /// and still pulls the resting rate down by around 10 bpm. Dilution scales with density — the
    /// same artefact in a 1 Hz bin is one reading in three hundred and vanishes. Rejecting a bin
    /// on its internal spread would close the gap and is the obvious next improvement; it is not
    /// done here because it would change every stored resting rate.
    public static func restingHR(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }

        var means: [Double] = []
        var qualified: [Double] = []
        var t = start
        while t < end {
            let win = seg.filter { $0.ts >= t && $0.ts < t + restingHRWindowS }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                means.append(mean)
                if win.count >= restingHRMinBinSamples, mean >= restingHRMinPlausibleBpm {
                    qualified.append(mean)
                }
            }
            t += restingHRWindowS
        }

        let floor: Double
        if let m = qualified.min() { floor = m }
        else if let m = means.min() { floor = m }
        else { floor = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count) }
        return Int(floor.rounded())
    }

    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    /// Score a morning.
    ///
    /// Returns nil when the HRV baseline is not yet usable. That refusal is deliberate: HRV
    /// carries more than half the weight, and a score assembled from the remaining drivers would
    /// look exactly like a real one while measuring something else. A blank with an explanation
    /// beats a number nobody can trust.
    ///
    /// Terms are re-weighted over whatever is PRESENT rather than treating a missing driver as
    /// zero — a missing respiratory rate must not read as a perfectly average one.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                hrvBaselineUsable: Bool = true) -> Double? {
        guard hrvBaselineUsable else { return nil }

        var terms: [(z: Double, w: Double)] = []

        // HRV: higher is better.
        if let b = hrvBaseline {
            terms.append((zScore(hrv, mean: b.mean, spread: b.spread), wHRV))
        }
        // Resting HR: LOWER is better, so the z is inverted by swapping the arguments.
        if let b = rhrBaseline {
            terms.append((zScore(b.mean, mean: rhr, spread: b.spread), wRHR))
        }
        // Respiratory rate: lower is better, and optional.
        if let r = resp, let b = respBaseline {
            terms.append((zScore(b.mean, mean: r, spread: b.spread), wResp))
        }
        if let sp = sleepPerf {
            terms.append(((sp - sleepPerfCenter) / sleepPerfScale, wSleep))
        }
        // Skin temperature penalises deviation in EITHER direction. Running cold is as much a
        // signal as running hot, and a signed term would let one cancel the other out.
        if let dev = skinTempDev {
            terms.append((-abs(dev) / skinTempScaleC, wSkinTemp))
        }

        guard !terms.isEmpty else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }

        let z = terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
        return max(0, min(100, 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))))
    }

    /// Convenience over `Baselines.BaselineState`, refusing when the HRV baseline is not usable yet.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: Baselines.BaselineState,
                                rhrBaseline: Baselines.BaselineState?,
                                respBaseline: Baselines.BaselineState?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil) -> Double? {
        recovery(hrv: hrv, rhr: rhr, resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 rhrBaseline: rhrBaseline.map(DriverBaseline.init),
                 respBaseline: respBaseline.map(DriverBaseline.init),
                 sleepPerf: sleepPerf, skinTempDev: skinTempDev,
                 hrvBaselineUsable: hrvBaseline.usable)
    }

    /// How many more nights before the score can be trusted.
    ///
    /// Surfaced so a cold start can say "four more nights" instead of showing a blank with no
    /// explanation — the difference between an app that looks broken and one that is waiting.
    public static func calibrationNights(nightlyHrv: [Double?],
                                         cfg: Baselines.MetricCfg = Baselines.hrvCfg) -> Int {
        let state = Baselines.foldHistory(nightlyHrv, cfg: cfg)
        return max(0, Baselines.minNightsSeed - state.nValid)
    }
}
