import XCTest
import StrapProtocol
import StrapAnalytics
@testable import whoopmaxx

/// 030 — the `HRVByStage` CONTRACT, as distinct from `HRVByStageCoverageTests`.
///
/// The sibling file pins the hazard: a `SleepStagingV2` span claimed over clock the strap never watched must
/// produce absence. This file pins everything a SURFACE has to be able to rely on when it renders the
/// result — the decode inverse, the shape of the output, the anchoring of the estimator, the determinism of
/// the reported spectrum, and the floors themselves.
///
/// Why the floors get their own test. `minEpochCoverage` was found set to `0.0` in this engine's first
/// draft while every comment around it said 0.60. That is not a loose gate, it is NO gate: every admission
/// check is `ratio >= minEpochCoverage`, so at zero the phantom span is admitted like any other and the
/// engine reports a confident deep-sleep rMSSD over hours of silence. Nothing else in the file changes
/// appearance when that happens — the comments still describe a bar that is not there. So the value is
/// pinned as a literal here, and pinned again behaviourally at its exact boundary below.
final class HRVByStageTests: XCTestCase {

    /// Anchor on the absolute 30 s staging grid (1_800_000_000 is an exact multiple of 30), so every epoch
    /// count in these fixtures is exact rather than off-by-one-dependent.
    private let t0 = 1_800_000_000

    /// A ~60 bpm beat train over `[from, to)`, one row per second, deterministically jittered so successive
    /// differences are non-zero. All values land well inside `HRVAnalyzer.rrMinMs...rrMaxMs` and inside
    /// Malik's 20 % relative threshold, so the cleaner keeps them and the fixtures test THIS engine's gates
    /// rather than the vendored cleaner's.
    private func beats(from: Int, to: Int, seed: Int = 3) -> [RRInterval] {
        var out: [RRInterval] = []
        var x = seed
        for t in stride(from: from, to: to, by: 1) {
            x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            out.append(RRInterval(ts: t, rrMs: 1_000 + (x % 80 - 40)))
        }
        return out
    }

    // MARK: - The absence contract

    /// THE TASK-MANDATED CASE: a stage span with no R-R inside it yields ABSENCE, not a number.
    ///
    /// Paired with a sibling stage that IS measured from the same call, because an engine that returned
    /// nothing for everything would pass a bare absence assertion while being useless. The point is that the
    /// two stages are resolved independently and one of them declines.
    func testAStageSpanWithNoRRInsideItYieldsAbsenceWhileItsSiblingIsMeasured() {
        let lightStart = t0
        let lightEnd = lightStart + 3_600
        let deepStart = lightEnd                  // contiguous, as the hypnogram tiles it
        let deepEnd = deepStart + 3_600

        let night = HRVByStage.analyze(
            spans: [.init(start: lightStart, end: lightEnd, stage: .light),
                    .init(start: deepStart, end: deepEnd, stage: .deep)],
            rr: beats(from: lightStart, to: lightEnd))   // NOTHING in the deep hour

        let light = night[.light]
        XCTAssertEqual(light.verdict, .measured, "the watched hour must still report")
        XCTAssertNotNil(light.rmssd)

        let deep = night[.deep]
        XCTAssertNil(deep.rmssd, "a stage with no R-R inside it has no number")
        XCTAssertNotEqual(deep.rmssd, 0, "…and absence is never a zero, which would read as a measurement")
        XCTAssertEqual(deep.verdict, .notObserved)
        XCTAssertEqual(deep.coverage, 0)
        XCTAssertEqual(deep.admittedSec, 0)
        XCTAssertEqual(deep.claimedSec, 3_600, "the hypnogram's claim is still reported in full")
        XCTAssertEqual(deep.windows, 0)
        XCTAssertEqual(deep.cleanBeats, 0)
        XCTAssertNil(deep.bands)
        XCTAssertNil(deep.bandSpanSec)
    }

    /// `.measured` is the ONLY verdict that carries a number, in both directions. A surface that switches on
    /// the verdict must never have to also nil-check, and must never find a verdict-carrying absence with a
    /// value hiding in it.
    func testMeasuredIsTheOnlyVerdictThatEverCarriesANumber() {
        let night = HRVByStage.analyze(
            spans: [.init(start: t0, end: t0 + 3_600, stage: .light),            // measured
                    .init(start: t0 + 3_600, end: t0 + 7_200, stage: .deep),     // claimed, unwatched
                    .init(start: t0 + 7_200, end: t0 + 7_320, stage: .wake)],    // too brief to judge
            rr: beats(from: t0, to: t0 + 3_600))

        for reading in night.readings {
            if reading.verdict == .measured {
                XCTAssertNotNil(reading.rmssd, "\(reading.stage): .measured must carry a value")
            } else {
                XCTAssertNil(reading.rmssd, "\(reading.stage): \(reading.verdict) must carry no value")
            }
        }
        // And each absence names a DIFFERENT reason — the vocabulary is not decorative.
        XCTAssertEqual(night[.light].verdict, .measured)
        XCTAssertEqual(night[.deep].verdict, .notObserved)
        XCTAssertEqual(night[.wake].verdict, .tooLittleTime)
        XCTAssertEqual(night[.rem].verdict, .notLabelled)
    }

    // MARK: - The floors

    /// The literal values, pinned. See the class doc for the regression this exists to catch.
    func testTheDocumentedFloorsAreTheActualFloors() {
        XCTAssertEqual(HRVByStage.minEpochCoverage, 0.60, accuracy: 1e-9,
                       "a zero here silently deletes the phantom-span gate")
        XCTAssertEqual(HRVByStage.minBandCoverage, 0.80, accuracy: 1e-9)
        XCTAssertEqual(HRVByStage.epochSec, 30, "must match the grid SleepStagingV2 stages on")
        XCTAssertEqual(HRVByStage.windowSec, 300, "must match SleepStaging.sessionAvgHRV's window")
        XCTAssertEqual(HRVByStage.minStageSec, 300)
        XCTAssertEqual(HRVByStage.minSpanEpochs, 2)
    }

    /// The floor behaviourally, at its exact boundary: 60 covered epochs of 100 is admitted, 59 is not.
    ///
    /// A literal-only pin would still pass if the comparison were rewritten to always succeed, so the bar is
    /// also exercised one epoch either side of itself. `>=` is the intended sense — a span that covers
    /// exactly the floor is watched enough.
    func testTheCoverageFloorAdmitsAtExactlySixtyPercentAndRefusesJustBelow() {
        let start = t0
        let end = start + 3_000                      // 100 whole epochs

        // 60 epochs covered → ratio is exactly the floor.
        let atFloor = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .deep)],
                                         rr: beats(from: start, to: start + 1_800))[.deep]
        XCTAssertEqual(atFloor.coverage, 0.60, accuracy: 1e-9)
        XCTAssertEqual(atFloor.verdict, .measured, "exactly at the floor is admitted")
        XCTAssertNotNil(atFloor.rmssd)
        XCTAssertEqual(atFloor.admittedSec, 3_000)

        // 59 epochs covered → one epoch under.
        let belowFloor = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .deep)],
                                            rr: beats(from: start, to: start + 1_770))[.deep]
        XCTAssertEqual(belowFloor.coverage, 0.59, accuracy: 1e-9)
        XCTAssertEqual(belowFloor.verdict, .notObserved, "one epoch under the floor is refused")
        XCTAssertNil(belowFloor.rmssd)
        XCTAssertEqual(belowFloor.admittedSec, 0)
    }

    // MARK: - The decode inverse

    /// `spans(fromStagesJSON:)` is the read side of `DayEngine.encodeStages`, so it is tested against
    /// the REAL writer rather than a hand-written JSON string — a hand-written fixture would only prove the
    /// two agree with my typing, not that they agree with each other.
    func testSpansRoundTripThroughTheRealStagesEncoder() {
        let segments = [StageSegment(start: t0, end: t0 + 1_800, stage: "light"),
                        StageSegment(start: t0 + 1_800, end: t0 + 3_600, stage: "deep"),
                        StageSegment(start: t0 + 3_600, end: t0 + 4_200, stage: "rem"),
                        StageSegment(start: t0 + 4_200, end: t0 + 4_500, stage: "wake")]
        // Passed through as the Optional the encoder returns and the decoder accepts — a nil encode would
        // surface as an empty span list and fail the count below, which is the report we want anyway.
        let spans = HRVByStage.spans(fromStagesJSON: DayEngine.encodeStages(segments))

        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans.map(\.stage), [.light, .deep, .rem, .wake], "in stored order")
        XCTAssertEqual(spans.map(\.start), segments.map(\.start))
        XCTAssertEqual(spans.map(\.end), segments.map(\.end))
    }

    /// The decode drops what `SleepStage.decode` drops, segment by segment: an unknown token and a
    /// non-positive span vanish while their neighbours survive. A future writer emitting a new label must
    /// degrade to a GAP in the hypnogram, never to a wrong stage.
    func testUnknownTokensAndEmptySpansAreDroppedNotGuessed() {
        let json = DayEngine.encodeStages([
            StageSegment(start: t0, end: t0 + 1_800, stage: "deep"),
            StageSegment(start: t0 + 1_800, end: t0 + 3_600, stage: "n3"),      // not in the vocabulary
            StageSegment(start: t0 + 3_600, end: t0 + 3_600, stage: "rem"),     // zero length
            StageSegment(start: t0 + 3_600, end: t0 + 5_400, stage: "awake")])  // importer's spelling

        let spans = HRVByStage.spans(fromStagesJSON: json)
        XCTAssertEqual(spans.map(\.stage), [.deep, .wake],
                       "the unknown token and the empty span are gaps; 'awake' buckets onto wake")

        XCTAssertEqual(HRVByStage.spans(fromStagesJSON: nil), [])
        XCTAssertEqual(HRVByStage.spans(fromStagesJSON: "not json"), [])
    }

    // MARK: - Output shape

    /// Always four readings, always in `Stage.allCases` order, so a surface can lay out a fixed table and
    /// index it positionally without inventing placeholder rows.
    func testTheReportingOrderIsFixedAndAllFourStagesArePresent() {
        XCTAssertEqual(HRVByStage.Stage.allCases, [.deep, .rem, .light, .wake],
                       "deep first: it is the stage the question is usually about")
        let night = HRVByStage.analyze(spans: [.init(start: t0, end: t0 + 3_600, stage: .rem)],
                                       rr: beats(from: t0, to: t0 + 3_600))
        XCTAssertEqual(night.readings.map(\.stage), HRVByStage.Stage.allCases)
        for stage in HRVByStage.Stage.allCases {
            XCTAssertEqual(night[stage].stage, stage, "the subscript must return the stage asked for")
        }
    }

    /// `admittedFraction` is the ratio a caption is built from, including its degenerate case: a stage that
    /// claims no clock is 0, not a divide-by-zero and not 1.
    func testAdmittedFractionIsSafeWhenNothingIsClaimed() {
        let night = HRVByStage.analyze(spans: [], rr: [])
        for reading in night.readings {
            XCTAssertEqual(reading.admittedFraction, 0)
            XCTAssertEqual(reading.coverage, 0)
        }
    }

    // MARK: - Estimator anchoring

    /// Windows tumble from the SPAN's start, not from the session's or from an absolute grid.
    ///
    /// The fixture is a single 300 s span deliberately offset by half a window (150 s) from the grid. Anchored
    /// at the span, it is exactly ONE window. Anchored anywhere absolute, the same 300 seconds straddle two
    /// windows of 150 s — each still holding ~150 beats, comfortably over `HRVAnalyzer.minBeats`, so the
    /// mis-anchored version would quietly report two windows and a mean of two half-width estimates.
    ///
    /// Turns red: anchor `stageWindowRmssds` on anything but `span.start`.
    func testWindowsAreAnchoredOnTheSpanNotOnAnAbsoluteGrid() {
        let start = t0 + 150
        let end = start + 300
        let deep = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .deep)],
                                      rr: beats(from: start, to: end))[.deep]

        XCTAssertEqual(deep.verdict, .measured)
        XCTAssertEqual(deep.windows, 1, "one span-width window, not two half-width ones")
        XCTAssertEqual(deep.admittedSec, 300)
    }

    /// A window never holds beats from two spans, so two blocks of the same stage hours apart are never
    /// differenced against each other. Two 300 s deep blocks six hours apart must be exactly two windows —
    /// a pooled implementation would fold the intervening clock into the bucketing.
    func testWindowsNeverSpanTwoBlocksOfTheSameStage() {
        let firstStart = t0
        let secondStart = t0 + 6 * 3_600
        let deep = HRVByStage.analyze(
            spans: [.init(start: firstStart, end: firstStart + 300, stage: .deep),
                    .init(start: secondStart, end: secondStart + 300, stage: .deep)],
            rr: beats(from: firstStart, to: firstStart + 300)
                + beats(from: secondStart, to: secondStart + 300, seed: 91))[.deep]

        XCTAssertEqual(deep.verdict, .measured)
        XCTAssertEqual(deep.windows, 2)
        XCTAssertEqual(deep.claimedSec, 600, "only the two blocks, never the six hours between them")
        XCTAssertEqual(deep.admittedSec, 600)
    }

    // MARK: - Determinism

    /// The result is a function of the INPUT SET, not of the order it arrives in. `analyze` sorts by
    /// (ts, rrMs) because Swift's sort is not stable and the corpus really does put several beats on one
    /// second — without the secondary key the same night could produce two different Δ-statistics.
    ///
    /// The fixture therefore puts two beats with different `rrMs` on every second, which is the only shape
    /// that can expose an unstable sort, and feeds the same rows forwards and reversed.
    func testTheResultDoesNotDependOnInputOrder() {
        let start = t0
        let end = start + 3_600
        var rr: [RRInterval] = []
        var x = 5
        for t in stride(from: start, to: end, by: 1) {
            x = (x &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
            rr.append(RRInterval(ts: t, rrMs: 980 + (x % 20)))
            rr.append(RRInterval(ts: t, rrMs: 1_010 + (x % 15)))   // same second, different interval
        }
        let spans: [HRVByStage.Span] = [.init(start: start, end: end, stage: .deep)]

        let forwards = HRVByStage.analyze(spans: spans, rr: rr)
        // `Array(...)` explicitly: on a BidirectionalCollection `reversed()` also has a lazy
        // `ReversedCollection` overload, and this must be the eager array the parameter takes.
        let backwards = HRVByStage.analyze(spans: spans, rr: Array(rr.reversed()))
        XCTAssertEqual(forwards, backwards, "R-R order must not move the numbers")
        XCTAssertEqual(forwards[.deep].verdict, .measured)
    }

    /// Span order must not move the numbers either — including which span the spectrum is read over.
    func testSpanOrderDoesNotMoveTheResultOrTheChosenSpectrum() {
        let longStart = t0
        let longEnd = longStart + 3_600
        let shortStart = longEnd + 1_800
        let shortEnd = shortStart + 1_800

        let rr = beats(from: longStart, to: longEnd) + beats(from: shortStart, to: shortEnd, seed: 41)
        let ordered: [HRVByStage.Span] = [.init(start: longStart, end: longEnd, stage: .rem),
                                          .init(start: shortStart, end: shortEnd, stage: .rem)]

        let a = HRVByStage.analyze(spans: ordered, rr: rr)
        let b = HRVByStage.analyze(spans: Array(ordered.reversed()), rr: rr)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a[.rem].bandSpanSec, 3_600,
                       "the spectrum is read over the LONGEST admitted span, chosen from the input not its order")
    }

    // MARK: - The spectrum

    /// A spectrum, when present, is a property of ONE continuous span and says which one. `bands` and
    /// `bandSpanSec` are present or absent together — a spectrum without the length of the record behind it
    /// is not interpretable, and a length without a spectrum is a dangling number.
    func testBandsAndBandSpanTravelTogether() {
        let start = t0
        let end = start + 3_600
        let rem = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .rem)],
                                     rr: beats(from: start, to: end))[.rem]

        XCTAssertEqual(rem.verdict, .measured)
        XCTAssertNotNil(rem.bands, "a fully-watched hour clears the spectral floor")
        XCTAssertEqual(rem.bandSpanSec, 3_600)

        let unwatched = HRVByStage.analyze(spans: [.init(start: start, end: end, stage: .rem)], rr: [])[.rem]
        XCTAssertNil(unwatched.bands)
        XCTAssertNil(unwatched.bandSpanSec)

        for reading in [rem, unwatched] {
            XCTAssertEqual(reading.bands == nil, reading.bandSpanSec == nil,
                           "\(reading.stage): the pair is all-or-nothing")
        }
    }

    // MARK: - Malformed input

    /// A malformed payload cannot produce a number. Spans are resolved independently, so an inverted span
    /// contributes nothing at all rather than a negative that would corrupt a total, and overlapping spans
    /// each speak for their own clock.
    func testInvertedAndOverlappingSpansAreHandledWithoutFabricatingClock() {
        // Inverted: end before start. It is not a 0 s span with a stage, it is not a span.
        let inverted = HRVByStage.analyze(spans: [.init(start: t0 + 3_600, end: t0, stage: .deep)],
                                          rr: beats(from: t0, to: t0 + 3_600))[.deep]
        XCTAssertEqual(inverted.verdict, .notLabelled, "an inverted span is no span at all")
        XCTAssertEqual(inverted.claimedSec, 0, "and never a negative contribution to the total")
        XCTAssertNil(inverted.rmssd)

        // Overlapping: both are resolved on their own merits; neither is silently merged away.
        let overlapped = HRVByStage.analyze(
            spans: [.init(start: t0, end: t0 + 2_400, stage: .light),
                    .init(start: t0 + 1_200, end: t0 + 3_600, stage: .light)],
            rr: beats(from: t0, to: t0 + 3_600))[.light]
        XCTAssertEqual(overlapped.verdict, .measured)
        XCTAssertEqual(overlapped.claimedSec, 4_800, "each span speaks for its own clock, overlap included")
        XCTAssertEqual(overlapped.admittedSec, 4_800)
    }

    /// R-R rows outside every span are ignored, so a caller may hand in a window wider than the night — which
    /// is what the store's `rrIntervals(deviceId:from:to:limit:)` naturally returns — without changing a
    /// single reported number.
    func testRRRowsOutsideEverySpanAreIgnored() {
        let start = t0 + 7_200
        let end = start + 3_600
        let spans: [HRVByStage.Span] = [.init(start: start, end: end, stage: .deep)]

        let tight = HRVByStage.analyze(spans: spans, rr: beats(from: start, to: end))
        let wide = HRVByStage.analyze(spans: spans,
                                      rr: beats(from: start - 7_200, to: start, seed: 61)
                                          + beats(from: start, to: end)
                                          + beats(from: end, to: end + 7_200, seed: 77))
        XCTAssertEqual(tight, wide, "a wider read window must cost correctness nothing")
    }
}
