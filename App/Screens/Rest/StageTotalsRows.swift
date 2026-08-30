import SwiftUI

/// Stage-total rows (deep / REM / light / awake): a hypnogram-ramp color tick, the stage name, the
/// share of sleep, and the h:mm total — hairline rules between rows, no boxes. Nil stages are
/// simply omitted; awake shows no percentage (it is not part of time asleep).
struct StageTotalsRows: View {
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?
    let wakeMin: Double?

    private var rows: [(stage: Int, name: String, minutes: Double)] {
        var r: [(stage: Int, name: String, minutes: Double)] = []
        if let deepMin { r.append((3, "Deep", deepMin)) }
        if let remMin { r.append((1, "REM", remMin)) }
        if let lightMin { r.append((2, "Light", lightMin)) }
        if let wakeMin { r.append((0, "Awake", wakeMin)) }
        return r
    }

    /// Denominator for the share captions — asleep time only.
    private var asleepTotal: Double { (deepMin ?? 0) + (remMin ?? 0) + (lightMin ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.stage) { index, row in
                if index > 0 {
                    WMRule()
                }
                rowView(row)
            }
        }
    }

    private func rowView(_ row: (stage: Int, name: String, minutes: Double)) -> some View {
        HStack(spacing: WM.Space.m) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(StepHypnogram.stageColor(row.stage))
                .frame(width: 3, height: 14)
            Text(row.name)
                .font(WMType.label)
                .foregroundStyle(WM.Ground.ink)
            Spacer(minLength: WM.Space.m)
            if row.stage != 0, asleepTotal > 0 {
                Text("\(Int((row.minutes / asleepTotal * 100).rounded()))%")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
            Text(RestFormat.hmm(row.minutes))
                .font(WMType.numeral(22))
                .foregroundStyle(WM.Ground.ink)
        }
        .padding(.vertical, WM.Space.s)
        .accessibilityElement(children: .combine)
    }
}

#Preview("StageTotalsRows — light") {
    StageTotalsSpecimen().preferredColorScheme(.light)
}

#Preview("StageTotalsRows — dark") {
    StageTotalsSpecimen().preferredColorScheme(.dark)
}

private struct StageTotalsSpecimen: View {
    var body: some View {
        StageTotalsRows(deepMin: 82, remMin: 96, lightMin: 254, wakeMin: 9)
            .padding(WM.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(WM.Ground.ground)
    }
}
