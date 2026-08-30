import SwiftUI

/// The day as a horizontal strip (h≈56): sleep blocks (rest wash), HR-intensity shading (ink
/// opacity ramp over equal buckets), workout segments (effort color), stress ticks (thin signal
/// marks). Every layer is optional — screens pass what they have.
struct TimelineStrip: View {
    let dayStart: Date
    let dayEnd: Date
    /// Sleep spans (drawn as rest-wash blocks).
    var sleep: [(start: Date, end: Date)] = []
    /// Normalized 0–1 HR intensity per equal-width bucket across the day (e.g. 24 hour buckets).
    var hrIntensity: [Double] = []
    /// Workout spans (drawn in effort color).
    var workouts: [(start: Date, end: Date)] = []
    /// Stress moments (thin signal ticks).
    var stressTicks: [Date] = []
    var height: CGFloat = 56

    init(dayStart: Date, dayEnd: Date,
         sleep: [(start: Date, end: Date)] = [],
         hrIntensity: [Double] = [],
         workouts: [(start: Date, end: Date)] = [],
         stressTicks: [Date] = [],
         height: CGFloat = 56) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.sleep = sleep
        self.hrIntensity = hrIntensity
        self.workouts = workouts
        self.stressTicks = stressTicks
        self.height = height
    }

    var body: some View {
        Canvas { context, size in
            let total = dayEnd.timeIntervalSince(dayStart)
            guard total > 0 else { return }

            func x(_ date: Date) -> CGFloat {
                CGFloat(date.timeIntervalSince(dayStart) / total) * size.width
            }

            // 1. HR-intensity shading: ink opacity ramp over equal buckets.
            if !hrIntensity.isEmpty {
                let bucketW = size.width / CGFloat(hrIntensity.count)
                for (i, v) in hrIntensity.enumerated() where v > 0 {
                    let alpha = 0.04 + min(max(v, 0), 1) * 0.16
                    let rect = CGRect(x: CGFloat(i) * bucketW, y: 0,
                                      width: bucketW + 0.5, height: size.height)
                    context.fill(Path(rect), with: .color(WM.Ground.ink.opacity(alpha)))
                }
            }

            // 2. Sleep blocks: rest wash.
            for span in sleep where span.end > span.start {
                let rect = CGRect(x: x(span.start), y: 0,
                                  width: max(x(span.end) - x(span.start), 1), height: size.height)
                context.fill(Path(rect), with: .color(WM.Domain.rest.dim))
            }

            // 3. Workout segments: effort color.
            for span in workouts where span.end > span.start {
                let rect = CGRect(x: x(span.start), y: 0,
                                  width: max(x(span.end) - x(span.start), 2), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                             with: .color(WM.Domain.effort.color))
            }

            // 4. Stress ticks: thin signal marks over the lower two-thirds.
            for tick in stressTicks {
                let rect = CGRect(x: x(tick), y: size.height / 3,
                                  width: 1, height: size.height * 2 / 3)
                context.fill(Path(rect), with: .color(WM.Domain.effort.color.opacity(0.8)))
            }

            // Floor hairline so an empty strip still reads as an instrument track.
            let floor = CGRect(x: 0, y: size.height - WM.hairline,
                               width: size.width, height: WM.hairline)
            context.fill(Path(floor), with: .color(WM.Ground.rule))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview("TimelineStrip — light") {
    TimelineSpecimen().preferredColorScheme(.light)
}

#Preview("TimelineStrip — dark") {
    TimelineSpecimen().preferredColorScheme(.dark)
}

private struct TimelineSpecimen: View {
    var body: some View {
        let day0 = Calendar.current.startOfDay(for: Date())
        let day1 = day0.addingTimeInterval(86_400)
        let intensity: [Double] = (0..<24).map { h in
            switch h {
            case 0..<7: return 0.1
            case 18: return 0.9
            case 19: return 0.7
            default: return 0.25 + 0.1 * sin(Double(h))
            }
        }
        TimelineStrip(
            dayStart: day0, dayEnd: day1,
            sleep: [(day0.addingTimeInterval(-45 * 60), day0.addingTimeInterval(7 * 3600))],
            hrIntensity: intensity,
            workouts: [(day0.addingTimeInterval(18 * 3600), day0.addingTimeInterval(19 * 3600))],
            stressTicks: [day0.addingTimeInterval(10 * 3600), day0.addingTimeInterval(14.5 * 3600)]
        )
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
