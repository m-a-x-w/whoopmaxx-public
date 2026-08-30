import Foundation

/// Pure, deterministic honesty/confidence rubric for the Rest "This morning's wake" panel.
///
/// Given the recorded wake (if any), how much of the wake window the strap actually STREAMED, and whether
/// the latest edge has passed, it scores 0…1 how much we can trust the "we woke you at a good moment"
/// claim — and returns the plain reasons behind that score. No over-claiming:
///
///  - An `earlyWatcher` fire is the ONLY case that PROVES the app was alive + connected + worn + streaming,
///    so it gets the HIGH base, scaled up by streamed coverage, worn, and an encrypted bond.
///  - A `strapBackstop` fire is kill-proof but means the live detection never engaged — the user woke at
///    the latest edge — so it gets a MEDIUM-LOW base.
///  - No event but the deadline passed is an inferred backup/notification wake with no strap detection at
///    all (likely the app wasn't alive) — LOW.
///
/// Everything is pure + deterministic (no clock, no I/O) so the rubric is unit-tested directly.
enum WakeConfidence {

    /// The confidence band the score falls into.
    enum Tier: String, Equatable {
        case high, medium, low

        /// Plain, exact label for the gauge (house voice — no exclamation, no over-claim).
        var label: String {
            switch self {
            case .high:   return "High confidence"
            case .medium: return "Medium confidence"
            case .low:    return "Low confidence"
            }
        }
    }

    /// The rubric result: a 0…1 score, its tier, and the plain reasons behind it.
    struct Assessment: Equatable {
        let score: Double
        let tier: Tier
        let reasons: [String]
    }

    // MARK: - Rubric weights (bases + modifiers), named so the tests read as the spec

    /// `earlyWatcher` base (before modifiers) — inherently the confident case.
    static let earlyBase = 0.55
    /// `earlyWatcher` bonus scaled by streamed window coverage (0…1 → 0…this).
    static let coverageWeight = 0.30
    /// `earlyWatcher` bonus when the strap was on the wrist at fire.
    static let wornWeight = 0.10
    /// `earlyWatcher` bonus when the strap had a genuine encrypted bond at fire.
    static let bondWeight = 0.05
    /// `strapBackstop` base — kill-proof buzz, but the smart detection did NOT engage.
    static let backstopBase = 0.40
    /// `strapBackstop` bonus when the strap had a genuine encrypted bond.
    static let backstopBondWeight = 0.10
    /// Inferred backup/notification wake (no event, but the deadline has passed).
    static let inferredBackupScore = 0.20

    /// Tier cutoffs on the 0…1 score.
    static let highCutoff = 0.66
    static let mediumCutoff = 0.40

    // MARK: - Assessment

    static func assess(event: WakeEvent?,
                       hrCoverageFraction: Double,
                       deadlinePassed: Bool) -> Assessment {
        let coverage = min(max(hrCoverageFraction, 0), 1)
        let pct = Int((coverage * 100).rounded())

        guard let event else {
            // No recorded wake. If the latest edge has passed, the user was (best-effort) woken by the OS
            // backup with no strap detection at all; otherwise there is simply nothing to report yet.
            if deadlinePassed {
                return Assessment(score: inferredBackupScore, tier: tier(for: inferredBackupScore),
                                  reasons: ["no strap detection — inferred backup wake",
                                            "the app wasn't streaming, so detection couldn't run"])
            }
            return Assessment(score: 0, tier: .low, reasons: ["no wake recorded yet"])
        }

        switch event.trigger {
        case .earlyWatcher:
            var score = earlyBase + coverage * coverageWeight
            var reasons = ["detection engaged", "streamed \(pct)% of the window"]
            if event.worn { score += wornWeight; reasons.append("strap on your wrist") }
            if event.encryptedBond { score += bondWeight; reasons.append("strap bonded") }
            score = min(score, 1)
            return Assessment(score: score, tier: tier(for: score), reasons: reasons)

        case .strapBackstop:
            var score = backstopBase
            var reasons = ["woke at your latest edge — the watcher didn't run",
                           "kill-proof strap backstop"]
            if event.encryptedBond { score += backstopBondWeight; reasons.append("strap bonded") }
            score = min(score, 1)
            return Assessment(score: score, tier: tier(for: score), reasons: reasons)
        }
    }

    /// Pips filled (0…`total`) for the gauge readout at this score. Deterministic (rounds half away from
    /// zero, then clamps), so the gauge and the tier can't disagree.
    static func filledPips(for score: Double, of total: Int = 5) -> Int {
        let clamped = min(max(score, 0), 1)
        return min(max(Int((clamped * Double(total)).rounded()), 0), total)
    }

    private static func tier(for score: Double) -> Tier {
        if score >= highCutoff { return .high }
        if score >= mediumCutoff { return .medium }
        return .low
    }
}
