import Foundation
import StrapProtocol

/// Frequency-domain HRV, by Lomb–Scargle periodogram.
///
/// Beats do not arrive on a regular grid — that irregularity IS the signal — so an FFT would need
/// the series resampled onto one first, and the interpolation that requires invents structure at
/// exactly the frequencies being measured. Lomb–Scargle estimates the spectrum from unevenly
/// sampled data directly, which is why it is the standard tool here despite costing more.
public enum HRVFreqDomain {

    public static let vlfLowHz: Double = 0.0033
    public static let lfLowHz: Double = 0.04
    public static let lfHighHz: Double = 0.15
    public static let hfLowHz: Double = 0.15
    public static let hfHighHz: Double = 0.40

    /// A band needs several cycles of its slowest component to be resolved at all. HF's lower edge
    /// is 0.15 Hz, so a minute covers about nine cycles.
    public static let minSpanForHFSec: Double = 60.0
    /// LF reaches down to 0.04 Hz — a 25-second cycle — so it needs several minutes. Reporting LF
    /// from a shorter record produces a number that is mostly the record's own length.
    public static let minSpanForLFSec: Double = 250.0

    public static let minBeats: Int = 20
    /// Integration step across each band.
    public static let freqStepHz: Double = 0.005

    /// Band powers from the NORMALISED periodogram.
    ///
    /// ⚠️ These are NOT absolute powers in ms², despite what the units on a textbook LF/HF plot
    /// suggest. Lomb–Scargle here divides by the signal's own variance, so what comes out is how
    /// the variance is DISTRIBUTED across frequencies — doubling the amplitude of a rhythm leaves
    /// these numbers essentially unchanged, which a test pins.
    ///
    /// The consequence: `lfhf` is meaningful and comparable across nights, because both halves are
    /// normalised the same way. `lf`, `hf` and `totalPower` are comparable WITHIN a record and
    /// should not be trended across nights as if they were absolute power — a night that reads
    /// higher has a more concentrated spectrum, not necessarily more variability. Use the
    /// time-domain RMSSD for that.
    public struct Bands: Equatable, Sendable {
        /// nil when the record is too short to resolve it.
        public let lf: Double?
        public let hf: Double
        /// nil whenever LF is, or when HF is zero.
        public let lfhf: Double?
        public let totalPower: Double
        public init(lf: Double?, hf: Double, lfhf: Double?, totalPower: Double) {
            self.lf = lf; self.hf = hf; self.lfhf = lfhf; self.totalPower = totalPower
        }
    }

    public static func freqDomain(rr: [RRInterval]) -> Bands? {
        freqDomain(rawRR: rr.sorted { $0.ts < $1.ts }.map { Double($0.rrMs) })
    }

    public static func freqDomain(rawRR: [Double]) -> Bands? {
        let clean = HRVAnalyzer.cleanRR(rawRR)
        guard clean.count >= minBeats else { return nil }

        // The tachogram: beat k sits at the cumulative sum of the intervals before it, and its
        // value IS the interval. Time in seconds, value in milliseconds.
        var times = [Double](repeating: 0, count: clean.count)
        var acc = 0.0
        for i in clean.indices {
            times[i] = acc / 1000.0
            acc += clean[i]
        }
        let span = times.last! - times.first!
        guard span >= minSpanForHFSec else { return nil }

        // Mean-removed: a DC offset leaks across every frequency and would swamp the bands.
        let mean = clean.reduce(0, +) / Double(clean.count)
        let y = clean.map { $0 - mean }

        let hf = bandPower(times: times, y: y, fLow: hfLowHz, fHigh: hfHighHz)
        let lfTrusted = span >= minSpanForLFSec
        let lf: Double? = lfTrusted ? bandPower(times: times, y: y, fLow: lfLowHz, fHigh: lfHighHz) : nil
        let lfhf: Double? = (lf != nil && hf > 0) ? lf! / hf : nil

        // Total power is the SUM of the sub-band integrals, not one wide integral.
        //
        // A single [VLF…HF] sweep samples the spectrum on a grid offset from the HF-only grid, so
        // against a narrow peak it can undercount the HF region and come out BELOW `hf` — which is
        // impossible for a superset band and reads as a bug in every chart that shows both.
        let totalPower: Double
        if lfTrusted, let lfVal = lf {
            totalPower = bandPower(times: times, y: y, fLow: vlfLowHz, fHigh: lfLowHz) + lfVal + hf
        } else {
            totalPower = hf
        }
        return Bands(lf: lf, hf: hf, lfhf: lfhf, totalPower: totalPower)
    }

    /// Trapezoidal integral of the periodogram across a band.
    static func bandPower(times: [Double], y: [Double], fLow: Double, fHigh: Double) -> Double {
        guard fHigh > fLow else { return 0 }
        let n = Double(y.count)
        var variance = 0.0
        for v in y { variance += v * v }
        variance /= n
        guard variance > 0 else { return 0 }

        var power = 0.0
        var prevP = 0.0
        var prevF = fLow
        var first = true
        var f = fLow
        while f <= fHigh + 1e-12 {
            let p = lombScarglePower(times: times, y: y, freqHz: f, variance: variance)
            if !first { power += 0.5 * (p + prevP) * (f - prevF) }
            prevP = p
            prevF = f
            first = false
            f += freqStepHz
        }
        // The loop can stop just short of the upper edge; close the last strip so a band is not
        // systematically undercounted by up to one step.
        if prevF < fHigh {
            let p = lombScarglePower(times: times, y: y, freqHz: fHigh, variance: variance)
            power += 0.5 * (p + prevP) * (fHigh - prevF)
        }
        return power
    }

    /// Lomb–Scargle power at one frequency.
    ///
    /// `tau` is the phase offset that makes the sine and cosine sums orthogonal on THIS sample
    /// set. It is what makes the estimate invariant to where the record happens to start — without
    /// it the same rhythm measured from a different beat reports a different power.
    static func lombScarglePower(times: [Double], y: [Double], freqHz: Double, variance: Double) -> Double {
        let omega = 2.0 * Double.pi * freqHz
        var sin2 = 0.0, cos2 = 0.0
        for t in times {
            let a = 2.0 * omega * t
            sin2 += sin(a)
            cos2 += cos(a)
        }
        let tau = atan2(sin2, cos2) / (2.0 * omega)

        var cTerm = 0.0, cDen = 0.0, sTerm = 0.0, sDen = 0.0
        for i in times.indices {
            let arg = omega * (times[i] - tau)
            let c = cos(arg), s = sin(arg)
            cTerm += y[i] * c; cDen += c * c
            sTerm += y[i] * s; sDen += s * s
        }
        let cosPart = cDen > 0 ? (cTerm * cTerm) / cDen : 0
        let sinPart = sDen > 0 ? (sTerm * sTerm) / sDen : 0
        // NORMALISED by twice the signal variance. This is the standard normalised periodogram,
        // and the normalisation is why the outputs are RELATIVE — see the note on `Bands`.
        return (cosPart + sinPart) / (2.0 * variance)
    }
}
