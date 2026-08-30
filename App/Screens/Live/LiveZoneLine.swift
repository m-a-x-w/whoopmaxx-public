import SwiftUI

/// The Live hero's zone line (037): five equal segments for Z1…Z5 across 50…100% of HRmax, the
/// current zone drawn 6pt tall in full Effort, the others 4pt at 18%, and a 12pt Effort dot at the
/// reading's exact %-of-max position. "Zone 1…5" captions sit under the segments, the current one in
/// ink. With no reading (`bpm == nil`) every segment rests and there is no dot — the hero's subtitle
/// says why.
///
/// Geometry comes from `EffortZoneRamp` (`lineSpan` / `lineFraction`), the same bounds `index` bands
/// by, so the lit segment, the dot and every other zone reading in the app agree. Pure renderer: no
/// accessibility identity of its own — the hero above it speaks the zone.
struct LiveZoneLine: View {
    /// The headline bpm, nil when there is no live reading.
    let bpm: Int?
    let hrMax: Int

    /// Each segment gives up this fraction of the line's width on either side, which leaves the 1.6%
    /// gaps between segments.
    private static let inset: Double = 0.008
    private static let height: CGFloat = 16
    private static let dot: CGFloat = 12

    var body: some View {
        let zone = bpm.map { EffortZoneRamp.index(bpm: $0, hrMax: hrMax) }
        let position = bpm.map { EffortZoneRamp.lineFraction(bpm: $0, hrMax: hrMax) }
        let effort = WM.Domain.effort.color
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let mid = geo.size.height / 2
                ZStack(alignment: .topLeading) {
                    ForEach(0..<5, id: \.self) { i in
                        let span = EffortZoneRamp.lineSpan(i)
                        let x0 = CGFloat(span.lowerBound + Self.inset) * w
                        let x1 = CGFloat(span.upperBound - Self.inset) * w
                        let current = i == zone
                        Capsule()
                            .fill(current ? effort : WM.Domain.effort.wash)
                            .frame(width: max(x1 - x0, 0), height: current ? 6 : 4)
                            .position(x: (x0 + x1) / 2, y: mid)
                    }
                    if let position {
                        let x = min(max(CGFloat(position) * w, Self.dot / 2), w - Self.dot / 2)
                        Circle()
                            .fill(effort)
                            .frame(width: Self.dot, height: Self.dot)
                            // The ground ring lifts the dot off the segment it sits on (LineScale's idiom).
                            .background(Circle().fill(WM.Ground.ground)
                                .frame(width: Self.dot + 6, height: Self.dot + 6))
                            .position(x: x, y: mid)
                    }
                }
            }
            .frame(height: Self.height)

            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    Text(EffortZoneRamp.name(i))
                        .font(WMType.caption)
                        .foregroundStyle(i == zone ? WM.Ground.ink : WM.Ground.inkTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .wmAnimation(WMMotion.value, value: bpm)
        .accessibilityHidden(true)
    }
}

#Preview("LiveZoneLine — light") {
    LiveZoneLineSpecimen().preferredColorScheme(.light)
}

#Preview("LiveZoneLine — dark") {
    LiveZoneLineSpecimen().preferredColorScheme(.dark)
}

private struct LiveZoneLineSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.section) {
            LiveZoneLine(bpm: 116, hrMax: 190)   // 61% — Zone 2, just past its lower edge
            LiveZoneLine(bpm: 62, hrMax: 190)    // under 50% — pinned to the left end of Zone 1
            LiveZoneLine(bpm: 181, hrMax: 190)   // Zone 5
            LiveZoneLine(bpm: nil, hrMax: 190)   // no reading
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
