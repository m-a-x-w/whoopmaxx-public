import SwiftUI
import Combine

/// The live bar stream: a rolling ring buffer of the last ~60 live bpm
/// samples, one thin bar per sample in the bar motif, each bar colored by heart-rate zone
/// (Effort-domain 5-step ramp, `EffortZoneRamp`). Newest sample rides the right edge; history slides left.
/// A zone caption below names the current zone; with no live signal it says so plainly.
///
/// The buffer is the SHARED `LiveState.hrStream` ring, sampled from `live.heartRate` on a fixed 1 Hz
/// clock owned by LiveScreen — a true bar-per-SECOND stream. It is shared (not per-view @State) so the
/// history survives the standalone↔in-workout view swap on workout Start/Stop; two view identities each
/// owning a separate @State ring would reset to empty on the swap. It can't ride `$heartRate` publishes:
/// both upstream writers are change-guarded, so a steady resting HR would publish nothing and freeze the
/// strip. It shows the RAW per-packet rate, not the smoothed `root.bpm` headline — the stream is where the
/// instrument shows its needle moving.
struct LiveHRStream: View {
    @EnvironmentObject private var live: LiveState

    /// Effective HRmax for zone banding (pass `root.profile.hrMax`).
    let hrMax: Int
    /// How many trailing samples to draw — one slot per bar, filling from the right.
    var capacity: Int = 60
    var height: CGFloat = 120

    var body: some View {
        // The shared ring's trailing window (the 1 Hz sampler that fills it lives in LiveScreen).
        let samples = Array(live.hrStream.suffix(capacity))
        return VStack(alignment: .leading, spacing: WM.Space.s) {
            Canvas { context, size in
                let slot = size.width / CGFloat(max(capacity, 1))
                let gap = min(1.5, slot * 0.35)
                let barWidth = max(slot - gap, 1)
                // Normalize 40…max(HRmax, hottest sample) so a zone-5 burst can't clip.
                let lo = 40.0
                let hi = Swift.max(Double(hrMax), Double(samples.max() ?? 0))
                let span = Swift.max(hi - lo, 1)
                for (i, bpm) in samples.enumerated() {
                    // Right-aligned: the newest sample occupies the last slot.
                    let slotIndex = capacity - samples.count + i
                    let frac = min(Swift.max((Double(bpm) - lo) / span, 0), 1)
                    let barHeight = Swift.max(CGFloat(frac) * size.height, 2)
                    let rect = CGRect(x: CGFloat(slotIndex) * slot, y: size.height - barHeight,
                                      width: barWidth, height: barHeight)
                    let zone = EffortZoneRamp.index(bpm: bpm, hrMax: hrMax)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(EffortZoneRamp.color(zone)))
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                WMRule()
            }
            .wmAnimation(value: samples)
            .accessibilityHidden(true)

            caption(samples: samples)
        }
        .accessibilityElement(children: .combine)
    }

    /// Current-zone caption; honest about a dead or absent link.
    @ViewBuilder
    private func caption(samples: [Int]) -> some View {
        if live.connected, let bpm = samples.last {
            let zone = EffortZoneRamp.index(bpm: bpm, hrMax: hrMax)
            Text("\(EffortZoneRamp.name(zone)) · \(EffortZoneRamp.rangeText(zone, hrMax: hrMax))")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        } else {
            Text("No live signal.")
                .font(WMType.caption)
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }
}

#Preview("LiveHRStream — light") {
    LiveHRStreamSpecimen().preferredColorScheme(.light)
}

#Preview("LiveHRStream — dark") {
    LiveHRStreamSpecimen().preferredColorScheme(.dark)
}

private struct LiveHRStreamSpecimen: View {
    /// A deterministic warm-up → interval-surge → cooldown shape spanning all five zones.
    private static let demo: [Int] = (0..<60).map { i in
        let base = 95.0 + 70.0 * sin(Double(i) / 9.5) * sin(Double(i) / 3.7)
        return Int(min(max(base + Double((i * 13) % 7), 62), 182))
    }

    /// Connected + seeded so the specimen shows the zone caption + bars (a fresh LiveState reads
    /// disconnected with an empty stream; the live 1 Hz sampler only runs inside LiveScreen).
    private let connectedLive: LiveState = {
        let s = LiveState()
        s.connected = true
        s.heartRate = 148
        s.seedHRStream(Self.demo)
        return s
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.section) {
            LiveHRStream(hrMax: 187)
        }
        .environmentObject(connectedLive)
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
