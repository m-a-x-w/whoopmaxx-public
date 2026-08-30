import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// WorkoutTailTrimmer: the EPOC / low-floor post-pass on auto-detect candidates. The bug it fixes:
/// a low overnight resting HR (fixtures use 45) puts the elevated floor (resting + 30 = 75) below
/// normal post-workout daytime HR, so cooldown / EPOC drift at 80–95 bpm never exits the elevated
/// state and the base detector runs a ~50 min bout out to ~4 h. The trimmer anchors the span to
/// its own work band (resting + 0.6 × reserve) plus a 5 min grace on both ends.
final class WorkoutTailTrimmerTests: XCTestCase {

    private let t0 = 1_760_000_000   // arbitrary fixed anchor (unix seconds)

    /// 5 s-cadence samples over `[from, from+durationS]` (inclusive of both endpoints) at `bpm`.
    private func block(from: Int, durationS: Int, bpm: Int) -> [(ts: Int, bpm: Int)] {
        stride(from: from, through: from + durationS, by: 5).map { (ts: $0, bpm: bpm) }
    }

    /// THE user-confirmed shape: resting 45 (floor 75), a 50-min bout peaking 150, then 3 h of
    /// cooldown / EPOC drift at 80–95 bpm — every drift sample above the floor, so the base
    /// detector never closes the span. Drift alternates 80/95 per sample (both below the
    /// work mark of 45 + 0.6 × 105 = 108).
    private func lowFloorDriftDay(boutS: Int = 50 * 60,
                                  driftS: Int = 3 * 3_600) -> [(ts: Int, bpm: Int)] {
        block(from: t0, durationS: boutS, bpm: 150)
            + block(from: t0 + boutS + 5, durationS: driftS, bpm: 80).enumerated()
                .map { (ts: $0.element.ts, bpm: $0.offset % 2 == 0 ? 80 : 95) }
    }

    // MARK: - The EPOC / low-floor case (tail trim)

    func testLowFloorDriftTailIsTrimmedToTheBout() throws {
        let hr = lowFloorDriftDay()
        // Precondition: the frozen base detector emits ONE huge candidate spanning bout + drift.
        let base = AutoWorkoutDetector.detect(hr: hr, restingBpm: 45)
        XCTAssertEqual(base.count, 1)
        let raw = try XCTUnwrap(base.first)
        XCTAssertGreaterThan(raw.durationMin, 200, "precondition: the raw span runs ~4 h")

        let outcome = WorkoutTailTrimmer.trim(raw, kind: .base, hr: hr, restingBpm: 45)
        guard case .trimmed(let trimRaw, let trimmed, let workMark) = outcome else {
            return XCTFail("expected .trimmed, got \(outcome)")
        }
        XCTAssertEqual(trimRaw, raw)
        XCTAssertEqual(workMark, 108, "45 + 0.6 × (150 − 45)")
        XCTAssertEqual(trimmed.startSec, t0, "the start held work — untouched")
        XCTAssertEqual(trimmed.endSec, t0 + 50 * 60 + WorkoutTailTrimmer.cooldownGraceS,
                       "the end anchors to the last work sample + the 5 min grace")
        XCTAssertLessThan(trimmed.durationMin, 70, "a ~50 min bout must read as ~a bout")
        XCTAssertGreaterThanOrEqual(Double(trimmed.durationMin),
                                    AutoWorkoutDetector.minSustainedMin,
                                    "the trimmed bout still qualifies")
        XCTAssertEqual(outcome.survivor, trimmed)
    }

    func testPreWorkoutWalkTrimsTheStartToo() throws {
        // 20 min walking to the gym at 78–85 (above the 75 floor, below the 108 work mark)
        // prepended to the same bout + drift: BOTH ends must trim symmetrically.
        let walkS = 20 * 60
        let walk = block(from: t0 - walkS - 5, durationS: walkS, bpm: 78).enumerated()
            .map { (ts: $0.element.ts, bpm: $0.offset % 2 == 0 ? 78 : 85) }
        let hr = walk + lowFloorDriftDay()
        let raw = try XCTUnwrap(AutoWorkoutDetector.detect(hr: hr, restingBpm: 45).first)
        XCTAssertEqual(raw.startSec, walk.first!.ts, "precondition: the raw span starts in the walk")

        let outcome = WorkoutTailTrimmer.trim(raw, kind: .base, hr: hr, restingBpm: 45)
        let trimmed = try XCTUnwrap(outcome.survivor)
        XCTAssertEqual(trimmed.startSec, t0 - WorkoutTailTrimmer.cooldownGraceS,
                       "the start anchors to the first work sample − the grace")
        XCTAssertEqual(trimmed.endSec, t0 + 50 * 60 + WorkoutTailTrimmer.cooldownGraceS)
    }

    // MARK: - Non-trimming shapes

    func testSteadyRunIsUntrimmed() throws {
        // A steady 40-min run at 125–135, resting 50: work mark = 50 + 0.6 × 85 = 101, and every
        // sample holds ≥ 125 — the whole span IS work, nothing to trim.
        let hr = block(from: t0, durationS: 40 * 60, bpm: 125).enumerated()
            .map { (ts: $0.element.ts, bpm: $0.offset % 2 == 0 ? 125 : 135) }
        let raw = try XCTUnwrap(AutoWorkoutDetector.detect(hr: hr, restingBpm: 50).first)
        let outcome = WorkoutTailTrimmer.trim(raw, kind: .base, hr: hr, restingBpm: 50)
        XCTAssertEqual(outcome, .unchanged(raw))
        XCTAssertEqual(outcome.survivor, raw)
    }

    func testFlatSpanIsUnchangedByTheDegenerateGuard() throws {
        // 30 min at 78–80, resting 45: elevated (floor 75) so the base detector fires, but the
        // peak (80) clears resting by ≤ flatPeakMarginBPM (40) — no work band exists, so the
        // guard returns the candidate unchanged rather than inventing a trim.
        let hr = block(from: t0, durationS: 30 * 60, bpm: 78).enumerated()
            .map { (ts: $0.element.ts, bpm: $0.offset % 2 == 0 ? 78 : 80) }
        let raw = try XCTUnwrap(AutoWorkoutDetector.detect(hr: hr, restingBpm: 45).first)
        let outcome = WorkoutTailTrimmer.trim(raw, kind: .base, hr: hr, restingBpm: 45)
        XCTAssertEqual(outcome, .unchanged(raw))
    }

    // MARK: - Revalidation

    func testCandidateShrinkingBelowMinSustainedIsDropped() throws {
        // A 5-min spike at 150 followed by 3 h of drift: the raw span passes the base detector's
        // 12-min gate only BECAUSE of the drift. Trimmed (5 min + 5 min grace = 10 min) it no
        // longer sustains 12 min — the trimmer must drop it, not emit a 10-min candidate.
        let hr = lowFloorDriftDay(boutS: 5 * 60)
        let raw = try XCTUnwrap(AutoWorkoutDetector.detect(hr: hr, restingBpm: 45).first)
        let outcome = WorkoutTailTrimmer.trim(raw, kind: .base, hr: hr, restingBpm: 45)
        guard case .dropped(let dropRaw, let workMark) = outcome else {
            return XCTFail("expected .dropped, got \(outcome)")
        }
        XCTAssertEqual(dropRaw, raw)
        XCTAssertEqual(workMark, 108)
        XCTAssertNil(outcome.survivor)
    }

    func testCanonicalIntervalSessionSurvivesTheTrimUntouched() throws {
        // The interval detector's canonical strength day (rests BELOW the floor — the normal-floor
        // world): 8 × 60 s at resting+40 with 150 s rests at 70, resting 60. Peak (100) clears
        // resting by exactly flatPeakMarginBPM (40) — the degenerate guard applies and the
        // candidate passes through unchanged.
        var hr: [(ts: Int, bpm: Int)] = []
        var t = t0
        for i in 0..<8 {
            hr += block(from: t, durationS: 60, bpm: 100)
            t += 65
            if i < 7 { hr += block(from: t, durationS: 145, bpm: 70); t += 150 }
        }
        let raw = try XCTUnwrap(IntervalWorkoutDetector.detect(hr: hr, restingBpm: 60).first)
        let outcome = WorkoutTailTrimmer.trim(raw, kind: .interval, hr: hr, restingBpm: 60)
        XCTAssertEqual(outcome, .unchanged(raw))
    }
}
