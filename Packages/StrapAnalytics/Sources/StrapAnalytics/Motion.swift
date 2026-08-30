import Foundation
import StrapProtocol

/// Motion primitives derived from the gravity vector.
///
/// The strap reports orientation, not acceleration. Movement is therefore inferred from how far the
/// vector TURNED between consecutive samples, not from its magnitude — a still wrist held at any
/// angle reads as zero, which a magnitude-based measure could not distinguish from a wrist held
/// vertically.
public enum Motion {

    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        /// Euclidean distance between consecutive gravity vectors.
        public let intensity: Double
        public init(ts: Int, intensity: Double) { self.ts = ts; self.intensity = intensity }
    }

    /// Per-sample movement intensity.
    ///
    /// The first sample is 0 by definition — there is no previous vector to compare it with, and
    /// seeding it from the vector's own magnitude would open every series with a spurious spike.
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        guard !gravity.isEmpty else { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var out: [ActivityPoint] = []
        out.reserveCapacity(rows.count)
        var prev: GravitySample?
        for (i, row) in rows.enumerated() {
            var intensity = 0.0
            if i > 0, let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            }
            out.append(ActivityPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return out
    }

    /// Trailing mean over a time window.
    ///
    /// Windowed by TIME rather than sample count: the sample rate is not constant, so a fixed
    /// count would average over three seconds in one stretch and three minutes in another, and the
    /// same wrist would read as still in one and active in the other.
    ///
    /// A non-finite intensity is treated as zero rather than propagated — one NaN in a running sum
    /// poisons every later value in the series.
    public static func smoothedIntensity(_ motion: [ActivityPoint], windowS: Double) -> [Double] {
        let ts = motion.map(\.ts)
        let raw = motion.map { $0.intensity.isFinite ? $0.intensity : 0.0 }
        var out: [Double] = []
        out.reserveCapacity(motion.count)
        var lo = 0
        var running = 0.0
        for i in motion.indices {
            running += raw[i]
            while Double(ts[i] - ts[lo]) > windowS { running -= raw[lo]; lo += 1 }
            out.append(running / Double(i - lo + 1))
        }
        return out
    }
}

/// Stretches of the day spent still enough to be worth a nudge.
public enum SedentaryDetector {

    /// Smoothed intensity below this reads as sitting. Above it is walking-level motion.
    public static let defaultMoveThresholdG: Double = 0.15
    /// Smoothing window. Long enough that reaching for a cup does not end a sedentary run.
    public static let defaultSmoothWindowS: Double = 240.0
    /// A gap longer than this ends a run rather than being spanned.
    ///
    /// The strap off the wrist produces no samples, which is indistinguishable from perfect
    /// stillness. Bridging the gap would report a two-hour sedentary bout for a two-hour shower.
    public static let maxGapS: Int = 20 * 60
    public static let defaultMinMinutes: Int = 15

    public static let defaultThresholdMinutes: Int = 45
    public static let defaultReNudgeMinutes: Int = 30
    public static let defaultBuzzLoops: Int = 2
    public static let defaultActiveStartMin: Int = 9 * 60
    public static let defaultActiveEndMin: Int = 17 * 60
    public static let defaultQuietStartMin: Int = 22 * 60
    public static let defaultQuietEndMin: Int = 7 * 60

    public struct InactivityPeriod: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let durationS: Double
        public init(start: Int, end: Int, durationS: Double) {
            self.start = start; self.end = end; self.durationS = durationS
        }
    }

    /// Find the still stretches in a span of gravity samples.
    public static func detectSedentaryBouts(_ gravity: [GravitySample],
                                            moveThresholdG: Double = defaultMoveThresholdG,
                                            minMinutes: Int = defaultMinMinutes,
                                            smoothWindowSeconds: Double = defaultSmoothWindowS) -> [InactivityPeriod] {
        let rows = gravity.sorted { $0.ts < $1.ts }
        guard rows.count >= 2 else { return [] }
        let motion = Motion.activitySeries(rows)
        let smoothed = Motion.smoothedIntensity(motion, windowS: smoothWindowSeconds)
        let ts = motion.map(\.ts)
        let minS = minMinutes * 60

        var out: [InactivityPeriod] = []
        var runStart = -1

        func closeRun(_ endIdx: Int) {
            if runStart >= 0, runStart <= endIdx {
                let s = ts[runStart], e = ts[endIdx]
                if e - s >= minS { out.append(InactivityPeriod(start: s, end: e, durationS: Double(e - s))) }
            }
            runStart = -1
        }

        for i in ts.indices {
            if i > 0, ts[i] - ts[i - 1] > maxGapS { closeRun(i - 1) }
            if smoothed[i] > moveThresholdG {
                closeRun(i - 1)
            } else if runStart < 0 {
                runStart = i
            }
        }
        closeRun(ts.count - 1)
        return out
    }
}

// MARK: - The nudge decision

extension SedentaryDetector {

    /// What the app remembers between offloads.
    ///
    /// `lastProcessedGravityTs` is what stops a replayed sync re-firing a nudge for a bout that was
    /// already handled — a re-sync of the same rows must be inert, not a second buzz.
    public struct SedentaryState: Equatable, Sendable {
        public var lastProcessedGravityTs: Int
        public var lastBuzzAt: Int
        public var lastBuzzedBoutStart: Int
        public var lastBuzzedBoutEnd: Int
        public init(lastProcessedGravityTs: Int = 0, lastBuzzAt: Int = 0,
                    lastBuzzedBoutStart: Int = 0, lastBuzzedBoutEnd: Int = 0) {
            self.lastProcessedGravityTs = lastProcessedGravityTs
            self.lastBuzzAt = lastBuzzAt
            self.lastBuzzedBoutStart = lastBuzzedBoutStart
            self.lastBuzzedBoutEnd = lastBuzzedBoutEnd
        }
        public static let initial = SedentaryState()
    }

    public struct SedentaryDecision: Equatable, Sendable {
        public let shouldBuzz: Bool
        public let buzzLoops: Int
        /// The bout under consideration, present even when no buzz fires so a caller can explain why.
        public let bout: InactivityPeriod?
        public let nextState: SedentaryState
        public init(shouldBuzz: Bool, buzzLoops: Int, bout: InactivityPeriod?, nextState: SedentaryState) {
            self.shouldBuzz = shouldBuzz; self.buzzLoops = buzzLoops
            self.bout = bout; self.nextState = nextState
        }
    }

    public struct SedentaryConfig: Equatable, Sendable {
        public var enabled: Bool
        /// The app-wide notification switch. Kept separate so turning notifications off silences
        /// this without also forgetting the feature was on.
        public var notificationsMasterOn: Bool

        public var moveThresholdG: Double
        public var thresholdMinutes: Int
        public var smoothWindowSeconds: Double

        public var reNudgeMinutes: Int
        public var buzzLoops: Int

        public var activeHoursEnabled: Bool
        public var activeStartMinutes: Int
        public var activeEndMinutes: Int

        public var quietHoursEnabled: Bool
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int

        public var onlyWhenWorn: Bool

        public init(enabled: Bool = false, notificationsMasterOn: Bool = false,
                    moveThresholdG: Double = SedentaryDetector.defaultMoveThresholdG,
                    thresholdMinutes: Int = SedentaryDetector.defaultThresholdMinutes,
                    smoothWindowSeconds: Double = SedentaryDetector.defaultSmoothWindowS,
                    reNudgeMinutes: Int = SedentaryDetector.defaultReNudgeMinutes,
                    buzzLoops: Int = SedentaryDetector.defaultBuzzLoops,
                    activeHoursEnabled: Bool = true,
                    activeStartMinutes: Int = SedentaryDetector.defaultActiveStartMin,
                    activeEndMinutes: Int = SedentaryDetector.defaultActiveEndMin,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    onlyWhenWorn: Bool = true) {
            self.enabled = enabled; self.notificationsMasterOn = notificationsMasterOn
            self.moveThresholdG = moveThresholdG; self.thresholdMinutes = thresholdMinutes
            self.smoothWindowSeconds = smoothWindowSeconds
            self.reNudgeMinutes = reNudgeMinutes; self.buzzLoops = buzzLoops
            self.activeHoursEnabled = activeHoursEnabled
            self.activeStartMinutes = activeStartMinutes; self.activeEndMinutes = activeEndMinutes
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes; self.quietEndMinutes = quietEndMinutes
            self.onlyWhenWorn = onlyWhenWorn
        }
    }

    /// Whether a window of the day contains a minute, handling windows that WRAP midnight.
    ///
    /// Quiet hours normally do wrap — 22:00 to 07:00 — and a plain range comparison silences
    /// nothing at all for exactly the hours it was configured to cover.
    public static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    static func localMinuteOfDay(_ epochSec: Int, tzOffsetSec: Int) -> Int {
        let local = epochSec + tzOffsetSec
        let mod = ((local % 86_400) + 86_400) % 86_400
        return mod / 60
    }

    /// Every gate that must pass before a nudge is allowed at all.
    ///
    /// Judged at the BOUT'S END rather than at the current moment: a sync arriving at midnight
    /// about an afternoon of sitting should not be silenced by quiet hours it was never in, and
    /// equally should not fire for a bout that happened during them.
    public static func mayBuzz(_ config: SedentaryConfig, worn: Bool,
                               boutEndEpochSec: Int, tzOffsetSec: Int) -> Bool {
        guard config.enabled, config.notificationsMasterOn else { return false }
        if config.quietHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if windowContains(mod, startMin: config.quietStartMinutes,
                              endMin: config.quietEndMinutes) { return false }
        }
        if config.onlyWhenWorn && !worn { return false }
        if config.activeHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if !windowContains(mod, startMin: config.activeStartMinutes,
                               endMin: config.activeEndMinutes) { return false }
        }
        return true
    }

    /// Decide whether to nudge, and what to remember.
    ///
    /// Returns the next state alongside the decision so the caller stores exactly what was
    /// decided on — splitting the two invites a nudge that fires without recording that it did,
    /// and then repeats on the next sync.
    public static func evaluate(_ gravity: [GravitySample],
                                state: SedentaryState,
                                config: SedentaryConfig,
                                worn: Bool,
                                nowSec: Int,
                                tzOffsetSec: Int) -> SedentaryDecision {
        func noBuzz(_ next: SedentaryState, _ bout: InactivityPeriod? = nil) -> SedentaryDecision {
            SedentaryDecision(shouldBuzz: false, buzzLoops: config.buzzLoops,
                              bout: bout, nextState: next)
        }

        guard config.enabled else { return noBuzz(state) }
        guard let newest = gravity.map(\.ts).max() else { return noBuzz(state) }
        // A replayed sync that brought nothing new must be inert.
        guard newest > state.lastProcessedGravityTs else { return noBuzz(state) }

        var next = state
        next.lastProcessedGravityTs = newest

        let bouts = detectSedentaryBouts(gravity, moveThresholdG: config.moveThresholdG,
                                         minMinutes: config.thresholdMinutes,
                                         smoothWindowSeconds: config.smoothWindowSeconds)
        guard let bout = bouts.max(by: { $0.end < $1.end }) else { return noBuzz(next) }

        // The bout must be CURRENT — a nudge about sitting that ended hours ago is noise.
        guard newest - bout.end <= maxGapS else { return noBuzz(next, bout) }
        guard mayBuzz(config, worn: worn, boutEndEpochSec: bout.end,
                      tzOffsetSec: tzOffsetSec) else { return noBuzz(next, bout) }

        // A bout that CONTINUES the last buzzed one re-nudges only on cadence; a genuinely new
        // bout — one starting after the last buzzed bout ended, so separated by real movement —
        // alerts on its own crossing rather than waiting out the timer.
        let continues = bout.start <= state.lastBuzzedBoutEnd
        let shouldBuzz = state.lastBuzzAt == 0 || !continues
            || (nowSec - state.lastBuzzAt >= config.reNudgeMinutes * 60)
        guard shouldBuzz else { return noBuzz(next, bout) }

        next.lastBuzzAt = nowSec
        next.lastBuzzedBoutStart = bout.start
        next.lastBuzzedBoutEnd = bout.end
        return SedentaryDecision(shouldBuzz: true, buzzLoops: config.buzzLoops,
                                 bout: bout, nextState: next)
    }
}
