import Foundation
import StrapProtocol

/// How much a night was disturbed, from movement alone.
///
/// Intensity is NORMALISED against the night's own peak rather than an absolute scale. Two nights
/// are not comparable in raw units — the strap sits differently, the sample rate varies — but
/// "restless relative to how still this person got" is meaningful, and it is what the hypnogram
/// and the disturbance count are read against.
public enum NightMovement {

    public struct Sample: Equatable, Sendable {
        public let ts: Int
        /// 0…1 after normalisation.
        public let intensity: Double
        public init(ts: Int, intensity: Double) { self.ts = ts; self.intensity = intensity }
    }

    public struct StillestStretch: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationSec: Int { max(0, end - start) }
    }

    /// Which lane the analysis came from. Kept on the result because the two have different
    /// resolutions, and a caller comparing nights needs to know it is not comparing like with like.
    public enum Source: Equatable, Sendable { case gravity, epochMotion }

    public struct Analysis: Equatable, Sendable {
        public let source: Source
        public let start: Int
        public let end: Int
        public let samples: [Sample]
        /// The raw intensity that normalised to 1.0. Kept so a caller can tell a genuinely
        /// restless night from a still one whose tiny movements were scaled up to fill the range.
        public let peak: Double
        public let stirCount: Int
        public let stillest: StillestStretch?

        public init(source: Source, start: Int, end: Int, samples: [Sample],
                    peak: Double, stirCount: Int, stillest: StillestStretch?) {
            self.source = source; self.start = start; self.end = end; self.samples = samples
            self.peak = peak; self.stirCount = stirCount; self.stillest = stillest
        }

        public var isEmpty: Bool { samples.isEmpty }
    }

    /// Normalised intensity at or above which a movement counts as a stir.
    public static let stirThresholdFraction = 0.35
    /// Quiet time required before another stir can be counted.
    ///
    /// Without it a single roll-over registers as a dozen stirs — the movement takes several
    /// samples to subside and each one is over threshold.
    public static let stirDebounceSec = 90
    /// At or below this, the wrist counts as still.
    public static let quietThresholdFraction = 0.12
    /// Guards the normalisation divide on a perfectly motionless night.
    public static let epsilon = 1e-9

    /// Count distinct movements, debounced.
    public static func stirCount(_ samples: [Sample], threshold: Double, debounceSec: Int) -> Int {
        var count = 0
        var armed = true
        var quietSince: Int?
        for s in samples.sorted(by: { $0.ts < $1.ts }) {
            if s.intensity >= threshold {
                if armed { count += 1; armed = false }
                quietSince = nil
            } else {
                if quietSince == nil { quietSince = s.ts }
                if let q = quietSince, s.ts - q >= debounceSec { armed = true }
            }
        }
        return count
    }

    /// The longest unbroken quiet run.
    ///
    /// Measured in CLOCK time between the first and last quiet sample rather than in sample count,
    /// so a sparse stretch and a dense one of the same real duration compare equally.
    public static func stillestStretch(_ samples: [Sample], quietThreshold: Double) -> StillestStretch? {
        let sorted = samples.sorted { $0.ts < $1.ts }
        var best: StillestStretch?
        var runStart: Int?
        var runEnd = 0

        func flush() {
            if let rs = runStart {
                let cand = StillestStretch(start: rs, end: runEnd)
                if best == nil || cand.durationSec > best!.durationSec { best = cand }
            }
            runStart = nil
        }

        for x in sorted {
            if x.intensity <= quietThreshold {
                if runStart == nil { runStart = x.ts }
                runEnd = x.ts
            } else {
                flush()
            }
        }
        flush()
        return best
    }

    /// Normalise and summarise.
    static func analyze(rawSamples: [Sample], start: Int, end: Int, source: Source) -> Analysis {
        guard !rawSamples.isEmpty else {
            return Analysis(source: source, start: start, end: end, samples: [],
                            peak: 0, stirCount: 0, stillest: nil)
        }
        let peak = Swift.max(rawSamples.map(\.intensity).max() ?? 0, epsilon)
        let norm = rawSamples.map { Sample(ts: $0.ts, intensity: Swift.min($0.intensity / peak, 1.0)) }
        return Analysis(source: source, start: start, end: end, samples: norm, peak: peak,
                        stirCount: stirCount(norm, threshold: stirThresholdFraction,
                                             debounceSec: stirDebounceSec),
                        stillest: stillestStretch(norm, quietThreshold: quietThresholdFraction))
    }

    static func movementIntensity(gravity: [GravitySample]) -> [Sample] {
        Motion.activitySeries(gravity).map { Sample(ts: $0.ts, intensity: $0.intensity) }
    }

    /// Epoch motion is already one magnitude per fixed epoch, so timestamps are reconstructed
    /// from the session start rather than carried.
    static func movementIntensity(epochMotion: [Double], sessionStart: Int, epochSeconds: Int) -> [Sample] {
        epochMotion.enumerated().map {
            Sample(ts: sessionStart + $0.offset * epochSeconds, intensity: $0.element)
        }
    }

    public static func fromGravity(_ gravity: [GravitySample], start: Int, end: Int) -> Analysis {
        analyze(rawSamples: movementIntensity(gravity: gravity), start: start, end: end, source: .gravity)
    }

    public static func fromEpochMotion(_ motion: [Double], sessionStart: Int, end: Int,
                                       epochSeconds: Int = 30) -> Analysis {
        analyze(rawSamples: movementIntensity(epochMotion: motion, sessionStart: sessionStart,
                                              epochSeconds: epochSeconds),
                start: sessionStart, end: end, source: .epochMotion)
    }

    /// Fewest gravity samples a night needs before its trace is drawn from them rather than from
    /// the stored per-epoch motion. Below it the raw stream is too thin to say anything about
    /// movement, and a sparse trace reads as a calm night rather than as no data.
    public static let minGravitySamples = 60

    /// A column's floor and PEAK.
    ///
    /// The peak is the point: a mean over a column erases exactly the deflection the trace exists
    /// to show. A column with nothing in it is `.quiet` — honest stillness, never interpolated from
    /// its neighbours.
    public struct Envelope: Equatable, Sendable {
        public let lo: Double
        public let hi: Double
        public init(lo: Double, hi: Double) { self.lo = lo; self.hi = hi }
        public static let quiet = Envelope(lo: 0, hi: 0)
    }

    /// Reduce a night's samples into one envelope per drawn column.
    public static func laneEnvelope(_ samples: [Sample], from: Int, to: Int,
                                    columns: Int) -> [Envelope] {
        guard columns > 0, to > from else { return [] }
        let span = Double(to - from)
        var seen = [Bool](repeating: false, count: columns)
        var mins = [Double](repeating: 0, count: columns)
        var maxs = [Double](repeating: 0, count: columns)
        for s in samples where s.ts >= from && s.ts < to {
            var c = Int(Double(s.ts - from) / span * Double(columns))
            c = max(0, min(columns - 1, c))
            if !seen[c] {
                seen[c] = true; mins[c] = s.intensity; maxs[c] = s.intensity
            } else {
                mins[c] = min(mins[c], s.intensity)
                maxs[c] = max(maxs[c], s.intensity)
            }
        }
        return (0..<columns).map { seen[$0] ? Envelope(lo: mins[$0], hi: maxs[$0]) : .quiet }
    }
}
