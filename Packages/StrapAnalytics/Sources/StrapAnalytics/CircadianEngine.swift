import Foundation

/// Where a person's body clock actually sits, fitted from their activity.
///
/// The method is cosinor analysis: least-squares fitting a single 24-hour cosine to binned
/// activity. It is the standard tool for this because the quantity of interest is a PHASE — what
/// time the rhythm peaks — and a phase is what a cosine fit reports directly. Summary statistics
/// like a mean active hour cannot: they have no way to express that 23:00 and 01:00 are two hours
/// apart rather than twenty-two.
public enum CircadianEngine {

    /// Days of data before a fit is reported as anything but unreadable.
    public static let minDaysForFit: Int = 7
    /// Days before it is called solid rather than wide.
    public static let goodDaysForFit: Int = 14

    /// Amplitude as a fraction of the mean, below which the rhythm is too flat to have a phase.
    ///
    /// A nearly flat fit still HAS a mathematical peak, and reporting it would give a confident
    /// body-clock reading for someone whose activity is arrhythmic — shift work, illness, a strap
    /// worn intermittently.
    public static let minRelativeAmplitude: Double = 0.10

    /// The most a schedule should be shifted in one day.
    public static let maxShiftPerDayHours: Double = 1.0
    /// In an entrained clock the core-temperature minimum sits about this long before wake.
    public static let cbtMinBeforeWakeHours: Double = 2.5
    /// Activity peaks roughly half a day after the temperature minimum.
    public static let acrophaseAfterCbtMinHours: Double = 12.0

    public struct ActivityBin: Equatable, Sendable {
        public let hour: Double
        public let activity: Double
        public init(hour: Double, activity: Double) { self.hour = hour; self.activity = activity }
    }

    public struct CosinorFit: Equatable, Sendable {
        /// Rhythm-adjusted mean.
        public let mesor: Double
        /// Half the peak-to-trough swing.
        public let amplitude: Double
        /// Clock hour of the activity peak, in [0, 24).
        public let acrophaseHours: Double
        public init(mesor: Double, amplitude: Double, acrophaseHours: Double) {
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseHours = acrophaseHours
        }
    }

    /// Least-squares single-harmonic cosinor fit.
    ///
    /// Solved in closed form through the 3×3 normal equations rather than iteratively: the model is
    /// linear in its coefficients once written as `M + β·cos(ωt) + γ·sin(ωt)`, so there is an exact
    /// answer and no starting guess to get wrong.
    public static func cosinor(_ bins: [ActivityBin]) -> CosinorFit? {
        guard bins.count >= 3 else { return nil }
        let w = 2.0 * Double.pi / 24.0
        let n = Double(bins.count)

        var sumY = 0.0, sumC = 0.0, sumS = 0.0
        var sumCC = 0.0, sumSS = 0.0, sumCS = 0.0
        var sumYC = 0.0, sumYS = 0.0
        for b in bins {
            let c = cos(w * b.hour), s = sin(w * b.hour), y = b.activity
            sumY += y; sumC += c; sumS += s
            sumCC += c * c; sumSS += s * s; sumCS += c * s
            sumYC += y * c; sumYS += y * s
        }

        let a11 = n,    a12 = sumC,  a13 = sumS
        let a21 = sumC, a22 = sumCC, a23 = sumCS
        let a31 = sumS, a32 = sumCS, a33 = sumSS
        let det = a11 * (a22 * a33 - a23 * a32)
                - a12 * (a21 * a33 - a23 * a31)
                + a13 * (a21 * a32 - a22 * a31)
        // A singular system means the bins do not span enough of the cycle to place a phase — all
        // clustered in one part of the day, say. There is no fit, not a fit worth zero.
        guard abs(det) > 1e-12 else { return nil }

        let detM = sumY * (a22 * a33 - a23 * a32)
                 - a12  * (sumYC * a33 - a23 * sumYS)
                 + a13  * (sumYC * a32 - a22 * sumYS)
        let detB = a11 * (sumYC * a33 - a23 * sumYS)
                 - sumY * (a21 * a33 - a23 * a31)
                 + a13  * (a21 * sumYS - sumYC * a31)
        let detG = a11 * (a22 * sumYS - sumYC * a32)
                 - a12 * (a21 * sumYS - sumYC * a31)
                 + sumY * (a21 * a32 - a22 * a31)

        let beta = detB / det, gamma = detG / det
        // Wrapped through the shared helper, which also closes the 24.0 edge: a phase at midnight
        // comes out of atan2 as a tiny negative, and adding 24 to it rounds to exactly 24.0.
        let phase = Circadian.wrap24(atan2(gamma, beta) / w)
        return CosinorFit(mesor: detM / det,
                          amplitude: (beta * beta + gamma * gamma).squareRoot(),
                          acrophaseHours: phase)
    }

    public typealias PhaseConfidence = Circadian.PhaseConfidence

    public struct PhaseEstimate: Equatable, Sendable {
        public let tempMinHour: Double
        public let acrophaseHours: Double
        /// Signed minutes the estimated clock sits from the schedule's ideal. Positive is later.
        public let offsetVsScheduleMinutes: Double
        public let confidence: PhaseConfidence
        public let note: String
        public init(tempMinHour: Double, acrophaseHours: Double, offsetVsScheduleMinutes: Double,
                    confidence: PhaseConfidence, note: String) {
            self.tempMinHour = tempMinHour; self.acrophaseHours = acrophaseHours
            self.offsetVsScheduleMinutes = offsetVsScheduleMinutes
            self.confidence = confidence; self.note = note
        }
    }

    /// Estimate the body clock's phase.
    ///
    /// A thin or flat fit still returns an estimate, marked `.unreadable`. Returning nil would
    /// leave the surface with nothing to say; returning a flagged reading lets it say "hard to read
    /// right now" — which is the true statement, and the one that tells the user to keep wearing it.
    public static func estimatePhase(bins: [ActivityBin],
                                     daysObserved: Int,
                                     habitualWakeHour: Double,
                                     observedTempMinHour: Double? = nil) -> PhaseEstimate? {
        guard let fit = cosinor(bins) else { return nil }

        let relativeAmplitude = fit.mesor != 0 ? fit.amplitude / abs(fit.mesor) : 0
        if daysObserved < minDaysForFit || relativeAmplitude < minRelativeAmplitude {
            return PhaseEstimate(
                tempMinHour: observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours),
                acrophaseHours: fit.acrophaseHours,
                offsetVsScheduleMinutes: 0,
                confidence: .unreadable,
                note: "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
        }

        let tempMinHour = observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        let idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        let offsetMinutes = signedHourDelta(from: idealTempMin, to: tempMinHour) * 60.0

        let lean: String
        if offsetMinutes > 20 { lean = "later (a night-owl lean)" }
        else if offsetMinutes < -20 { lean = "earlier (a morning-lark lean)" }
        else { lean = "well-aligned with your schedule" }

        return PhaseEstimate(tempMinHour: tempMinHour, acrophaseHours: fit.acrophaseHours,
                             offsetVsScheduleMinutes: offsetMinutes,
                             confidence: daysObserved >= goodDaysForFit ? .solid : .wide,
                             note: "Your body clock looks \(lean).")
    }

    public static func wrap24(_ h: Double) -> Double { Circadian.wrap24(h) }

    /// The shortest signed distance between two clock hours, in −12…12.
    ///
    /// Signed and wrapped, because clock arithmetic is circular: 23:00 to 01:00 is +2 hours, not
    /// −22, and a phase offset computed by plain subtraction is wrong by a day for half its range.
    static func signedHourDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 24.0)
        if d > 12.0 { d -= 24.0 }
        if d <= -12.0 { d += 24.0 }
        return d
    }

    // MARK: - Shifting the clock

    public enum ShiftDirection: String, Equatable, Sendable, Codable {
        /// Move the clock EARLIER — eastward travel, or an earlier shift.
        case advance
        /// Move it LATER — westward travel, or a later shift.
        case delay
        case none
    }

    /// One day of a re-entrainment plan.
    ///
    /// Light and timing only. Nothing here is a supplement or a drug, and the plan says so.
    public struct DayPlan: Equatable, Sendable {
        public let dayIndex: Int
        public let brightLightStartHour: Double
        public let brightLightEndHour: Double
        public let dimFromHour: Double
        public let targetSleepHour: Double
        public let targetWakeHour: Double
        public let guidance: String
        public init(dayIndex: Int, brightLightStartHour: Double, brightLightEndHour: Double,
                    dimFromHour: Double, targetSleepHour: Double, targetWakeHour: Double,
                    guidance: String) {
            self.dayIndex = dayIndex
            self.brightLightStartHour = brightLightStartHour
            self.brightLightEndHour = brightLightEndHour
            self.dimFromHour = dimFromHour
            self.targetSleepHour = targetSleepHour
            self.targetWakeHour = targetWakeHour
            self.guidance = guidance
        }
    }

    public struct JetLagPlan: Equatable, Sendable {
        public let direction: ShiftDirection
        public let totalShiftHours: Double
        public let estimatedDays: Int
        public let days: [DayPlan]
        public let note: String
        public init(direction: ShiftDirection, totalShiftHours: Double, estimatedDays: Int,
                    days: [DayPlan], note: String) {
            self.direction = direction; self.totalShiftHours = totalShiftHours
            self.estimatedDays = estimatedDays; self.days = days; self.note = note
        }
    }

    /// A stepped light-and-timing plan for absorbing a clock shift.
    ///
    /// Positive `shiftHours` means the clock has to move EARLIER (eastward); negative, later.
    ///
    /// The plan steps by at most `maxShiftPerDayHours` a day because that is roughly what a
    /// circadian system will actually absorb — telling someone to move eight hours tonight
    /// produces no entrainment and a bad night.
    ///
    /// The light advice follows from the phase-response curve: to go EARLIER, bright light after
    /// waking and a dim evening; to go LATER, bright light in the evening and easy on the morning.
    /// Getting them the wrong way round pushes the clock in the opposite direction.
    public static func planShift(shiftHours: Double,
                                 currentSleepHour: Double,
                                 currentWakeHour: Double) -> JetLagPlan {
        let magnitude = abs(shiftHours)
        guard magnitude >= 0.5 else {
            return JetLagPlan(direction: .none, totalShiftHours: 0, estimatedDays: 0, days: [],
                              note: "No meaningful body-clock shift needed - you're about aligned.")
        }
        let advancing = shiftHours > 0
        let dayCount = Int((magnitude / maxShiftPerDayHours).rounded(.up))

        var plan: [DayPlan] = []
        var cumulative = 0.0
        for i in 1...dayCount {
            let step = min(maxShiftPerDayHours, magnitude - cumulative)
            cumulative += step
            let signed = advancing ? -cumulative : cumulative
            let sleep = wrap24(currentSleepHour + signed)
            let wake = wrap24(currentWakeHour + signed)

            let brightStart: Double, brightEnd: Double, dimFrom: Double, guidance: String
            if advancing {
                brightStart = wake
                brightEnd = wrap24(wake + 2.0)
                dimFrom = wrap24(sleep - 2.0)
                guidance = "Get bright light early after waking and keep the evening dim - this "
                    + "nudges your clock earlier. Aim for lights-out around \(clockString(sleep))."
            } else {
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light - "
                    + "this nudges your clock later. Aim for lights-out around "
                    + "\(clockString(sleep))."
            }
            plan.append(DayPlan(dayIndex: i, brightLightStartHour: brightStart,
                                brightLightEndHour: brightEnd, dimFromHour: dimFrom,
                                targetSleepHour: sleep, targetWakeHour: wake, guidance: guidance))
        }

        let dirWord = advancing ? "earlier" : "later"
        let perDay = maxShiftPerDayHours == 1.0 ? "an hour" : "\(maxShiftPerDayHours) h"
        let note = "Shifting your clock \(String(format: "%.1f", magnitude)) h \(dirWord), about "
            + "\(perDay) a day. Light and sleep timing only."
        return JetLagPlan(direction: advancing ? .advance : .delay, totalShiftHours: magnitude,
                          estimatedDays: dayCount, days: plan, note: note)
    }

    /// An hour as a clock face. Rounding 23:59.7 must not print 24:00.
    static func clockString(_ hour: Double) -> String {
        let h = wrap24(hour)
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}
