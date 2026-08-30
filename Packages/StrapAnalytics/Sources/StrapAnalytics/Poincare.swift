import Foundation

/// Poincaré descriptors — the scatter of each beat interval against the next one.
///
/// Plotting NN[i] against NN[i+1] gives a cloud whose shape is the classical summary of
/// variability: SD1 is the spread ACROSS the identity line (short-term, beat-to-beat), SD2 the
/// spread ALONG it (long-term drift). They are not new measurements — both are exact algebraic
/// rearrangements of RMSSD and SDNN — which is why they are derived here rather than fitted.
public enum Poincare {
    public static let sqrt2: Double = 2.0.squareRoot()

    /// The cloud's major axis lies on the identity line, so the ellipse is always rotated 45°.
    public static let identityAngleRadians: Double = Double.pi / 4

    /// Three beats give two successive differences — the minimum for a spread to mean anything.
    public static let minEllipseBeats: Int = 3

    public struct Descriptors: Equatable, Sendable {
        /// Short-term variability, ms. Identically RMSSD / √2.
        public let sd1: Double
        /// Long-term variability, ms.
        public let sd2: Double
        /// SD2/SD1 — the cloud's elongation. Near 1 is a round cloud.
        public let ratio: Double
        public let rmssd: Double
        public let sdnn: Double
        public let meanNN: Double
        public let n: Int

        public init(sd1: Double, sd2: Double, ratio: Double, rmssd: Double,
                    sdnn: Double, meanNN: Double, n: Int) {
            self.sd1 = sd1; self.sd2 = sd2; self.ratio = ratio
            self.rmssd = rmssd; self.sdnn = sdnn; self.meanNN = meanNN; self.n = n
        }
    }

    /// Derive the descriptors from metrics already computed.
    ///
    /// `sd2² = 2·SDNN² − SD1²`. That right-hand side can go NEGATIVE on inputs where SDNN and
    /// RMSSD did not come from the same beats — a caller mixing a night's SDNN with a spot RMSSD,
    /// say. Returning nil there is deliberate: the alternative is a square root of a negative
    /// number rendered as a plausible-looking width.
    public static func descriptors(rmssd: Double, sdnn: Double, meanNN: Double, n: Int) -> Descriptors? {
        guard rmssd >= 0, sdnn >= 0, n >= minEllipseBeats else { return nil }
        let sd1 = rmssd / sqrt2
        let sd2sq = 2 * sdnn * sdnn - sd1 * sd1
        guard sd2sq >= 0 else { return nil }
        let sd2 = sd2sq.squareRoot()
        guard sd1 > 0 else { return nil }
        return Descriptors(sd1: sd1, sd2: sd2, ratio: sd2 / sd1,
                           rmssd: rmssd, sdnn: sdnn, meanNN: meanNN, n: n)
    }

    /// Derive them from beats directly.
    public static func descriptors(nn: [Double]) -> Descriptors? {
        guard nn.count >= minEllipseBeats,
              let rmssd = HRVAnalyzer.rmssdRaw(nn),
              let sdnn = HRVAnalyzer.sdnnRaw(nn),
              let mean = HRVAnalyzer.meanNNRaw(nn) else { return nil }
        return descriptors(rmssd: rmssd, sdnn: sdnn, meanNN: mean, n: nn.count)
    }

    /// The plotted ellipse: centred on the mean interval, rotated onto the identity line.
    public struct Ellipse: Equatable, Sendable {
        public let centerX: Double
        public let centerY: Double
        public let sd1: Double
        public let sd2: Double
        public let angleRadians: Double
        public init(centerX: Double, centerY: Double, sd1: Double, sd2: Double, angleRadians: Double) {
            self.centerX = centerX; self.centerY = centerY
            self.sd1 = sd1; self.sd2 = sd2; self.angleRadians = angleRadians
        }
    }

    public static func ellipse(descriptors d: Descriptors) -> Ellipse? {
        guard d.meanNN > 0 else { return nil }
        return Ellipse(centerX: d.meanNN, centerY: d.meanNN,
                       sd1: d.sd1, sd2: d.sd2, angleRadians: identityAngleRadians)
    }

    public static func ellipse(nn: [Double]) -> Ellipse? {
        descriptors(nn: nn).flatMap(ellipse(descriptors:))
    }

    // MARK: - Per-beat verdicts

    /// How one interval fared against the cleaning pipeline, so a scatter can draw survivors in ink
    /// and rejects dimmed rather than silently dropping them.
    public enum BeatClass: Equatable, Sendable {
        case clean
        /// Outside the physiologically possible range.
        case outOfRange
        /// In range, but too far from its local neighbours to be a real beat.
        case ectopic
    }

    /// Classify every input beat, aligned one-to-one with the input.
    ///
    /// This mirrors the cleaner exactly — range filter first, then the local-median rule over the
    /// IN-RANGE subsequence only. Running the second pass over all beats instead would let an
    /// impossible value sit in its neighbours' median and change which real beats survive, so the
    /// picture would no longer be of the series the metrics were computed from.
    public static func classify(rr: [Double]) -> [BeatClass] {
        let n = rr.count
        guard n > 0 else { return [] }
        let inRangeIdx = (0..<n).filter { rr[$0] >= HRVAnalyzer.rrMinMs && rr[$0] <= HRVAnalyzer.rrMaxMs }
        let inRange = inRangeIdx.map { rr[$0] }

        let radius = HRVAnalyzer.ectopicWindowRadius
        let threshold = HRVAnalyzer.ectopicThreshold
        var kept = [Bool](repeating: true, count: inRange.count)
        if inRange.count > radius {
            for i in 0..<inRange.count {
                let lo = max(0, i - radius)
                let hi = min(inRange.count - 1, i + radius)
                var neighbours: [Double] = []
                neighbours.reserveCapacity(hi - lo)
                for j in lo...hi where j != i { neighbours.append(inRange[j]) }
                guard neighbours.count >= 2 else { continue }
                let med = HRVAnalyzer.median(neighbours)
                guard med > 0 else { continue }
                if abs(inRange[i] - med) / med > threshold { kept[i] = false }
            }
        }
        var out = [BeatClass](repeating: .outOfRange, count: n)
        for (k, idx) in inRangeIdx.enumerated() { out[idx] = kept[k] ? .clean : .ectopic }
        return out
    }

    /// The survivors, in order — the same series the metrics are built from.
    public static func cleanedNN(from rr: [Double]) -> [Double] {
        cleanedNN(from: rr, classes: classify(rr: rr))
    }

    /// The survivors, given verdicts a caller already has. A view that draws every beat has the
    /// classes in hand; reclassifying would repeat the work and risk the two disagreeing.
    public static func cleanedNN(from rr: [Double], classes: [BeatClass]) -> [Double] {
        zip(rr, classes).compactMap { $1 == .clean ? $0 : nil }
    }
}
