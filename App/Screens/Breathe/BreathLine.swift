import SwiftUI

/// The Breathe pacer (037): the phase word as a 44pt numeral over a horizontal breath line — a
/// 6pt `track` rail, a Rest-iris fill out to `expansion`, and an 18pt Rest dot riding the fill's end. The
/// fill runs out on the inhale, holds full, and draws back on the exhale. It replaces the vertical
/// breath column: the app's one instrument is a line, so the pacer is one too.
///
/// The component is DUMB: it renders whatever `expansion` it's handed. The caller animates the fill by
/// wrapping this in `.animation(_:value:)` with the current phase duration (nil under Reduce Motion,
/// where the caller parks `expansion` at a steady mid-fill and lets the phase word carry the breath).
struct BreathLine: View {
    /// 0…1 fill fraction.
    let expansion: CGFloat
    /// "Breathe in" / "Hold" / "Breathe out".
    let phaseWord: String

    private static let rail: CGFloat = 6
    private static let dot: CGFloat = 18
    /// The ground ring around the dot, so it reads as sitting ON the rail rather than blotting it.
    private static let ring: CGFloat = 4

    var body: some View {
        VStack(spacing: 26) {
            Text(phaseWord)
                .font(WMType.numeral(44))
                .foregroundStyle(WM.Ground.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Respect Reduce Motion — `wmAnimation` resolves to nil under it, so the word swaps
                // instantly (no cross-dissolve) and the phase word alone carries the breath.
                .wmAnimation(.easeInOut(duration: 0.25), value: phaseWord)
            GeometryReader { geo in line(width: geo.size.width) }
                .frame(height: Self.dot + Self.ring * 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Breathing pacer")
        .accessibilityValue(phaseWord)
    }

    private func line(width w: CGFloat) -> some View {
        let x = min(max(expansion, 0), 1) * w
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(WM.Ground.track)
                .frame(width: w, height: Self.rail)
            Capsule()
                .fill(WM.Domain.rest.color)
                .frame(width: max(x, Self.rail), height: Self.rail)
            Circle()
                .fill(WM.Domain.rest.color)
                .frame(width: Self.dot, height: Self.dot)
                .background(Circle().fill(WM.Ground.ground)
                    .frame(width: Self.dot + Self.ring * 2, height: Self.dot + Self.ring * 2))
                .offset(x: min(max(x - Self.dot / 2, 0), w - Self.dot))
        }
        .frame(width: w, height: Self.dot + Self.ring * 2, alignment: .leading)
    }
}

#Preview("BreathLine — light") {
    BreathLineSpecimen().preferredColorScheme(.light)
}

#Preview("BreathLine — dark") {
    BreathLineSpecimen().preferredColorScheme(.dark)
}

private struct BreathLineSpecimen: View {
    var body: some View {
        VStack(spacing: WM.Space.sectionLoose) {
            BreathLine(expansion: 0.62, phaseWord: "Breathe in")    // mid-inhale
            BreathLine(expansion: 1.0, phaseWord: "Hold")           // full
            BreathLine(expansion: 0.2, phaseWord: "Breathe out")    // drawing back
            BreathLine(expansion: 0.5, phaseWord: "Breathe in")     // Reduce-Motion steady mid-fill
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WM.Ground.ground)
    }
}
