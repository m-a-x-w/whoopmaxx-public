import SwiftUI

/// Last night's two headline numerals side by side — Rest score and time asleep — with the
/// plain-voice verdict line beneath ("Rest 82 — above your typical."). Calibrating shows "—".
///
/// On a night the stager kept but FLAGGED (016), the Asleep numeral takes the provisional treatment
/// `ScoreColumn` already gives a carried or low-coverage score — secondary ink, no new colour, no icon,
/// no alert — and the caveat lands as a caption beneath the verdict. The caveat COMPOSES with the
/// verdict rather than replacing it: the verdict explains the Rest number, the caveat the recording, and
/// swapping one for the other would delete an explanation to make room for another.
struct RestNightHero: View {
    /// Rest score 0–100; nil = calibrating.
    let score: Double?
    /// Minutes asleep; nil = unknown.
    let asleepMin: Double?
    /// 30-day typical Rest score for the verdict caption; nil hides the line.
    var typical: Double? = nil
    /// The stager's low-confidence caveat for this night (`RestNight.lowConfidenceCaption`), or nil on
    /// an ordinary night — which renders byte-identically to before this argument existed.
    ///
    /// REQUIRED, deliberately no default. A defaulted honesty argument that the single production call
    /// site forgets to pass is invisible: green build, green tests, feature absent from the binary —
    /// which is exactly how `ScoreTrio.Entry.calibratingNote` and `ArousalForensicsSection.dayKey`
    /// shipped dead. A caller with no caveat to make now says `nil` out loud.
    let lowConfidenceCaption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
                block(label: "Rest",
                      value: score.map { "\(Int($0.rounded()))" } ?? "—",
                      provisional: false)
                // Only the ASLEEP numeral dims: the flag is about how long the recording ran, which is
                // what that numeral is read off. The Rest score is caveated by the caption below, not by
                // a second dimmed numeral.
                block(label: "Asleep",
                      value: asleepMin.map(RestFormat.hmm) ?? "—",
                      provisional: lowConfidenceCaption != nil)
            }
            if let verdict {
                Text(verdict)
                    .font(WMType.body)
                    .foregroundStyle(WM.Ground.inkSecondary)
            }
            if let lowConfidenceCaption {
                Text(lowConfidenceCaption)
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The caveat is a Text in the combined element, so VoiceOver speaks it with the numerals — the
        // dimmed ink that marks the state visually is invisible to it (ScoreColumn's own reasoning).
        .accessibilityElement(children: .combine)
    }

    private func block(label: String, value: String, provisional: Bool) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text(label).wmOverline()
            Text(value)
                .font(WMType.display(64))
                .foregroundStyle(provisional ? WM.Ground.inkSecondary : WM.Ground.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var verdict: String? {
        guard let score, let typical else { return nil }
        let word: String
        switch score - typical {
        case ..<(-3): word = "below"
        case 3...:    word = "above"
        default:      word = "near"
        }
        return "Rest \(Int(score.rounded())) — \(word) your typical."
    }
}

#Preview("RestNightHero — light") {
    RestNightHeroSpecimen().preferredColorScheme(.light)
}

#Preview("RestNightHero — dark") {
    RestNightHeroSpecimen().preferredColorScheme(.dark)
}

private struct RestNightHeroSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.sectionLoose) {
            RestNightHero(score: 82, asleepMin: 432, typical: 74, lowConfidenceCaption: nil)
            RestNightHero(score: nil, asleepMin: nil, lowConfidenceCaption: nil)   // calibrating
            // The flagged night: a 17 h 12 min recorded stretch against the 16 h cap. Through the
            // production copy so the preview cannot drift from what the screen prints — and so this
            // state is inspectable in both themes without a simulator.
            RestNightHero(score: 68, asleepMin: 580, typical: 74,
                          lowConfidenceCaption: RestNight.lowConfidenceCaption(spanS: 61_920))
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
