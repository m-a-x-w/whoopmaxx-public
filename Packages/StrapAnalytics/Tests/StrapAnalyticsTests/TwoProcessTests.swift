import XCTest
@testable import StrapAnalytics

final class CircadianPrimitiveTests: XCTestCase {

    func testWrap24HandlesNegativesAndOverflow() {
        XCTAssertEqual(Circadian.wrap24(25), 1, accuracy: 1e-12)
        XCTAssertEqual(Circadian.wrap24(-1), 23, accuracy: 1e-12)
        XCTAssertEqual(Circadian.wrap24(-25), 23, accuracy: 1e-12)
        XCTAssertEqual(Circadian.wrap24(0), 0, accuracy: 1e-12)
        XCTAssertEqual(Circadian.wrap24(24), 0, accuracy: 1e-12)
    }

    func testClockString() {
        XCTAssertEqual(Circadian.clockString(23.5), "23:30")
        XCTAssertEqual(Circadian.clockString(0), "00:00")
        XCTAssertEqual(Circadian.clockString(25), "01:00")
        XCTAssertEqual(Circadian.clockString(23.999), "00:00", "rounding to 60 carries the hour")
    }
}

final class TwoProcessTests: XCTestCase {

    func testPressureRisesAwakeAndFallsAsleep() {
        let after8Awake = TwoProcessModel.sAfterWake(hoursAwake: 8, from: 0.2)
        XCTAssertGreaterThan(after8Awake, 0.2)
        XCTAssertLessThan(TwoProcessModel.sAfterSleep(hoursAsleep: 8, from: 0.9), 0.9)
    }

    func testPressureIsBoundedToZeroOne() {
        XCTAssertLessThanOrEqual(TwoProcessModel.sAfterWake(hoursAwake: 1000, from: 0.5), 1.0)
        XCTAssertGreaterThanOrEqual(TwoProcessModel.sAfterSleep(hoursAsleep: 1000, from: 0.9), 0.0)
        XCTAssertEqual(TwoProcessModel.sAfterWake(hoursAwake: -5, from: 0.4), 0.4, accuracy: 1e-12)
    }

    func testPressureDrainsFasterThanItBuilds() {
        // One long night clears a deficit that took days to build — that asymmetry IS the model.
        XCTAssertLessThan(TwoProcessModel.tauDecayHours, TwoProcessModel.tauRiseHours)
        let built = TwoProcessModel.sAfterWake(hoursAwake: 8, from: 0.2) - 0.2
        let drained = 0.9 - TwoProcessModel.sAfterSleep(hoursAsleep: 8, from: 0.9)
        XCTAssertGreaterThan(drained, built)
    }

    func testAShortNightLeavesResidualPressure() {
        // Integrating the whole history is why debt carries; starting from the last wake would
        // erase exactly what the model exists to represent.
        let day = 86_400
        func night(_ i: Int, hours: Double) -> TwoProcessModel.SleepSpan {
            TwoProcessModel.SleepSpan(start: i * day, end: i * day + Int(hours * 3600))
        }
        let rested = (0..<10).map { night($0, hours: 8) }
        let deprived = (0..<10).map { night($0, hours: 4) }
        let sRested = TwoProcessModel.homeostaticPressureAtWake(spans: rested)!
        let sDeprived = TwoProcessModel.homeostaticPressureAtWake(spans: deprived)!
        XCTAssertGreaterThan(sDeprived, sRested, "short nights leave the morning under more pressure")
    }

    func testHistoryNeedsAtLeastOneSpan() {
        XCTAssertNil(TwoProcessModel.homeostaticPressureAtWake(spans: []))
        XCTAssertNil(TwoProcessModel.homeostaticPressureAtWake(
            spans: [TwoProcessModel.SleepSpan(start: 100, end: 100)]), "a zero-length span is not a night")
    }

    func testTheWakeMaintenanceZoneMakesSleepHarderBeforeItGetsEasier() {
        // The paradox the model exists to capture: a few hours before the circadian low, the body
        // resists sleep despite mounting pressure.
        let tempMin = 4.0
        let wmz = Circadian.wrap24(tempMin - TwoProcessModel.wakeMaintenanceLeadHours)
        let atWMZ = TwoProcessModel.circadianThreshold(clockHour: wmz, tempMinHour: tempMin)
        let atLow = TwoProcessModel.circadianThreshold(clockHour: tempMin, tempMinHour: tempMin)
        XCTAssertGreaterThan(atWMZ, atLow, "the threshold peaks in the wake-maintenance zone")
    }

    func testOnsetLatencyIsBoundedAndMonotone() {
        let easy = TwoProcessModel.onsetLatencyMinutes(margin: 0.5)
        let hard = TwoProcessModel.onsetLatencyMinutes(margin: -0.5)
        XCTAssertLessThan(easy, hard, "more pressure over threshold means faster onset")
        for m in [-10.0, -1, 0, 1, 10] {
            let v = TwoProcessModel.onsetLatencyMinutes(margin: m)
            XCTAssertGreaterThanOrEqual(v, TwoProcessModel.solFloorMinutes, "nobody falls asleep instantly")
            XCTAssertLessThanOrEqual(v, TwoProcessModel.solCeilMinutes)
        }
    }

    func testAnUnreadablePhaseProducesNoRecommendation() {
        // Advice resting on a phase we could not fit would be advice shaped like evidence.
        XCTAssertNil(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7, tempMinHour: 4,
                                               needHours: 8, wakeTargetHour: nil,
                                               phaseConfidence: .unreadable))
    }

    func testARecommendationLandsInTheEvening() throws {
        let r = try XCTUnwrap(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7,
                                                        tempMinHour: 4, needHours: 8,
                                                        wakeTargetHour: nil, phaseConfidence: .solid))
        XCTAssertGreaterThanOrEqual(r.targetBedtimeHour, 19)
        XCTAssertLessThanOrEqual(r.earliestHour, r.latestHour + 24)
        XCTAssertFalse(r.rationale.isEmpty)
        XCTAssertTrue(r.note.contains("not medical advice"))
    }

    func testAnEarlyWakeTargetPullsBedtimeForwardAndSaysSo() throws {
        let free = try XCTUnwrap(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7,
                                                           tempMinHour: 4, needHours: 8,
                                                           wakeTargetHour: nil, phaseConfidence: .solid))
        let constrained = try XCTUnwrap(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7,
                                                                  tempMinHour: 4, needHours: 9,
                                                                  wakeTargetHour: 5,
                                                                  phaseConfidence: .solid))
        XCTAssertTrue(constrained.constrainedByWake)
        XCTAssertFalse(free.constrainedByWake)
        XCTAssertTrue(constrained.rationale.contains("05:00"))
    }

    func testAWideFitIsHedgedInTheNote() throws {
        let r = try XCTUnwrap(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7,
                                                        tempMinHour: 4, needHours: 8,
                                                        wakeTargetHour: nil, phaseConfidence: .wide))
        XCTAssertTrue(r.note.contains("soft nudge"))
    }

    func testTooFewNightsGivesNoRecommendation() {
        let spans = (0..<2).map { TwoProcessModel.SleepSpan(start: $0 * 86_400, end: $0 * 86_400 + 28_800) }
        XCTAssertNil(TwoProcessModel.recommendBedtime(spans: spans, habitualWakeHour: 7,
                                                      tempMinHour: 4, needHours: 8,
                                                      wakeTargetHour: nil, phaseConfidence: .solid))
    }

    func testEnoughNightsProducesOne() {
        let spans = (0..<10).map { TwoProcessModel.SleepSpan(start: $0 * 86_400, end: $0 * 86_400 + 28_800) }
        XCTAssertNotNil(TwoProcessModel.recommendBedtime(spans: spans, habitualWakeHour: 7,
                                                         tempMinHour: 4, needHours: 8,
                                                         wakeTargetHour: nil, phaseConfidence: .solid))
    }

    func testPredictedOnsetIsReportedWithTheRecommendation() throws {
        let r = try XCTUnwrap(TwoProcessModel.recommend(sAtWake: 0.2, habitualWakeHour: 7,
                                                        tempMinHour: 4, needHours: 8,
                                                        wakeTargetHour: nil, phaseConfidence: .solid))
        XCTAssertGreaterThanOrEqual(r.predictedOnsetMinutes, TwoProcessModel.solFloorMinutes)
        XCTAssertGreaterThan(r.homeostaticPressure, 0)
    }
}
