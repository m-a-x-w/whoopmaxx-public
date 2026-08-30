import SwiftUI
import StrapAnalytics

/// The Rest "Tonight's bedtime" cluster — the forward-looking two-process (Borbély) optimal bedtime, sitting
/// below "Last night". Open-editorial RuleSection, no card; rest-indigo used sparingly for the bedtime hero
/// (a Rest concept), everything else neutral ink. Copy is condensed — hero + compact cells + one tight
/// caption line, and that ONE line carries the rationale AND the model's standing awareness-only tail
/// (`rec.note`) run together. Honest cold-start state.
///
/// Pure over an injected `TwoProcessModel.BedtimeRecommendation?` so it previews without a live Repository /
/// engine (the `OptimalBedtimeArmed` wrapper owns the `BodyClockEngine` and feeds this the readout).
struct OptimalBedtimeSection: View {
    /// The recommendation, or nil for the honest cold-start / thin-data state.
    let recommendation: TwoProcessModel.BedtimeRecommendation?
    /// True once the first body-clock compute has landed, so "learning" reads differently from "no data".
    var loaded: Bool = true

    var body: some View {
        RuleSection("Tonight's bedtime", topGap: WM.Space.sectionTight) {
            if let rec = recommendation {
                content(rec)
            } else {
                coldStart
            }
        }
    }

    // MARK: - Populated

    private func content(_ rec: TwoProcessModel.BedtimeRecommendation) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            hero(rec)
            detailRow(rec)
            // rationale AND note, run together as one caption block.
            //
            // WHAT WAS WRONG: when the copy was condensed (f7e72fc) the rationale was promoted into the
            // caption slot and `Text(rec.note)` was deleted with it — so `rec.note` reached no rendered
            // surface anywhere in the app. That silently dropped BOTH halves the model computes there:
            // the `.wide`-confidence caveat ("Still refining your rhythm - treat this as a soft nudge.")
            // and the standing `TwoProcessModel.disclaimerTail` ("On-device estimate - sleep-timing
            // awareness, not medical advice."). A 32pt indigo clock time is the most assertive thing on
            // this screen, and it was hedged only by the single word "Learning" in the Read cell — which
            // reads as a data quality label, not as "do not treat this as medical guidance".
            //
            // WHY THIS SHAPE: the one-tight-caption-line constraint from f7e72fc is deliberate and worth
            // keeping, so this folds rather than reverting to a second paragraph — the layout is
            // unchanged, the hero does not reflow, and the tail simply continues the sentence. Both
            // fields are non-optional stored Strings on the struct, so unlike an `if let` branch this
            // render path has no way to drop the caveat again. `rationale` always ends in a full stop and
            // `note` always begins capitalised (TwoProcessModel.swift), so the single space reads clean.
            Text("\(rec.rationale) \(rec.note)")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hero(_ rec: TwoProcessModel.BedtimeRecommendation) -> some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Text("Aim for").wmOverline()
            Text(Self.clockLabel(rec.targetBedtimeHour))
                .font(WMType.numeral(32))
                .foregroundStyle(WM.Domain.rest.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("window \(Self.clockLabel(rec.earliestHour))–\(Self.clockLabel(rec.latestHour))")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested bedtime \(Self.clockLabel(rec.targetBedtimeHour)), window "
            + "\(Self.clockLabel(rec.earliestHour)) to \(Self.clockLabel(rec.latestHour))")
    }

    private func detailRow(_ rec: TwoProcessModel.BedtimeRecommendation) -> some View {
        HStack(alignment: .top, spacing: WM.Space.sectionLoose) {
            SignalCell(label: "Est. onset",
                       value: "\(Int(rec.predictedOnsetMinutes.rounded()))",
                       unit: "min")
            SignalCell(label: "Sleep pressure",
                       value: "\(Int((rec.homeostaticPressure * 100).rounded()))",
                       unit: "%")
            SignalCell(label: "Read", value: Self.confidenceWord(rec.confidence))
        }
    }

    // MARK: - Cold start

    private var coldStart: some View {
        Text(loaded
             ? "Your rhythm is still coming into focus. Keep wearing whoopmaxx overnight and through the day, and a bedtime will appear here."
             : "Reading your body clock…")
            .font(WMType.body)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, WM.Space.xs)
            .accessibilityLabel("Bedtime not available yet")
    }

    // MARK: - Formatting

    private static func confidenceWord(_ c: CircadianEngine.PhaseConfidence) -> String {
        switch c {
        case .solid: return "Solid"
        case .wide: return "Learning"
        case .unreadable: return "Low"
        }
    }

    /// Locale-aware HH:mm for a clock hour in [0, 24), matching the wake-window pickers' formatting.
    static func clockLabel(_ hour: Double) -> String { WMFormat.clockLabel(hour) }
}

/// The observing wrapper injected into RestScreen: owns the `BodyClockEngine`, reads the Repository +
/// wake-window settings from the environment, and feeds the pure section its readout. Kept isolated so the
/// engine's on-appear compute never re-runs the whole Rest screen. Previewable-free — RestScreen injects it
/// as an AnyView so RestScreenContent stays pure.
struct OptimalBedtimeArmed: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var alarmSettings: SmartAlarmSettings
    @StateObject private var engine = BodyClockEngine()

    var body: some View {
        OptimalBedtimeSection(recommendation: engine.readout?.bedtime,
                              loaded: engine.readout != nil)
            .task(id: taskKey) {
                await engine.refresh(repo: repo, wakeTargetHour: wakeTargetHour)
            }
    }

    /// Wake target = the smart alarm's guaranteed latest edge (minutes → clock hour) when enabled, else
    /// nil so the bedtime runs unconstrained.
    private var wakeTargetHour: Double? {
        alarmSettings.enabled ? Double(alarmSettings.latestMin) / 60.0 : nil
    }

    /// Recompute when the day, the data (refreshSeq), or the wake target changes — never per frame.
    private var taskKey: String {
        "\(repo.refreshSeq)|\(alarmSettings.enabled ? alarmSettings.latestMin : -1)"
    }
}

// MARK: - Previews

#Preview("Bedtime — free, light") {
    OptimalBedtimeSpecimen(recommendation: .freeSpecimen).preferredColorScheme(.light)
}

#Preview("Bedtime — constrained, dark") {
    OptimalBedtimeSpecimen(recommendation: .constrainedSpecimen).preferredColorScheme(.dark)
}

#Preview("Bedtime — cold start, light") {
    OptimalBedtimeSpecimen(recommendation: nil).preferredColorScheme(.light)
}

private struct OptimalBedtimeSpecimen: View {
    let recommendation: TwoProcessModel.BedtimeRecommendation?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OptimalBedtimeSection(recommendation: recommendation)
            }
            .padding(.horizontal, WM.Space.gutter)
        }
        .background(WM.Ground.ground)
    }
}

extension TwoProcessModel.BedtimeRecommendation {
    /// Synthetic "free" (unconstrained) recommendation for previews / specimens — no live engine.
    static let freeSpecimen = TwoProcessModel.BedtimeRecommendation(
        targetBedtimeHour: 22.75, earliestHour: 22.25, latestHour: 23.25,
        predictedOnsetMinutes: 19.7, homeostaticPressure: 0.618, constrainedByWake: false,
        confidence: .solid,
        rationale: "Your sleep pressure meets its circadian gate around 22:45 - aim for lights-out near then for a quick drift-off and deep early-night sleep.",
        note: TwoProcessModel.disclaimerTail)

    /// Synthetic wake-window-constrained recommendation for previews / specimens.
    static let constrainedSpecimen = TwoProcessModel.BedtimeRecommendation(
        targetBedtimeHour: 22.0, earliestHour: 21.5, latestHour: 22.0,
        predictedOnsetMinutes: 21.2, homeostaticPressure: 0.613, constrainedByWake: true,
        confidence: .wide,
        rationale: "To clear about 8 h before your 06:00 wake, consider being in bed by 22:00 - a touch before your body's natural gate.",
        note: "Still refining your rhythm - treat this as a soft nudge. " + TwoProcessModel.disclaimerTail)
}
