import XCTest
import StrapProtocol
import StrapStore
@testable import StrapAnalytics

final class RestCompositeTests: XCTestCase {

    /// A textbook eight-hour night: 95% efficient, 45% restorative, 20% deep.
    private func goodNight(consistency: Double? = 1.0, ageYears: Double? = nil) -> Double {
        Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600 / 0.95, efficiency: 0.95,
                       restorativeSeconds: 8 * 3600 * 0.45, needHours: 8,
                       consistency: consistency, deepSeconds: 8 * 3600 * 0.20,
                       ageYears: ageYears)
    }

    func testAGoodNightScoresHigh() {
        XCTAssertGreaterThan(goodNight(), 90)
        XCTAssertLessThanOrEqual(goodNight(), 100)
    }

    func testTheScoreIsBounded() {
        // Every sub-score clamps, so no component can carry or sink a night on its own.
        let absurd = Rest.composite(tstSeconds: 20 * 3600, inBedSeconds: 20 * 3600,
                                    efficiency: 3.0, restorativeSeconds: 20 * 3600,
                                    needHours: 8, consistency: 5.0, deepSeconds: 20 * 3600)
        XCTAssertEqual(absurd, 100)
        let nothing = Rest.composite(tstSeconds: 0, inBedSeconds: 0, efficiency: 0,
                                     restorativeSeconds: 0, needHours: 8, consistency: 0)
        XCTAssertEqual(nothing, 0)
    }

    func testAnUnknownScheduleIsNeutralNotAFailure() {
        let unknown = goodNight(consistency: nil)
        XCTAssertEqual(unknown, goodNight(consistency: Rest.neutralConsistency))
        XCTAssertGreaterThan(unknown, goodNight(consistency: 0))
        XCTAssertLessThan(unknown, goodNight(consistency: 1))
    }

    func testDurationIsMeasuredAgainstTheWearersOwnNeed() {
        let sixHours = 6 * 3600.0
        let againstEight = Rest.composite(tstSeconds: sixHours, inBedSeconds: sixHours,
                                          efficiency: 1, restorativeSeconds: sixHours * 0.45,
                                          needHours: 8, consistency: 1, deepSeconds: sixHours * 0.2)
        let againstSix = Rest.composite(tstSeconds: sixHours, inBedSeconds: sixHours,
                                        efficiency: 1, restorativeSeconds: sixHours * 0.45,
                                        needHours: 6, consistency: 1, deepSeconds: sixHours * 0.2)
        XCTAssertGreaterThan(againstSix, againstEight)
    }

    func testANearZeroDeepNightIsDentedNotCollapsed() {
        // Pooled with REM, such a night still scores in the nineties. Split, it loses up to half of
        // one 20-point term — visible, and no stages are invented to produce it.
        let noDeep = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600, efficiency: 0.95,
                                    restorativeSeconds: 8 * 3600 * 0.45, needHours: 8,
                                    consistency: 1, deepSeconds: 0)
        let withDeep = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600,
                                      efficiency: 0.95, restorativeSeconds: 8 * 3600 * 0.45,
                                      needHours: 8, consistency: 1, deepSeconds: 8 * 3600 * 0.2)
        XCTAssertLessThan(noDeep, withDeep)
        XCTAssertGreaterThan(noDeep, withDeep - 11, "a dent, not a collapse")
        XCTAssertGreaterThan(noDeep, 80)
    }

    func testAnUnknownDeepSplitIsThePooledBehaviour() {
        // An imported night carrying only a total must not be penalised for what it cannot report.
        let unknown = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600,
                                     efficiency: 0.95, restorativeSeconds: 8 * 3600 * 0.45,
                                     needHours: 8, consistency: 1, deepSeconds: nil)
        let ample = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600, efficiency: 0.95,
                                   restorativeSeconds: 8 * 3600 * 0.45, needHours: 8,
                                   consistency: 1, deepSeconds: 8 * 3600 * 0.5)
        XCTAssertEqual(unknown, ample)
    }

    func testAnUnknownAgeIsTheYoungAdultScoring() {
        XCTAssertEqual(Rest.restorativeTarget(ageYears: nil), Rest.restorativeTarget)
        XCTAssertEqual(Rest.deepShareTarget(ageYears: nil), Rest.deepShareTarget)
        XCTAssertEqual(goodNight(ageYears: nil), goodNight(ageYears: 30))
    }

    func testTheTargetsTaperWithAgeAndNeverRise() {
        let ages: [Double] = [20, 40, 45, 55, 70, 90]
        let restorative = ages.map { Rest.restorativeTarget(ageYears: $0) }
        let deep = ages.map { Rest.deepShareTarget(ageYears: $0) }
        for (a, b) in zip(restorative, restorative.dropFirst()) { XCTAssertGreaterThanOrEqual(a, b) }
        for (a, b) in zip(deep, deep.dropFirst()) { XCTAssertGreaterThanOrEqual(a, b) }
        XCTAssertEqual(restorative.last!, Rest.restorativeTargetFloor)
        XCTAssertEqual(deep.last!, Rest.deepShareTargetFloor)
    }

    func testAnOlderAdultIsNotCappedByAYoungAdultTarget() {
        // Deep and REM share declines with age; a fixed target quietly caps a score they cannot
        // reach.
        let modest = 8 * 3600 * 0.42
        let young = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600, efficiency: 0.95,
                                   restorativeSeconds: modest, needHours: 8, consistency: 1,
                                   deepSeconds: 8 * 3600 * 0.10, ageYears: 30)
        let older = Rest.composite(tstSeconds: 8 * 3600, inBedSeconds: 8 * 3600, efficiency: 0.95,
                                   restorativeSeconds: modest, needHours: 8, consistency: 1,
                                   deepSeconds: 8 * 3600 * 0.10, ageYears: 75)
        XCTAssertGreaterThan(older, young)
    }

    func testTheWeightsSumToOne() {
        XCTAssertEqual(Rest.wDuration + Rest.wEfficiency + Rest.wRestorative + Rest.wConsistency,
                       1.0, accuracy: 1e-12)
    }

    // MARK: - From a stored day

    func testTheStoredFormAgreesWithTheStreamForm() {
        // One definition, so the stored series and the Charge term can never disagree.
        let d = DailyMetric(day: "2026-07-15", totalSleepMin: 480, efficiency: 0.95,
                            deepMin: 96, remMin: 120, lightMin: 264)
        let stored = Rest.composite(daily: d, needHours: 8, consistency: 1)
        let direct = Rest.composite(tstSeconds: 480 * 60, inBedSeconds: 480 * 60 / 0.95,
                                    efficiency: 0.95, restorativeSeconds: (96 + 120) * 60,
                                    needHours: 8, consistency: 1, deepSeconds: 96 * 60)
        XCTAssertEqual(try! XCTUnwrap(stored), direct, accuracy: 1e-9)
    }

    func testAStoredDayWithNoSleepHasNoScore() {
        XCTAssertNil(Rest.composite(daily: DailyMetric(day: "2026-07-15")))
        XCTAssertNil(Rest.composite(daily: DailyMetric(day: "2026-07-15", totalSleepMin: 0,
                                                       efficiency: 0.9)))
        XCTAssertNil(Rest.composite(daily: DailyMetric(day: "2026-07-15", totalSleepMin: 400)))
    }
}

final class SkinTempTests: XCTestCase {

    private func session(_ from: Int, _ to: Int) -> SleepSession {
        SleepSession(start: from, end: to, efficiency: 0.9, stages: [],
                     restingHR: nil, avgHRV: nil)
    }

    /// Worn 5/MG samples: centidegrees.
    private func worn(_ from: Int, _ count: Int, c: Double = 33.5) -> [SkinTempSample] {
        (0..<count).map { SkinTempSample(ts: from + $0, raw: Int(c * 100)) }
    }

    private func hr(_ from: Int, _ count: Int, bpm: Int = 55) -> [HRSample] {
        (0..<count).map { HRSample(ts: from + $0, bpm: bpm) }
    }

    func testAWornNightYieldsAMean() throws {
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: hr(0, 3600),
                                skinTemp: worn(0, 3600))
        XCTAssertEqual(try XCTUnwrap(f.mean), 33.5, accuracy: 0.05)
        XCTAssertEqual(f.kept, 3600)
        XCTAssertFalse(f.isAbsent)
    }

    func testTheBucketsAccountForEverySample() {
        let temps = worn(0, 600) + worn(5000, 600) + worn(600, 600, c: 15)
        let f = SkinTemp.funnel(sessions: [session(0, 1200)], hr: hr(0, 1200),
                                skinTemp: temps)
        XCTAssertEqual(f.droppedNotWorn + f.droppedOutOfWindow + f.droppedOutOfRange + f.kept,
                       f.totalSamples)
    }

    func testASampleWithNoLiveHeartRateIsNotWorn() {
        // The strap streams heart rate only on-wrist, so a live BPM is the wear evidence.
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: [], skinTemp: worn(0, 3600))
        XCTAssertEqual(f.droppedNotWorn, 3600)
        XCTAssertNil(f.mean)
    }

    func testAnImplausibleDeadBPMIsNotWear() {
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: hr(0, 3600, bpm: 0),
                                skinTemp: worn(0, 3600))
        XCTAssertEqual(f.droppedNotWorn, 3600)
    }

    func testAChargerDriftingToAmbientCannotPoisonTheMean() {
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: hr(0, 3600),
                                skinTemp: worn(0, 1800) + worn(1800, 1800, c: 21))
        XCTAssertEqual(f.droppedOutOfRange, 1800)
        XCTAssertEqual(try! XCTUnwrap(f.mean), 33.5, accuracy: 0.05)
    }

    func testSamplesOutsideTheNightAreOutOfWindow() {
        let f = SkinTemp.funnel(sessions: [session(0, 1000)], hr: hr(0, 4000),
                                skinTemp: worn(0, 4000))
        XCTAssertEqual(f.droppedOutOfWindow, 4000 - 1001)
    }

    func testAHandfulOfSamplesIsNotABaseline() {
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: hr(0, 3600),
                                skinTemp: worn(0, 100))
        XCTAssertEqual(f.kept, 100)
        XCTAssertNil(f.mean, "under the minimum")
        XCTAssertTrue(f.isAbsent)
    }

    func testNoSessionsMeansEverySampleIsOutOfWindow() {
        let f = SkinTemp.funnel(sessions: [], hr: hr(0, 3600), skinTemp: worn(0, 3600))
        XCTAssertEqual(f.droppedOutOfWindow, 3600)
        XCTAssertNil(f.mean)
    }

    func testAnEmptyFunnel() {
        let f = SkinTemp.funnel(sessions: [session(0, 3600)], hr: [], skinTemp: [])
        XCTAssertEqual(f.totalSamples, 0)
        XCTAssertNil(f.mean)
        XCTAssertTrue(f.summary.contains("absent"))
    }

    func testTheMeanAndItsExplanationComeFromTheSameCode() {
        let sessions = [session(0, 3600)]
        let temps = worn(0, 3600)
        XCTAssertEqual(SkinTemp.wornNightlyMeanC(sessions: sessions, hr: hr(0, 3600),
                                                 skinTemp: temps),
                       SkinTemp.funnel(sessions: sessions, hr: hr(0, 3600),
                                       skinTemp: temps).mean)
    }
}

final class ScoreConfidenceTierTests: XCTestCase {

    private func baseline(_ n: Int) -> Baselines.BaselineState {
        Baselines.foldHistory([Double?](repeating: 95.0, count: n),
                              cfg: Baselines.metricCfg["hrv"]!)
    }

    func testChargeIsOnlyAsGoodAsItsBaseline() {
        XCTAssertEqual(ScoreConfidence.charge(recovery: nil, hrvBaseline: baseline(40)),
                       ScoreConfidence.calibrating)
        XCTAssertEqual(ScoreConfidence.charge(recovery: 60, hrvBaseline: nil),
                       ScoreConfidence.calibrating)
        XCTAssertEqual(ScoreConfidence.charge(recovery: 60, hrvBaseline: baseline(0)),
                       ScoreConfidence.calibrating)
        XCTAssertEqual(ScoreConfidence.charge(recovery: 60, hrvBaseline: baseline(40)),
                       ScoreConfidence.solid)
    }

    func testEffortNeedsBothDensityAndCoverage() {
        XCTAssertEqual(ScoreConfidence.effort(strain: nil, hrSampleCount: 99_999),
                       ScoreConfidence.calibrating)
        XCTAssertEqual(ScoreConfidence.effort(strain: 40, hrSampleCount: 100),
                       ScoreConfidence.building)
        XCTAssertEqual(ScoreConfidence.effort(strain: 40, hrSampleCount: 40_000),
                       ScoreConfidence.solid)
        // The sample count alone cannot see a hole: a half-missing day still carries tens of
        // thousands of samples.
        XCTAssertEqual(ScoreConfidence.effort(strain: 40, hrSampleCount: 40_000, coverage: 0.5),
                       ScoreConfidence.building)
        XCTAssertEqual(ScoreConfidence.effort(strain: 40, hrSampleCount: 40_000, coverage: nil),
                       ScoreConfidence.solid, "not graded is not the same as bad")
    }

    func testCoverageCannotUpgradeAThinDay() {
        XCTAssertEqual(ScoreConfidence.effort(strain: 40, hrSampleCount: 10, coverage: 1.0),
                       ScoreConfidence.building)
    }

    func testRestNeedsStages() {
        XCTAssertEqual(ScoreConfidence.rest(hasSession: false, hasStagedSleep: true),
                       ScoreConfidence.calibrating)
        XCTAssertEqual(ScoreConfidence.rest(hasSession: true, hasStagedSleep: false),
                       ScoreConfidence.building)
        XCTAssertEqual(ScoreConfidence.rest(hasSession: true, hasStagedSleep: true),
                       ScoreConfidence.solid)
    }

    func testAnImplausiblyUnrestorativeNightIsFlagged() {
        // High efficiency with almost no deep or REM is likelier a staging miss than a real night.
        let flagged = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                           asleepSeconds: 8 * 3600,
                                           restorativeSeconds: 8 * 3600 * 0.05, efficiency: 0.95)
        XCTAssertEqual(flagged, ScoreConfidence.building)
        let ordinary = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                            asleepSeconds: 8 * 3600,
                                            restorativeSeconds: 8 * 3600 * 0.40, efficiency: 0.95)
        XCTAssertEqual(ordinary, ScoreConfidence.solid)
    }

    func testAFragmentedNightIsNotFlaggedForTheSameShare() {
        // It legitimately carries less deep and REM, so the floor would fire on exactly the nights
        // it should not.
        let fragmented = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                              asleepSeconds: 8 * 3600,
                                              restorativeSeconds: 8 * 3600 * 0.05,
                                              efficiency: 0.60)
        XCTAssertEqual(fragmented, ScoreConfidence.solid)
    }
}
