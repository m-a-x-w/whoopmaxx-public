import Foundation

/// Borbély's two-process model of sleep regulation, used to suggest a bedtime.
///
/// Sleep readiness is the gap between two things: process S, homeostatic pressure that builds
/// while awake and drains while asleep, and process C, a circadian threshold that rises and falls
/// on a 24-hour cycle. Sleep comes easily when S is well above C, and badly when it is not —
/// which is why lying down early in the "wake maintenance zone", a few hours before the circadian
/// low, produces a long frustrating wait despite real tiredness.
public enum TwoProcessModel {

    /// Time constants for the exponential rise and fall of process S. Pressure builds far more
    /// slowly than it drains, which is why one long night clears a deficit that took days to build.
    public static let tauRiseHours: Double = 18.2
    public static let tauDecayHours: Double = 4.2
    public static let sAsymptote: Double = 1.0
    /// Where S is assumed to sit at the very start of a history, before anything is known.
    public static let sInitialAtHistoryStart: Double = 0.55

    /// The wake-maintenance zone sits this far BEFORE the circadian temperature minimum — the
    /// paradoxical window where the body is least willing to fall asleep despite mounting pressure.
    public static let wakeMaintenanceLeadHours: Double = 8.0
    public static let circadianAmplitude: Double = 0.12
    public static let upperThresholdMean: Double = 0.46

    public static let solFloorMinutes: Double = 5.0
    public static let solCeilMinutes: Double = 55.0
    /// Steepness of the onset curve in the margin S − C.
    public static let onsetSteepness: Double = 15.0
    /// Predicted onset at or below this counts as the gate being open.
    public static let sleepGateOnsetMinutes: Double = 20.0

    public static let minSleepSessions: Int = 5
    public static let eveningScanStartLeadHours: Double = 12.0
    public static let eveningScanEndLeadHours: Double = 22.0
    public static let scanStepHours: Double = 1.0 / 12.0
    public static let windowHalfWidthHours: Double = 0.5

    public static let disclaimerTail =
        "On-device estimate - sleep-timing awareness, not medical advice."

    static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    /// Pressure after a stretch awake.
    public static func sAfterWake(hoursAwake: Double, from s0: Double) -> Double {
        clamp01(sAsymptote - (sAsymptote - s0) * exp(-max(0, hoursAwake) / tauRiseHours))
    }

    /// Pressure after a stretch asleep.
    public static func sAfterSleep(hoursAsleep: Double, from s0: Double) -> Double {
        clamp01(s0 * exp(-max(0, hoursAsleep) / tauDecayHours))
    }

    public struct SleepSpan: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationHours: Double { Double(max(0, end - start)) / 3600.0 }
    }

    /// Walk a night history forward to get S at the most recent wake.
    ///
    /// Integrating the WHOLE history rather than the last night: the model is stateful, and a
    /// short night leaves residual pressure that carries into the next day. Starting from the last
    /// wake alone would erase exactly the accumulated debt the model exists to represent.
    public static func homeostaticPressureAtWake(spans: [SleepSpan]) -> Double? {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return nil }
        var s = sInitialAtHistoryStart
        var prevEnd = first.start
        for (i, span) in sorted.enumerated() {
            if i > 0 {
                let wakeHours = Double(span.start - prevEnd) / 3600.0
                if wakeHours > 0 { s = sAfterWake(hoursAwake: wakeHours, from: s) }
            }
            s = sAfterSleep(hoursAsleep: span.durationHours, from: s)
            prevEnd = span.end
        }
        return s
    }

    /// Process C: the threshold S must exceed for sleep to come readily.
    public static func circadianThreshold(clockHour t: Double, tempMinHour: Double) -> Double {
        let wmz = Circadian.wrap24(tempMinHour - wakeMaintenanceLeadHours)
        return upperThresholdMean + circadianAmplitude * cos(2.0 * Double.pi * (t - wmz) / 24.0)
    }

    /// Predicted sleep-onset latency from the margin S − C.
    ///
    /// A logistic between a floor and a ceiling rather than an unbounded curve: nobody falls
    /// asleep instantly, and nobody's predicted latency should run to hours on a model this coarse.
    public static func onsetLatencyMinutes(margin m: Double) -> Double {
        solFloorMinutes + (solCeilMinutes - solFloorMinutes) / (1.0 + exp(onsetSteepness * m))
    }

    public struct BedtimeRecommendation: Equatable, Sendable {
        public let targetBedtimeHour: Double
        public let earliestHour: Double
        public let latestHour: Double
        public let predictedOnsetMinutes: Double
        public let homeostaticPressure: Double
        /// True when the wake target, not the body, chose the bedtime.
        public let constrainedByWake: Bool
        public let confidence: Circadian.PhaseConfidence
        public let rationale: String
        public let note: String

        public init(targetBedtimeHour: Double, earliestHour: Double, latestHour: Double,
                    predictedOnsetMinutes: Double, homeostaticPressure: Double,
                    constrainedByWake: Bool, confidence: Circadian.PhaseConfidence,
                    rationale: String, note: String) {
            self.targetBedtimeHour = targetBedtimeHour
            self.earliestHour = earliestHour; self.latestHour = latestHour
            self.predictedOnsetMinutes = predictedOnsetMinutes
            self.homeostaticPressure = homeostaticPressure
            self.constrainedByWake = constrainedByWake; self.confidence = confidence
            self.rationale = rationale; self.note = note
        }
    }

    /// Suggest a bedtime.
    ///
    /// Returns nil when the circadian phase is unreadable. A recommendation resting on a phase we
    /// could not fit would be advice shaped like evidence.
    ///
    /// The evening is scanned forward for the first moment the sleep gate opens. If it never opens
    /// in-window the LOWEST-onset candidate is used instead — a night with poor readiness still
    /// deserves the best available answer rather than none.
    public static func recommend(sAtWake: Double,
                                 habitualWakeHour: Double,
                                 tempMinHour: Double,
                                 needHours: Double,
                                 wakeTargetHour: Double?,
                                 phaseConfidence: Circadian.PhaseConfidence) -> BedtimeRecommendation? {
        guard phaseConfidence != .unreadable else { return nil }

        let wake = Circadian.wrap24(habitualWakeHour)
        let need = max(needHours, 0.5)
        let startLin = wake + eveningScanStartLeadHours
        let endLin = wake + eveningScanEndLeadHours

        // Times are handled on a LINEAR axis anchored to this morning's wake, wrapped only at the
        // very end. Wrapping mid-calculation is how a bedtime after midnight ends up compared
        // against a morning as if it were earlier in the same day.
        let wakeTargetLin = (wakeTargetHour.map { Circadian.wrap24($0) } ?? wake) + 24.0
        let latestFeasibleLin = wakeTargetLin - need

        var gateOpenLin: Double?
        var bestLin = startLin
        var bestOnset = Double.greatestFiniteMagnitude
        var b = startLin
        while b <= endLin + 1e-9 {
            let s = sAfterWake(hoursAwake: b - wake, from: sAtWake)
            let h = circadianThreshold(clockHour: Circadian.wrap24(b), tempMinHour: tempMinHour)
            let onset = onsetLatencyMinutes(margin: s - h)
            if onset < bestOnset { bestOnset = onset; bestLin = b }
            if onset <= sleepGateOnsetMinutes { gateOpenLin = b; break }
            b += scanStepHours
        }
        let gateLin = gateOpenLin ?? bestLin

        // Never later than the last bedtime that still clears `need` before the wake target, and
        // clamped into the scan window so a very short need cannot push it absurdly early.
        var targetLin = min(gateLin, latestFeasibleLin)
        targetLin = min(max(targetLin, startLin), endLin)
        let constrainedByWake = (wakeTargetHour != nil) && (latestFeasibleLin < gateLin)

        let sAtTarget = sAfterWake(hoursAwake: targetLin - wake, from: sAtWake)
        let hAtTarget = circadianThreshold(clockHour: Circadian.wrap24(targetLin), tempMinHour: tempMinHour)
        let onsetAtTarget = onsetLatencyMinutes(margin: sAtTarget - hAtTarget)

        let earliestLin = max(startLin, targetLin - windowHalfWidthHours)
        var latestLin = targetLin + windowHalfWidthHours
        if wakeTargetHour != nil { latestLin = min(latestLin, latestFeasibleLin) }
        latestLin = max(latestLin, targetLin)

        let targetHour = Circadian.wrap24(targetLin)
        return BedtimeRecommendation(
            targetBedtimeHour: targetHour,
            earliestHour: Circadian.wrap24(earliestLin),
            latestHour: Circadian.wrap24(latestLin),
            predictedOnsetMinutes: (onsetAtTarget * 10).rounded() / 10,
            homeostaticPressure: (sAtTarget * 1000).rounded() / 1000,
            constrainedByWake: constrainedByWake,
            confidence: phaseConfidence,
            rationale: rationaleText(targetClock: Circadian.clockString(targetHour),
                                     wakeTargetHour: wakeTargetHour, needHours: need,
                                     constrained: constrainedByWake, gateOpened: gateOpenLin != nil),
            note: noteText(confidence: phaseConfidence))
    }

    /// Convenience over a night history.
    /// The same recommendation from an OPTIONAL phase estimate.
    ///
    /// Returns nil when the phase is missing or unreadable, which is where that rule belongs: every
    /// caller holds an optional estimate, and left to each of them one would eventually recommend a
    /// bedtime from a clock nobody could read.
    public static func recommendBedtime(spans: [SleepSpan],
                                        habitualWakeHour: Double,
                                        tempMinHour: Double?,
                                        phaseConfidence: Circadian.PhaseConfidence?,
                                        needHours: Double,
                                        wakeTargetHour: Double?) -> BedtimeRecommendation? {
        guard let tempMinHour, let phaseConfidence, phaseConfidence != .unreadable else {
            return nil
        }
        return recommendBedtime(spans: spans, habitualWakeHour: habitualWakeHour,
                                tempMinHour: tempMinHour, needHours: needHours,
                                wakeTargetHour: wakeTargetHour, phaseConfidence: phaseConfidence)
    }

    public static func recommendBedtime(spans: [SleepSpan],
                                        habitualWakeHour: Double,
                                        tempMinHour: Double,
                                        needHours: Double,
                                        wakeTargetHour: Double?,
                                        phaseConfidence: Circadian.PhaseConfidence) -> BedtimeRecommendation? {
        guard spans.count >= minSleepSessions,
              let s = homeostaticPressureAtWake(spans: spans) else { return nil }
        return recommend(sAtWake: s, habitualWakeHour: habitualWakeHour, tempMinHour: tempMinHour,
                         needHours: needHours, wakeTargetHour: wakeTargetHour,
                         phaseConfidence: phaseConfidence)
    }

    static func rationaleText(targetClock: String, wakeTargetHour: Double?, needHours: Double,
                              constrained: Bool, gateOpened: Bool) -> String {
        if constrained, let w = wakeTargetHour {
            let needText = needHours == needHours.rounded()
                ? "\(Int(needHours))" : String(format: "%.1f", needHours)
            return "To clear about \(needText) h before your \(Circadian.clockString(Circadian.wrap24(w))) wake, "
                + "consider being in bed by \(targetClock) - a touch before your body's natural gate."
        }
        if gateOpened {
            return "Your sleep pressure meets its circadian gate around \(targetClock) - aim for lights-out "
                + "near then for a quick drift-off and deep early-night sleep."
        }
        return "Your body reads most ready for sleep around \(targetClock) - consider aiming for then; "
            + "onset may still take a little while tonight."
    }

    static func noteText(confidence: Circadian.PhaseConfidence) -> String {
        switch confidence {
        case .solid: return disclaimerTail
        case .wide: return "Still refining your rhythm - treat this as a soft nudge. " + disclaimerTail
        case .unreadable: return disclaimerTail
        }
    }
}

/// Circadian primitives shared across the sleep-timing engines.
public enum Circadian {

    /// How well the person's rhythm could be fitted.
    ///
    /// Carried into every recommendation so advice can be hedged honestly rather than presented
    /// with uniform confidence.
    public enum PhaseConfidence: String, Equatable, Sendable, Codable {
        /// Too few days, or arrhythmic — hard to read right now.
        case unreadable
        /// A fit, but from thin data, so the band is wide.
        case wide
        /// A stable fit over enough days.
        case solid
    }

    /// Fold an hour into [0, 24), including negatives.
    ///
    /// The final guard is not redundant. A tiny negative — the kind `atan2` produces for a phase
    /// at midnight — adds 24 and lands on exactly 24.0, because 24 − 1e-16 is not representable
    /// and rounds back up. That breaks the half-open contract every comparison downstream assumes.
    public static func wrap24(_ h: Double) -> Double {
        var x = h.truncatingRemainder(dividingBy: 24.0)
        if x < 0 { x += 24.0 }
        if x >= 24.0 { x = 0 }
        return x
    }

    /// A decimal hour as a 24-hour clock string.
    public static func clockString(_ hour: Double) -> String {
        let wrapped = wrap24(hour)
        var h = Int(wrapped)
        var m = Int(((wrapped - Double(h)) * 60).rounded())
        if m == 60 { m = 0; h = (h + 1) % 24 }
        return String(format: "%02d:%02d", h, m)
    }
}
