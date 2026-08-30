import Foundation
import StrapProtocol

/// A behaviour's effect at the lag where it shows up most strongly.
public struct RankedEffect: Equatable, Sendable {
    public let behavior: String
    public let outcome: String
    /// Days between the behaviour and the outcome it moved.
    public let lag: Int
    public let effect: BehaviorEffect
    public let confidence: ScoreConfidence

    public init(behavior: String, outcome: String, lag: Int,
                effect: BehaviorEffect, confidence: ScoreConfidence) {
        self.behavior = behavior; self.outcome = outcome
        self.lag = lag; self.effect = effect; self.confidence = confidence
    }

    public var leadLagText: String {
        switch lag {
        case 0: return "same day"
        case 1: return "next morning"
        default: return "\(lag) mornings later"
        }
    }

    /// The plain sentence, with the lag stated.
    ///
    /// Naming the lag is not decoration: "alcohol lowers your Charge" and "alcohol lowers your
    /// Charge two mornings later" are different claims, and only one of them is what was measured.
    public func sentence() -> String {
        let base = BehaviorInsights.sentence(effect)
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return "\(trimmed) (\(leadLagText))."
    }
}

/// Finds, for each behaviour, the lag at which it moves an outcome most.
public enum EffectRanker {

    /// Lags searched. Deliberately short — a behaviour's effect three days later is more likely a
    /// coincidence found by searching than a real delayed response.
    public static let lagSet: [Int] = [0, 1, 2]
    public static let calibratingBelow: Int = BehaviorInsights.minGroupForSignificance
    public static let solidPairs: Int = 10

    public static func rank(behaviors: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String) -> [RankedEffect] {
        // Names sorted so the build order does not depend on dictionary iteration.
        sorted(behaviors.keys.sorted().compactMap { name in
            bestLag(behaviorDays: behaviors[name]!, outcomeByDay: outcomeByDay,
                    behavior: name, outcome: outcome)
        })
    }

    /// The strongest lag for one behaviour.
    ///
    /// Searching several lags and keeping the best is a multiple-comparison problem in miniature,
    /// so a lag only competes when BOTH its groups clear the significance minimum. Without that
    /// gate a two-day lag wins on a handful of days and the result reads as a discovered delayed
    /// effect rather than the fluke it is.
    public static func bestLag(behaviorDays: Set<String>,
                               outcomeByDay: [String: Double],
                               behavior: String,
                               outcome: String) -> RankedEffect? {
        var best: (lag: Int, effect: BehaviorEffect)?
        for lag in lagSet {
            guard let e = BehaviorInsights.effect(behaviorDays: behaviorDays,
                                                  outcomeByDay: shiftedOutcome(outcomeByDay, byLag: lag),
                                                  behavior: behavior, outcome: outcome) else { continue }
            guard Swift.min(e.nWith, e.nWithout) >= BehaviorInsights.minGroupForSignificance else { continue }

            if let cur = best {
                // Largest absolute effect wins; ties break to the SHORTER lag, because a same-day
                // explanation is more plausible than a delayed one at equal evidence.
                let better = abs(e.cohensD) > abs(cur.effect.cohensD)
                    || (abs(e.cohensD) == abs(cur.effect.cohensD) && lag < cur.lag)
                if better { best = (lag, e) }
            } else {
                best = (lag, e)
            }
        }
        guard let chosen = best else { return nil }
        return RankedEffect(behavior: behavior, outcome: outcome, lag: chosen.lag, effect: chosen.effect,
                            confidence: confidence(forPairs: Swift.min(chosen.effect.nWith,
                                                                       chosen.effect.nWithout)))
    }

    /// Re-key the outcome so day D's value is attributed to the behaviour day `D − lag`.
    static func shiftedOutcome(_ outcomeByDay: [String: Double], byLag lag: Int) -> [String: Double] {
        guard lag != 0 else { return outcomeByDay }
        var out: [String: Double] = [:]
        out.reserveCapacity(outcomeByDay.count)
        for (day, value) in outcomeByDay {
            if let behaviourKey = CorrelationEngine.shiftDay(day, by: -lag) { out[behaviourKey] = value }
        }
        return out
    }

    static func sorted(_ rows: [RankedEffect]) -> [RankedEffect] {
        rows.sorted { a, b in
            if a.effect.significant != b.effect.significant { return a.effect.significant }
            let la = abs(a.effect.cohensD), lb = abs(b.effect.cohensD)
            if la != lb { return la > lb }
            return a.behavior < b.behavior
        }
    }

    static func confidence(forPairs pairs: Int) -> ScoreConfidence {
        if pairs < calibratingBelow { return .calibrating }
        return pairs >= solidPairs ? .solid : .building
    }
}

/// Which device owns a day's displayed metrics.
public enum DayOwnerResolver {

    public struct Candidate: Equatable, Sendable {
        public let deviceId: String
        /// 0 = the active strap, 1 = another live strap, 2 = an import. Lower wins.
        public let priority: Int
        public let hasData: Bool
        public init(deviceId: String, priority: Int, hasData: Bool) {
            self.deviceId = deviceId; self.priority = priority; self.hasData = hasData
        }
    }

    /// Resolve a day's owner.
    ///
    /// A LOCKED owner short-circuits everything — locked means a person decided, and this resolver
    /// runs on a schedule, so without the short-circuit the next automatic pass would quietly
    /// reverse them.
    ///
    /// Candidates without data are excluded entirely: a higher-priority device that recorded
    /// nothing that day should not win the day and blank it.
    public static func resolve(day: String, lockedOwner: String?, candidates: [Candidate]) -> String? {
        if let locked = lockedOwner { return locked }
        return candidates.filter(\.hasData).sorted { $0.priority < $1.priority }.first?.deviceId
    }
}

/// Re-scoring a manually added workout once its heart rate has arrived.
public enum ManualWorkoutRescore {

    public struct Scored: Equatable, Sendable {
        public let avgHr: Int
        public let maxHr: Int
        public let strain: Double?
        public let kcal: Double?
        public init(avgHr: Int, maxHr: Int, strain: Double?, kcal: Double?) {
            self.avgHr = avgHr; self.maxHr = maxHr; self.strain = strain; self.kcal = kcal
        }
    }

    /// At or below this, a stored workout is treated as never really scored.
    ///
    /// A manually logged workout is saved before its heart rate has synced, so it lands with
    /// essentially no energy — which is what makes it worth revisiting rather than leaving as the
    /// user's own number.
    public static let underScoredKcalThreshold = 5.0
    /// How much better a re-score must be before it replaces what is stored. Without a margin,
    /// float noise alone would rewrite a workout on every pass.
    public static let improvementMarginKcal = 1.0

    public static func looksUnderScored(currentKcal: Double?) -> Bool {
        (currentKcal ?? 0) <= underScoredKcalThreshold
    }

    public static func scored(windowSamples: [HRSample], profile: UserProfile, hrMax: Double,
                              restingHR: Double = StrainScorer.defaultRestingHR) -> Scored? {
        guard windowSamples.count >= 2 else { return nil }
        let bpms = windowSamples.map(\.bpm)
        let kcalRaw = Calories.estimateBoutCalories(windowSamples, profile: profile,
                                                    hrmax: hrMax, restingHR: restingHR).0
        return Scored(avgHr: Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded()),
                      maxHr: bpms.max() ?? 0,
                      strain: StrainScorer.strain(windowSamples, maxHR: hrMax,
                                                  restingHR: restingHR, sex: profile.sex),
                      // Zero energy is no estimate, not an estimate of nothing.
                      kcal: kcalRaw > 0 ? kcalRaw : nil)
    }

    /// Whether a re-score is worth writing back.
    ///
    /// The strain-only fill exists because a workout can have a believable energy figure and no
    /// strain at all, and filling that gap is an improvement even when the energy does not beat
    /// what is stored.
    public static func improves(_ scored: Scored, over currentKcal: Double?,
                                currentStrain: Double? = nil,
                                allowStrainOnlyFill: Bool = false,
                                allowStrainRewrite: Bool = false) -> Bool {
        if let newK = scored.kcal, newK > (currentKcal ?? 0) + improvementMarginKcal { return true }
        if allowStrainRewrite, scored.strain != nil, scored.strain != currentStrain { return true }
        return allowStrainOnlyFill && currentStrain == nil && scored.strain != nil
    }
}

/// A one-line record of a raw frame, for re-deriving a decode later.
public enum Spo2ReTrace {

    /// Records dumped per offload session. A handful is enough for an offline correlation pass and
    /// keeps the strap log bounded; the counter spans chunks and resets once per session.
    public static let maxSamples = 8
    /// Every field is rendered, `null` included, and the raw hex is always appended.
    ///
    /// A trace that omitted absent fields would be unparseable as a table, and one without the
    /// bytes could not be re-decoded at all — which is the only reason it is written.
    public static func recordLine(frame: [UInt8], version: Int?, unix: Int?,
                                  red: Int?, ir: Int?, skinRaw: Int?) -> String {
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        func f(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return "spo2re v=\(f(version)) unix=\(f(unix)) red=\(f(red)) ir=\(f(ir)) "
            + "skinRaw=\(f(skinRaw)) len=\(frame.count) raw=\(hex)"
    }
}
