import Foundation

/// How regular a heart rhythm looks, described neutrally.
///
/// Every label here is descriptive on purpose. "Varied a lot" is a statement about the timing of
/// beats; it is not a finding, and nothing in this file names a condition. The whole design goal is
/// a screener conservative enough that a person is not alarmed by their own noise.
public enum RhythmRegularity: String, Equatable, Sendable, Codable {
    case steady
    case occasionalEctopy
    case varied
    case unreadable
}

public enum RhythmConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid
}

public enum RhythmScreener {

    /// Beats needed before a window is read at all.
    public static let windowMinBeats: Int = 60
    /// Plausible resting range. Outside it the window is something other than quiet rest.
    public static let restingHrMinBpm: Double = 40
    public static let restingHrMaxBpm: Double = 110

    /// SD1/SD2 at or above which the Poincaré cloud counts as round rather than elongated.
    public static let tauRatio: Double = 0.55
    /// Normalised RMSSD threshold — variability as a fraction of the mean interval, so it does not
    /// simply track heart rate.
    public static let tauNRmssd: Double = 0.12
    /// Turning-point rate relative to random. At 1.0 the series reverses direction as often as
    /// noise would.
    public static let tauTP: Double = 0.90
    /// Ectopic fraction above which extra or skipped beats are worth naming.
    public static let tauEctopicLow: Double = 0.04

    public static let nightMinVariedWindows: Int = 3
    public static let nightMinSpanSeconds: Int = 30 * 60
    public static let solidBeats: Int = 200

    public struct WindowInput: Equatable, Sendable {
        public let rrMs: [Double]
        public let ts: [Int]
        /// An independent optical channel, when one exists. Two sensors agreeing is far stronger
        /// than one sensor being confident.
        public let ppgIBIms: [Double]?
        public let motionStill: Bool
        public let meanHR: Double
        public init(rrMs: [Double], ts: [Int] = [], ppgIBIms: [Double]? = nil,
                    motionStill: Bool, meanHR: Double) {
            self.rrMs = rrMs; self.ts = ts; self.ppgIBIms = ppgIBIms
            self.motionStill = motionStill; self.meanHR = meanHR
        }
    }

    public struct PoincarePoint: Equatable, Sendable, Codable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct WindowResult: Equatable, Sendable, Codable {
        public let label: RhythmRegularity
        public let sd1: Double?
        public let sd2: Double?
        public let sd1sd2: Double?
        public let normRmssd: Double?
        public let turningPointRate: Double?
        public let ectopicFraction: Double?
        public let nBeats: Int
        public let confidence: RhythmConfidence
        public let agreedAcrossSources: Bool
        public let poincare: [PoincarePoint]

        public init(label: RhythmRegularity, sd1: Double? = nil, sd2: Double? = nil,
                    sd1sd2: Double? = nil, normRmssd: Double? = nil, turningPointRate: Double? = nil,
                    ectopicFraction: Double? = nil, nBeats: Int,
                    confidence: RhythmConfidence = .calibrating,
                    agreedAcrossSources: Bool = false, poincare: [PoincarePoint] = []) {
            self.label = label; self.sd1 = sd1; self.sd2 = sd2; self.sd1sd2 = sd1sd2
            self.normRmssd = normRmssd; self.turningPointRate = turningPointRate
            self.ectopicFraction = ectopicFraction; self.nBeats = nBeats
            self.confidence = confidence; self.agreedAcrossSources = agreedAcrossSources
            self.poincare = poincare
        }

        static func unreadable(nBeats: Int, confidence: RhythmConfidence = .calibrating) -> WindowResult {
            WindowResult(label: .unreadable, nBeats: nBeats, confidence: confidence)
        }
    }

    struct Stats: Equatable {
        let sd1: Double?
        let sd2: Double?
        let sd1sd2: Double?
        let normRmssd: Double?
        let turningPointRate: Double?
        let ectopicFraction: Double?
    }

    /// Screen one window.
    ///
    /// The motion gate comes first and is absolute. Movement masquerades as irregularity and is the
    /// single biggest source of false signal here — reading a rhythm off a moving wrist would make
    /// the screener fire on anyone who fidgets.
    public static func screenWindow(_ input: WindowInput) -> WindowResult {
        guard input.motionStill else { return .unreadable(nBeats: 0) }

        // Range-filtered but NOT ectopy-rejected: the extra beats are the thing being measured, so
        // cleaning them out first would remove the signal along with the noise.
        let clean = HRVAnalyzer.rangeFilter(input.rrMs)
        guard clean.count >= windowMinBeats else { return .unreadable(nBeats: clean.count) }
        guard input.meanHR >= restingHrMinBpm, input.meanHR <= restingHrMaxBpm else {
            return .unreadable(nBeats: clean.count, confidence: confidence(for: clean.count))
        }

        let stats = computeStats(clean)
        let rrLabel = classify(stats)

        // A second, independent sensor reaching the same label. Reported rather than required —
        // most windows have no optical channel, and demanding one would silence the screener.
        var agreed = false
        if let ppg = input.ppgIBIms {
            let ppgClean = HRVAnalyzer.rangeFilter(ppg)
            if ppgClean.count >= windowMinBeats {
                agreed = classify(computeStats(ppgClean)) == rrLabel
            }
        }

        return WindowResult(label: rrLabel, sd1: stats.sd1, sd2: stats.sd2, sd1sd2: stats.sd1sd2,
                            normRmssd: stats.normRmssd, turningPointRate: stats.turningPointRate,
                            ectopicFraction: stats.ectopicFraction, nBeats: clean.count,
                            confidence: confidence(for: clean.count),
                            agreedAcrossSources: agreed, poincare: poincareCloud(clean))
    }

    static func computeStats(_ nn: [Double]) -> Stats {
        guard nn.count >= 2 else {
            return Stats(sd1: nil, sd2: nil, sd1sd2: nil, normRmssd: nil,
                         turningPointRate: nil, ectopicFraction: ectopicFraction(nn))
        }
        let rmssd = HRVAnalyzer.rmssdRaw(nn)
        let sdnn = HRVAnalyzer.sdnnRaw(nn)
        let meanNN = nn.reduce(0, +) / Double(nn.count)

        let sd1: Double? = rmssd.map { $0 / 2.0.squareRoot() }
        var sd2: Double?
        if let sd1, let sdnn {
            let v = 2.0 * sdnn * sdnn - sd1 * sd1
            sd2 = v > 0 ? v.squareRoot() : 0
        }
        let ratio: Double? = (sd1 != nil && (sd2 ?? 0) > 0) ? sd1! / sd2! : nil
        // Normalised by the mean interval so the measure does not simply track heart rate — a fast
        // rhythm has smaller intervals and would otherwise look less variable by construction.
        let normRmssd: Double? = (rmssd != nil && meanNN > 0) ? rmssd! / meanNN : nil

        return Stats(sd1: sd1, sd2: sd2, sd1sd2: ratio, normRmssd: normRmssd,
                     turningPointRate: turningPointRate(nn), ectopicFraction: ectopicFraction(nn))
    }

    /// How often the interval series reverses direction, RELATIVE to what pure noise would do.
    ///
    /// A random series turns on two thirds of its interior points, so the rate is divided by 2/3:
    /// 1.0 means "as choppy as noise", and that reference is what makes the threshold meaningful
    /// rather than an arbitrary count.
    static func turningPointRate(_ nn: [Double]) -> Double? {
        guard nn.count >= 3 else { return nil }
        var turns = 0
        for i in 1..<(nn.count - 1) where (nn[i] - nn[i - 1]) * (nn[i + 1] - nn[i]) < 0 { turns += 1 }
        let interior = Double(nn.count - 2)
        guard interior > 0 else { return nil }
        return (Double(turns) / interior) / (2.0 / 3.0)
    }

    /// Share of beats the ectopic filter would remove.
    static func ectopicFraction(_ nn: [Double]) -> Double {
        guard !nn.isEmpty else { return 0 }
        return Double(nn.count - HRVAnalyzer.rejectEctopic(nn).count) / Double(nn.count)
    }

    /// Consecutive interval pairs, for plotting.
    static func poincareCloud(_ nn: [Double]) -> [PoincarePoint] {
        guard nn.count >= 2 else { return [] }
        return (1..<nn.count).map { PoincarePoint(x: nn[$0 - 1], y: nn[$0]) }
    }

    /// Label a window from its statistics.
    ///
    /// The `varied` verdict requires ALL THREE conditions — round cloud, high normalised
    /// variability, and choppy timing. A conservative AND rather than a majority vote, because any
    /// one of them alone is reached often by ordinary noise, and this is the main lever against
    /// over-reading it.
    static func classify(_ s: Stats) -> RhythmRegularity {
        guard let ratio = s.sd1sd2, let nrmssd = s.normRmssd, let tp = s.turningPointRate
        else { return .unreadable }

        let scatterHigh = ratio >= tauRatio
        let variationHigh = nrmssd >= tauNRmssd
        let turningHigh = tp >= tauTP

        if scatterHigh && variationHigh && turningHigh { return .varied }

        // A notable ectopic fraction on an otherwise SMOOTH rhythm is sparse extra beats, not
        // disorganised timing. The `!turningHigh` is what separates the two.
        if (s.ectopicFraction ?? 0) >= tauEctopicLow && !turningHigh { return .occasionalEctopy }

        return .steady
    }

    static func confidence(for nBeats: Int) -> RhythmConfidence {
        if nBeats < windowMinBeats { return .calibrating }
        return nBeats >= solidBeats ? .solid : .building
    }

    public struct NightRhythmSummary: Equatable, Sendable, Codable {
        public let readableWindows: Int
        public let steadyWindows: Int
        public let occasionalWindows: Int
        public let variedWindows: Int
        /// Whether variation showed up in enough separate windows to be worth mentioning.
        public let variationRecurred: Bool
        public let overall: RhythmRegularity
        public init(readableWindows: Int, steadyWindows: Int, occasionalWindows: Int,
                    variedWindows: Int, variationRecurred: Bool, overall: RhythmRegularity) {
            self.readableWindows = readableWindows; self.steadyWindows = steadyWindows
            self.occasionalWindows = occasionalWindows; self.variedWindows = variedWindows
            self.variationRecurred = variationRecurred; self.overall = overall
        }
    }

    /// Roll a night's windows into one line.
    ///
    /// A night reads as varied only when several windows do. One odd window in a night is what a
    /// single roll-over or a loose strap looks like, and promoting it to the night's headline is
    /// exactly the over-reading the thresholds exist to prevent.
    public static func summarizeNight(_ windows: [WindowResult]) -> NightRhythmSummary {
        let readable = windows.filter { $0.label != .unreadable }
        let steady = readable.filter { $0.label == .steady }.count
        let occasional = readable.filter { $0.label == .occasionalEctopy }.count
        let varied = readable.filter { $0.label == .varied }.count

        let overall: RhythmRegularity
        if readable.isEmpty { overall = .unreadable }
        else if varied >= nightMinVariedWindows { overall = .varied }
        else if varied > 0 || occasional > 0 { overall = .occasionalEctopy }
        else { overall = .steady }

        return NightRhythmSummary(readableWindows: readable.count, steadyWindows: steady,
                                  occasionalWindows: occasional, variedWindows: varied,
                                  variationRecurred: varied >= nightMinVariedWindows,
                                  overall: overall)
    }
}
