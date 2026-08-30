import XCTest
import StrapProtocol
import StrapAnalytics
@testable import whoopmaxx

/// 030 — the coverage gate on per-stage HRV.
///
/// THE HAZARD, stated once. The stored `stagesJSON` is `SleepStagingV2` output, and V2 asserts a stage
/// across spans where NO channel had data: its epoch loop skips an epoch with neither HR nor gravity
/// (`SleepStagingV2.swift:286`) and the tiling that follows (`:118-131`) stretches the preceding label to
/// the next STAGED epoch's start. The hypnogram therefore claims stage over clock the strap never
/// watched, and nothing in the JSON marks the stretch.
///
/// That makes a naive per-stage HRV the single most dangerous number this app could compute. On the real
/// corpus the night ending 2026-08-02 carries a 176-minute "deep" segment holding 570 in-range beats
/// clustered at its EDGES and nothing across the middle — far more than the 20 beats `HRVAnalyzer` asks
/// for. A bucketing that only counted beats would return a confident deep-sleep rMSSD computed from ten
/// minutes of data and attributed to nearly three hours the strap was not reading.
///
/// These tests drive `HRVByStage` directly, because it is pure by construction — spans and R-R in,
/// readings out, no store and no clock. They pin that a span the strap did not watch produces ABSENCE
/// with a stated reason, never a number and never a zero.
final class HRVByStageCoverageTests: XCTestCase {

    /// Midnight-ish anchor on the 30 s staging grid, so epoch arithmetic in the fixtures is exact.
    private let t0 = 1_800_000_000

    /// A physiologically ordinary beat train over `[from, to)` at ~60 bpm, jittered deterministically so
    /// successive differences are non-zero (an rMSSD of exactly 0 would be indistinguishable from a
    /// degenerate input and would prove nothing).
    private func beats(from: Int, to: Int, seed: Int = 7) -> [RRInterval] {
        var out: [RRInterval] = []
        var x = seed
        var t = from
        while t < to {
            x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            let jitter = x % 80 - 40                    // ±40 ms
            out.append(RRInterval(ts: t, rrMs: 1_000 + jitter))
            t += 1
        }
        return out
    }

    // MARK: - The phantom span

    /// THE CENTRAL CASE, built to the real corpus night's shape: one long "deep" span whose beats sit only
    /// at the edges, with a multi-hour hole across the middle that the hypnogram silently claims.
    ///
    /// The stage has far more than `HRVAnalyzer.minBeats` beats and far more than `minStageSec` of claimed
    /// clock. Only epoch OCCUPANCY separates it from a real night — which is exactly why the gate is
    /// measured that way rather than by beat count.
    ///
    /// Turns red: drop the `ratio >= minEpochCoverage` guard, or measure coverage by counting beats.
    func testAStageClaimedOverAHoleTheStrapNeverWatchedReportsAbsence() {
        let start = t0
        let end = start + 176 * 60                       // 176 minutes, the corpus segment's length
        // 20 minutes of dense beats at each edge, ~136 minutes of nothing in between.
        let rr = beats(from: start, to: start + 20 * 60) + beats(from: end - 20 * 60, to: end, seed: 11)

        let night = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .deep)], rr: rr)
        let deep = night[.deep]

        XCTAssertNil(deep.rmssd, "a span the strap did not watch must produce NO number")
        XCTAssertEqual(deep.verdict, .notObserved, "…and must say which way it failed")
        XCTAssertEqual(deep.admittedSec, 0, "the phantom span contributes no clock")
        XCTAssertEqual(deep.claimedSec, 176 * 60, "…while the hypnogram's claim is reported in full")
        XCTAssertLessThan(deep.coverage, HRVByStage.minEpochCoverage)
        // The trap it walked past: there was never a shortage of beats.
        XCTAssertGreaterThan(rr.count, HRVAnalyzer.minBeats * 10)
    }

    /// The same span, watched throughout, DOES report — otherwise the gate would simply be a mute button
    /// and the test above would prove nothing about it.
    func testTheSameSpanWatchedThroughoutIsMeasured() {
        let start = t0
        let end = start + 176 * 60
        let night = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .deep)],
                                       rr: beats(from: start, to: end))
        let deep = night[.deep]

        XCTAssertEqual(deep.verdict, .measured)
        let rmssd = try? XCTUnwrap(deep.rmssd)
        XCTAssertGreaterThan(rmssd ?? 0, 0)
        XCTAssertEqual(deep.admittedSec, 176 * 60)
        XCTAssertEqual(deep.coverage, 1.0, accuracy: 0.001)
        XCTAssertEqual(deep.admittedFraction, 1.0, accuracy: 0.001)
    }

    // MARK: - Partial admission

    /// A stage with one real block and one phantom block reports the REAL one, and says so: the number
    /// speaks for `admittedSec`, not for `claimedSec`. Blanking it would throw away real measurement;
    /// printing it bare would let the reader assume it covers the whole claim.
    ///
    /// Turns red: admit spans stage-wide on a pooled coverage ratio instead of span by span.
    func testAStageWithOneRealBlockAndOnePhantomReportsOnlyTheRealOne() {
        let realStart = t0
        let realEnd = realStart + 40 * 60
        let phantomStart = realEnd + 60 * 60
        let phantomEnd = phantomStart + 120 * 60

        let night = HRVByStage.analyze(
            spans: [.init(start: realStart, end: realEnd, stage: .deep),
                    .init(start: phantomStart, end: phantomEnd, stage: .deep)],
            rr: beats(from: realStart, to: realEnd))
        let deep = night[.deep]

        XCTAssertEqual(deep.verdict, .measured)
        XCTAssertNotNil(deep.rmssd)
        XCTAssertEqual(deep.admittedSec, 40 * 60, "only the watched block backs the number")
        XCTAssertEqual(deep.claimedSec, 160 * 60, "the hypnogram's full claim is still reported")
        XCTAssertLessThan(deep.admittedFraction, 1.0,
                          "the qualification must travel with the value, or a surface cannot caption it")
    }

    // MARK: - Absence is never zero

    /// Every withheld reading is nil with a verdict — never 0.0. A stage rendered as "0 ms" would be a
    /// measurement, and a strikingly abnormal one.
    func testEveryWithheldStageIsNilAndNeverZero() {
        let start = t0
        // Deep is claimed but unwatched; REM is never labelled at all; light is too brief to judge.
        let night = HRVByStage.analyze(
            spans: [.init(start: start, end: start + 120 * 60, stage: .deep),
                    .init(start: start + 120 * 60, end: start + 120 * 60 + 120, stage: .light)],
            rr: [])

        XCTAssertNil(night[.deep].rmssd)
        XCTAssertEqual(night[.deep].verdict, .notObserved)
        XCTAssertNil(night[.rem].rmssd)
        XCTAssertEqual(night[.rem].verdict, .notLabelled, "a stage never labelled is not a stage of zero")
        XCTAssertNil(night[.light].rmssd)
        XCTAssertEqual(night[.light].verdict, .tooLittleTime)

        for reading in night.readings {
            XCTAssertNotEqual(reading.rmssd, 0, "\(reading.stage) must never report a zero rMSSD")
        }
    }

    /// All four buckets are always present, so a surface can lay out a fixed table without inventing a
    /// placeholder row — and an empty night is four absences, not four zeros.
    func testAnEmptyNightIsFourAbsences() {
        let night = HRVByStage.analyze(spans: [], rr: [])
        XCTAssertEqual(night.readings.count, HRVByStage.Stage.allCases.count)
        for reading in night.readings {
            XCTAssertNil(reading.rmssd)
            XCTAssertEqual(reading.verdict, .notLabelled)
            XCTAssertEqual(reading.claimedSec, 0)
            XCTAssertEqual(reading.admittedSec, 0)
        }
    }

    // MARK: - The spectrum is stricter still

    /// A span admitted for the time domain is NOT automatically admitted for the frequency domain: the
    /// Lomb-Scargle time base is the cumulative sum of the intervals, so missing clock does not blank the
    /// spectrum, it SHIFTS it — silently, with no nil to warn anyone.
    ///
    /// Turns red: reuse `minEpochCoverage` for `bands`.
    func testASpanAdmittedForRmssdCanStillBeRefusedASpectrum() {
        XCTAssertGreaterThan(HRVByStage.minBandCoverage, HRVByStage.minEpochCoverage,
                             "the spectral floor must be the stricter of the two")

        let start = t0
        let end = start + 60 * 60
        // ~70 % occupancy: over the time-domain floor, under the spectral one. Beats in the first 42
        // minutes only.
        let night = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .rem)],
                                       rr: beats(from: start, to: start + 42 * 60))
        let rem = night[.rem]

        XCTAssertEqual(rem.verdict, .measured, "70 % clears the time-domain bar")
        XCTAssertNotNil(rem.rmssd)
        XCTAssertNil(rem.bands, "…but not the spectral one")
        XCTAssertNil(rem.bandSpanSec, "and no span length is quoted for a spectrum that does not exist")
    }

    // MARK: - Boundaries

    /// Half-open spans: a beat landing exactly on a boundary belongs to the later span only, so no beat is
    /// counted into two stages.
    func testSpansAreHalfOpenSoNoBeatIsCountedTwice() {
        let start = t0
        let mid = start + 30 * 60
        let end = mid + 30 * 60
        let rr = beats(from: start, to: end)

        let night = HRVByStage.analyze(spans: [.init(start: start, end: mid, stage: .deep),
                                               .init(start: mid, end: end, stage: .rem)], rr: rr)
        XCTAssertEqual(night[.deep].claimedSec + night[.rem].claimedSec, end - start)
        XCTAssertEqual(night[.deep].verdict, .measured)
        XCTAssertEqual(night[.rem].verdict, .measured)
    }

    /// `wake` and `awake` are one bucket. The stager and the importer spell the same state differently,
    /// and two wake rows for one night would be a reporting artefact, not a finding.
    func testWakeAndAwakeCollapseToOneBucket() {
        XCTAssertEqual(HRVByStage.Stage(.wake), .wake)
        XCTAssertEqual(HRVByStage.Stage(.awake), .wake)
    }
}
