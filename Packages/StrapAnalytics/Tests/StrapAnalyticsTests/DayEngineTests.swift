import XCTest
import StrapProtocol
import StrapStore
@testable import StrapAnalytics

final class DayEngineTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: "male")

    // MARK: - Day keys

    func testTheDayKeyIsTheWearersCalendarDay() {
        // 2026-03-10 02:00 UTC is still the 9th in New York. Bucketing it as the 10th puts an
        // evening in tomorrow, and the local "today" read never finds it.
        let ts = 1_772_589_600
        XCTAssertEqual(DayEngine.dayString(ts), DayEngine.dayString(ts, offsetSec: 0))
        XCTAssertNotEqual(DayEngine.dayString(ts, offsetSec: -5 * 3600),
                          DayEngine.dayString(ts, offsetSec: 0))
    }

    func testDayStartRoundTrips() {
        let day = "2026-07-15"
        let start = DayEngine.dayStartUTCSeconds(day)
        XCTAssertEqual(DayEngine.dayString(start), day)
        XCTAssertEqual(DayEngine.dayString(start + 86_399), day)
        XCTAssertNotEqual(DayEngine.dayString(start + 86_400), day)
    }

    func testAMalformedDayKeyMatchesNothingRatherThanTrapping() {
        // One bad key must not take down a whole scoring pass.
        XCTAssertEqual(DayEngine.dayStartUTCSeconds("not-a-day"), 0)
    }

    // MARK: - Wear events

    private func evt(_ ts: Int, _ kind: String) -> WhoopEvent {
        WhoopEvent(ts: ts, kind: kind, payload: [:])
    }

    func testWearEventsPairIntoIntervals() {
        let e = [evt(100, "WRIST_OFF(10)"), evt(500, "WRIST_ON(11)")]
        let out = DayEngine.offWristIntervals(events: e, windowEnd: 1000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 100)
        XCTAssertEqual(out[0].end, 500)
    }

    func testAnUnclosedOffRunsToTheEndOfTheWindow() {
        let out = DayEngine.offWristIntervals(events: [evt(100, "WRIST_OFF(10)")], windowEnd: 900)
        XCTAssertEqual(out.map(\.end), [900])
    }

    func testDuplicateEventsCoalesce() {
        // A repeated event is a transport artefact, not the band coming off twice.
        let e = [evt(100, "WRIST_OFF(10)"), evt(150, "WRIST_OFF(10)"),
                 evt(500, "WRIST_ON(11)"), evt(550, "WRIST_ON(11)")]
        XCTAssertEqual(DayEngine.offWristIntervals(events: e, windowEnd: 1000).count, 1)
    }

    func testUnorderedEventsAreSortedAndUnrelatedOnesIgnored() {
        let e = [evt(500, "WRIST_ON(11)"), evt(300, "BATTERY(3)"), evt(100, "WRIST_OFF(10)")]
        let out = DayEngine.offWristIntervals(events: e, windowEnd: 1000)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 100)
    }

    func testNoEventsMeansNoIntervals() {
        XCTAssertTrue(DayEngine.offWristIntervals(events: [], windowEnd: 1000).isEmpty)
        XCTAssertTrue(DayEngine.offWristIntervals(events: [evt(50, "WRIST_ON(11)")],
                                                  windowEnd: 1000).isEmpty)
    }

    // MARK: - Day slice

    func testASliceIsTakenFromTheWindowWhenItIsSafe() {
        let night = (0..<1000).map { HRSample(ts: $0, bpm: 60) }
        let slice = DayEngine.daySliceFromNight(night, nightLo: 0, nightHi: 999,
                                                dayLo: 100, dayHi: 199) { $0.ts }
        XCTAssertEqual(slice?.count, 100)
    }

    func testTheSliceDeclinesRatherThanReturningTheWrongRows() {
        let night = (0..<1000).map { HRSample(ts: $0, bpm: 60) }
        XCTAssertNil(DayEngine.daySliceFromNight(night, nightLo: 0, nightHi: 999,
                                                 dayLo: 100, dayHi: 2000) { $0.ts },
                     "the day runs past the window")
        XCTAssertNil(DayEngine.daySliceFromNight(night, nightLo: 0, nightHi: 999,
                                                 dayLo: 100, dayHi: 199, limit: 10) { $0.ts },
                     "the read may be truncated where the day sits")
    }

    // MARK: - Stage JSON

    func testStageJSONIsStable() {
        // The self-heal skips a write when the JSON is unchanged; unstable key order rewrites every
        // night on every pass.
        let stages = [StageSegment(start: 0, end: 60, stage: "light"),
                      StageSegment(start: 60, end: 120, stage: "deep")]
        let a = DayEngine.encodeStages(stages)
        XCTAssertEqual(a, DayEngine.encodeStages(stages))
        XCTAssertEqual(a, #"[{"end":60,"stage":"light","start":0},"#
                        + #"{"end":120,"stage":"deep","start":60}]"#)
    }

    // MARK: - Steps

    func testStepsAreTheSumOfIncrementsNotOfTheCounter() {
        // Summing a running total produces millions of steps a day.
        let s = (0..<100).map { StepSample(ts: $0, counter: $0 * 10) }
        XCTAssertEqual(DayEngine.stepTotal(s, inDay: { _ in true }, profile: profile), 990)
    }

    func testTheCounterWrap() {
        let s = [StepSample(ts: 0, counter: 65_500), StepSample(ts: 1, counter: 20)]
        XCTAssertEqual(DayEngine.stepTotal(s, inDay: { _ in true }, profile: profile), 56)
    }

    func testASyncBoundaryIsNotSteps() {
        let s = [StepSample(ts: 0, counter: 0), StepSample(ts: 1, counter: 5),
                 StepSample(ts: 2, counter: 40_000)]
        XCTAssertEqual(DayEngine.stepTotal(s, inDay: { _ in true }, profile: profile), 5)
    }

    func testCalibrationCannotExplodeTheTotal() {
        let s = (0..<100).map { StepSample(ts: $0, counter: $0 * 10) }
        let reckless = UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: "male",
                                   stepTicksPerStep: 0.001)
        XCTAssertEqual(DayEngine.stepTotal(s, inDay: { _ in true }, profile: reckless), 1980,
                       "the floor caps the damage at a doubling")
    }

    func testStepsNeedTwoSamplesAndSomeMotion() {
        XCTAssertNil(DayEngine.stepTotal([], inDay: { _ in true }, profile: profile))
        let flat = (0..<10).map { StepSample(ts: $0, counter: 500) }
        XCTAssertNil(DayEngine.stepTotal(flat, inDay: { _ in true }, profile: profile))
    }

    // MARK: - A whole day

    private func day(_ key: String) -> Int { DayEngine.dayStartUTCSeconds(key) }

    /// A night ending on `day`, with an awake evening before and morning after.
    private func nightStreams(endingOn key: String)
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        let wake = day(key) + 6 * 3600            // 06:00 on the day
        let start = wake - 7 * 3600               // 23:00 the evening before
        var g: [GravitySample] = [], h: [HRSample] = [], r: [RRInterval] = []
        for i in -(2 * 3600)..<0 {
            g.append(GravitySample(ts: start + i, x: Double(i % 2) * 0.5, y: 0, z: 1))
            h.append(HRSample(ts: start + i, bpm: 76))
            r.append(RRInterval(ts: start + i, rrMs: 789))
        }
        for i in 0..<(7 * 3600) {
            g.append(GravitySample(ts: start + i, x: 0, y: 0, z: 1))
            h.append(HRSample(ts: start + i, bpm: 50))
            r.append(RRInterval(ts: start + i, rrMs: 1200 + (i % 2 == 0 ? 40 : -40)))
        }
        for i in 0..<(2 * 3600) {
            g.append(GravitySample(ts: wake + i, x: Double(i % 2) * 0.5, y: 0, z: 1))
            h.append(HRSample(ts: wake + i, bpm: 76))
            r.append(RRInterval(ts: wake + i, rrMs: 789))
        }
        return (g, h, r)
    }

    func testAWholeDayProducesAConsistentRow() throws {
        let key = "2026-07-15"
        let n = nightStreams(endingOn: key)
        let res = DayEngine.analyzeDay(day: key, hr: n.h, rr: n.r, gravity: n.g, profile: profile)

        XCTAssertEqual(res.daily.day, key)
        XCTAssertEqual(res.sleepSessions.count, 1)
        XCTAssertEqual(res.cachedSleep.count, 1)
        let tst = try XCTUnwrap(res.daily.totalSleepMin)
        let deep = try XCTUnwrap(res.daily.deepMin)
        let rem = try XCTUnwrap(res.daily.remMin)
        let light = try XCTUnwrap(res.daily.lightMin)
        XCTAssertEqual(deep + rem + light, tst, accuracy: 1e-6, "the stages ARE the sleep")
        let eff = try XCTUnwrap(res.daily.efficiency)
        XCTAssertTrue(eff > 0 && eff <= 1)
        XCTAssertNotNil(res.daily.restingHr)
        XCTAssertNotNil(res.restScore)
        XCTAssertNotNil(res.cachedSleep.first?.stagesJSON)
    }

    func testWithNoStreamsEveryFieldIsAbsentRatherThanZero() {
        let res = DayEngine.analyzeDay(day: "2026-07-15", profile: profile)
        XCTAssertNil(res.daily.totalSleepMin)
        XCTAssertNil(res.daily.efficiency)
        XCTAssertNil(res.daily.disturbances)
        XCTAssertNil(res.daily.restingHr)
        XCTAssertNil(res.daily.recovery)
        XCTAssertNil(res.daily.steps)
        XCTAssertTrue(res.sleepSessions.isEmpty)
        XCTAssertEqual(res.chargeConfidence, ScoreConfidence.calibrating)
        XCTAssertEqual(res.restConfidence, ScoreConfidence.calibrating)
    }

    func testLatencyIsAlwaysAbsent() {
        // The strap gives no lights-out reference to measure one from.
        let n = nightStreams(endingOn: "2026-07-15")
        let res = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                       profile: profile)
        XCTAssertNil(res.daily.solMin)
    }

    func testANightWithNoREMReportsNoLatencyRatherThanNaN() {
        // A NaN reaching a stored column poisons every later mean over it.
        let n = nightStreams(endingOn: "2026-07-15")
        let res = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                       profile: profile)
        if let l = res.daily.remLatencyMin { XCTAssertFalse(l.isNaN) }
    }

    func testTheMainNightIsScoredAndTheNapIsNot() throws {
        // Both end on the day; only one is "your night".
        let key = "2026-07-15"
        var n = nightStreams(endingOn: key)
        let napStart = day(key) + 14 * 3600
        for i in 0..<(50 * 60) {
            n.g.append(GravitySample(ts: napStart + i, x: 0, y: 0, z: 1))
            n.h.append(HRSample(ts: napStart + i, bpm: 46))
            n.r.append(RRInterval(ts: napStart + i, rrMs: 1300 + (i % 2 == 0 ? 40 : -40)))
        }
        let res = DayEngine.analyzeDay(day: key, hr: n.h, rr: n.r, gravity: n.g, profile: profile)
        let tst = try XCTUnwrap(res.daily.totalSleepMin)
        XCTAssertLessThan(tst, 7 * 60 + 50, "the nap must not be summed into the night")
        XCTAssertGreaterThan(res.sleepSessions.count, 0)
    }

    func testANapOnlyDayDoesNotSeedTheBaselines() {
        // A nap's resting HR sits well above a night's; letting it seed the baselines drags every
        // later Charge with it.
        let key = "2026-07-15"
        let start = day(key) + 13 * 3600
        var g: [GravitySample] = [], h: [HRSample] = [], r: [RRInterval] = []
        for i in -3600..<0 {
            g.append(GravitySample(ts: start + i, x: Double(i % 2) * 0.5, y: 0, z: 1))
            h.append(HRSample(ts: start + i, bpm: 82))
            r.append(RRInterval(ts: start + i, rrMs: 730))
        }
        for i in 0..<(45 * 60) {
            g.append(GravitySample(ts: start + i, x: 0, y: 0, z: 1))
            h.append(HRSample(ts: start + i, bpm: 46))
            r.append(RRInterval(ts: start + i, rrMs: 1300 + (i % 2 == 0 ? 40 : -40)))
        }
        for i in 0..<3600 {
            g.append(GravitySample(ts: start + 45 * 60 + i, x: Double(i % 2) * 0.5, y: 0, z: 1))
            h.append(HRSample(ts: start + 45 * 60 + i, bpm: 82))
            r.append(RRInterval(ts: start + 45 * 60 + i, rrMs: 730))
        }
        let res = DayEngine.analyzeDay(day: key, hr: h, rr: r, gravity: g, profile: profile)
        XCTAssertFalse(res.sleepSessions.isEmpty, "the nap is still a real session")
        XCTAssertNil(res.daily.restingHr, "but it is not the day's resting physiology")
        XCTAssertNil(res.daily.avgHrv)
    }

    func testEffortFallsBackToTheWearersOwnRestingHRWhenNoNightWasBanked() throws {
        // A day with no session is exactly a day with a capture hole. Scoring it against a generic
        // stranger suppresses Effort further on the days already missing hours.
        let key = "2026-07-15"
        let base = day(key)
        let hr = (0..<7200).map { HRSample(ts: base + 8 * 3600 + $0, bpm: 157) }
        let generic = DayEngine.analyzeDay(day: key, hr: hr, dayHr: hr, profile: profile)
        let personal = DayEngine.analyzeDay(day: key, hr: hr, dayHr: hr, profile: profile,
                                            restingHRFallbackBpm: 46)
        XCTAssertTrue(generic.sleepSessions.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(personal.strain), try XCTUnwrap(generic.strain))
    }

    func testACaptureHoleIsFlaggedWithoutRescalingTheScore() throws {
        // The hole's contents are unknowable, so the number stays and the tier says so.
        let key = "2026-07-15"
        let hr = (0..<40_000).map { HRSample(ts: day(key) + $0, bpm: 95) }
        let full = DayEngine.analyzeDay(day: key, hr: hr, dayHr: hr, profile: profile,
                                        dayCoverage: 1.0)
        let holed = DayEngine.analyzeDay(day: key, hr: hr, dayHr: hr, profile: profile,
                                         dayCoverage: 0.5)
        XCTAssertEqual(full.strain, holed.strain)
        XCTAssertEqual(full.effortConfidence, ScoreConfidence.solid)
        XCTAssertEqual(holed.effortConfidence, ScoreConfidence.building)
    }

    func testUngradedCoverageNeverFlagsTheLiveDay() {
        let key = "2026-07-15"
        let hr = (0..<40_000).map { HRSample(ts: day(key) + $0, bpm: 95) }
        XCTAssertEqual(DayEngine.analyzeDay(day: key, hr: hr, dayHr: hr, profile: profile)
                        .effortConfidence, ScoreConfidence.solid)
    }

    func testOnlySamplesFromTheDayCountTowardTheAdditiveTotals() {
        let key = "2026-07-15"
        let steps = [StepSample(ts: day(key) - 100, counter: 0),
                     StepSample(ts: day(key) - 50, counter: 5_000),
                     StepSample(ts: day(key) + 100, counter: 5_000),
                     StepSample(ts: day(key) + 200, counter: 5_100)]
        let res = DayEngine.analyzeDay(day: key, daySteps: steps, profile: profile)
        XCTAssertEqual(res.daily.steps, 100, "yesterday's walking is yesterday's")
    }

    func testAWesternOffsetMovesWhichSamplesBelongToTheDay() {
        let key = "2026-07-15"
        // 01:00 UTC is still the 14th at −5 h.
        let steps = [StepSample(ts: day(key) + 3600, counter: 0),
                     StepSample(ts: day(key) + 3700, counter: 400)]
        XCTAssertEqual(DayEngine.analyzeDay(day: key, daySteps: steps, profile: profile)
                        .daily.steps, 400)
        XCTAssertNil(DayEngine.analyzeDay(day: key, daySteps: steps, profile: profile,
                                          tzOffsetSeconds: -5 * 3600).daily.steps)
    }

    func testChargeNeedsABaselineBeforeItScores() {
        let n = nightStreams(endingOn: "2026-07-15")
        let cold = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                        profile: profile)
        XCTAssertNil(cold.recovery)
        XCTAssertTrue(cold.chargeDrivers.isEmpty, "no score, nothing to explain")
        XCTAssertEqual(cold.chargeConfidence, ScoreConfidence.calibrating)
    }

    func testDriversAppearOnlyAlongsideAScore() throws {
        let n = nightStreams(endingOn: "2026-07-15")
        let hrvHistory: [Double?] = (0..<40).map { _ in 95.0 }
        let base = Baselines.foldHistory(hrvHistory, cfg: Baselines.metricCfg["hrv"]!)
        let res = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                       profile: profile,
                                       baselines: DayEngine.ProfileBaselines(hrv: base))
        XCTAssertNotNil(res.recovery)
        XCTAssertFalse(res.chargeDrivers.isEmpty)
        XCTAssertNotEqual(res.chargeConfidence, ScoreConfidence.calibrating)
    }

    func testPerEpochMotionIsAbsentRatherThanFlatWhenItCannotBeGridded() {
        let key = "2026-07-15"
        let n = nightStreams(endingOn: key)
        let res = DayEngine.analyzeDay(day: key, hr: n.h, rr: n.r, gravity: n.g, profile: profile)
        for s in res.sleepSessions {
            if let m = res.sessionMotionByStart[s.start] { XCTAssertFalse(m.isEmpty) }
        }
        let none = DayEngine.analyzeDay(day: key, hr: n.h, rr: n.r, gravity: n.g,
                                        profile: profile).sessionMotionByStart
        XCTAssertEqual(Set(none.keys).subtracting(res.sleepSessions.map(\.start)), [])
    }

    func testTheSameStreamsAlwaysGiveTheSameRow() {
        let n = nightStreams(endingOn: "2026-07-15")
        let a = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                     profile: profile)
        let b = DayEngine.analyzeDay(day: "2026-07-15", hr: n.h, rr: n.r, gravity: n.g,
                                     profile: profile)
        XCTAssertEqual(a.daily, b.daily)
        XCTAssertEqual(a.cachedSleep, b.cachedSleep)
    }
}
