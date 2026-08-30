import Foundation

/// Early warning that the body is under strain — and, more importantly, the machinery for NOT
/// saying so.
///
/// A health warning is only useful if it is rare. Every gate here exists to keep it that way: one
/// signal is never enough, a cold-start baseline never warns at all, and a logged behaviour that
/// plainly explains the reading downgrades it rather than letting it fire. An app that tells
/// someone they might be ill the morning after a hard workout and a late drink is an app whose
/// warnings get dismissed unread, at which point the real one is invisible too.
public enum IllnessSignalEngine {

    /// Composite score at which the signal surfaces and notifies.
    public static let raiseThreshold: Double = 50.0
    /// Below this, nothing is said at all.
    public static let mildThreshold: Double = 25.0
    /// Signals that must agree before anything is raised.
    ///
    /// Two, not one. Any single vital drifts two sigmas often enough on its own — a bad night's
    /// sleep moves HRV that far — and warning on one would fire most weeks.
    public static let minCorroboratingSignals: Int = 2
    /// Sigmas a signal must exceed before it counts as firing.
    public static let signalZThreshold: Double = 2.0
    /// Score per sigma beyond the threshold.
    public static let kZToScore: Double = 22.0
    /// Ceiling on one signal's contribution, so a single extreme reading cannot raise the
    /// composite alone and bypass the corroboration rule by arithmetic.
    public static let perSignalCap: Double = 40.0
    /// What a confounder multiplies the score by.
    public static let confounderDampen: Double = 0.45

    public static let disclaimerTail = "On-device estimate - not a diagnosis."

    /// One vital's deviation, already oriented so POSITIVE means illness-ward.
    ///
    /// The orientation is the caller's job because it differs per signal: a rising resting heart
    /// rate and a FALLING HRV both point the same way, and a signed z would cancel them out.
    public struct SignalReading: Equatable, Sendable {
        public let zIllnessward: Double
        /// Whether the signal was measured at all. Absent is not zero.
        public let present: Bool
        public init(zIllnessward: Double, present: Bool = true) {
            self.zIllnessward = zIllnessward; self.present = present
        }
    }

    public struct Inputs: Equatable, Sendable {
        public var restingHR: SignalReading?
        public var skinTemp: SignalReading?
        /// The NEGATED z: a drop is illness-ward.
        public var hrv: SignalReading?
        public var respiration: SignalReading?
        public init(restingHR: SignalReading? = nil, skinTemp: SignalReading? = nil,
                    hrv: SignalReading? = nil, respiration: SignalReading? = nil) {
            self.restingHR = restingHR; self.skinTemp = skinTemp
            self.hrv = hrv; self.respiration = respiration
        }
    }

    /// What the user logged, and whether their baseline can be trusted yet.
    public struct Context: Equatable, Sendable {
        public var alcohol: Bool
        public var stress: Bool
        public var sauna: Bool
        public var weed: Bool
        public var hardOrLateWorkout: Bool
        public var travelPhaseJump: Bool
        /// The user said they already feel unwell. Their own report outranks the signals.
        public var alreadyUnwell: Bool
        public var baselineTrusted: Bool

        public init(alcohol: Bool = false, stress: Bool = false, sauna: Bool = false,
                    weed: Bool = false, hardOrLateWorkout: Bool = false,
                    travelPhaseJump: Bool = false, alreadyUnwell: Bool = false,
                    baselineTrusted: Bool = true) {
            self.alcohol = alcohol; self.stress = stress; self.sauna = sauna; self.weed = weed
            self.hardOrLateWorkout = hardOrLateWorkout; self.travelPhaseJump = travelPhaseJump
            self.alreadyUnwell = alreadyUnwell; self.baselineTrusted = baselineTrusted
        }
    }

    public enum Level: String, Equatable, Sendable, Codable {
        case quiet
        /// Visible in a detail view, never notified.
        case mild
        case raised
        /// Real anomaly with a plainer explanation logged.
        case suppressed
        /// The user told us. Not a scare.
        case alreadyUnwell
    }

    public struct Result: Equatable, Sendable {
        public let score: Double
        public let level: Level
        public let firedSignals: [String]
        public let suppressedBy: [String]
        public let signalCount: Int
        public let copy: String
        public init(score: Double, level: Level, firedSignals: [String],
                    suppressedBy: [String], signalCount: Int, copy: String) {
            self.score = score; self.level = level; self.firedSignals = firedSignals
            self.suppressedBy = suppressedBy; self.signalCount = signalCount; self.copy = copy
        }
    }

    public static func evaluate(_ inputs: Inputs, context: Context,
                                firedLabels: [String: String] = [:]) -> Result {
        // Fixed order so `firedSignals` is deterministic — the copy quotes it, and a set's
        // iteration order would reword the same morning differently on each launch.
        let ordered: [(key: String, reading: SignalReading?)] = [
            ("restingHR", inputs.restingHR),
            ("skinTemp", inputs.skinTemp),
            ("hrv", inputs.hrv),
            ("respiration", inputs.respiration),
        ]

        var rawScore = 0.0
        var firedKeys: [String] = []
        for (key, reading) in ordered {
            guard let r = reading, r.present else { continue }
            let over = r.zIllnessward - signalZThreshold
            guard over > 0 else { continue }
            firedKeys.append(key)
            rawScore += min(perSignalCap, kZToScore * over)
        }
        let score = min(100.0, rawScore)
        let signalCount = firedKeys.count
        let firedSignals = firedKeys.compactMap { firedLabels[$0] }

        // An untrusted baseline never warns. "Unusual for you" is meaningless before there is a
        // "for you" — the score is still reported so a detail view can show its working.
        guard context.baselineTrusted else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Still learning your baseline - keeping an eye out.")
        }

        // The user's own report is ground truth. Once they have said they feel unwell, the job is
        // no longer to warn — it is to stop warning.
        if context.alreadyUnwell {
            let agreeing = score >= mildThreshold && signalCount >= 1
            return Result(score: score, level: .alreadyUnwell, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: agreeing
                            ? "Rest up - you logged feeling unwell, and your numbers agree. \(disclaimerTail)"
                            : "Rest up - you logged feeling unwell. Take it easy today. \(disclaimerTail)")
        }

        guard signalCount >= minCorroboratingSignals, score >= mildThreshold else {
            return Result(score: score, level: .quiet, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "Nothing notable - your signals look like your normal range.")
        }

        var suppressedBy: [String] = []
        if context.alcohol { suppressedBy.append("alcohol") }
        if context.stress { suppressedBy.append("stress") }
        if context.sauna { suppressedBy.append("sauna") }
        if context.weed { suppressedBy.append("weed") }
        if context.hardOrLateWorkout { suppressedBy.append("a hard or late workout") }
        if context.travelPhaseJump { suppressedBy.append("travel") }

        let signalsPhrase = firedSignals.isEmpty ? "Some signals are up" : firedSignals.joined(separator: ", ")

        if !suppressedBy.isEmpty {
            return Result(score: score * confounderDampen, level: .suppressed,
                          firedSignals: firedSignals, suppressedBy: suppressedBy,
                          signalCount: signalCount,
                          copy: "Some signals are up (\(signalsPhrase)), but you logged "
                              + "\(joinReasons(suppressedBy)) - likely that, not illness. \(disclaimerTail)")
        }

        if score < raiseThreshold {
            return Result(score: score, level: .mild, firedSignals: firedSignals,
                          suppressedBy: [], signalCount: signalCount,
                          copy: "A few signals are mildly up (\(signalsPhrase)). Nothing alarming - "
                              + "worth a calmer day. \(disclaimerTail)")
        }

        // The copy says only what this path actually knows: NONE of the confounders fired. Naming
        // two of them would go stale the moment the list grows, and would claim they were each
        // ruled out individually — which is not what happened.
        return Result(score: score, level: .raised, firedSignals: firedSignals,
                      suppressedBy: [], signalCount: signalCount,
                      copy: "Heads-up - your body looks strained. \(signalsPhrase). With nothing logged "
                          + "to explain it, consider taking it easy. \(disclaimerTail)")
    }

    static func joinReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0: return "something"
        case 1: return reasons[0]
        case 2: return "\(reasons[0]) and \(reasons[1])"
        default: return "\(reasons.dropLast().joined(separator: ", ")) and \(reasons.last!)"
        }
    }
}
