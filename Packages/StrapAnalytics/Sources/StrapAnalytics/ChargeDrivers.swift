import Foundation

/// One line of "what shaped your Charge today".
public struct ChargeDriver: Equatable, Sendable {
    public let label: String
    /// Charge points this driver ADDED (or removed) versus sitting at its own baseline.
    public let deltaPoints: Int
    public let valueText: String
    /// Empty for drivers measured against a fixed target rather than a learned baseline.
    public let baselineText: String
    public let verdict: String
    public init(label: String, deltaPoints: Int, valueText: String,
                baselineText: String, verdict: String) {
        self.label = label; self.deltaPoints = deltaPoints
        self.valueText = valueText; self.baselineText = baselineText; self.verdict = verdict
    }
}

/// Skin temperature relative to the personal baseline.
public struct SkinTempRelative: Equatable, Sendable, Codable {
    public enum Tier: String, Equatable, Sendable, Codable {
        case cooler, typical, warmer
    }
    public let deviationC: Double
    public let tier: Tier
    public init(deviationC: Double, tier: Tier) { self.deviationC = deviationC; self.tier = tier }
}

extension RecoveryScorer {

    /// Half-width of the band counted as ordinary drift.
    public static let skinTempTypicalBandC: Double = 0.3

    public static func skinTempRelative(deviationC: Double?) -> SkinTempRelative? {
        guard let dev = deviationC else { return nil }
        let tier: SkinTempRelative.Tier =
            dev > skinTempTypicalBandC ? .warmer : (dev < -skinTempTypicalBandC ? .cooler : .typical)
        return SkinTempRelative(deviationC: dev, tier: tier)
    }

    /// Attribute the Charge score to its drivers.
    ///
    /// Each driver's points are the full score MINUS the score recomputed with that one term held
    /// at its own baseline, every weight unchanged. Two consequences that make the numbers
    /// trustworthy: a term sitting exactly at baseline is worth zero, and because the recomputation
    /// runs through the same scorer, the points can never drift from the headline they explain.
    ///
    /// Renormalised leave-one-out would be WRONG here. When the surviving terms happen to average
    /// to the same z as the full set, dropping one and renormalising returns the same score — so a
    /// clearly good or clearly bad driver collapses to zero points and reads as irrelevant.
    public static func chargeDrivers(hrv: Double,
                                     rhr: Double,
                                     resp: Double?,
                                     hrvBaseline: Baselines.BaselineState,
                                     rhrBaseline: Baselines.BaselineState?,
                                     respBaseline: Baselines.BaselineState?,
                                     sleepPerf: Double?,
                                     skinTempDev: Double? = nil) -> [ChargeDriver] {
        // No headline means no contributions to attribute. Mirroring the scorer's own cold-start
        // gate is what stops a blank score sprouting a full table of confident driver rows.
        guard let full = recovery(hrv: hrv, rhr: rhr, resp: resp,
                                  hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                  respBaseline: respBaseline, sleepPerf: sleepPerf,
                                  skinTempDev: skinTempDev) else { return [] }

        func points(_ neutralised: Double?) -> Int { Int((full - (neutralised ?? full)).rounded()) }

        var drivers: [ChargeDriver] = []

        drivers.append(ChargeDriver(
            label: "Heart rate variability",
            deltaPoints: points(recovery(hrv: hrvBaseline.baseline, rhr: rhr, resp: resp,
                                         hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                         respBaseline: respBaseline, sleepPerf: sleepPerf,
                                         skinTempDev: skinTempDev)),
            valueText: "\(Int(hrv.rounded())) ms",
            baselineText: "\(Int(hrvBaseline.baseline.rounded())) ms baseline",
            verdict: hrvVerdict(value: hrv, baseline: hrvBaseline.baseline)))

        if let b = rhrBaseline {
            drivers.append(ChargeDriver(
                label: "Resting heart rate",
                deltaPoints: points(recovery(hrv: hrv, rhr: b.baseline, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: skinTempDev)),
                valueText: "\(Int(rhr.rounded())) bpm",
                baselineText: "\(Int(b.baseline.rounded())) bpm baseline",
                verdict: rhrVerdict(value: rhr, baseline: b.baseline)))
        }

        if let sp = sleepPerf {
            drivers.append(ChargeDriver(
                label: "Rest quality",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerfCenter,
                                             skinTempDev: skinTempDev)),
                valueText: "\(Int((sp * 100).rounded()))%",
                baselineText: "",
                verdict: sleepVerdict(sleepPerf: sp)))
        }

        if let r = resp, let b = respBaseline {
            drivers.append(ChargeDriver(
                label: "Respiratory rate",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: b.baseline,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: skinTempDev)),
                valueText: String(format: "%.1f br/min", r),
                baselineText: String(format: "%.1f br/min baseline", b.baseline),
                verdict: respVerdict(value: r, baseline: b.baseline)))
        }

        if let dev = skinTempDev {
            drivers.append(ChargeDriver(
                label: "Skin temperature",
                deltaPoints: points(recovery(hrv: hrv, rhr: rhr, resp: resp,
                                             hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
                                             respBaseline: respBaseline, sleepPerf: sleepPerf,
                                             skinTempDev: 0)),
                valueText: skinTempDevText(dev),
                baselineText: "",
                verdict: skinTempVerdict(dev)))
        }

        // Biggest absolute contribution first — a driver that COST ten points is as worth showing
        // as one that gave ten. Ties keep construction order so the list is stable.
        return drivers.enumerated()
            .sorted { a, b in
                let am = abs(a.element.deltaPoints), bm = abs(b.element.deltaPoints)
                return am != bm ? am > bm : a.offset < b.offset
            }
            .map(\.element)
    }

    static func hrvVerdict(value: Double, baseline: Double) -> String {
        if value > baseline { return "above baseline, supporting recovery" }
        if value < baseline { return "below baseline, limiting recovery" }
        return "at baseline"
    }

    static func rhrVerdict(value: Double, baseline: Double) -> String {
        if value < baseline { return "below baseline, supporting recovery" }
        if value > baseline { return "above baseline, limiting recovery" }
        return "at baseline"
    }

    static func respVerdict(value: Double, baseline: Double) -> String {
        if value < baseline { return "below baseline, supporting recovery" }
        if value > baseline { return "above baseline, limiting recovery" }
        return "at baseline"
    }

    static func sleepVerdict(sleepPerf: Double) -> String {
        if sleepPerf > sleepPerfCenter { return "a strong night, supporting recovery" }
        if sleepPerf < sleepPerfCenter { return "below a good night, limiting recovery" }
        return "a typical night"
    }

    /// Symmetric: drift in EITHER direction limits recovery.
    static func skinTempVerdict(_ dev: Double) -> String {
        if abs(dev) <= skinTempTypicalBandC { return "near baseline" }
        return dev > 0 ? "warmer than baseline, limiting recovery"
                       : "cooler than baseline, limiting recovery"
    }

    static func skinTempDevText(_ dev: Double) -> String {
        "\(dev >= 0 ? "+" : "")\(String(format: "%.1f", dev)) C vs baseline"
    }
}

/// A short, seated HRV capture — explicitly not an overnight baseline.
public enum SpotHrvReading {

    public enum Source: Sendable { case opticalPPG, chestStrap, unknown }

    public enum Outcome: Equatable, Sendable {
        case reading(rmssdMs: Double, hrBpm: Double?, beats: Int, full: HRVAnalyzer.HRVResult)
        /// Carries all three counts so a surface can say what was short rather than just failing.
        case insufficient(clean: Int, needed: Int, input: Int)
    }

    public static func compute(_ rrMs: [Int],
                               maxRejectedFraction: Double = HRVAnalyzer.defaultSpotMaxRejectedFraction) -> Outcome {
        let result = HRVAnalyzer.analyze(rawRR: rrMs.map(Double.init),
                                         maxRejectedFraction: maxRejectedFraction)
        guard let rmssd = result.rmssd else {
            return .insufficient(clean: result.nClean, needed: HRVAnalyzer.minBeats,
                                 input: result.nInput)
        }
        return .reading(rmssdMs: rmssd, hrBpm: meanHrFromNN(result.meanNN),
                        beats: result.nClean, full: result)
    }

    public static func meanHrFromNN(_ meanNN: Double?) -> Double? {
        guard let meanNN, meanNN > 0 else { return nil }
        return 60_000.0 / meanNN
    }

    /// The caveat shown with every spot reading.
    ///
    /// Not optional copy. A spot RMSSD and an overnight one differ by more than the day-to-day
    /// changes people read into them, so presenting one without saying which it is invites exactly
    /// the wrong comparison.
    public static func caveatFor(_ source: Source) -> String {
        let base = "This is a spot reading over a short, still capture, not your overnight HRV "
            + "baseline. Take it seated, still, and at a consistent time of day for comparable "
            + "numbers, and only a reading with enough clean beats is shown."
        switch source {
        case .opticalPPG:
            return base + " Wrist optical beats are noisier than a chest strap's."
        case .chestStrap:
            return base
        case .unknown:
            return base
        }
    }
}
