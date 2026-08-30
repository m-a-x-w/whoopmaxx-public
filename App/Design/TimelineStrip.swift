import SwiftUI

/// The day as a quiet rail (037, "Your day"): a 6pt `track` capsule spanning midnight→midnight.
/// Inside it, HR intensity darkens the rail where the day was active (ink ramp over equal buckets),
/// sleep sits in rest at 55%, workouts in effort; a 10pt ink dot marks "now". Optional entry dots
/// (logged intake, 8pt) ride just above the rail. Every layer is optional — screens pass what they have.
struct TimelineStrip: View {
    let dayStart: Date
    let dayEnd: Date
    /// Sleep spans (rest color inside the rail).
    var sleep: [(start: Date, end: Date)] = []
    /// Normalized 0–1 HR intensity per equal-width bucket across the day (e.g. 96 × 15 min).
    var hrIntensity: [Double] = []
    /// Workout spans (effort color inside the rail).
    var workouts: [(start: Date, end: Date)] = []
    /// Stress moments (thin effort marks inside the rail).
    var stressTicks: [Date] = []
    /// Logged moments drawn as dots above the rail, each in its own data color.
    var entries: [(date: Date, color: Color)] = []
    /// The "now" marker; nil for a past day.
    var now: Date? = nil

    init(dayStart: Date, dayEnd: Date,
         sleep: [(start: Date, end: Date)] = [],
         hrIntensity: [Double] = [],
         workouts: [(start: Date, end: Date)] = [],
         stressTicks: [Date] = [],
         entries: [(date: Date, color: Color)] = [],
         now: Date? = nil) {
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.sleep = sleep
        self.hrIntensity = hrIntensity
        self.workouts = workouts
        self.stressTicks = stressTicks
        self.entries = entries
        self.now = now
    }

    private static let rail: CGFloat = 6
    private static let dot: CGFloat = 10
    private static let entryDot: CGFloat = 8
    private static let entryBand: CGFloat = 12

    private var height: CGFloat { (entries.isEmpty ? 0 : Self.entryBand) + Self.dot }

    var body: some View {
        Canvas { context, size in
            let total = dayEnd.timeIntervalSince(dayStart)
            guard total > 0 else { return }

            func x(_ date: Date) -> CGFloat {
                CGFloat(min(max(date.timeIntervalSince(dayStart) / total, 0), 1)) * size.width
            }

            let railMid = (entries.isEmpty ? 0 : Self.entryBand) + Self.dot / 2
            let railRect = CGRect(x: 0, y: railMid - Self.rail / 2, width: size.width, height: Self.rail)
            let railPath = Path(roundedRect: railRect, cornerRadius: Self.rail / 2)
            context.fill(railPath, with: .color(WM.Ground.track))

            context.drawLayer { rail in
                rail.clip(to: railPath)

                // 1. HR intensity: the rail darkens where the day was active.
                if !hrIntensity.isEmpty {
                    let bucketW = size.width / CGFloat(hrIntensity.count)
                    for (i, v) in hrIntensity.enumerated() where v > 0 {
                        let alpha = 0.05 + min(max(v, 0), 1) * 0.30
                        let rect = CGRect(x: CGFloat(i) * bucketW, y: railRect.minY,
                                          width: bucketW + 0.5, height: Self.rail)
                        rail.fill(Path(rect), with: .color(WM.Ground.ink.opacity(alpha)))
                    }
                }

                // 2. Sleep: rest color.
                for span in sleep where span.end > span.start {
                    let rect = CGRect(x: x(span.start), y: railRect.minY,
                                      width: max(x(span.end) - x(span.start), Self.rail), height: Self.rail)
                    rail.fill(Path(roundedRect: rect, cornerRadius: Self.rail / 2),
                              with: .color(WM.Domain.rest.color.opacity(0.55)))
                }

                // 3. Workouts: effort color.
                for span in workouts where span.end > span.start {
                    let rect = CGRect(x: x(span.start), y: railRect.minY,
                                      width: max(x(span.end) - x(span.start), Self.rail), height: Self.rail)
                    rail.fill(Path(roundedRect: rect, cornerRadius: Self.rail / 2),
                              with: .color(WM.Domain.effort.color))
                }

                // 4. Stress ticks: thin effort marks.
                for tick in stressTicks {
                    let rect = CGRect(x: x(tick) - 1, y: railRect.minY, width: 2, height: Self.rail)
                    rail.fill(Path(rect), with: .color(WM.Domain.effort.color.opacity(0.8)))
                }
            }

            // Entry dots above the rail.
            for entry in entries {
                let cx = min(max(x(entry.date), Self.entryDot / 2), size.width - Self.entryDot / 2)
                let rect = CGRect(x: cx - Self.entryDot / 2, y: 0, width: Self.entryDot, height: Self.entryDot)
                context.fill(Path(ellipseIn: rect), with: .color(entry.color))
            }

            // Now: an ink dot with a ground ring, on the rail.
            if let now, now >= dayStart, now <= dayEnd {
                let cx = min(max(x(now), Self.dot / 2), size.width - Self.dot / 2)
                let ring = CGRect(x: cx - Self.dot / 2 - 2, y: railMid - Self.dot / 2 - 2,
                                  width: Self.dot + 4, height: Self.dot + 4)
                context.fill(Path(ellipseIn: ring), with: .color(WM.Ground.ground))
                let dot = CGRect(x: cx - Self.dot / 2, y: railMid - Self.dot / 2, width: Self.dot, height: Self.dot)
                context.fill(Path(ellipseIn: dot), with: .color(WM.Ground.ink))
            }
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
