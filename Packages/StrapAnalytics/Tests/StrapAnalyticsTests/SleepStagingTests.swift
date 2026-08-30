import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SleepStagingTests: XCTestCase {

    // MARK: - Cole–Kripke spine

    func testAStillNightScoresAsSleepThroughout() {
        XCTAssertTrue(SleepStaging.coleKripke([Double](repeating: 0, count: 20)).allSatisfy { $0 })
    }

    func testSustainedMotionScoresAsWake() {
        // 300 is the count clip, so this is the loudest input the spine can see.
        XCTAssertTrue(SleepStaging.coleKripke([Double](repeating: 300, count: 20))
                        .allSatisfy { !$0 })
    }

    func testCountsAreClippedAndNormalised() {
        XCTAssertEqual(SleepStaging.rescaleCounts([50_000, 100, 0]), [300, 1, 0])
    }

    func testOnsetNeedsPersistence() {
        // One quiet epoch while still awake in bed is not falling asleep.
        var f = [Bool](repeating: false, count: 20)
        f[3] = true
        f[10] = true; f[11] = true; f[12] = true
        let ow = SleepStaging.onsetAndFinalWake(f)
        XCTAssertEqual(ow.onset, 10)
        XCTAssertEqual(ow.finalWake, 12)
    }

    func testFinalWakeIsTheLastSleepEpochNotTheFirstWakeRun() {
        var f = [Bool](repeating: true, count: 20)
        f[5] = false; f[6] = false
        XCTAssertEqual(SleepStaging.onsetAndFinalWake(f).finalWake, 19)
    }

    func testNoSleepAtAllStillYieldsAUsableRange() {
        let ow = SleepStaging.onsetAndFinalWake([Bool](repeating: false, count: 10))
        XCTAssertEqual(ow.onset, 0)
        XCTAssertEqual(ow.finalWake, 9)
    }

    func testEmptySpine() {
        let ow = SleepStaging.onsetAndFinalWake([])
        XCTAssertEqual(ow.onset, 0)
        XCTAssertEqual(ow.finalWake, 0)
    }

    // MARK: - Epoch grid

    private func grav(_ from: Int, _ seconds: Int, jitter: Double = 0) -> [GravitySample] {
        (0..<seconds).map {
            GravitySample(ts: from + $0, x: Double($0 % 2) * jitter, y: 0, z: 1)
        }
    }

    func testAnEpochWithNoGravityReadsAsMoving() {
        // Absent motion evidence must not read as stillness — stillness is what becomes sleep.
        let g = grav(0, 30)                       // only the first epoch has samples
        let grid = SleepStaging.buildEpochGrid(0, 120, g, [], [], [])
        XCTAssertEqual(grid.nEpochs, 4)
        XCTAssertEqual(grid.moveFrac[0], 0.0)
        XCTAssertEqual(grid.moveFrac[3], 1.0)
    }

    func testNoTrustworthyCadenceAbandonsTheMotionChannel() {
        // An all-zero count series would score si < 1 everywhere, i.e. sleep everywhere.
        let erratic = [0, 1, 700, 701, 5000, 9000].map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        let grid = SleepStaging.buildEpochGrid(0, 9600, erratic, [], [], [])
        XCTAssertTrue(grid.ckFlags.allSatisfy { !$0 })
        XCTAssertTrue(grid.counts.allSatisfy { $0 == 0 })
    }

    func testTheCountSumIsCadenceInvariant() {
        // Same physical movement, two sampling rates: the per-epoch sum must match, or the spine's
        // onset decision moves with the device rather than with the sleeper.
        let fast = (0..<600).map { GravitySample(ts: $0, x: Double($0) * 0.01, y: 0, z: 1) }
        let slow = stride(from: 0, to: 600, by: 5).map {
            GravitySample(ts: $0, x: Double($0) * 0.01, y: 0, z: 1)
        }
        let f = SleepStaging.buildEpochGrid(0, 600, fast, [], [], []).counts.reduce(0, +)
        let s = SleepStaging.buildEpochGrid(0, 600, slow, [], [], []).counts.reduce(0, +)
        // Not exact: the leading sample of each stream contributes no delta, and that missing
        // edge is proportionally larger for the coarser one. It shrinks with window length,
        // which is why the invariant is stated over a whole night's worth of epochs.
        XCTAssertEqual(f, s, accuracy: 0.05)
    }

    func testHeartRateIsAveragedPerEpochAndMissingEpochsAreNaN() {
        let hr = [HRSample(ts: 0, bpm: 50), HRSample(ts: 10, bpm: 60)]
        let grid = SleepStaging.buildEpochGrid(0, 60, grav(0, 60), hr, [], [])
        XCTAssertEqual(grid.hr[0], 55)
        XCTAssertTrue(grid.hr[1].isNaN)
    }

    func testASampleExactlyAtTheEndLandsInTheLastEpoch() {
        let hr = [HRSample(ts: 60, bpm: 44)]
        let grid = SleepStaging.buildEpochGrid(0, 60, grav(0, 60), hr, [], [])
        XCTAssertEqual(grid.hr[1], 44)
    }

    // MARK: - DoG variability

    func testFlatHeartRateHasNoVariability() {
        let dog = SleepStaging.dogHRVariability([Double](repeating: 55, count: 60))
        XCTAssertTrue(dog.allSatisfy { abs($0) < 1e-6 })
    }

    func testASlowDriftIsRemovedButAStepSurvives() {
        // The point of the difference: overnight drift is not a stage transition, a step is.
        let n = 120
        let drift = (0..<n).map { 50.0 + Double($0) * 0.05 }
        let step = (0..<n).map { $0 < 60 ? 50.0 : 62.0 }
        let driftPeak = SleepStaging.dogHRVariability(drift).map(abs).max() ?? 0
        let stepPeak = SleepStaging.dogHRVariability(step).map(abs).max() ?? 0
        XCTAssertLessThan(driftPeak, stepPeak)
    }

    func testGapsAreInterpolatedNotZeroed() {
        var hr = [Double](repeating: 55, count: 40)
        hr[20] = .nan
        let dog = SleepStaging.dogHRVariability(hr)
        XCTAssertTrue(dog.allSatisfy { abs($0) < 1e-6 }, "a hole is not an event")
    }

    func testAllMissingYieldsZeros() {
        let dog = SleepStaging.dogHRVariability([Double](repeating: .nan, count: 10))
        XCTAssertEqual(dog, [Double](repeating: 0, count: 10))
    }

    func testTheKernelSumsToOne() {
        let k = SleepStaging.gaussianKernel(sigmaS: 120)
        XCTAssertEqual(k.reduce(0, +), 1.0, accuracy: 1e-12)
        XCTAssertEqual(k.count % 2, 1, "a smoothing kernel must have a centre")
    }

    func testConvolutionPreservesLength() {
        let x = (0..<50).map { Double($0) }
        XCTAssertEqual(SleepStaging.convolveReflect(x, SleepStaging.gaussianKernel(sigmaS: 60)).count,
                       50)
    }

    func testReflectedEdgesDoNotDipTowardZero() {
        let x = [Double](repeating: 100, count: 40)
        let out = SleepStaging.convolveReflect(x, SleepStaging.gaussianKernel(sigmaS: 90))
        XCTAssertEqual(out.first!, 100, accuracy: 1e-9)
        XCTAssertEqual(out.last!, 100, accuracy: 1e-9)
    }

    // MARK: - Peaks

    func testPlateauPeaksReportTheirCentre() {
        XCTAssertEqual(SleepStaging.findPeaks([0, 1, 1, 1, 0], distance: 1, height: 0), [2])
    }

    func testNearbyPeaksAreThinnedTallestFirst() {
        let x: [Double] = [0, 5, 0, 9, 0]
        XCTAssertEqual(SleepStaging.findPeaks(x, distance: 3, height: 0), [3])
    }

    func testAMonotonicSeriesHasNoPeaks() {
        XCTAssertTrue(SleepStaging.findPeaks([1, 2, 3, 4, 5], distance: 1, height: 0).isEmpty)
    }

    // MARK: - Breathing from beat intervals

    func testAModulatedRRSeriesYieldsAPlausibleBreathingRate() {
        // 1000 ms beats with a 12 breath/min sinusoid on top.
        let rr = (0..<120).map { i -> Double in
            1000 + 40 * sin(2 * Double.pi * Double(i) / 5.0)
        }
        let out = SleepStaging.rrvFromRRSeries(rr)
        XCTAssertTrue(out.rate.isFinite)
        XCTAssertEqual(out.rate, 12, accuracy: 3)
    }

    func testAFlatRRSeriesHasNoBreathingEstimate() {
        XCTAssertTrue(SleepStaging.rrvFromRRSeries([Double](repeating: 1000, count: 60)).rate.isNaN)
    }

    func testTooFewBeatsAbstains() {
        XCTAssertTrue(SleepStaging.rrvFromRRSeries([1000, 1010, 990]).rrv.isNaN)
    }

    func testRawRespirationIsUsedWhenPresent() {
        let resp = (0..<120).map { 512.0 + 50 * sin(2 * Double.pi * Double($0) / 5.0) }
        let out = SleepStaging.respRateAndRRV(resp)
        XCTAssertEqual(out.rate, 12, accuracy: 2)
    }

    func testAConstantRespirationTraceAbstains() {
        XCTAssertTrue(SleepStaging.respRateAndRRV([Double](repeating: 7, count: 60)).rate.isNaN)
    }

    // MARK: - Classifier

    private func feat(hr: Double = 55, hrVar: Double = 0.1, rmssd: Double = 60,
                      rrv: Double = 1.0, move: Double = 0.0,
                      clock: Double = 0.2, ck: Bool = true) -> SleepStaging.EpochFeatures {
        SleepStaging.EpochFeatures(index: 0, midTs: 0, moveFrac: move, ckSleep: ck,
                                   hr: hr, hrVar: hrVar, rmssd: rmssd, sdnn: 50,
                                   respRate: 14, rrv: rrv, clock: clock)
    }

    func testMovementWithCardiacActivationIsWake() {
        let f = feat(hr: 80, move: 0.5)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "wake")
    }

    func testMovementWithNoHeartRateIsWake() {
        let f = feat(hr: .nan, move: 0.5)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "wake")
    }

    func testStillAndLowAndRegularIsDeep() {
        let f = feat(hr: 45, rmssd: 90, rrv: 0.5)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "deep")
    }

    func testStillAndActivatedAndIrregularIsREM() {
        let f = feat(hr: 75, rrv: 3.0)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "rem")
    }

    func testAMissingRRVStillReachesREM() {
        // The rare-gap fallback. Without it REM disappears from nights that had it.
        let f = feat(hr: 75, rrv: .nan)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "rem")
    }

    func testAMissingChannelAbstainsRatherThanBlockingDeep() {
        // No beat intervals at all: deep must still be reachable on HR and motion.
        let f = feat(hr: 45, rmssd: .nan, rrv: .nan)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: nil,
                                                hrvarHi: nil, rrvHi: nil, rrvLo: nil,
                                                cardiacSparse: true), "deep")
    }

    func testEverythingElseIsLight() {
        let f = feat(hr: 60, rrv: 1.5)
        XCTAssertEqual(SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                                hrvarHi: 1, rrvHi: 2, rrvLo: 1,
                                                cardiacSparse: false), "light")
    }

    func testSparseCardiacDataNarrowsTheWakeTest() {
        // hrVar alone over-calls wake once RMSSD is mostly gone.
        let f = feat(hr: 55, hrVar: 5, move: 0.5)
        let dense = SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                             hrvarHi: 1, rrvHi: 2, rrvLo: 1, cardiacSparse: false)
        let sparse = SleepStaging.classifyOne(f, hrLo: 50, hrHi: 70, rmssdHi: 50,
                                              hrvarHi: 1, rrvHi: 2, rrvLo: 1, cardiacSparse: true)
        XCTAssertEqual(dense, "wake")
        XCTAssertNotEqual(sparse, "wake")
    }

    func testBandsAreDrawnOverSleepEpochsOnly() {
        // An awake tail at 100 bpm must not drag the sleep percentiles up with it.
        let sleep = (0..<20).map { _ in feat(hr: 55) }
        let awake = (0..<20).map { _ in feat(hr: 100, ck: false) }
        let hiWithTail = SleepStaging.pct((sleep + awake).filter(\.ckSleep).map(\.hr),
                                          SleepStaging.stageHRHighPct)
        XCTAssertEqual(hiWithTail!, 55, accuracy: 1e-9)
    }

    func testPercentileIgnoresNonFiniteValues() {
        XCTAssertEqual(SleepStaging.pct([.nan, 10, 20, .infinity], 50)!, 15, accuracy: 1e-9)
        XCTAssertNil(SleepStaging.pct([.nan, .nan], 50))
    }

    func testCardiacSparsityThreshold() {
        let missing = (0..<5).map { _ in feat(rmssd: .nan) }
        let present = (0..<5).map { _ in feat(rmssd: 60) }
        XCTAssertTrue(SleepStaging.isCardiacSparse(missing + present), "half counts as sparse")
        XCTAssertFalse(SleepStaging.isCardiacSparse(Array(present + missing.dropLast())))
    }

    // MARK: - Post-processing

    func testALoneEpochIsSmoothedAway() {
        let labels = ["light", "light", "deep", "light", "light"]
        XCTAssertEqual(SleepStaging.smoothLabels(labels),
                       ["light", "light", "light", "light", "light"])
    }

    func testSmoothingKeepsTheEpochsOwnLabelOnATie() {
        let labels = ["deep", "deep", "rem", "rem"]
        XCTAssertEqual(SleepStaging.smoothLabels(labels, window: 3)[2], "rem")
    }

    func testNoREMImmediatelyAfterOnset() {
        let labels = [String](repeating: "rem", count: 60)
        let feats = (0..<60).map { i in feat(clock: Double(i) / 59.0) }
        let out = SleepStaging.reimposePhysiology(labels, feats, onsetIdx: 0, finalWakeIdx: 59)
        XCTAssertEqual(out[0], "light")
        XCTAssertEqual(out[29], "light", "still inside the first 15 minutes")
        XCTAssertEqual(out[30], "rem", "30 epochs = 15 minutes")
    }

    func testLateDeepIsDemotedOnlyWhenEarlyDeepExists() {
        let feats = (0..<60).map { i in feat(clock: Double(i) / 59.0) }
        var withEarly = [String](repeating: "light", count: 60)
        withEarly[5] = "deep"; withEarly[50] = "deep"
        let a = SleepStaging.reimposePhysiology(withEarly, feats, onsetIdx: 0, finalWakeIdx: 59)
        XCTAssertEqual(a[5], "deep")
        XCTAssertEqual(a[50], "light")

        var lateOnly = [String](repeating: "light", count: 60)
        lateOnly[50] = "deep"
        let b = SleepStaging.reimposePhysiology(lateOnly, feats, onsetIdx: 0, finalWakeIdx: 59)
        XCTAssertEqual(b[50], "deep", "the only deep evidence there is")
    }

    func testFragmentsDisappearIntoMatchingNeighbours() {
        let labels = [String](repeating: "light", count: 10)
            + ["deep", "deep"] + [String](repeating: "light", count: 10)
        XCTAssertEqual(Set(SleepStaging.mergeFragments(labels)), ["light"])
    }

    func testALongerNeighbourTakesTheFragment() {
        let labels = [String](repeating: "light", count: 12)
            + ["rem", "rem"] + [String](repeating: "deep", count: 8)
        let out = SleepStaging.mergeFragments(labels)
        XCTAssertEqual(out[12], "light")
        XCTAssertEqual(out.count, labels.count)
    }

    func testATieGoesToTheShallowerStage() {
        // Inventing deep from a tie is the expensive error.
        let labels = [String](repeating: "light", count: 8)
            + ["rem"] + [String](repeating: "deep", count: 8)
        let out = SleepStaging.mergeFragments(labels)
        XCTAssertEqual(out[8], "light")
    }

    func testMergingPreservesLength() {
        let labels = ["deep", "rem", "light", "wake", "deep", "rem", "light"]
        XCTAssertEqual(SleepStaging.mergeFragments(labels).count, labels.count)
    }

    // MARK: - Segments

    func testSegmentsTileTheWindowAndTheLastReachesTheEnd() {
        let grid = SleepStaging.buildEpochGrid(1000, 1100, grav(1000, 100), [], [], [])
        let labels = [String](repeating: "light", count: grid.nEpochs)
        let segs = SleepStaging.buildSegments(labels, grid, end: 1100)
        XCTAssertEqual(segs.first?.start, 1000)
        XCTAssertEqual(segs.last?.end, 1100)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    }

    // MARK: - End to end

    /// A night with a low still first half and a livelier still second half.
    private func syntheticNight(start: Int = 0, hours: Int = 7)
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        let seconds = hours * 3600
        var g: [GravitySample] = []
        var h: [HRSample] = []
        var r: [RRInterval] = []
        for i in 0..<seconds {
            let ts = start + i
            let restless = i > seconds / 2 && (i / 600) % 3 == 0
            g.append(GravitySample(ts: ts, x: restless ? Double(i % 2) * 0.05 : 0, y: 0, z: 1))
            let bpm = restless ? 68 : 48
            h.append(HRSample(ts: ts, bpm: bpm))
            if i % 1 == 0 { r.append(RRInterval(ts: ts, rrMs: 60_000 / bpm)) }
        }
        return (g, h, r)
    }

    func testAWholeNightStagesIntoContiguousSegments() {
        let n = syntheticNight()
        let segs = SleepStaging.stageSession(start: 0, end: 7 * 3600, grav: n.g, hr: n.h, rr: n.r)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, 7 * 3600)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertTrue(segs.allSatisfy { ["wake", "light", "deep", "rem"].contains($0.stage) })
    }

    func testAWindowWithNoMotionChannelIsLightNotDropped() {
        // Detection already said this was sleep; light claims the least.
        let segs = SleepStaging.stageSession(start: 0, end: 3600, grav: [], hr: [])
        XCTAssertEqual(segs, [StageSegment(start: 0, end: 3600, stage: "light")])
    }

    func testEfficiencyCountsOnlyWake() {
        let stages = [StageSegment(start: 0, end: 900, stage: "wake"),
                      StageSegment(start: 900, end: 3600, stage: "light")]
        XCTAssertEqual(SleepStaging.efficiency(start: 0, end: 3600, stages: stages),
                       0.75, accuracy: 1e-9)
        XCTAssertEqual(SleepStaging.efficiency(start: 0, end: 0, stages: stages), 0)
    }

    func testStageWindowFillsTheSessionNumbers() {
        let n = syntheticNight()
        let s = SleepStaging.stageWindow(start: 0, end: 7 * 3600, grav: n.g, hr: n.h, rr: n.r)
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.end, 7 * 3600)
        XCTAssertNotNil(s.restingHR)
        XCTAssertTrue(s.efficiency >= 0 && s.efficiency <= 1)
    }

    // MARK: - Session HRV

    func testSessionHRVAveragesCleanWindows() {
        // Alternating 900/1000 ms: RMSSD is 100 ms in every window.
        let rr = (0..<3600).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 900 : 1000) }
        let v = SleepStaging.sessionAvgHRV(start: 0, end: 3600, rr: rr)
        XCTAssertEqual(try XCTUnwrap(v), 100, accuracy: 5)
    }

    func testAWindowThatThrewAwayMostOfItsBeatsIsExcluded() {
        // These windows are not motion artefacts and they produce the LARGEST numbers, so
        // averaging them at full weight lets them dominate.
        var rr: [RRInterval] = []
        for i in 0..<300 { rr.append(RRInterval(ts: i, rrMs: i % 2 == 0 ? 900 : 1000)) }
        // A second window where four of every five beats are impossible.
        for i in 300..<600 { rr.append(RRInterval(ts: i, rrMs: i % 5 == 0 ? 950 : 2500)) }
        let both = try! XCTUnwrap(SleepStaging.sessionAvgHRV(start: 0, end: 600, rr: rr))
        let firstOnly = try! XCTUnwrap(SleepStaging.sessionAvgHRV(start: 0, end: 300,
                                                                 rr: Array(rr.prefix(300))))
        XCTAssertEqual(both, firstOnly, accuracy: 1e-9)
    }

    func testSessionHRVNeedsBeats() {
        XCTAssertNil(SleepStaging.sessionAvgHRV(start: 0, end: 3600, rr: []))
        XCTAssertNil(SleepStaging.sessionAvgHRV(start: 100, end: 50,
                                                rr: [RRInterval(ts: 60, rrMs: 900)]))
    }

    func testSessionHRVDoesNotDifferenceAcrossADropout() {
        // Two clusters an hour apart inside one window would fabricate one huge ΔNN.
        var rr = (0..<40).map { RRInterval(ts: $0, rrMs: $0 % 2 == 0 ? 900 : 1000) }
        rr += (0..<40).map { RRInterval(ts: 200 + $0, rrMs: $0 % 2 == 0 ? 900 : 1000) }
        let v = try! XCTUnwrap(SleepStaging.sessionAvgHRV(start: 0, end: 300, rr: rr))
        XCTAssertEqual(v, 100, accuracy: 5)
    }

    // MARK: - Small math

    func testPopulationStd() {
        XCTAssertEqual(SleepStaging.populationStd([2, 4, 4, 4, 5, 5, 7, 9]), 2.0, accuracy: 1e-12)
        XCTAssertEqual(SleepStaging.populationStd([]), 0)
    }
}

final class HypnogramMetricsTests: XCTestCase {

    private func session(_ segs: [(String, Int, Int)], start: Int = 0, end: Int = 28_800)
        -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0,
                     stages: segs.map { StageSegment(start: $0.1, end: $0.2, stage: $0.0) },
                     restingHR: nil, avgHRV: nil)
    }

    func testAPlainNightAddsUp() {
        let s = session([("wake", 0, 600), ("light", 600, 10_800), ("deep", 10_800, 14_400),
                         ("rem", 14_400, 18_000), ("light", 18_000, 28_800)])
        let m = SleepStaging.hypnogramMetrics(s)
        XCTAssertEqual(m.tibS, 28_800)
        XCTAssertEqual(m.tstS, 28_200)
        XCTAssertEqual(m.deepMin, 60)
        XCTAssertEqual(m.remMin, 60)
        XCTAssertEqual(m.lightMin, 350)
        XCTAssertEqual(m.deepPct + m.remPct + m.lightPct, 100, accuracy: 1e-9)
        XCTAssertEqual(m.efficiency, 28_200.0 / 28_800.0, accuracy: 1e-9)
    }

    func testWakeBeforeSleepIsNotWASO() {
        // A night that started late must not read as a fragmented one.
        let s = session([("wake", 0, 3600), ("light", 3600, 28_800)])
        let m = SleepStaging.hypnogramMetrics(s)
        XCTAssertEqual(m.wasoS, 0)
        XCTAssertEqual(m.disturbances, 0)
        XCTAssertEqual(m.leadingNonSleepS, 3600)
    }

    func testWakeAfterFinalWakingIsNotWASO() {
        let s = session([("light", 0, 25_200), ("wake", 25_200, 28_800)])
        let m = SleepStaging.hypnogramMetrics(s)
        XCTAssertEqual(m.wasoS, 0)
        XCTAssertEqual(m.sptS, 25_200)
    }

    func testMidNightWakeIsCounted() {
        let s = session([("light", 0, 10_800), ("wake", 10_800, 12_600),
                         ("light", 12_600, 28_800)])
        let m = SleepStaging.hypnogramMetrics(s)
        XCTAssertEqual(m.wasoS, 1800)
        XCTAssertEqual(m.disturbances, 1)
        XCTAssertEqual(m.sptS, 28_800)
    }

    func testNoSleepAtAllReportsNoLatency() {
        // Calling the whole window "time to fall asleep" beside a TST of zero is a fabrication.
        let m = SleepStaging.hypnogramMetrics(session([("wake", 0, 28_800)]))
        XCTAssertNil(m.leadingNonSleepS)
        XCTAssertEqual(m.tstS, 0)
        XCTAssertEqual(m.sptS, 0)
        XCTAssertEqual(m.efficiency, 0)
        XCTAssertEqual(m.deepPct, 0)
    }

    func testREMLatencyIsMeasuredFromOnsetNotFromBedtime() {
        let s = session([("wake", 0, 1800), ("light", 1800, 7200), ("rem", 7200, 9000),
                         ("light", 9000, 28_800)])
        XCTAssertEqual(SleepStaging.hypnogramMetrics(s).remLatencyS, 5400)
    }

    func testNoREMYieldsNaNLatency() {
        let s = session([("light", 0, 28_800)])
        XCTAssertTrue(SleepStaging.hypnogramMetrics(s).remLatencyS.isNaN)
    }

    func testAnEmptyHypnogram() {
        let m = SleepStaging.hypnogramMetrics(session([]))
        XCTAssertEqual(m.tstS, 0)
        XCTAssertNil(m.leadingNonSleepS)
    }

    func testSegmentsAreSortedBeforeSummarising() {
        let s = session([("light", 14_400, 28_800), ("wake", 0, 600), ("light", 600, 14_400)])
        let m = SleepStaging.hypnogramMetrics(s)
        XCTAssertEqual(m.leadingNonSleepS, 600)
        XCTAssertEqual(m.sptS, 28_200)
    }

    func testAZeroLengthWindow() {
        let m = SleepStaging.hypnogramMetrics(session([], start: 100, end: 100))
        XCTAssertEqual(m.tibS, 0)
        XCTAssertEqual(m.efficiency, 0)
    }
}
