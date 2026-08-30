import Foundation
import StrapProtocol

/// A workout the app SUGGESTS, for the user to confirm or dismiss.
public struct DetectedWorkout: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    public let durationMin: Int
    public init(startSec: Int, endSec: Int, avgBpm: Int, peakBpm: Int, durationMin: Int) {
        self.startSec = startSec; self.endSec = endSec
        self.avgBpm = avgBpm; self.peakBpm = peakBpm; self.durationMin = durationMin
    }
}

/// A workout the user already has, so it is never suggested again.
public struct SavedWorkoutSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public init(startSec: Int, endSec: Int) { self.startSec = startSec; self.endSec = endSec }
}

/// Suggests workouts from heart rate alone, optionally confirmed by motion.
///
/// Deliberately separate from `WorkoutDetector`, and deliberately more forgiving. That one decides
/// what a workout WAS for scoring; this one asks "did you mean to log this?" — a question where
/// missing a real session costs more than offering one the user dismisses in a tap.
public enum AutoWorkoutDetector {

    /// How far above resting a sample must sit. Higher than the scoring detector's margin: a
    /// suggestion should be obviously a workout, not a brisk walk.
    public static let elevatedMarginBPM = 30
    public static let minSustainedMin: Double = 12.0
    /// A sub-threshold run shorter than this is bridged rather than ending the span.
    public static let maxDipS = 90
    /// Spans closer than this become one suggestion.
    public static let mergeGapS = 5 * 60
    public static let defaultRestingHR = 60
    /// Mean motion a window must show when a motion series is supplied.
    public static let motionConfirmMean = 0.05

    public struct MotionPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
        public init(ts: Int, intensity: Double) { self.ts = ts; self.intensity = intensity }
    }

    public static func motionPoints(_ gravity: [GravitySample]) -> [MotionPoint] {
        Motion.activitySeries(gravity).map { MotionPoint(ts: $0.ts, intensity: $0.intensity) }
    }

    /// Find candidate workouts.
    ///
    /// Motion is CONFIRMATION, not a requirement — it is only applied when a series is supplied.
    /// Suggesting from heart rate alone when there is no motion data is better than suggesting
    /// nothing, because the user is the one who decides.
    public static func detect(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [MotionPoint]? = nil,
                              savedSpans: [SavedWorkoutSpan] = []) -> [DetectedWorkout] {
        let seg = hr.sorted { $0.ts < $1.ts }
        guard !seg.isEmpty else { return [] }
        let floor = (restingBpm ?? defaultRestingHR) + elevatedMarginBPM

        // Grow spans over elevated samples, tolerating brief dips. A workout is not over because
        // someone paused at a traffic light, and closing the span there would leave two short
        // fragments that each miss the duration floor.
        var spans: [(start: Int, end: Int)] = []
        var spanStart: Int?
        var spanEnd = 0
        var dipStart: Int?

        func closeSpan() {
            if let s = spanStart, Double(spanEnd - s) >= minSustainedMin * 60.0 {
                spans.append((s, spanEnd))
            }
            spanStart = nil
            dipStart = nil
        }

        for sample in seg {
            if sample.bpm >= floor {
                if spanStart == nil { spanStart = sample.ts }
                spanEnd = sample.ts
                dipStart = nil
            } else if spanStart != nil {
                if dipStart == nil { dipStart = sample.ts }
                if let d = dipStart, sample.ts - d > maxDipS { closeSpan() }
            }
        }
        closeSpan()
        guard !spans.isEmpty else { return [] }

        var merged: [(start: Int, end: Int)] = []
        var curStart = spans[0].start
        var curEnd = spans[0].end
        for k in 1..<spans.count {
            let next = spans[k]
            if next.start - curEnd < mergeGapS {
                curEnd = max(curEnd, next.end)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.start
                curEnd = next.end
            }
        }
        merged.append((curStart, curEnd))

        let motionSeries = (motion?.isEmpty ?? true) ? nil : motion
        var results: [DetectedWorkout] = []
        for (start, end) in merged {
            // Never re-suggest something the user already has. Overlap, not equality: a saved
            // workout rarely shares its exact boundaries with a fresh detection, and an
            // equality check would offer the same session back every sync.
            if savedSpans.contains(where: { overlaps(start, end, $0.startSec, $0.endSec) }) { continue }

            let window = seg.filter { $0.ts >= start && $0.ts <= end }
            guard !window.isEmpty else { continue }

            if let motionSeries {
                let inWin = motionSeries.filter { $0.ts >= start && $0.ts <= end }.map(\.intensity)
                let meanMotion = inWin.isEmpty ? 0 : inWin.reduce(0, +) / Double(inWin.count)
                if meanMotion < motionConfirmMean { continue }
            }

            let bpms = window.map(\.bpm)
            results.append(DetectedWorkout(
                startSec: start, endSec: end,
                avgBpm: Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded()),
                peakBpm: bpms.max() ?? 0,
                durationMin: (end - start) / 60))
        }
        return results
    }

    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart <= bEnd && bStart <= aEnd
    }
}

// MARK: - Breath pacing

public enum BreathPhase: String, Equatable, Sendable { case inhale, exhale }

/// One haptic cue in a paced-breathing session.
public struct BreathCue: Equatable, Sendable {
    public let offsetMs: Int
    public let phase: BreathPhase
    /// Buzz repetitions. Inhale and exhale differ so the two are distinguishable without looking.
    public let loops: Int
    public init(offsetMs: Int, phase: BreathPhase, loops: Int) {
        self.offsetMs = offsetMs; self.phase = phase; self.loops = loops
    }
}

/// Builds the cue schedule for a paced-breathing session.
public enum BreathPacer {
    public static let inhaleLoops: Int = 1
    public static let exhaleLoops: Int = 2

    /// Inhale takes less of the cycle than exhale. A longer exhale is the point of paced breathing
    /// — it is the half that engages the parasympathetic response — so an even split would make
    /// the exercise a metronome rather than an intervention.
    public static let defaultInhaleFraction: Double = 0.4

    public static let minBpm: Double = 3.0
    public static let maxBpm: Double = 12.0

    /// The whole schedule up front, as offsets from session start.
    ///
    /// Precomputed rather than ticked: a timer that recalculates each cue accumulates drift across
    /// a ten-minute session, and a breathing pace that slides is worse than no pace at all.
    /// Offsets are integers so they are exact and identical on every platform.
    public static func schedule(bpm: Double,
                                inhaleFraction: Double = defaultInhaleFraction,
                                cycles: Int) -> [BreathCue] {
        guard cycles >= 1 else { return [] }
        let safeBpm = min(max(bpm, minBpm), maxBpm)
        let frac = min(max(inhaleFraction, 0.1), 0.9)
        let cycleMs = Int((60_000.0 / safeBpm).rounded())
        let inhaleMs = Int((Double(cycleMs) * frac).rounded())

        var out: [BreathCue] = []
        out.reserveCapacity(cycles * 2)
        for c in 0..<cycles {
            let base = c * cycleMs
            out.append(BreathCue(offsetMs: base, phase: .inhale, loops: inhaleLoops))
            out.append(BreathCue(offsetMs: base + inhaleMs, phase: .exhale, loops: exhaleLoops))
        }
        return out
    }

    public static func sessionDurationMs(bpm: Double, cycles: Int) -> Int {
        guard cycles >= 1 else { return 0 }
        return Int((60_000.0 / min(max(bpm, minBpm), maxBpm)).rounded()) * cycles
    }
}
