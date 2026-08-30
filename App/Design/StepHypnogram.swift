import SwiftUI

/// Lane hypnogram (037). Lanes top→bottom: wake, REM, light, deep. Each stage run is a rounded
/// 12pt block in its lane; thin connectors join consecutive blocks so the night reads as one path.
/// Rest-iris ramp: deep = full rest, REM = 62%, light = 34%; wake = charge at 75% (the one warm mark
/// in a night, so an awakening is findable at a glance). Start/end time captions below.
///
/// Stage convention: 0 = awake, 1 = REM, 2 = light, 3 = deep. NOTE the store's `stagesJSON`
/// (DemoSeed / DayEngine.encodeStages) carries STRING stages
/// (`[{"start":epoch,"end":epoch,"stage":"light|deep|rem|wake"}]`) — decode them via
/// `SleepStage.decode(_:)` and project with `SleepStage.laneCode`. This view is a PURE renderer:
/// it owns no token table.
struct StepHypnogram: View {
    /// The night's stage runs IN START ORDER, each with `end > start` — the shape `RestNight` hands
    /// over (its init sorts the union of every fragment; `SleepStage.decode` has already dropped
    /// zero-length spans and unknown tokens). Trusted as given rather than re-filtered and re-sorted on
    /// every draw; a stage code outside 0…3 is still skipped.
    let segments: [(start: Date, end: Date, stage: Int)]
    var height: CGFloat = 72
    /// The first start → the latest end, taken once here rather than on each draw and caption pass.
    private let span: (start: Date, end: Date)?

    init(segments: [(start: Date, end: Date, stage: Int)], height: CGFloat = 72) {
        self.segments = segments
        self.height = height
        if let start = segments.first?.start,
           let end = segments.lazy.map(\.end).max(), end > start {
            span = (start: start, end: end)
        } else {
            span = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.s) {
            Canvas { context, size in
                guard let span else { return }
                let total = span.end.timeIntervalSince(span.start)
                let laneH = size.height / 4
                let blockH = min(12, laneH - 4)

                func xFor(_ d: Date) -> CGFloat {
                    CGFloat(d.timeIntervalSince(span.start) / total) * size.width
                }
                func midY(_ lane: Int) -> CGFloat { CGFloat(lane) * laneH + laneH / 2 }

                // Connectors first, so blocks sit on top of them.
                for (prev, next) in zip(segments, segments.dropFirst()) {
                    guard let a = Self.lane(for: prev.stage), let b = Self.lane(for: next.stage), a != b else { continue }
                    var path = Path()
                    let x = xFor(next.start)
                    path.move(to: CGPoint(x: x, y: midY(a)))
                    path.addLine(to: CGPoint(x: x, y: midY(b)))
                    context.stroke(path, with: .color(WM.Domain.rest.color.opacity(0.3)), lineWidth: 1)
                }

                for seg in segments {
                    guard let lane = Self.lane(for: seg.stage) else { continue }
                    let x0 = xFor(seg.start)
                    let x1 = xFor(seg.end)
                    let rect = CGRect(x: x0, y: midY(lane) - blockH / 2, width: max(x1 - x0, 3), height: blockH)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Self.stageColor(seg.stage)))
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

    /// The stage palette. Also read by `StageColumns`, `PostureTape` / `PostureSection`, and the
    /// awake dot in `ArousalForensicsSection`.
    static func stageColor(_ stage: Int) -> Color {
        switch stage {
        case 3: return WM.Domain.rest.color                 // deep — full
        case 1: return WM.Domain.rest.color.opacity(0.62)   // rem
        case 2: return WM.Domain.rest.color.opacity(0.34)   // light
        default: return WM.Domain.charge.color.opacity(0.75) // wake
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
