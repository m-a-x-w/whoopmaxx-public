import Foundation
import StrapProtocol
import StrapAnalytics

/// Recurring WRIST ORIENTATIONS across one night — told apart from one another, and from nothing else.
///
/// The strap's `x/y/z` is a DSP-separated GRAVITY vector in g, |g| ≈ 1 (`Streams.swift:119-128`; the
/// v24 field notes carry unit "g", and `PostHooks.swift:310-318` rejects anything that isn't ~1 g),
/// banked contiguously at 1 Hz. Every other consumer in the app collapses it to a MAGNITUDE —
/// `SleepStaging.swift:369`, `NightMovement.swift:104`, `AutoWorkoutDetector.swift:106`,
/// `SedentaryDetector.swift:192` and `StepsEstimateEngine.swift:188` all take |Δg|, and
/// `ArousalForensics.swift:179-185` uses a RELATIVE roll-over angle. The absolute direction is
/// genuinely untouched, and the direction is what this reads.
///
/// **A wrist is not a torso, and this never pretends otherwise.** Gravity fixes 2 of the 3 degrees of
/// freedom (yaw about vertical is unobservable) and the forearm pronates/supinates ~150–180° freely
/// inside any torso position, so wrist roll does not determine which way the sleeper faced — measured
/// forearm-axis elevation during sleep spans −75°…+90°, with ~21% of held epochs beyond |45°|, and
/// those carry no torso information at all. Uncalibrated there is no honest mapping from these
/// clusters to a body position, so the engine carries no such names: it emits NUMBERED orientations
/// and `label(for:)` prints "Orientation 1…n". That is the entire claim — these stretches of the night
/// differed from each other, and they recurred.
///
/// **Method.** 30 s epochs on `SleepStaging.epochS`, so the lane grids with the hypnogram above it. Per
/// epoch: the mean RAW vector (its magnitude in g) and the p90 angle of that epoch's samples about
/// their own mean direction. An epoch is HELD only when the p90 spread is under `stableSpreadDeg` AND
/// the mean magnitude sits inside `stableMagnitude` — the magnitude test is what rejects a
/// dynamic-acceleration burst, which can point perfectly consistently while being nothing like 1 g.
/// Held directions are clustered greedily in TIME order (merge under `mergeAngleDeg`, centroid =
/// running mean of its members) with one Lloyd reassignment, and a cluster holding under
/// `minClusterShare` of the held epochs is DROPPED rather than promoted to an orientation the night
/// never really returned to.
///
/// **Refusals** (011 decision 4 — the app never prints a number it did not measure). An epoch with too
/// little gravity is `.noData`, never a guessed orientation; a measured-but-unheld epoch is `.moving`;
/// a held epoch in a dropped cluster is `.other`. A night that never held still long enough to tell
/// orientations apart (`minStableEpochs`, `minStableFraction`), or that never returned to any one of
/// them, returns nil — the surface then shows nothing rather than a plausible-looking band.
///
/// READ-ONLY (011 decision 2). Nothing here reaches `AnalyticsEngine`: no Charge/Effort/Rest score
/// moves and no historical value changes because of it.
///
/// Framing register (011 decision 5): descriptive, within-user, no condition name, no probability, no
/// call-to-action. Banned from every string this type and its surfaces produce — *thermoregulation,
/// vasodilation, impaired, poor, abnormal, apnea, insomnia, hypoxemia, arrhythmia, "consider", "you
/// should", "talk to"*.
enum PostureEngine {

    // MARK: - Constants

    /// The epoch grid, taken from the stager rather than re-typed as 30, so the lane can never drift a
    /// second away from the hypnogram it sits under.
    static var epochS: Double { SleepStaging.epochS }

    /// The longest `.moving` gap that still bridges two epochs of the SAME orientation. Two 30 s
    /// epochs — one minute. A shift that lands where it started is not a change of orientation; a
    /// minute of motion is no longer a shift.
    static let maxBridgeEpochs = 2

    /// Samples an epoch needs before it is measured at all. Gravity is banked at 1 Hz (523,179 of
    /// 523,215 consecutive deltas on the real store are exactly 1 s), so a full epoch holds ~30; under
    /// a sixth of that there is no direction to average, only a sample.
    static let minEpochSamples = 5

    /// p90 angular spread (degrees) about the epoch's own mean direction, under which the wrist was
    /// being held rather than moved.
    static let stableSpreadDeg = 12.0

    /// Mean RAW magnitude band (g) for a held wrist. Measured on the store: |g| median 0.989, p25
    /// 0.981, p75 1.007. Outside this the epoch carries dynamic acceleration or a dropout, not an
    /// orientation — and this is the ONLY test that catches a burst whose direction is consistent.
    static let stableMagnitude: ClosedRange<Double> = 0.85...1.15

    /// Merge radius for the greedy clustering, in degrees.
    static let mergeAngleDeg = 25.0

    /// Share of the held epochs a cluster must hold to count as one of the night's recurring
    /// orientations. Below it the night passed through, it did not return.
    static let minClusterShare = 0.05

    /// Held epochs a night needs before orientations are worth telling apart — 120 epochs = one hour.
    static let minStableEpochs = 120

    /// Share of the MEASURED epochs that must be held. Per-night stable fraction over the 15-night
    /// corpus was 85–96%, so this floor only ever catches a night that was not really slept.
    static let minStableFraction = 0.5

    /// Hard ceiling on seeded clusters, so a night of continuous slow drift cannot spawn hundreds of
    /// them before the 5% rule throws them all away.
    static let maxClusters = 24

    /// Hard ceiling on the epoch grid one call will build (24 h), so a malformed window cannot
    /// allocate without bound.
    static let maxEpochs = 2_880

    // MARK: - Values

    /// A 3-vector, so the direction math reads as math.
    struct Vec: Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double

        var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

        /// The unit direction, or nil for a zero-length vector — which has no direction at all, and
        /// must not be normalized into a fabricated one.
        var unit: Vec? {
            let m = magnitude
            guard m > 1e-9 else { return nil }
            return Vec(x: x / m, y: y / m, z: z / m)
        }

        func dot(_ other: Vec) -> Double { x * other.x + y * other.y + z * other.z }

        static func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func / (a: Vec, d: Double) -> Vec { Vec(x: a.x / d, y: a.y / d, z: a.z / d) }
    }

    /// One 30 s slot of the tape.
    enum Epoch: Equatable, Sendable {
        /// Too little gravity in the slot to measure anything. Never a guessed orientation.
        case noData
        /// Measured, but the wrist was not being held still.
        case moving
        /// Held still, in a direction the night did not return to often enough to be one of its
        /// recurring orientations.
        case other
        /// Held still, in recurring orientation `index` (0-based into `Night.orientations`).
        case orientation(Int)

        /// The recurring orientation this slot belongs to, or nil for every other case.
        var orientationIndex: Int? {
            if case .orientation(let i) = self { return i }
            return nil
        }
    }

    /// One recurring orientation. It has a RANK and a dwell, and deliberately no name.
    struct Orientation: Equatable, Sendable {
        /// Rank, 0-based: 0 is the orientation the night spent the most epochs in. The UI prints
        /// `label(for: index)` — "Orientation 1" — and NEVER a body position.
        let index: Int
        /// Epochs assigned to it.
        let epochs: Int
        /// Its share of the ASSIGNED epochs, 0…1.
        let share: Double
        /// Longest unbroken stretch, in epochs. A `.moving` slot between two of its own bridges the
        /// stretch (a shift that lands where it started is not a change of orientation); `.noData` and
        /// `.other` end it, because nothing there says the wrist stayed put.
        let longestHoldEpochs: Int

        var minutes: Double { Double(epochs) * PostureEngine.epochS / 60 }
        var longestHoldMinutes: Double { Double(longestHoldEpochs) * PostureEngine.epochS / 60 }
    }

    /// The per-night numbers that OUTLIVE the tape. Raw gravity is pruned at 28 days
    /// (`SampleRetention.swift:92-95`), so the bands are a 28-day artifact — the same rule `NightTape`
    /// already lives with. These four ride `metricSeries` and are never pruned.
    struct Summary: Equatable, Sendable {
        /// Changes from one recurring orientation to a DIFFERENT one, across the night. Slots that are
        /// not an orientation are skipped rather than counted as a change.
        let switches: Int
        /// Share of the MEASURED epochs the wrist was held still, 0…1.
        let stableFraction: Double
        /// The largest orientation's share of the assigned epochs, 0…1.
        let dominantFraction: Double
        /// Shannon entropy of the orientation occupancies, in bits: 0 = one orientation all night,
        /// 2 = four equally-occupied ones. Deliberately NOT normalized — the normalizing base is the
        /// orientation count, which itself varies night to night, so dividing by it would hide the
        /// difference between two orientations and five.
        let entropyBits: Double
        /// How many recurring orientations the night had.
        let orientationCount: Int
    }

    /// One night's read.
    struct Night: Equatable, Sendable {
        /// The window read, in unix seconds.
        let start: Int
        let end: Int
        /// One slot per `epochS` from `start`, in time order.
        let epochs: [Epoch]
        /// The recurring orientations, most-occupied first.
        let orientations: [Orientation]
        let summary: Summary
    }

    /// Each orientation's stage mix — the cross-tab under the tape.
    struct StageMix: Equatable, Sendable {
        /// Which orientation (0-based rank, matching `Orientation.index`).
        let orientation: Int
        /// Epochs of this orientation that fell inside a staged span. The denominator, and the reason
        /// an orientation the stager never covered reads as an em-dash instead of "0% deep".
        let staged: Int
        let deep: Int
        let rem: Int
        let light: Int
        let wake: Int

        /// `count` as a share of the staged epochs; 0 when nothing was staged (callers gate on
        /// `staged` before printing).
        func share(_ count: Int) -> Double { staged > 0 ? Double(count) / Double(staged) : 0 }
    }

    // MARK: - Naming

    /// The ONLY name an orientation ever gets: its rank, one-based. Not supine / left / right / prone —
    /// see the wrist-is-not-a-torso paragraph above. Naming them is a separate feature behind a user
    /// calibration affordance (011 W3.5), and until that exists a number is the honest label.
    static func label(for index: Int) -> String { "Orientation \(index + 1)" }

    // MARK: - Entry point

    /// Read one night's wrist orientations from its raw gravity.
    ///
    /// - Parameters:
    ///   - gravity: the window's gravity samples (order is not assumed — each sample is binned by its
    ///     own timestamp).
    ///   - start: window start, unix seconds. The epoch grid is anchored here.
    ///   - end: window end, unix seconds (exclusive).
    /// - Returns: nil when there is nothing measured to describe — see the refusals in the type doc.
    static func analyze(gravity: [GravitySample], start: Int, end: Int) -> Night? {
        guard end > start else { return nil }
        let slots = Int(ceil(Double(end - start) / epochS))
        guard slots > 0, slots <= maxEpochs else { return nil }

        var bins = [[GravitySample]](repeating: [], count: slots)
        for s in gravity {
            guard s.ts >= start, s.ts < end else { continue }
            let i = Int(Double(s.ts - start) / epochS)
            if i >= 0 && i < slots { bins[i].append(s) }
        }

        // ── Measure each slot. Slots stay `.noData` until something is measured in them, so a gap in
        // the stream can only ever render as a gap.
        var epochs = [Epoch](repeating: .noData, count: slots)
        var measured = 0
        var held: [(slot: Int, direction: Vec)] = []
        for (i, bin) in bins.enumerated() {
            guard bin.count >= minEpochSamples else { continue }
            measured += 1
            let sum = bin.reduce(Vec(x: 0, y: 0, z: 0)) { $0 + Vec(x: $1.x, y: $1.y, z: $1.z) }
            let mean = sum / Double(bin.count)
            // The magnitude gate FIRST: a dynamic-acceleration burst points consistently enough to pass
            // any spread test, and only its magnitude gives it away.
            guard stableMagnitude.contains(mean.magnitude), let direction = mean.unit else {
                epochs[i] = .moving
                continue
            }
            var angles: [Double] = []
            angles.reserveCapacity(bin.count)
            for s in bin {
                guard let u = Vec(x: s.x, y: s.y, z: s.z).unit else { continue }
                angles.append(angleDeg(u, direction))
            }
            guard let spread = percentile90(angles), spread < stableSpreadDeg else {
                epochs[i] = .moving
                continue
            }
            held.append((slot: i, direction: direction))
        }

        guard measured > 0 else { return nil }
        let stableFraction = Double(held.count) / Double(measured)
        guard held.count >= minStableEpochs, stableFraction >= minStableFraction else { return nil }

        // ── Cluster the held directions, then keep only the ones the night RETURNED to.
        let clustered = cluster(held.map { $0.direction })
        var countByCluster: [Int: Int] = [:]
        var firstSlotByCluster: [Int: Int] = [:]
        for (k, entry) in held.enumerated() {
            let c = clustered.labels[k]
            countByCluster[c, default: 0] += 1
            if firstSlotByCluster[c] == nil { firstSlotByCluster[c] = entry.slot }
        }
        let keepFloor = minClusterShare * Double(held.count)
        // Ranked by occupancy, ties broken by FIRST APPEARANCE — so two equally-occupied orientations
        // still come out in the same order on every run, over any input ordering.
        let kept = countByCluster
            .filter { Double($0.value) >= keepFloor }
            .sorted { a, b in
                a.value == b.value
                    ? (firstSlotByCluster[a.key] ?? 0) < (firstSlotByCluster[b.key] ?? 0)
                    : a.value > b.value
            }
            .map { $0.key }
        guard !kept.isEmpty else { return nil }
        var rankByCluster: [Int: Int] = [:]
        for (rank, c) in kept.enumerated() { rankByCluster[c] = rank }

        for (k, entry) in held.enumerated() {
            if let rank = rankByCluster[clustered.labels[k]] {
                epochs[entry.slot] = .orientation(rank)
            } else {
                epochs[entry.slot] = .other
            }
        }

        // ── The numbers.
        let assigned = epochs.compactMap { $0.orientationIndex }
        guard !assigned.isEmpty else { return nil }
        var switches = 0
        for i in 1..<assigned.count where assigned[i] != assigned[i - 1] { switches += 1 }

        var counts = [Int](repeating: 0, count: kept.count)
        for i in assigned { counts[i] += 1 }
        let longest = longestHolds(epochs, orientations: kept.count)
        let assignedTotal = Double(assigned.count)
        let orientations = (0..<kept.count).map { rank in
            Orientation(index: rank, epochs: counts[rank],
                        share: Double(counts[rank]) / assignedTotal,
                        longestHoldEpochs: longest[rank])
        }
        var entropy = 0.0
        for o in orientations where o.share > 0 { entropy -= o.share * log2(o.share) }

        return Night(start: start, end: end, epochs: epochs, orientations: orientations,
                     summary: Summary(switches: switches,
                                      stableFraction: stableFraction,
                                      dominantFraction: orientations.first?.share ?? 0,
                                      entropyBits: entropy,
                                      orientationCount: orientations.count))
    }

    // MARK: - Clustering

    /// Deterministic greedy angular clustering plus one Lloyd reassignment.
    ///
    /// Seeds in the order given (callers give TIME order): each direction joins the nearest existing
    /// centroid within `mergeAngleDeg` and pulls it toward itself (the centroid is the running mean of
    /// its members, renormalized), or opens a new cluster. One reassignment pass then re-files every
    /// direction against the SETTLED centroids, which repairs the early members that were filed
    /// against a centroid that later moved.
    ///
    /// No randomness, no seeding heuristic, and no k: the same directions in the same order always
    /// give the same labels — which is what makes the tape reproducible night after night.
    static func cluster(_ directions: [Vec]) -> (labels: [Int], centroids: [Vec]) {
        var labels = [Int](repeating: 0, count: directions.count)
        var sums: [Vec] = []
        var centroids: [Vec] = []
        for (i, d) in directions.enumerated() {
            let near = nearest(d, in: centroids)
            if let n = near, n.angle <= mergeAngleDeg || centroids.count >= maxClusters {
                labels[i] = n.index
                sums[n.index] = sums[n.index] + d
                centroids[n.index] = sums[n.index].unit ?? centroids[n.index]
            } else {
                labels[i] = centroids.count
                sums.append(d)
                centroids.append(d)
            }
        }
        guard !centroids.isEmpty else { return (labels, centroids) }

        var newSums = [Vec](repeating: Vec(x: 0, y: 0, z: 0), count: centroids.count)
        var newCounts = [Int](repeating: 0, count: centroids.count)
        for (i, d) in directions.enumerated() {
            let index = nearest(d, in: centroids)?.index ?? labels[i]
            labels[i] = index
            newSums[index] = newSums[index] + d
            newCounts[index] += 1
        }
        for c in centroids.indices where newCounts[c] > 0 {
            centroids[c] = newSums[c].unit ?? centroids[c]
        }
        return (labels, centroids)
    }

    /// The nearest centroid to `d` and its angle, or nil when there are no centroids yet. Ties go to
    /// the EARLIER centroid (strict `<`), which is what keeps the labels stable.
    private static func nearest(_ d: Vec, in centroids: [Vec]) -> (index: Int, angle: Double)? {
        var best: (index: Int, angle: Double)?
        for (i, c) in centroids.enumerated() {
            let a = angleDeg(d, c)
            if a < (best?.angle ?? .greatestFiniteMagnitude) { best = (i, a) }
        }
        return best
    }

    // MARK: - Math

    /// Angle in DEGREES between two unit directions. The dot product is clamped before `acos` — a
    /// value of 1.0000000002 out of floating point would otherwise return NaN and poison every
    /// comparison downstream of it.
    static func angleDeg(_ a: Vec, _ b: Vec) -> Double {
        acos(Swift.min(Swift.max(a.dot(b), -1), 1)) * 180 / .pi
    }

    /// p90 by NEAREST RANK over the sorted values — "90% of this epoch's samples were within this
    /// angle". No interpolation, so the number returned is one that was actually measured.
    static func percentile90(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(0.9 * Double(sorted.count))) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }

    /// Longest unbroken stretch per orientation, in epochs — see `Orientation.longestHoldEpochs` for
    /// the bridging rule.
    static func longestHolds(_ epochs: [Epoch], orientations: Int) -> [Int] {
        var longest = [Int](repeating: 0, count: orientations)
        var current: Int?
        var run = 0
        var bridged = 0
        for e in epochs {
            switch e {
            case .orientation(let i):
                guard i < orientations else { current = nil; run = 0; bridged = 0; continue }
                // The bridged epochs are NOT folded into the run: they were measured as MOVEMENT, and
                // a hold counts only the epochs actually held. Folding them in let a "longest stretch"
                // exceed the orientation's own dwell time on the same row — the row contradicting
                // itself. And a bridge only survives while it is brief: past `maxBridgeEpochs` the
                // wrist moved long enough that calling the whole span one hold would claim minutes
                // nothing measured as still.
                if current == i && bridged <= maxBridgeEpochs { run += 1 } else { current = i; run = 1 }
                bridged = 0
                longest[i] = Swift.max(longest[i], run)
            case .moving:
                if current != nil { bridged += 1 }
            case .noData, .other:
                current = nil
                run = 0
                bridged = 0
            }
        }
        return longest
    }

    // MARK: - Cross-tab

    /// Cross-tab the tape against the night's staged spans: for each recurring orientation, how its
    /// epochs divided between deep / REM / light / awake.
    ///
    /// An epoch is attributed by its MIDPOINT, so a 30 s slot straddling a stage boundary lands on the
    /// stage it spent most of itself in rather than being counted twice. Epochs no span covers are not
    /// counted at all — `staged` is the denominator, and an orientation the stager never covered comes
    /// back with `staged == 0` so the surface can refuse rather than print "0% deep".
    ///
    /// This is not circular: `SleepStager` reads only |Δg| (`SleepStaging.swift:369`), never the
    /// absolute direction this engine clusters on.
    static func stageMix(night: Night,
                         stages: [(start: Int, end: Int, stage: SleepStage)]) -> [StageMix] {
        let count = night.orientations.count
        guard count > 0, !stages.isEmpty else { return [] }
        let ordered = stages.sorted { $0.start < $1.start }
        var staged = [Int](repeating: 0, count: count)
        var deep = [Int](repeating: 0, count: count)
        var rem = [Int](repeating: 0, count: count)
        var light = [Int](repeating: 0, count: count)
        var wake = [Int](repeating: 0, count: count)
        // The epochs are in time order and so is `ordered`, so the span cursor only ever advances.
        var cursor = 0
        for (i, e) in night.epochs.enumerated() {
            guard let rank = e.orientationIndex, rank < count else { continue }
            let mid = night.start + Int((Double(i) + 0.5) * epochS)
            while cursor < ordered.count && ordered[cursor].end <= mid { cursor += 1 }
            guard cursor < ordered.count, ordered[cursor].start <= mid else { continue }
            staged[rank] += 1
            switch ordered[cursor].stage.laneCode {
            case 3: deep[rank] += 1
            case 1: rem[rank] += 1
            case 2: light[rank] += 1
            default: wake[rank] += 1
            }
        }
        return (0..<count).map {
            StageMix(orientation: $0, staged: staged[$0], deep: deep[$0], rem: rem[$0],
                     light: light[$0], wake: wake[$0])
        }
    }
}
