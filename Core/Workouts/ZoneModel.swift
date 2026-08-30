import Foundation
import StrapProtocol
import StrapAnalytics

/// Time-in-zone MINUTES (Z1…Z5) over an HR stream — a thin Core adapter over the vendored
/// `StrapAnalytics.HRZones` so the app carries exactly ONE %HRmax zone implementation.
///
/// The engine's model (unchanged here): six band edges [0.50, 0.60, 0.70, 0.80, 0.90, 1.00] × HRmax,
/// each band `[lower, upper)` except the top one, which is inclusive so HRmax itself lands in Z5. Each
/// sample is credited the duration until the next reading, capped at the median plausible (0, 300 s)
/// inter-sample gap — floored at 1 s — so one wall-clock hole can't blow up a bucket; the tail sample
/// gets that same median gap. Below-Z1 time is tracked separately by the engine and dropped here.
///
/// NOTE: this is Z1 = the 50–60 %HRmax band. The live-stream ramp (`EffortZoneRamp`) instead folds
/// EVERYTHING under 60 % into its Z1 — a deliberate, separate difference; do not "reconcile" them.
enum ZoneModel {

    /// Per-zone minutes, five buckets, index 0 == Z1. An empty stream returns five zeros.
    ///
    /// Pass the override-aware HRmax (the `profile.hrMax` the live stream + Effort scoring use) as
    /// `hrMax`; nil falls back to Tanaka (208 − 0.7 · age). Without it a user with an HRmax override
    /// would see zone bars bucketed against a DIFFERENT max than the live zones for the same bout —
    /// over-crediting the top zones.
    nonisolated static func minutes(_ hr: [HRSample], age: Double, hrMax: Double? = nil) -> [Double] {
        let zoneSet = HRZones.zones(age: age, maxHROverride: hrMax)
        return HRZones.timeInZone(hr, zoneSet: zoneSet).seconds.map { $0 / 60.0 }
    }
}
