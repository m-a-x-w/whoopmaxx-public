import SwiftUI

/// The five classic %-of-max heart-rate zones for the Live tab:
/// Z1 < 60%, Z2 60–70%, Z3 70–80%, Z4 80–90%, Z5 ≥ 90% of HRmax.
///
/// HRmax comes from `ProfileStore.hrMax` (the user's explicit override when set, else the Tanaka
/// estimate off their age) — the SAME resolution the score engine uses, so the live zones can never
/// disagree with Effort scoring.
///
/// Also the geometry of the Live hero's zone line (`LiveZoneLine`): five equal segments across
/// 50…100% of HRmax, cut at the same `bounds` `index` bands by, so the highlighted segment and the dot
/// can never disagree with the zone this type names.
///
/// Named `EffortZoneRamp`, not `HRZones`, because the latter shadowed the vendored
/// `StrapAnalytics.HRZones` module-wide (and that one can't be qualified either — `StrapAnalytics`
/// is itself a top-level enum in its package).
enum EffortZoneRamp {

    /// Zone lower bounds as fractions of HRmax (Z2…Z5); everything below 60% is Z1.
    static let bounds: [Double] = [0.60, 0.70, 0.80, 0.90]

    /// Zone index 0…4 (Z1…Z5) for an instantaneous bpm against HRmax.
    static func index(bpm: Int, hrMax: Int) -> Int {
        let pct = Double(bpm) / Double(max(hrMax, 1))
        var zone = 0
        for bound in bounds where pct >= bound { zone += 1 }
        return zone
    }

    /// "Zone 3" — the zone line's caption under each segment.
    static func name(_ zone: Int) -> String { "Zone \(clamped(zone) + 1)" }

    /// The zone's %-of-max span, e.g. "70–80% of max 187" — the Live hero's spoken zone reading.
    /// Z1 reads "under 60% …", Z5 "90–100% …".
    static func rangeText(_ zone: Int, hrMax: Int) -> String {
        let z = clamped(zone)
        let hi = z == 4 ? 100 : Int((bounds[z] * 100).rounded())
        guard z > 0 else { return "under \(hi)% of max \(hrMax)" }
        let lo = Int((bounds[z - 1] * 100).rounded())
        return "\(lo)–\(hi)% of max \(hrMax)"
    }

    // MARK: - Zone line

    /// Where the zone line starts, as a fraction of HRmax. 50% is Z1's lower edge in the engine's own
    /// zone model (`ZoneModel`), and it gives the five zones equal width. A reading under 50% pins to
    /// the line's left end — still inside Z1, which here folds in everything under 60%.
    static let lineFloor: Double = 0.50

    /// The six zone edges on the line (the floor, the four bounds, 100%), as fractions of HRmax.
    private static let lineEdges: [Double] = [lineFloor] + bounds + [1.0]

    /// `bpm`'s position on the zone line, 0…1 of its width.
    static func lineFraction(bpm: Int, hrMax: Int) -> Double {
        lineFraction(ofMax: Double(bpm) / Double(max(hrMax, 1)))
    }

    /// Zone `zone`'s span on the zone line, as 0…1 fractions of its width.
    static func lineSpan(_ zone: Int) -> ClosedRange<Double> {
        let z = clamped(zone)
        return lineFraction(ofMax: lineEdges[z])...lineFraction(ofMax: lineEdges[z + 1])
    }

    private static func lineFraction(ofMax pct: Double) -> Double {
        min(max((pct - lineFloor) / (1 - lineFloor), 0), 1)
    }

    private static func clamped(_ zone: Int) -> Int { min(max(zone, 0), 4) }
}

#Preview("Effort zones — light") {
    EffortZoneRampSpecimen().preferredColorScheme(.light)
}

#Preview("Effort zones — dark") {
    EffortZoneRampSpecimen().preferredColorScheme(.dark)
}

/// Each zone's %-of-max span next to the stretch of the zone line it occupies.
private struct EffortZoneRampSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            ForEach(0..<5, id: \.self) { z in
                let span = EffortZoneRamp.lineSpan(z)
                Text("\(EffortZoneRamp.name(z)) · \(EffortZoneRamp.rangeText(z, hrMax: 187)) · line "
                     + "\(Int((span.lowerBound * 100).rounded()))–\(Int((span.upperBound * 100).rounded()))%")
                    .font(WMType.caption)
                    .foregroundStyle(WM.Ground.inkTertiary)
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
