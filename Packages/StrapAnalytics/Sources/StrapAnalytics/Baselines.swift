import Foundation

/// Personal baselines: what is normal FOR THIS PERSON, and how far tonight sits from it.
///
/// Everything downstream that says "your HRV is low" means low against this, not against a
/// population. The model is an exponentially weighted mean with a matching dispersion estimate,
/// updated once per night.
///
/// `spread` is carried as a MEAN ABSOLUTE DEVIATION, not a standard deviation. MAD is far less
/// sensitive to the occasional wild night, which matters when a single bad reading would otherwise
/// widen the band enough to make the next fortnight's real changes look normal. It converts to σ
/// by the factor 1.253 (the ratio for a normal distribution), applied at the point of comparison.
public enum Baselines {

    /// Per-metric bounds and adaptation rates.
    public struct MetricCfg: Equatable, Sendable {
        /// Hard physiological bounds. A value outside them is not folded in at all.
        public let minVal: Double
        public let maxVal: Double
        /// Minimum dispersion. Without a floor a long flat stretch collapses the band to nothing
        /// and every subsequent night reads as a dramatic deviation.
        public let floorSpread: Double
        /// Half-life in nights for the centre.
        public let halfLifeB: Double
        /// Half-life for the spread — deliberately SLOWER than the centre, so the band does not
        /// chase the very night it is supposed to be judging.
        public let halfLifeS: Double

        public init(minVal: Double, maxVal: Double, floorSpread: Double,
                    halfLifeB: Double, halfLifeS: Double) {
            self.minVal = minVal; self.maxVal = maxVal; self.floorSpread = floorSpread
            self.halfLifeB = halfLifeB; self.halfLifeS = halfLifeS
        }
    }

    public enum BaselineStatus: String, Equatable, Sendable {
        /// Too few nights to say anything.
        case calibrating
        /// Enough to show, with a caveat.
        case provisional
        /// Enough to compare against.
        case trusted
        /// Was trusted, but nothing has updated it in a long time.
        case stale
    }

    public struct BaselineState: Equatable, Sendable {
        public let baseline: Double
        /// Mean absolute deviation, not σ.
        public let spread: Double
        public let nValid: Int
        public let nightsSinceUpdate: Int
        public let status: BaselineStatus

        public init(baseline: Double, spread: Double, nValid: Int,
                    nightsSinceUpdate: Int, status: BaselineStatus) {
            self.baseline = baseline; self.spread = spread; self.nValid = nValid
            self.nightsSinceUpdate = nightsSinceUpdate; self.status = status
        }

        public var trusted: Bool { status == .trusted }
        public var usable: Bool { status == .provisional || status == .trusted }
    }

    public struct Deviation: Equatable, Sendable {
        public let z: Double
        public let delta: Double
        public let ratio: Double
        public let inNormalRange: Bool
        public init(z: Double, delta: Double, ratio: Double, inNormalRange: Bool) {
            self.z = z; self.delta = delta; self.ratio = ratio; self.inNormalRange = inNormalRange
        }
    }

    // MARK: - Constants

    /// Clamp band for folding a night in, in spreads.
    public static let winsorK: Double = 3.0
    /// Beyond this, a night is not folded at all.
    public static let hardOutlierK: Double = 5.0
    public static let minNightsSeed: Int = 4
    public static let minNightsTrust: Int = 14
    /// Nights without an update before a baseline is called stale.
    public static let staleDays: Int = 14

    // Early-life anti-anchoring.
    //
    // Seeding the centre on the first night with the spread pinned at its floor creates a trap: a
    // high first reading becomes an anchor, and the user's real, lower nights then sit more than
    // five floor-spreads away and are rejected as outliers. The baseline never moves and the app
    // reports a deficit that does not exist. So while young the model adapts faster, widens the
    // clamp band, and suspends hard-outlier rejection entirely.
    //
    // Youth is measured in VALID NIGHTS, not in spread: a long flat history is settled even though
    // its spread never lifted off the floor, and must still reject a wild one-off.
    public static let earlyAdaptNights: Int = 8
    public static let earlyHalfLifeB: Double = 3.0
    public static let earlySpreadInflate: Double = 2.5

    /// MAD to σ for a normal distribution.
    public static let sigmaPerMAD: Double = 1.253

    public static let metricCfg: [String: MetricCfg] = [
        "hrv": MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0, halfLifeB: 14.0, halfLifeS: 21.0),
        "resting_hr": MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0, halfLifeB: 14.0, halfLifeS: 21.0),
        "resp": MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5, halfLifeB: 14.0, halfLifeS: 21.0),
        "skin_temp": MetricCfg(minVal: 20.0, maxVal: 42.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0),
    ]

    public static var hrvCfg: MetricCfg { metricCfg["hrv"]! }
    public static var restingHRCfg: MetricCfg { metricCfg["resting_hr"]! }
    public static var respCfg: MetricCfg { metricCfg["resp"]! }
    public static var skinTempCfg: MetricCfg { metricCfg["skin_temp"]! }

    /// Per-night decay factor for a half-life expressed in nights.
    static func lambda(halfLife: Double) -> Double { 1.0 - pow(0.5, 1.0 / halfLife) }

    /// How much of the spread estimate is still the seeded floor rather than measured dispersion.
    ///
    /// The EWMA starts AT the floor, so early spreads are mostly that seed rather than anything
    /// observed. This weight is divided back out below, which is what stops a young baseline
    /// reporting a confident band it has not earned.
    static func spreadSeedWeight(nValid: Int, cfg: MetricCfg) -> Double {
        pow(1.0 - lambda(halfLife: cfg.halfLifeS), Double(max(0, nValid - 1)))
    }

    static func computeStatus(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && nValid >= minNightsSeed { return .stale }
        if nValid < minNightsSeed { return .calibrating }
        if nValid < minNightsTrust { return .provisional }
        return .trusted
    }

    // MARK: - Update

    /// Fold one night in.
    ///
    /// A missing or implausible night is SKIP-AND-HOLD: the baseline is untouched and the
    /// nights-since-update counter advances. It is not folded in as a zero, and it does not reset
    /// anything — a week off the wrist should leave the baseline exactly where it was, marked
    /// stale, not quietly relearned from nothing.
    public static func update(_ state: BaselineState?, value: Double?, cfg: MetricCfg) -> BaselineState {
        let lb = lambda(halfLife: cfg.halfLifeB)
        let ls = lambda(halfLife: cfg.halfLifeS)

        // First night ever.
        guard let state else {
            if let v = value, cfg.minVal <= v, v <= cfg.maxVal {
                return BaselineState(baseline: v, spread: cfg.floorSpread, nValid: 1,
                                     nightsSinceUpdate: 0, status: .calibrating)
            }
            // Nothing usable yet — seed the centre at the midpoint of the plausible range so the
            // first real night has somewhere to move from, and count it as no valid nights.
            return BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2, spread: cfg.floorSpread,
                                 nValid: 0, nightsSinceUpdate: 1, status: .calibrating)
        }

        func hold(_ nightsSince: Int) -> BaselineState {
            BaselineState(baseline: state.baseline, spread: state.spread, nValid: state.nValid,
                          nightsSinceUpdate: nightsSince,
                          status: computeStatus(nValid: state.nValid, nightsSinceUpdate: nightsSince))
        }

        guard let value else { return hold(state.nightsSinceUpdate + 1) }
        guard cfg.minVal <= value, value <= cfg.maxVal else { return hold(state.nightsSinceUpdate + 1) }

        let isYoung = state.nValid < earlyAdaptNights

        // Hard outlier: seen, acknowledged as a night, but not folded. Suspended while young —
        // that suspension is the anti-anchoring fix, and without it a true reading far below an
        // anchored baseline is rejected forever as an outlier.
        if state.nValid >= minNightsSeed, !isYoung,
           abs(value - state.baseline) > hardOutlierK * state.spread {
            return BaselineState(baseline: state.baseline, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: 0,
                                 status: computeStatus(nValid: state.nValid, nightsSinceUpdate: 0))
        }

        // First real value after a placeholder seed: treat as a clean first night rather than
        // averaging against a midpoint nobody measured.
        if state.nValid == 0 {
            return BaselineState(baseline: value, spread: cfg.floorSpread, nValid: 1,
                                 nightsSinceUpdate: 0, status: .calibrating)
        }

        // Winsorized EWMA: clamp the night into the band before folding, so one extreme value
        // moves the centre by a bounded amount instead of dragging it.
        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effLb = isYoung ? lambda(halfLife: earlyHalfLifeB) : lb
        let clamped = max(state.baseline - winsorK * effSpread,
                          min(state.baseline + winsorK * effSpread, value))
        let newBaseline = effLb * clamped + (1 - effLb) * state.baseline

        // Spread tracks the deviation from the NEW centre. The seed weight is removed so an early
        // spread reports measured dispersion rather than the floor it was seeded with.
        let absDev = abs(value - newBaseline)
        let newN = state.nValid + 1
        let qPrev = spreadSeedWeight(nValid: state.nValid, cfg: cfg)
        let rawPrev = state.nValid <= 1
            ? cfg.floorSpread
            : state.spread * (1 - qPrev) + qPrev * cfg.floorSpread
        let raw = max(cfg.floorSpread, ls * absDev + (1 - ls) * rawPrev)
        let q = spreadSeedWeight(nValid: newN, cfg: cfg)
        let newSpread = (1 - q) > 1e-12
            ? max(cfg.floorSpread, (raw - q * cfg.floorSpread) / (1 - q))
            : cfg.floorSpread

        return BaselineState(baseline: newBaseline, spread: newSpread, nValid: newN,
                             nightsSinceUpdate: 0,
                             status: computeStatus(nValid: newN, nightsSinceUpdate: 0))
    }

    /// Fold a whole history in, oldest first.
    public static func foldHistory(_ values: [Double?], cfg: MetricCfg) -> BaselineState {
        var state: BaselineState?
        for v in values { state = update(state, value: v, cfg: cfg) }
        return state ?? BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2,
                                      spread: cfg.floorSpread, nValid: 0,
                                      nightsSinceUpdate: 0, status: .calibrating)
    }

    // MARK: - Comparison

    /// How far a value sits from the baseline.
    ///
    /// `z` is in σ, converted from the stored MAD. `inNormalRange` is |z| ≤ 1 — a deliberately
    /// wide band, because the purpose is to avoid crying wolf on ordinary night-to-night movement.
    public static func deviation(_ value: Double, state: BaselineState) -> Deviation {
        let sigma = max(sigmaPerMAD * state.spread, 1e-9)
        return Deviation(z: (value - state.baseline) / sigma,
                         delta: value - state.baseline,
                         ratio: state.baseline != 0 ? (value / state.baseline - 1) : 0,
                         inNormalRange: abs((value - state.baseline) / sigma) <= 1.0)
    }

    /// A plain trailing-window mean and standard deviation.
    ///
    /// Offered alongside the EWMA because it is auditable: a user asking "what is my baseline"
    /// can be shown a mean of the last N nights and check it by hand, which is not true of an
    /// exponentially weighted estimate.
    public static func rollingMeanSD(_ values: [Double?], cfg: MetricCfg, window: Int = 30) -> BaselineState {
        let valid = values.compactMap { v -> Double? in
            guard let v, cfg.minVal <= v, v <= cfg.maxVal else { return nil }
            return v
        }
        guard !valid.isEmpty else {
            return BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2, spread: cfg.floorSpread,
                                 nValid: 0, nightsSinceUpdate: 0, status: .calibrating)
        }
        let trailing = Array(valid.suffix(window))
        let n = trailing.count
        let mean = trailing.reduce(0, +) / Double(n)
        let sd: Double
        if n >= 2 {
            let ss = trailing.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            sd = (ss / Double(n - 1)).squareRoot()
        } else {
            // One sample has no dispersion. Reporting zero would make the next night read as an
            // infinite deviation.
            sd = cfg.floorSpread * sigmaPerMAD
        }
        return BaselineState(baseline: mean, spread: max(cfg.floorSpread, sd) / sigmaPerMAD,
                             nValid: n, nightsSinceUpdate: 0,
                             status: computeStatus(nValid: n, nightsSinceUpdate: 0))
    }

    // MARK: - Recalibration

    /// Where the manual "start my baseline again from today" instant is kept, in epoch seconds.
    /// Zero means never recalibrated.
    public static let hrvBaselineEpochKey = "wm.hrvBaselineEpoch"
    /// The same, for the wider recovery set — resting HR, respiration, skin temperature. HRV has
    /// its own key because it was wired first and its stored value must keep its meaning.
    public static let recoveryBaselineEpochKey = "wm.recoveryBaselineEpoch"

    public static func hrvBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: hrvBaselineEpochKey)
    }

    public static func recoveryBaselineEpoch(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: recoveryBaselineEpochKey)
    }

    /// Re-anchor every baseline that feeds Charge, so the build-up restarts from now.
    ///
    /// It deletes NO stored night — only the day the baselines learn FROM moves. Everything
    /// re-seeds from the first night on or after `now`, and the screens honestly show the
    /// calibrating state again.
    public static func recalibrateRecoveryBaselines(now: Double = Date().timeIntervalSince1970,
                                                    defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: hrvBaselineEpochKey)
        defaults.set(now, forKey: recoveryBaselineEpochKey)
    }

    /// Fold a history that knows which day each value came from, honouring a recalibration.
    ///
    /// A night before the recalibration instant is DROPPED, not skipped-and-held: skipping would
    /// carry the pre-recalibration state forward, which is the very thing the wearer asked to
    /// forget.
    ///
    /// With no recalibration set this is exactly the plain fold.
    public static func foldHistory(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                   baselineEpoch: Double? = nil,
                                   offsetSec: Int = 0) -> BaselineState {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        guard epoch > 0 else { return foldHistory(values, cfg: cfg) }
        var state: BaselineState?
        for (i, v) in values.enumerated() {
            if i < dayKeys.count, let start = dayStartEpoch(dayKeys[i]),
               start - Double(offsetSec) < epoch { continue }
            state = update(state, value: v, cfg: cfg)
        }
        return state ?? BaselineState(baseline: (cfg.minVal + cfg.maxVal) / 2,
                                      spread: cfg.floorSpread, nValid: 0,
                                      nightsSinceUpdate: 0, status: .calibrating)
    }

    /// Was the baseline usable AS OF each night, rather than at the end of the history?
    ///
    /// A scoring pass folds one baseline over everything and then scores every day against that
    /// final state — so an early night gets judged against a baseline built partly from its own
    /// future. This answers the honest question for each night in turn.
    public static func foldPrefixUsable(_ values: [Double?], dayKeys: [String], cfg: MetricCfg,
                                        baselineEpoch: Double? = nil,
                                        offsetSec: Int = 0) -> [String: Bool] {
        let epoch = baselineEpoch ?? hrvBaselineEpoch()
        var state: BaselineState?
        var out: [String: Bool] = [:]
        for (i, v) in values.enumerated() {
            guard i < dayKeys.count else { break }
            if epoch > 0, let start = dayStartEpoch(dayKeys[i]),
               start - Double(offsetSec) < epoch {
                continue        // dropped: no entry at all, which reads as not usable
            }
            state = update(state, value: v, cfg: cfg)
            out[dayKeys[i]] = state?.usable ?? false
        }
        return out
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayStartEpoch(_ dayKey: String) -> Double? {
        dayKeyFormatter.date(from: dayKey)?.timeIntervalSince1970
    }
}
