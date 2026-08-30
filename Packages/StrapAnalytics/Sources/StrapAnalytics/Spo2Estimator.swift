import Foundation
import StrapProtocol

/// Nightly blood-oxygen estimate from the optical channels.
///
/// ⚠️ THE INPUT MAY NOT SUPPORT THIS MEASUREMENT. Pulse oximetry needs two independent wavelengths
/// with a real pulsatile waveform on each. Two independent findings say this stream has neither:
///
/// 1. An analysis of a 13-day export found `spo2RedRaw` and `spo2IrRaw` differ by a FIXED INTEGER
///    within a capture session while both drift together — constant across 178 of 300 hours. If
///    they are one signal offset by a constant, any ratio-of-ratios built from them algebraically
///    collapses to a function of one channel's baseline drift and measures that drift, not
///    oxygenation.
/// 2. This decoder's own pulsatility gate — requiring real mean crossings on both channels —
///    rejects roughly 77% of real windows outright and disqualifies every remaining night. A gate
///    that rejects almost everything is not a strict gate; it is evidence the waveform it is
///    looking for is not there.
///
/// Those two arrived independently and agree. The estimator is kept because it is a shipped
/// column, and the app carries a heal sweep that clears values pinned at the band floor — which is
/// exactly the signature of an estimate that is not measuring anything. Do not build a new metric
/// on this, and do not present its output as a clinical reading.
public enum Spo2Estimator {

    /// Window over which one estimate is formed.
    public static let windowS = 300
    public static let minSamplesPerWindow = 20
    /// Windows required before a night reports at all.
    public static let minWindows = 3

    /// Physiologically possible band. A value outside it is discarded rather than clamped —
    /// clamping is what produces the pinned readings the heal sweep exists to remove.
    public static let bandLo = 85.0, bandHi = 100.0

    /// Plausible ratio-of-ratios range.
    static let rLo = 0.1, rHi = 3.0

    /// Crossings of the window mean required on EACH channel before it counts as pulsatile.
    ///
    /// Non-zero AC amplitude is not enough: a stair-step sample-and-hold has a perfectly non-zero
    /// interquartile range and no pulse whatsoever.
    public static let minMeanCrossings = 5

    /// The night's estimate: the MEDIAN of its window estimates.
    ///
    /// Median rather than mean, and windows bucketed on ABSOLUTE time rather than from the first
    /// sample, so the same night yields the same answer regardless of where the recording happened
    /// to start.
    public static func nightlyPct(samples: [SpO2Sample], sessions: [(start: Int, end: Int)]) -> Double? {
        guard !sessions.isEmpty, !samples.isEmpty else { return nil }
        let inSleep = samples.filter { s in sessions.contains { s.ts >= $0.start && s.ts < $0.end } }
        var windows: [Int: [SpO2Sample]] = [:]
        for s in inSleep { windows[s.ts / windowS, default: []].append(s) }
        let pcts = windows.keys.sorted().compactMap { windowPct(windows[$0]!) }
        guard pcts.count >= minWindows else { return nil }
        return (HRVAnalyzer.median(pcts) * 10).rounded() / 10
    }

    /// One window's estimate, or nil if the window cannot support one.
    static func windowPct(_ chunk: [SpO2Sample]) -> Double? {
        guard chunk.count >= minSamplesPerWindow else { return nil }
        guard let r = ratioOfRatios(red: chunk.map { Double($0.red) },
                                    ir: chunk.map { Double($0.ir) }) else { return nil }
        // The standard empirical calibration line. Its constants are population values, not
        // fitted to this hardware.
        let raw = 110.0 - 25.0 * r
        return (bandLo...bandHi).contains(raw) ? raw : nil
    }

    /// (AC/DC red) / (AC/DC infrared), with a pulsatility precondition on both channels.
    static func ratioOfRatios(red: [Double], ir: [Double]) -> Double? {
        guard let dcRed = mean(red), dcRed > 0, let dcIr = mean(ir), dcIr > 0 else { return nil }
        let acRed = iqr(red), acIr = iqr(ir)
        guard acRed > 0, acIr > 0 else { return nil }
        guard meanCrossings(red) >= minMeanCrossings,
              meanCrossings(ir) >= minMeanCrossings else { return nil }
        let r = (acRed / dcRed) / (acIr / dcIr)
        return (rLo...rHi).contains(r) ? r : nil
    }

    // MARK: - Small stats

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Times the series crosses its own mean — a cheap proxy for "is this oscillating".
    static func meanCrossings(_ xs: [Double]) -> Int {
        guard let m = mean(xs) else { return 0 }
        var count = 0, prev = 0
        for x in xs {
            let side = x > m ? 1 : (x < m ? -1 : 0)
            if side == 0 { continue }
            if prev != 0, side != prev { count += 1 }
            prev = side
        }
        return count
    }

    /// Interquartile range, standing in for pulse amplitude. Robust to the occasional spike in a
    /// way a peak-to-peak range is not.
    static func iqr(_ xs: [Double]) -> Double {
        guard xs.count >= 2 else { return 0 }
        let sorted = xs.sorted()
        func quantile(_ q: Double) -> Double {
            let pos = q * Double(sorted.count - 1)
            let lo = Int(pos), hi = Swift.min(lo + 1, sorted.count - 1)
            return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
        }
        return quantile(0.75) - quantile(0.25)
    }
}
