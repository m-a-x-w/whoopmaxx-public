import SwiftUI

/// The five classic %-of-max heart-rate zones for the live stream:
/// Z1 < 60%, Z2 60–70%, Z3 70–80%, Z4 80–90%, Z5 ≥ 90% of HRmax.
///
/// HRmax comes from `ProfileStore.hrMax` (the user's explicit override when set, else the Tanaka
/// estimate off their age) — the SAME resolution the score engine uses, so the live zones can never
/// disagree with Effort scoring. Colors are a local 5-step opacity ramp on the Effort domain color
/// (color = data only).
///
/// Named `EffortZoneRamp`, not `HRZones`, because the latter shadowed the vendored
/// `StrapAnalytics.HRZones` module-wide (and that one can't be qualified either — `StrapAnalytics`
/// is itself a top-level enum in its package).
enum EffortZoneRamp {

    /// Zone lower bounds as fractions of HRmax (Z2…Z5); everything below 60% is Z1.
    static let bounds: [Double] = [0.60, 0.70, 0.80, 0.90]

    /// Effort-domain opacity per zone, light → full across Z1…Z5.
    static let ramp: [Double] = [0.25, 0.40, 0.55, 0.75, 1.0]

    /// Zone index 0…4 (Z1…Z5) for an instantaneous bpm against HRmax.
    static func index(bpm: Int, hrMax: Int) -> Int {
        let pct = Double(bpm) / Double(max(hrMax, 1))
        var zone = 0
        for bound in bounds where pct >= bound { zone += 1 }
        return zone
    }

    /// The zone's bar color: Effort signal red-pink stepped by the ramp.
    static func color(_ zone: Int) -> Color {
        WM.Domain.effort.color.opacity(ramp[clamped(zone)])
    }

    /// "Zone 3" — display name for the caption.
    static func name(_ zone: Int) -> String { "Zone \(clamped(zone) + 1)" }

    /// The zone's %-of-max span for the caption, e.g. "70–80% of max 187".
    /// Z1 reads "under 60% …", Z5 "90–100% …".
    static func rangeText(_ zone: Int, hrMax: Int) -> String {
        let z = clamped(zone)
        let hi = z == 4 ? 100 : Int((bounds[z] * 100).rounded())
        guard z > 0 else { return "under \(hi)% of max \(hrMax)" }
        let lo = Int((bounds[z - 1] * 100).rounded())
        return "\(lo)–\(hi)% of max \(hrMax)"
    }

    private static func clamped(_ zone: Int) -> Int { min(max(zone, 0), 4) }
}

#Preview("Effort zone ramp — light") {
    EffortZoneRampSpecimen().preferredColorScheme(.light)
}

#Preview("Effort zone ramp — dark") {
    EffortZoneRampSpecimen().preferredColorScheme(.dark)
}

private struct EffortZoneRampSpecimen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WM.Space.m) {
            ForEach(0..<5, id: \.self) { z in
                HStack(spacing: WM.Space.m) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(EffortZoneRamp.color(z))
                        .frame(width: 3, height: 24)
                    Text("\(EffortZoneRamp.name(z)) · \(EffortZoneRamp.rangeText(z, hrMax: 187))")
                        .font(WMType.caption)
                        .foregroundStyle(WM.Ground.inkTertiary)
                }
            }
        }
        .padding(WM.Space.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WM.Ground.ground)
    }
}
