import SwiftUI

/// The night's stage totals as four columns under the hypnogram (037, Rest › "Stages"): each a
/// dot in the hypnogram's own stage mark beside the stage name, the h:mm total as a numeral, and the
/// stage's share of time asleep as a caption. Awake carries no share — it is not part of time asleep.
/// A stage with no total is simply left out, and the remaining columns keep equal widths.
struct StageColumns: View {
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?
    let wakeMin: Double?

    init(deepMin: Double?, remMin: Double?, lightMin: Double?, wakeMin: Double?) {
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.wakeMin = wakeMin
    }

    /// Whether there is any total to show — the Stages section hides without it (and without a
    /// hypnogram) rather than drawing a label over nothing.
    var isEmpty: Bool { deepMin == nil && remMin == nil && lightMin == nil && wakeMin == nil }

    private var columns: [(stage: Int, name: String, minutes: Double)] {
        var c: [(stage: Int, name: String, minutes: Double)] = []
        if let deepMin { c.append((3, "Deep", deepMin)) }
        if let remMin { c.append((1, "REM", remMin)) }
        if let lightMin { c.append((2, "Light", lightMin)) }
        if let wakeMin { c.append((0, "Awake", wakeMin)) }
        return c
    }

    /// Denominator for the share captions — asleep time only.
    private var asleepTotal: Double { (deepMin ?? 0) + (remMin ?? 0) + (lightMin ?? 0) }

    var body: some View {
        HStack(alignment: .top, spacing: WM.Space.s) {
            ForEach(columns, id: \.stage) { column in
                columnView(column)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func columnView(_ column: (stage: Int, name: String, minutes: Double)) -> some View {
        let share = sleepShare(column)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(StepHypnogram.stageColor(column.stage))
                    .frame(width: 7, height: 7)
                Text(column.name)
                    .font(WMType.label)
                    .foregroundStyle(WM.Ground.inkTertiary)
                    .lineLimit(1)
            }
            Text(RestFormat.hmm(column.minutes))
                .font(WMType.numeral(22))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let share {
                Text("\(share)%")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.name), \(RestFormat.hmm(column.minutes))"
            + (share.map { ", \($0) percent of sleep" } ?? ""))
    }

    /// Whole-percent share of time asleep; nil for Awake and when nothing was asleep.
    private func sleepShare(_ column: (stage: Int, name: String, minutes: Double)) -> Int? {
        guard column.stage != 0, asleepTotal > 0 else { return nil }
        return Int((column.minutes / asleepTotal * 100).rounded())
    }
}

#Preview("StageColumns — light") {
    StageColumnsSpecimen().preferredColorScheme(.light)
}

#Preview("StageColumns — dark") {
    StageColumnsSpecimen().preferredColorScheme(.dark)
}

private struct StageColumnsSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.section) {
            StageColumns(deepMin: 95, remMin: 100, lightMin: 213, wakeMin: 8)
            // A summary-only night with no awake total: three columns, same widths.
            StageColumns(deepMin: 82, remMin: 96, lightMin: 254, wakeMin: nil)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
