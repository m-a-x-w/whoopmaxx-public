import SwiftUI

/// The live bar stream (037): the last 60 live bpm samples as 60 rounded bars in Effort at 22%,
/// the newest bar (right edge) at full strength, history sliding left, with a "1 minute ago … now"
/// axis under it. The zone reading lives on the hero's zone line above, so the bars carry the SHAPE of
/// the last minute and nothing else.
///
/// The buffer is the SHARED `LiveState.hrStream` ring, sampled from `live.heartRate` on a fixed 1 Hz
/// clock owned by LiveScreen — a true bar-per-SECOND stream. It is shared (not per-view @State) so the
/// history survives the standalone↔in-workout view swap on workout Start/Stop; two view identities each
/// owning a separate @State ring would reset to empty on the swap. It can't ride `$heartRate` publishes:
/// both upstream writers are change-guarded, so a steady resting HR would publish nothing and freeze the
/// strip. It shows the RAW per-packet rate, not the smoothed `root.bpm` headline — the stream is where the
/// instrument shows its needle moving.
///
/// Scaled to its own window, not to 40…HRmax: at this height a zone-anchored scale draws a resting
/// minute as a flat 6pt stubble. The window's highest sample tops the strip, its lowest sits half-way
/// up, and the scale never spans less than `minSpan` bpm, so a steady heart reads as a steady strip
/// rather than as a 1-bpm wobble blown up to full height.
struct LiveHRStream: View {
    @EnvironmentObject private var live: LiveState

    /// How many trailing samples to draw — one slot per bar, filling from the right.
    var capacity: Int = LiveState.hrStreamCapacity
    var height: CGFloat = 48

    /// The narrowest bpm span the strip will scale to.
    private static let minSpan = 20.0
    private static let wash = 0.22

    var body: some View {
        // The shared ring's trailing window (the 1 Hz sampler that fills it lives in LiveScreen), and its
        // extremes, taken once per pass for the scale AND the spoken range.
        let samples = Array(live.hrStream.suffix(capacity))
        let lo = samples.min()
        let hi = samples.max()
        let spoken: String
        if let lo, let hi {
            spoken = lo == hi ? "\(hi) beats per minute" : "\(lo) to \(hi) beats per minute"
        } else {
            spoken = "No live signal"
        }
        return VStack(alignment: .leading, spacing: WM.Space.s) {
            Canvas { context, size in
                guard let lo, let hi else { return }
                let slot = size.width / CGFloat(max(capacity, 1))
                let gap = min(2.5, slot * 0.45)
                let barWidth = max(slot - gap, 1)
                let radius = min(2, barWidth / 2)
                let span = max(Double(hi - lo), Self.minSpan)
                let top = Double(hi + lo) / 2 + span / 2
                let bottom = top - span * 2
                let color = WM.Domain.effort.color
                for (i, bpm) in samples.enumerated() {
                    // Right-aligned: the newest sample occupies the last slot.
                    let slotIndex = capacity - samples.count + i
                    let frac = min(max((Double(bpm) - bottom) / (top - bottom), 0), 1)
                    let barHeight = max(CGFloat(frac) * size.height, 2)
                    let rect = CGRect(x: CGFloat(slotIndex) * slot, y: size.height - barHeight,
                                      width: barWidth, height: barHeight)
                    let newest = i == samples.count - 1
                    context.fill(Path(roundedRect: rect, cornerRadius: radius),
                                 with: .color(newest ? color : color.opacity(Self.wash)))
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)

            HStack {
                Text("1 minute ago")
                Spacer(minLength: WM.Space.s)
                Text("now")
            }
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate, last minute")
        .accessibilityValue(spoken)
    }
}

#Preview("LiveHRStream — light") {
    LiveHRStreamSpecimen().preferredColorScheme(.light)
}

#Preview("LiveHRStream — dark") {
    LiveHRStreamSpecimen().preferredColorScheme(.dark)
}

private struct LiveHRStreamSpecimen: View {
    /// A deterministic warm-up → interval-surge → cooldown shape.
    private static let demo: [Int] = (0..<60).map { i in
        let base = 95.0 + 70.0 * sin(Double(i) / 9.5) * sin(Double(i) / 3.7)
        return Int(min(max(base + Double((i * 13) % 7), 62), 182))
    }

    /// Seeded so the specimen shows bars (a fresh LiveState has an empty stream; the live 1 Hz sampler
    /// only runs inside LiveScreen).
    private let seededLive: LiveState = {
        let s = LiveState()
        s.connected = true
        s.heartRate = 148
        s.seedHRStream(Self.demo)
        return s
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.section) {
            LiveHRStream()
                .environmentObject(seededLive)
            LiveHRStream()
                .environmentObject(LiveState())   // empty ring: the bare axis
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
