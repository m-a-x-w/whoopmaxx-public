import Foundation
import SwiftUI

/// The Rest "Regularity" cluster (011 W2.1): the Sleep Regularity Index as a hero numeral, one thin
/// column per night-to-night comparison, and the line that says how much of the window was actually
/// comparable.
///
/// It is a MULTI-NIGHT statistic, not a property of last night, which is why it sits with History
/// rather than inside "Last night" — and why the whole reading arrives pre-derived from
/// `RestModel.assemble` (a pure value, no injected `AnyView`, no Repository of its own), so the section
/// is previewable and the 1440-slot walk never runs on a SwiftUI frame.
///
/// Under `SleepRegularity.minimumPairs` comparisons it prints an em-dash and says how far along it is.
/// That is 011 decision 4 rendered: a partial window has no index, and an honest refusal with a reason
/// beats a plausible-looking number.
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
            RuleSection("Regularity") {
                VStack(alignment: .leading, spacing: WM.Space.m) {
                    Text(outcome.numeral)
                        .font(WMType.display(56))
                        .foregroundStyle(WM.Ground.ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    Text(outcome.summaryLine(isNewest: isNewest))
                        .font(WMType.body)
                        .foregroundStyle(WM.Ground.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .reading(let reading) = outcome, !reading.pairs.isEmpty {
                        RegularityPairColumns(pairs: reading.pairs)
                    }
                    if let detail = outcome.detailLine {
                        Text(detail)
                            .font(WMType.caption)
                            .foregroundStyle(WM.Ground.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(voiceOverLabel(outcome))
            }
        }
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

// MARK: - The columns

/// One thin column per comparison, oldest → newest: the locked bars motif, never a ring or a dial.
/// Each column stands in a rest-wash track running the full 0…100 of the index, so the gap above a
/// fill is the part of the day the two nights did NOT match — the reading and its headroom in one mark.
/// Latest at full strength, history at 62%; Rest indigo is the only color.
private struct RegularityPairColumns: View {
    let pairs: [SleepRegularity.Pair]

    private let columnWidth: CGFloat = 6
    private let gap: CGFloat = 4
    private let height: CGFloat = 56

    /// The strip is left-aligned and sized to its columns, so its floor rule stops with the data
    /// rather than running the full gutter and implying nights that were never compared.
    private var stripWidth: CGFloat {
        CGFloat(pairs.count) * columnWidth + CGFloat(max(0, pairs.count - 1)) * gap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(pairs.enumerated()), id: \.element.dayKey) { index, pair in
                    column(pair, isLatest: index == pairs.count - 1)
                }
            }
            Rectangle()
                .fill(WM.Ground.rule)
                .frame(width: stripWidth, height: WM.hairline)
        }
        .accessibilityHidden(true)   // the section's combined label already states the reading
    }

    private func column(_ pair: SleepRegularity.Pair, isLatest: Bool) -> some View {
        // The index runs −100…100; the track runs 0…1 over that span, clamped so a negative pair
        // (rarer than it sounds — it means the two nights matched on under half the day) reads as an
        // empty track rather than an inverted one.
        let fill = min(max((pair.sri + 100) / 200, 0), 1)
        let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        return ZStack(alignment: .bottom) {
            shape.fill(WM.Domain.rest.wash)
            shape
                .fill(WM.Domain.rest.color.opacity(isLatest ? 1 : 0.62))
                .frame(height: max(1.5, height * fill))
        }
        .frame(width: columnWidth, height: height)
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
            .padding(.horizontal, WM.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WM.Ground.ground)
    }
}
