import SwiftUI

/// The Breathe visual — the anti-orb. A single tall vertical track (mirroring `ScoreColumn.track`:
/// hairline outline over a rest `wash`) whose rest-indigo fill height = `expansion` (0…1); the fill rises
/// bottom→top on the inhale, holds full, drains on the exhale. A quiet live-bpm numeral rides the fill top
/// (or "—" off-strap), and the phase word sits below.
///
/// The component is DUMB: it renders whatever `expansion` it's handed. The caller animates the fill by
/// wrapping this in `.animation(_:value: expansion)` with the current phase duration (nil under Reduce
/// Motion, where the caller parks `expansion` at a steady mid-fill and lets the phase word carry the breath).
struct BreathColumn: View {
    /// 0…1 fill fraction.
    let expansion: CGFloat
    /// "Breathe in" / "Hold" / "Breathe out".
    let phaseWord: String
    /// Live heart rate riding the fill top; nil shows a quiet "—".
    var bpm: Int? = nil

    var body: some View {
        VStack(spacing: WM.Space.l) {
            GeometryReader { geo in track(in: geo.size) }
            Text(phaseWord)
                .font(WMType.title)
                .foregroundStyle(WM.Ground.ink)
                // Respect Reduce Motion — `wmAnimation` resolves to nil under it, so the word swaps
                // instantly (no cross-dissolve) and the phase word alone carries the breath.
                .wmAnimation(.easeInOut(duration: 0.25), value: phaseWord)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Breathing pacer")
        .accessibilityValue(phaseWord)
    }

    private func track(in size: CGSize) -> some View {
        let h = size.height
        let frac = min(max(expansion, 0), 1)
        let fillH = frac * h
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return ZStack(alignment: .bottom) {
            // Track: a whisper of rest behind a hairline outline — the paper stays paper, the fill carries
            // the breath (mirrors ScoreColumn.track).
            shape.fill(WM.Domain.rest.wash)
            shape.strokeBorder(WM.Ground.rule, lineWidth: WM.hairline)

            // The rest-indigo fill.
            shape
                .fill(WM.Domain.rest.color)
                .frame(height: max(fillH, 2))

            // Live bpm riding the fill top (quiet "—" off-strap, like the Live headline's no-signal state).
            bpmReadout
                .padding(.bottom, min(fillH + WM.Space.s, h - 44))
        }
        .clipped()
    }

    @ViewBuilder
    private var bpmReadout: some View {
        if let bpm {
            VStack(spacing: 0) {
                Text(String(bpm))
                    .font(WMType.display(26))
                    .foregroundStyle(WM.Ground.ink)
                Text("bpm")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        } else {
            Text("—")
                .font(WMType.numeral(20))
                .foregroundStyle(WM.Ground.inkTertiary)
        }
    }
}

#Preview("BreathColumn — light") {
    BreathColumnSpecimen().preferredColorScheme(.light)
}

#Preview("BreathColumn — dark") {
    BreathColumnSpecimen().preferredColorScheme(.dark)
}

private struct BreathColumnSpecimen: View {
    var body: some View {
        HStack(spacing: WM.Space.sectionLoose) {
            column(0.85, "Breathe in", bpm: 62)      // mid-inhale
            column(1.0, "Hold", bpm: nil)            // full
            column(0.2, "Breathe out", bpm: nil)     // draining
            column(0.5, "Breathe in", bpm: nil)      // Reduce-Motion steady mid-fill
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WM.Ground.ground)
    }

    private func column(_ e: CGFloat, _ word: String, bpm: Int?) -> some View {
        BreathColumn(expansion: e, phaseWord: word, bpm: bpm)
            .frame(width: 72, height: 320)
    }
}
