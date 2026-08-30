import SwiftUI

/// Classic horizontal step-band hypnogram. Lanes top→bottom: wake, REM, light, deep.
/// Rest-indigo ramp per 001: deep = full rest color, REM = 75%, light = 45%, wake = ink @ 15%.
/// Start/end time captions below.
///
/// Stage convention: 0 = awake, 1 = REM, 2 = light, 3 = deep. NOTE the store's `stagesJSON`
/// (DemoSeed / DayEngine.encodeStages) carries STRING stages
/// (`[{"start":epoch,"end":epoch,"stage":"light|deep|rem|wake"}]`) — decode them via
/// `SleepStage.decode(_:)` and project with `SleepStage.laneCode`. This view is a PURE renderer:
/// it owns no token table.
struct StepHypnogram: View {
    let segments: [(start: Date, end: Date, stage: Int)]
    var height: CGFloat = 96

    init(segments: [(start: Date, end: Date, stage: Int)], height: CGFloat = 96) {
        self.segments = segments
        self.height = height
    }

    private var span: (start: Date, end: Date)? {
        guard let s = segments.map(\.start).min(),
              let e = segments.map(\.end).max(), e > s else { return nil }
        return (s, e)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Canvas { context, size in
                guard let span else { return }
                let total = span.end.timeIntervalSince(span.start)
                let laneH = size.height / 4
                let blockH = laneH - 2
                for seg in segments where seg.end > seg.start {
                    guard let lane = Self.lane(for: seg.stage) else { continue }
                    let x0 = seg.start.timeIntervalSince(span.start) / total * size.width
                    let x1 = seg.end.timeIntervalSince(span.start) / total * size.width
                    let rect = CGRect(x: x0, y: CGFloat(lane) * laneH + 1,
                                      width: max(x1 - x0, 1), height: blockH)
                    context.fill(Path(rect), with: .color(Self.stageColor(seg.stage)))
                }
            }
            .frame(height: height)

            if let span {
                HStack {
                    Text(span.start, format: .dateTime.hour().minute())
                    Spacer()
                    Text(span.end, format: .dateTime.hour().minute())
                }
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages")
    }

    /// Lane row (0 = top) for a stage code; nil for unknown stages.
    private static func lane(for stage: Int) -> Int? {
        (0...3).contains(stage) ? stage : nil   // 0 wake (top), 1 rem, 2 light, 3 deep (bottom)
    }

    /// The rest-indigo opacity ramp.
    static func stageColor(_ stage: Int) -> Color {
        switch stage {
        case 3: return WM.Domain.rest.color                // deep — full
        case 1: return WM.Domain.rest.color.opacity(0.75)  // rem
        case 2: return WM.Domain.rest.color.opacity(0.45)  // light
        default: return WM.Ground.ink.opacity(0.15)        // wake
        }
    }
}

#Preview("StepHypnogram — light") {
    HypnogramSpecimen().preferredColorScheme(.light)
}

#Preview("StepHypnogram — dark") {
    HypnogramSpecimen().preferredColorScheme(.dark)
}

private struct HypnogramSpecimen: View {
    private var demo: [(start: Date, end: Date, stage: Int)] {
        let onset = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600 * 0.75) // 23:15
        // Mirrors DemoSeed's cycle shape: light→deep→light→rem→deep→light→rem→wake.
        let plan: [(stage: Int, minutes: Double)] = [
            (2, 48), (3, 52), (0, 4), (2, 40), (1, 34), (3, 30), (2, 44), (1, 26), (0, 9)
        ]
        var t = onset
        return plan.map { p in
            let s = t
            t = t.addingTimeInterval(p.minutes * 60)
            return (start: s, end: t, stage: p.stage)
        }
    }

    var body: some View {
        StepHypnogram(segments: demo)
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WM.Ground.ground)
    }
}
