import SwiftUI
import StrapAnalytics

/// The "Bedtime" row under Rest › "Tonight" (037) — the forward-looking two-process (Borbély)
/// optimal bedtime. A list row: "Bedtime" over "Aim for 10:45 PM · window 10:15 PM – 11:15 PM", the model's
/// three cells (estimated onset, sleep pressure, how solid the read is) as one caption, and the
/// rationale with the model's standing awareness-only tail (`rec.note`) as the closing caption. No
/// color: the row is guidance, not a reading. Honest cold-start state.
///
/// Pure over an injected `TwoProcessModel.BedtimeRecommendation?` so it previews without a live Repository /
/// engine (the `OptimalBedtimeArmed` wrapper owns the `BodyClockEngine` and feeds this the readout). The
/// "Tonight" section label and the hairline to the wake-window row belong to the Rest screen.
struct OptimalBedtimeSection: View {
    /// The recommendation, or nil for the honest cold-start / thin-data state.
    let recommendation: TwoProcessModel.BedtimeRecommendation?
    /// True once the first body-clock compute has landed, so "learning" reads differently from "no data".
    var loaded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bedtime")
                .font(WMType.body)
                .foregroundStyle(WM.Ground.ink)
            if let rec = recommendation {
                content(rec)
            } else {
                coldStart
            }
        }
        .padding(.vertical, WM.Space.s)
        .frame(maxWidth: .infinity, minHeight: WM.Space.row + 8, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Populated

    @ViewBuilder
    private func content(_ rec: TwoProcessModel.BedtimeRecommendation) -> some View {
        Text(Self.aimLine(rec))
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(Self.cellsLine(rec))
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
        // rationale AND note, run together as one caption block.
        //
        // WHAT WAS WRONG: when the copy was condensed (f7e72fc) the rationale was promoted into the
        // caption slot and `Text(rec.note)` was deleted with it — so `rec.note` reached no rendered
        // surface anywhere in the app. That silently dropped BOTH halves the model computes there:
        // the `.wide`-confidence caveat ("Still refining your rhythm - treat this as a soft nudge.")
        // and the standing `TwoProcessModel.disclaimerTail` ("On-device estimate - sleep-timing
        // awareness, not medical advice."). A clock time is the most assertive thing in this row, and
        // it was hedged only by the single word "Learning" in the cells — which reads as a data quality
        // label, not as "do not treat this as medical guidance".
        //
        // WHY THIS SHAPE: one caption rather than a second paragraph — the tail simply continues the
        // sentence. Both fields are non-optional stored Strings on the struct, so unlike an `if let`
        // branch this render path has no way to drop the caveat again. `rationale` always ends in a full
        // stop and `note` always begins capitalised (TwoProcessModel.swift), so the single space reads
        // clean.
        Text("\(rec.rationale) \(rec.note)")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, WM.Space.xs)
    }

    /// "Aim for 10:45 PM · window 10:15 PM – 11:15 PM".
    private static func aimLine(_ rec: TwoProcessModel.BedtimeRecommendation) -> String {
        let window = "\(clockLabel(rec.earliestHour)) \u{2013} \(clockLabel(rec.latestHour))"
        return "Aim for \(clockLabel(rec.targetBedtimeHour)) \u{00B7} window \(window)"
    }

    /// "Est. onset 20 min · sleep pressure 62% · read Solid" — the model's three cells as one caption.
    private static func cellsLine(_ rec: TwoProcessModel.BedtimeRecommendation) -> String {
        [
            "Est. onset \(Int(rec.predictedOnsetMinutes.rounded())) min",
            "sleep pressure \(Int((rec.homeostaticPressure * 100).rounded()))%",
            "read \(confidenceWord(rec.confidence))",
        ].joined(separator: " \u{00B7} ")
    }

    // MARK: - Cold start

    private var coldStart: some View {
        Text(loaded
             ? "Your rhythm is still coming into focus. Keep wearing whoopmaxx overnight and through the day, and a bedtime will appear here."
             : "Reading your body clock\u{2026}")
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
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
            .padding(WM.Space.gutter)
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
