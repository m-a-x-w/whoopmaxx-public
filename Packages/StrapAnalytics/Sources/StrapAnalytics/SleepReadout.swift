import Foundation
import StrapProtocol

/// What the detector can actually see tonight.
///
/// Both figures are taken from the same streams detection reads, so a readout panel reports the
/// input quality rather than a second opinion about it.
public enum SleepReadout {

    /// HR samples per minute over the stream's own span, 0 when there is nothing to measure.
    ///
    /// Density over the SPAN, not over the window a caller had in mind: a stream that stopped at
    /// 2 a.m. was dense while it ran, and reporting it as thin would blame the sensor for a
    /// disconnect.
    public static func hrDensityPerMinute(hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return 0 }
        let sorted = hr.sorted { $0.ts < $1.ts }
        let spanS = Double(sorted[sorted.count - 1].ts - sorted[0].ts)
        guard spanS > 0 else { return 0 }
        return Double(sorted.count) / (spanS / 60.0)
    }

    /// How much of the heart-rate window the gravity stream spans, 0…1.
    ///
    /// The same ratio the sparse-gravity path keys on, so a value under
    /// `SleepDetection.sparseGravitySpanFrac` says which staging path ran — not that the night was
    /// bad.
    public static func gravityCoverageFraction(gravity: [GravitySample], hr: [HRSample]) -> Double {
        guard gravity.count >= 2, hr.count >= 2 else { return 0 }
        let g = gravity.sorted { $0.ts < $1.ts }
        let h = hr.sorted { $0.ts < $1.ts }
        let hrSpan = Double(h[h.count - 1].ts - h[0].ts)
        guard hrSpan > 0 else { return 0 }
        let gravSpan = Double(g[g.count - 1].ts - g[0].ts)
        return max(0, min(1, gravSpan / hrSpan))
    }
}
