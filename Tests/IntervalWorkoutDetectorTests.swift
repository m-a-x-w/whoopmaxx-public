import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// IntervalWorkoutDetector: the app-layer set/rest-cadence detector that catches strength /
/// interval sessions the frozen StrapAnalytics `AutoWorkoutDetector` structurally cannot (its
/// ≤90 s dip tolerance splits on every 2–3 min rest). Fixtures build synthetic HR at a 5 s cadence
/// around a resting HR of 60, so the elevated gate sits at 90 bpm (resting + 30).
final class IntervalWorkoutDetectorTests: XCTestCase {

    private let resting = 60
    private let t0 = 1_760_000_000   // arbitrary fixed anchor (unix seconds)

    /// 5 s-cadence samples over `[from, from+durationS]` (inclusive of both endpoints) at `bpm`.
    private func block(from: Int, durationS: Int, bpm: Int) -> [(ts: Int, bpm: Int)] {
        stride(from: from, through: from + durationS, by: 5).map { (ts: $0, bpm: bpm) }
    }

    /// A set/rest day: `sets` × (`setS` s at `workBpm`) separated by `restS` s at `restBpm`,
    /// on a continuous 5 s cadence (rests are LOW samples, not silence).
    private func intervalDay(sets: Int, setS: Int, restS: Int,
                             workBpm: Int, restBpm: Int = 70) -> [(ts: Int, bpm: Int)] {
        var out: [(ts: Int, bpm: Int)] = []
        var t = t0
        for i in 0..<sets {
            out += block(from: t, durationS: setS, bpm: workBpm)
            t += setS + 5
            if i < sets - 1 {
                out += block(from: t, durationS: restS - 5, bpm: restBpm)
                t += restS
            }
        }
        return out
    }

    // MARK: - Detection

    func testPushDayWithRestsIsDetected() throws {
        // 8 × (60 s at resting+40) with 150 s rests → ~25.5 min wall, work fraction ≈ 0.31.
        // The base detector sees eight 60 s fragments (every 150 s rest > its 90 s dip cap) and
        // finds nothing; the interval detector must own this exact shape.
        let hr = intervalDay(sets: 8, setS: 60, restS: 150, workBpm: resting + 40)
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: resting).isEmpty,
                      "precondition: the base detector cannot see a set/rest session")

        let out = IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting)
        XCTAssertEqual(out.count, 1)
        let w = try XCTUnwrap(out.first)
        XCTAssertEqual(w.startSec, t0, "span starts at the first elevated sample")
        XCTAssertEqual(w.endSec, hr.last!.ts, "span ends at the last elevated sample")
        XCTAssert((20...30).contains(w.durationMin), "duration was \(w.durationMin) min")
        XCTAssertEqual(w.avgBpm, resting + 40, "average is over ELEVATED samples only")
        XCTAssertEqual(w.peakBpm, resting + 40)
    }

    func testIsolatedSpikesAreNotDetected() {
        // Two 60 s spikes an hour apart: each is a valid micro-span, but the hour gap splits them
        // into two one-set sessions — both fail the ≥4-set and ≥20-min gates.
        let hr = block(from: t0, durationS: 60, bpm: resting + 40)
            + block(from: t0 + 90, durationS: 3_600 - 180, bpm: 70)
            + block(from: t0 + 3_600, durationS: 60, bpm: resting + 40)
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting).isEmpty)
    }

    func testSparseSetsFailTheFractionGate() {
        // 4 × 30 s sets spread over ~40 min (rests way past the 240 s chain gap): even if the
        // fraction gate (~0.05 here) were passed, the chain gap splits them — either way, nothing.
        let hr = intervalDay(sets: 4, setS: 30, restS: 770, workBpm: resting + 40)
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting).isEmpty)

        // Isolate the FRACTION gate itself: 6 × 30 s sets with rests just under the 240 s chain
        // ceiling → ONE session that passes the span (~22.6 min) and set-count (6) gates but has
        // an elevated fraction of only 180/1355 ≈ 0.13 < 0.25. Nothing may surface.
        let chained = intervalDay(sets: 6, setS: 30, restS: 230, workBpm: resting + 40)
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: chained, restingBpm: resting).isEmpty)
    }

    func testThreeSetsFailTheSetCountGate() {
        // 3 long sets over 21+ min pass span and fraction but not the ≥4-set signal.
        let hr = intervalDay(sets: 3, setS: 300, restS: 200, workBpm: resting + 40)
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting).isEmpty)
    }

    // MARK: - Saved-span exclusion

    func testQualifyingSessionOverlappingSavedSpanIsExcluded() {
        let hr = intervalDay(sets: 8, setS: 60, restS: 150, workBpm: resting + 40)
        XCTAssertEqual(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting).count, 1,
                       "precondition: the session qualifies without the saved span")
        // A saved workout overlapping the middle of the session suppresses the suggestion.
        let saved = [SavedWorkoutSpan(startSec: t0 + 600, endSec: t0 + 900)]
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting,
                                                     savedSpans: saved).isEmpty)
    }

    // MARK: - Merge with the base detector (base wins overlaps)

    func testSteadyRunYieldsNoSecondCandidateAfterMerge() {
        // A steady 15-min run at resting+40: the BASE detector's case. The interval detector must
        // not add a second overlapping candidate after the merge rule.
        let hr = block(from: t0, durationS: 15 * 60, bpm: resting + 40)
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: resting)
        XCTAssertEqual(base.count, 1, "precondition: the base detector owns a steady run")
        let interval = IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting)
        let merged = IntervalWorkoutDetector.merged(base: base, interval: interval)
        XCTAssertEqual(merged, base, "the merge must yield exactly the base candidate")
    }

    func testMergeDropsIntervalCandidateThatOverlapsBase() {
        // Short 80 s rests sit under BOTH detectors' tolerances (≤90 s dip / ≤240 s chain gap), so
        // each finds the same session — the merge must keep only the base reading.
        let hr = intervalDay(sets: 6, setS: 180, restS: 80, workBpm: resting + 40)
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: resting)
        let interval = IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting)
        XCTAssertEqual(base.count, 1, "precondition: base bridges the ≤90 s rests")
        XCTAssertEqual(interval.count, 1, "precondition: interval sees the set cadence too")
        let merged = IntervalWorkoutDetector.merged(base: base, interval: interval)
        XCTAssertEqual(merged, base, "base wins the overlap — one candidate, the base one")
    }

    func testMergeKeepsDisjointCandidatesFromBothDetectors() {
        // A steady run and a lift session an hour later don't overlap — both survive the merge.
        // The hour between them carries LOW samples (not silence): the base detector only closes
        // a span on sub-threshold SAMPLES, so an empty gap would bridge the two into one window.
        let run = block(from: t0, durationS: 15 * 60, bpm: resting + 40)
        let filler = block(from: t0 + 905, durationS: 3_590, bpm: 70)
        let lift = intervalDay(sets: 8, setS: 60, restS: 150, workBpm: resting + 40)
            .map { (ts: $0.ts + 5_400, bpm: $0.bpm) }
        let hr = run + filler + lift
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: resting)
        let interval = IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting)
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(interval.count, 1)
        let merged = IntervalWorkoutDetector.merged(base: base, interval: interval)
        XCTAssertEqual(merged.count, 2,
                       "disjoint candidates must both survive — base \(base) interval \(interval)")
    }

    // MARK: - Diagnostic evaluation (`sessions` / `microSpans` — the Signal Lab detection panel)

    func testSessionsSurfacesNearMissWithPerGateVerdicts() throws {
        // 3 long sets over 21+ min: `detect` finds nothing (set-count gate), but the diagnostic
        // evaluation must SHOW the session with exactly that one gate failing.
        let hr = intervalDay(sets: 3, setS: 300, restS: 200, workBpm: resting + 40)
        XCTAssertTrue(IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting).isEmpty)

        let evals = IntervalWorkoutDetector.sessions(hr: hr, restingBpm: resting)
        XCTAssertEqual(evals.count, 1)
        let e = try XCTUnwrap(evals.first)
        XCTAssertEqual(e.setCount, 3)
        XCTAssertTrue(e.wallOK, "21+ min wall span passes")
        XCTAssertFalse(e.setsOK, "3 sets < 4 — THE failing gate")
        XCTAssertTrue(e.fractionOK, "900/1310 s elevated passes 0.25")
        XCTAssertFalse(e.qualifies)
    }

    func testSessionsFractionGateVerdict() throws {
        // 6 × 30 s sets chained across 230 s rests: span + set count pass, fraction (~0.13) fails.
        let hr = intervalDay(sets: 6, setS: 30, restS: 230, workBpm: resting + 40)
        let e = try XCTUnwrap(IntervalWorkoutDetector.sessions(hr: hr, restingBpm: resting).first)
        XCTAssertTrue(e.wallOK)
        XCTAssertTrue(e.setsOK)
        XCTAssertFalse(e.fractionOK, "fraction was \(e.elevatedFraction)")
        XCTAssertFalse(e.qualifies)
    }

    func testDetectEqualsQualifyingSessions() {
        // The refactor contract: `detect` (no saved spans) is exactly `sessions` filtered to
        // `qualifies`, mapped to `DetectedWorkout` — same spans, stats and duration.
        let hr = intervalDay(sets: 8, setS: 60, restS: 150, workBpm: resting + 40)
            + block(from: t0 + 7_200, durationS: 60, bpm: resting + 40)   // an isolated 1-set spike
        let detected = IntervalWorkoutDetector.detect(hr: hr, restingBpm: resting)
        let fromEvals = IntervalWorkoutDetector.sessions(hr: hr, restingBpm: resting)
            .filter { $0.qualifies }
            .map { DetectedWorkout(startSec: $0.startSec, endSec: $0.endSec,
                                   avgBpm: $0.avgBpm, peakBpm: $0.peakBpm,
                                   durationMin: ($0.endSec - $0.startSec) / 60) }
        XCTAssertEqual(detected, fromEvals)
        XCTAssertEqual(detected.count, 1, "the near-miss spike must not qualify")
    }

    func testMicroSpansFindSetsAndDropBlips() {
        // One 60 s set, one 10 s blip (below the 30 s set floor), one 45 s set.
        let hr = block(from: t0, durationS: 60, bpm: resting + 40)
            + block(from: t0 + 65, durationS: 55, bpm: 70)
            + block(from: t0 + 125, durationS: 10, bpm: resting + 40)
            + block(from: t0 + 140, durationS: 55, bpm: 70)
            + block(from: t0 + 200, durationS: 45, bpm: resting + 40)
        let spans = IntervalWorkoutDetector.microSpans(hr: hr, restingBpm: resting)
        XCTAssertEqual(spans.map { $0.durationS }, [60, 45], "the 10 s blip is noise, not a set")
        XCTAssertEqual(spans.first?.start, t0)
    }
}
