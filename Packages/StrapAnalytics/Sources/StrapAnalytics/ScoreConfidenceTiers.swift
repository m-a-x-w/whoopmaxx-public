import Foundation

/// How much to trust each of the three scores on a given day.
///
/// A score and its confidence are computed from the SAME inputs, at the same moment, so the tier
/// can never describe a different day than the number beside it.
public extension ScoreConfidence {

    /// Charge is only as good as the baseline it is measured against.
    static func charge(recovery: Double?, hrvBaseline: Baselines.BaselineState?)
        -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// About an hour of heart-rate coverage before a day's Effort is dense enough to be solid.
    static let solidEffortReadings: Int = 3600

    static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Waking-window capture coverage a day needs before its Effort can be called solid.
    static let effortSolidCoverage: Double = 0.85

    /// Effort confidence including how much of the day was actually captured.
    ///
    /// Effort ACCUMULATES: fewer samples strictly means less load, and the log compression at the
    /// end means a half-missing day does not look half-missing — it lands inside the normal range,
    /// numerically indistinguishable from a genuinely quiet one. The sample-count bar cannot catch
    /// this, because a day with a multi-hour hole still carries tens of thousands of samples.
    ///
    /// The score itself is never rescaled. The hole's contents are unknowable — anywhere from
    /// nothing to the busiest window this wearer has ever recorded — and inventing a number for it
    /// would be worse than saying so.
    ///
    /// nil coverage means "not graded" and changes nothing, so today's live gauge is never flagged
    /// merely for being incomplete.
    static func effort(strain: Double?, hrSampleCount: Int, coverage: Double?) -> ScoreConfidence {
        let base = effort(strain: strain, hrSampleCount: hrSampleCount)
        guard base == .solid, let c = coverage, c < effortSolidCoverage else { return base }
        return .building
    }

    static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }

    /// Restorative share below which staging on a high-efficiency night is suspect.
    static let restorativeLowConfidenceShare: Double = 0.10
    /// A fragmented night legitimately carries less deep and REM, so the floor only applies above
    /// this efficiency — otherwise it fires on exactly the nights it should not.
    static let highEfficiencyThreshold: Double = 0.85

    /// Rest confidence, with a check on whether the stages are believable.
    ///
    /// A night that scored high efficiency — plenty of measured sleep — and yet almost no deep or
    /// REM is far more likely a staging miss than a real night without either: separating light
    /// from deep and REM is the weakest part of any EEG-free classifier. The tier says so, rather
    /// than fabricating stages or docking the score.
    static func rest(hasSession: Bool, hasStagedSleep: Bool,
                     asleepSeconds: Double, restorativeSeconds: Double,
                     efficiency: Double) -> ScoreConfidence {
        let base = rest(hasSession: hasSession, hasStagedSleep: hasStagedSleep)
        guard base == .solid, asleepSeconds > 0 else { return base }
        let share = restorativeSeconds / asleepSeconds
        if efficiency >= highEfficiencyThreshold && share < restorativeLowConfidenceShare {
            return .building
        }
        return base
    }
}
