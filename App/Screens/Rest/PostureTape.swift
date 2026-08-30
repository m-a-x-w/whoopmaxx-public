import SwiftUI

/// The wrist-orientation lane — one horizontal band per stretch of the night in a 12 pt rounded lane,
/// the same epoch grid as the hypnogram (both walk `SleepStaging.epochS`).
///
/// A neutral ink ramp (the Line language, 037): the four most-occupied orientations step down in
/// strength, so the lane reads as "these stretches differed" without a hue implying a kind of sleep. A
/// slot the wrist was moving through borrows the hypnogram's own awake mark
/// (`StepHypnogram.stageColor(0)`), and a slot with no gravity is left UNPAINTED — an honest gap for
/// "not measured" rather than a band that claims an orientation nobody recorded. No ring, no gauge, no
/// dial (011 decision 8).
///
/// A pure renderer: it owns no thresholds, and it never names an orientation — see `PostureEngine` for
/// why a wrist is not a torso.
struct PostureTape: View {
    /// One slot per `PostureEngine.epochS`, in time order.
    let epochs: [PostureEngine.Epoch]
    /// Window bounds, for the end labels.
    let start: Int
    let end: Int
    var height: CGFloat = 12

    /// A run of identical slots.
    struct Band: Equatable {
        let from: Int
        /// Inclusive.
        let through: Int
        let epoch: PostureEngine.Epoch
    }

    /// Merged once per render rather than per fill — see `bands`.
    private var merged: [Band] { Self.bands(epochs) }
    private var slotCount: CGFloat { CGFloat(max(epochs.count, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.xs) {
            Canvas { context, size in
                let merged = self.merged, slotCount = self.slotCount
                for band in merged {
                    guard let color = Self.color(band.epoch) else { continue }
                    let x0 = CGFloat(band.from) / slotCount * size.width
                    let x1 = CGFloat(band.through + 1) / slotCount * size.width
                    let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
                    context.fill(Path(rect), with: .color(color))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            HStack {
                Text(WMFormat.timeOfDay(start))
                Spacer()
                Text(WMFormat.timeOfDay(end))
            }
            .font(WMType.caption)
            .foregroundStyle(WM.Ground.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wrist orientation through the night")
    }

    /// Merge consecutive identical slots. An eight-hour night is ~960 slots but only a few dozen runs,
    /// so this is the difference between ~40 fills per redraw and ~960 sub-pixel ones.
    static func bands(_ epochs: [PostureEngine.Epoch]) -> [Band] {
        var out: [Band] = []
        var i = 0
        while i < epochs.count {
            var j = i
            while j + 1 < epochs.count && epochs[j + 1] == epochs[i] { j += 1 }
            out.append(Band(from: i, through: j, epoch: epochs[i]))
            i = j + 1
        }
        return out
    }

    /// The lane's marks: an ink ramp for the orientations (by occupancy rank), the hypnogram's awake mark
    /// for a moving slot, a faint ink wash for a held but non-recurring slot, and NO fill at all for a
    /// slot with no gravity (the paper shows through as the gap).
    static func color(_ epoch: PostureEngine.Epoch) -> Color? {
        switch epoch {
        case .noData:                 return nil
        case .moving:                 return StepHypnogram.stageColor(0)
        case .other:                  return WM.Ground.ink.opacity(0.06)
        case .orientation(let rank):  return WM.Ground.ink.opacity(shade(rank))
        }
    }

    /// Ink strength for orientation rank `rank`. Ranks past the fourth — a night that genuinely returned
    /// to five or more orientations — all sit at the floor rather than fading to invisible.
    static func shade(_ rank: Int) -> Double {
        let ramp: [Double] = [0.75, 0.45, 0.25, 0.14]
        return rank < ramp.count ? ramp[rank] : 0.10
    }
}

// MARK: - Previews

#Preview("PostureTape — light") {
    PostureTapeSpecimen().preferredColorScheme(.light)
}

#Preview("PostureTape — dark") {
    PostureTapeSpecimen().preferredColorScheme(.dark)
}

private struct PostureTapeSpecimen: View {
    /// A deterministic night: four recurring orientations in occupancy order (0 = most-occupied, as
    /// the engine emits them), brief moving slots at each change, one stretch the strap banked
    /// nothing, and one held-but-rare stretch.
    private var epochs: [PostureEngine.Epoch] {
        var out: [PostureEngine.Epoch] = []
        func run(_ e: PostureEngine.Epoch, _ n: Int) { out += Array(repeating: e, count: n) }
        run(.orientation(1), 120); run(.moving, 3)
        run(.orientation(2), 70);  run(.moving, 2)
        run(.orientation(1), 96);  run(.noData, 24)
        run(.orientation(0), 140); run(.moving, 4)
        run(.other, 12)
        run(.orientation(3), 64);  run(.moving, 2)
        run(.orientation(0), 110)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.l) {
            PostureTape(epochs: epochs, start: 1_753_400_000, end: 1_753_427_000)
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WM.Ground.ground)
    }
}
