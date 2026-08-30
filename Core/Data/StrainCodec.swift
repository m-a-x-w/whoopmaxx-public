import Foundation
import StrapAnalytics

/// Wire codec for the persisted `strain_level` metric series — the health monitor's per-day
/// heads-up level as a stable small integer (the metricSeries table stores doubles).
/// 0 quiet / 1 mild / 2 raised / 3 suppressed / 4 alreadyUnwell (the engine's fifth level — the
/// "sick"-logged gentle rest-up path). `Comparable` on the raw value so the Today banner gates on
/// `level >= .mild` (everything the spec calls "mild or louder": mild, raised, suppressed,
/// alreadyUnwell all render a heads-up row).
enum StrainLevel: Int, Comparable, Sendable {
    case quiet = 0, mild = 1, raised = 2, suppressed = 3, alreadyUnwell = 4

    init(_ level: IllnessSignalEngine.Level) {
        switch level {
        case .quiet:         self = .quiet
        case .mild:          self = .mild
        case .raised:        self = .raised
        case .suppressed:    self = .suppressed
        case .alreadyUnwell: self = .alreadyUnwell
        }
    }

    static func < (lhs: StrainLevel, rhs: StrainLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Wire codec for the persisted `strain_fired` metric series (007 F2): a small bitmask of which
/// signals cleared the engine's illness-ward firing bar (z > `signalZThreshold` against a trusted
/// baseline) the night ScoreEngine scored it. Written next to `strain_score`/`strain_level` so the
/// detail screen's per-vital "Flagged" markers read the SAME derivation as the persisted level,
/// instead of re-deriving z over a different baseline population (which let the banner and the
/// rows disagree). Bit values are stable wire format — never renumber.
enum StrainFiredMask {
    static let restingHR = 1
    static let skinTemp = 2
    static let hrv = 4
    static let respiration = 8

    /// The bitmask for one night's assembled readings — the exact firing rule the engine applies
    /// (`zIllnessward - signalZThreshold > 0`; an absent/untrusted reading never fires).
    static func mask(of inputs: IllnessSignalEngine.Inputs) -> Int {
        func fired(_ r: IllnessSignalEngine.SignalReading?) -> Bool {
            guard let r, r.present else { return false }
            return r.zIllnessward - IllnessSignalEngine.signalZThreshold > 0
        }
        var m = 0
        if fired(inputs.restingHR) { m |= restingHR }
        if fired(inputs.skinTemp) { m |= skinTemp }
        if fired(inputs.hrv) { m |= hrv }
        if fired(inputs.respiration) { m |= respiration }
        return m
    }
}
