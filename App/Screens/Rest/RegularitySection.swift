import Foundation
import SwiftUI

/// Rest › "Trend"'s Regularity reading (011 W2.1): the Sleep Regularity Index as a `ScoreLine` (037)
/// — the index as a rest numeral over a `.row` line on 0…100 — then the line that says what was measured
/// and how much of the window was actually comparable.
///
/// It is a MULTI-NIGHT statistic, not a property of last night, which is why it sits in "Trend" with the
/// duration history rather than beside the hero — and why the whole reading arrives pre-derived from
/// `RestModel.assemble` (a pure value, no injected `AnyView`, no Repository of its own), so it is
/// previewable and the 1440-slot walk never runs on a SwiftUI frame.
///
/// The line carries no typical band: the only range this window could offer is the spread of its own
/// night-to-night pairs, and a band built from the same pairs the index pools would always contain it —
/// a comparison with nothing on the other side.
///
/// Under `SleepRegularity.minimumPairs` comparisons it prints an em-dash over an empty line and says how
/// far along it is. That is 011 decision 4 rendered: a partial window has no index, and an honest refusal
/// with a reason beats a plausible-looking number.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string here — *thermoregulation, vasodilation, impaired, poor,
/// abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you should", "talk to"*.
struct RegularitySection: View {
    /// The window's reading; nil hides the section entirely (nothing was measured).
    let outcome: SleepRegularity.Outcome?
    /// Whether the screen is on its newest night. REQUIRED, no default — this section was the LAST one
    /// on the browsable screen whose copy still spoke in the present tense ("so far", "your"), so a
    /// default here is precisely how it would drift back.
    let isNewest: Bool

    var body: some View {
        if let outcome {
            VStack(alignment: .leading, spacing: WM.Space.s) {
                ScoreLine(title: "Regularity",
                          subtitle: subtitle(outcome),
                          value: outcome.numeral,
                          fraction: fraction(outcome),
                          domain: .rest)
                Text(caption(outcome))
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(voiceOverLabel(outcome))
        }
    }

    /// "sleep regularity index · 14 nights" — the window the index was read over.
    private func subtitle(_ outcome: SleepRegularity.Outcome) -> String {
        switch outcome {
        case .reading(let r): return "sleep regularity index \u{00B7} \(r.nightsConsidered) nights"
        case .calibrating:    return "sleep regularity index"
        }
    }

    /// The index on the line's 0…100 scale. A negative index (the two nights matched on under half the
    /// day) sits at the left end rather than off the rail; calibrating draws the empty track.
    private func fraction(_ outcome: SleepRegularity.Outcome) -> Double? {
        guard case .reading(let r) = outcome else { return nil }
        return min(max(r.sri / 100, 0), 1)
    }

    /// The summary (browse-aware tense) and, on a reading, the comparable-nights footnote.
    private func caption(_ outcome: SleepRegularity.Outcome) -> String {
        [outcome.summaryLine(isNewest: isNewest), outcome.detailLine]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func voiceOverLabel(_ outcome: SleepRegularity.Outcome) -> String {
        switch outcome {
        case .reading(let r):
            return "Sleep regularity \(Int(r.sri.rounded())). \(outcome.summaryLine(isNewest: isNewest)) "
                + (outcome.detailLine ?? "")
        case .calibrating:
            return "Sleep regularity. \(outcome.summaryLine(isNewest: isNewest))"
        }
    }
}

// MARK: - Previews

#Preview("Regularity — light") {
    RegularitySpecimen(kind: .steady).preferredColorScheme(.light)
}

#Preview("Regularity — dark") {
    RegularitySpecimen(kind: .steady).preferredColorScheme(.dark)
}

#Preview("Regularity — calibrating, light") {
    RegularitySpecimen(kind: .calibrating).preferredColorScheme(.light)
}

#Preview("Regularity — calibrating, dark") {
    RegularitySpecimen(kind: .calibrating).preferredColorScheme(.dark)
}

private struct RegularitySpecimen: View {
    enum Kind { case steady, calibrating }
    let kind: Kind

    /// Eleven deterministic comparisons over a 1440-minute day, wandering the way a real fortnight
    /// does — built as agreeing-minute COUNTS so the specimen is on the same scale as the engine.
    /// Eleven and not thirteen on purpose: one unusable night inside a 14-day window takes BOTH of its
    /// pairs, which is exactly the arithmetic the "13 of 14 nights compared" line is describing.
    private var outcome: SleepRegularity.Outcome {
        switch kind {
        case .calibrating:
            return .calibrating(pairs: 4, needed: SleepRegularity.minimumPairs)
        case .steady:
            let agreements = [1288, 1210, 1332, 1265, 1180, 1301, 1244, 1156, 1290, 1318, 1223]
            let pairs = agreements.enumerated().map { i, a in
                SleepRegularity.Pair(dayKey: String(format: "2026-07-%02d", i + 6),
                                     agreeing: a, compared: SleepRegularity.slotsPerDay)
            }
            let total = agreements.reduce(0, +)
            return .reading(SleepRegularity.Reading(
                sri: SleepRegularity.index(agreeing: total,
                                           compared: agreements.count * SleepRegularity.slotsPerDay),
                pairs: pairs, nightsUsable: 13, nightsConsidered: 14))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RegularitySection(outcome: outcome, isNewest: true)
            }
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }
}
