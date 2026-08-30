import XCTest
@testable import StrapAnalytics

final class CosinorTests: XCTestCase {

    /// 24 hourly bins with a cosine peaking at `peakHour`.
    private func bins(peakHour: Double, mesor: Double = 100, amplitude: Double = 40) -> [CircadianEngine.ActivityBin] {
        (0..<24).map { h in
            let v = mesor + amplitude * cos(2 * .pi * (Double(h) - peakHour) / 24)
            return CircadianEngine.ActivityBin(hour: Double(h), activity: v)
        }
    }

    func testTheFitRecoversAKnownPeak() throws {
        for peak in [3.0, 9.0, 15.0, 21.0] {
            let f = try XCTUnwrap(CircadianEngine.cosinor(bins(peakHour: peak)))
            XCTAssertEqual(f.acrophaseHours, peak, accuracy: 0.01, "peak \(peak)")
        }
    }

    func testTheFitRecoversMesorAndAmplitude() throws {
        let f = try XCTUnwrap(CircadianEngine.cosinor(bins(peakHour: 15, mesor: 120, amplitude: 30)))
        XCTAssertEqual(f.mesor, 120, accuracy: 0.01)
        XCTAssertEqual(f.amplitude, 30, accuracy: 0.01)
    }

    func testAcrophaseIsAlwaysInRange() throws {
        for peak in stride(from: 0.0, to: 24.0, by: 1.0) {
            let f = try XCTUnwrap(CircadianEngine.cosinor(bins(peakHour: peak)))
            XCTAssertGreaterThanOrEqual(f.acrophaseHours, 0)
            XCTAssertLessThan(f.acrophaseHours, 24)
        }
    }

    func testTooFewBins() {
        XCTAssertNil(CircadianEngine.cosinor([]))
        XCTAssertNil(CircadianEngine.cosinor([CircadianEngine.ActivityBin(hour: 1, activity: 1),
                                              CircadianEngine.ActivityBin(hour: 2, activity: 2)]))
    }

    func testBinsClusteredInOnePartOfTheDayHaveNoFit() {
        // A singular system means the bins do not span enough of the cycle to place a phase.
        let clustered = (0..<4).map { CircadianEngine.ActivityBin(hour: 9, activity: Double($0)) }
        XCTAssertNil(CircadianEngine.cosinor(clustered))
    }

    func testAFlatSeriesFitsWithNoAmplitude() throws {
        let flat = (0..<24).map { CircadianEngine.ActivityBin(hour: Double($0), activity: 50) }
        let f = try XCTUnwrap(CircadianEngine.cosinor(flat))
        XCTAssertEqual(f.amplitude, 0, accuracy: 1e-9)
        XCTAssertEqual(f.mesor, 50, accuracy: 1e-9)
    }
}

final class PhaseEstimateTests: XCTestCase {

    private func bins(peakHour: Double, amplitude: Double = 40) -> [CircadianEngine.ActivityBin] {
        (0..<24).map { h in
            CircadianEngine.ActivityBin(hour: Double(h),
                                        activity: 100 + amplitude * cos(2 * .pi * (Double(h) - peakHour) / 24))
        }
    }

    func testAnEntrainedSleeperReadsAsAligned() throws {
        // Wake at 07:00 puts the ideal temperature minimum at 04:30, so activity should peak
        // about twelve hours later — around 16:30.
        let p = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16.5),
                                                            daysObserved: 20, habitualWakeHour: 7))
        XCTAssertEqual(p.confidence, .solid)
        XCTAssertLessThan(abs(p.offsetVsScheduleMinutes), 20)
        XCTAssertTrue(p.note.contains("well-aligned"))
    }

    func testANightOwlLeansLate() throws {
        let p = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 20),
                                                            daysObserved: 20, habitualWakeHour: 7))
        XCTAssertGreaterThan(p.offsetVsScheduleMinutes, 20)
        XCTAssertTrue(p.note.contains("night-owl"))
    }

    func testAMorningLarkLeansEarly() throws {
        let p = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 13),
                                                            daysObserved: 20, habitualWakeHour: 7))
        XCTAssertLessThan(p.offsetVsScheduleMinutes, -20)
        XCTAssertTrue(p.note.contains("morning-lark"))
    }

    func testThinDataIsFlaggedUnreadableRatherThanReturningNothing() throws {
        // Returning nil leaves the surface with nothing to say. A flagged reading lets it say
        // "hard to read right now", which is both true and actionable.
        let p = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16),
                                                            daysObserved: 3, habitualWakeHour: 7))
        XCTAssertEqual(p.confidence, .unreadable)
        XCTAssertEqual(p.offsetVsScheduleMinutes, 0, "no lean is claimed from an unreadable fit")
        XCTAssertTrue(p.note.contains("keep wearing"))
    }

    func testAnArrhythmicSeriesIsUnreadableEvenWithManyDays() throws {
        // A nearly flat fit still has a mathematical peak; reporting it would give a confident
        // body-clock reading for shift work or illness.
        let p = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16, amplitude: 1),
                                                            daysObserved: 60, habitualWakeHour: 7))
        XCTAssertEqual(p.confidence, .unreadable)
    }

    func testConfidenceLadder() throws {
        let wide = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16),
                                                               daysObserved: 8, habitualWakeHour: 7))
        XCTAssertEqual(wide.confidence, .wide)
        let solid = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16),
                                                                daysObserved: 14, habitualWakeHour: 7))
        XCTAssertEqual(solid.confidence, .solid)
    }

    func testAnObservedTemperatureMinimumOverridesTheDerivedOne() throws {
        let derived = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16),
                                                                  daysObserved: 20, habitualWakeHour: 7))
        let observed = try XCTUnwrap(CircadianEngine.estimatePhase(bins: bins(peakHour: 16),
                                                                   daysObserved: 20, habitualWakeHour: 7,
                                                                   observedTempMinHour: 2.0))
        XCTAssertEqual(observed.tempMinHour, 2.0)
        XCTAssertNotEqual(derived.tempMinHour, 2.0)
    }

    func testNoFitAtAllReturnsNil() {
        XCTAssertNil(CircadianEngine.estimatePhase(bins: [], daysObserved: 30, habitualWakeHour: 7))
    }
}

final class ClockArithmeticTests: XCTestCase {

    func testSignedDeltaTakesTheShortWayRound() {
        // Plain subtraction is wrong by a day for half its range: 23:00 to 01:00 is +2, not -22.
        XCTAssertEqual(CircadianEngine.signedHourDelta(from: 23, to: 1), 2, accuracy: 1e-12)
        XCTAssertEqual(CircadianEngine.signedHourDelta(from: 1, to: 23), -2, accuracy: 1e-12)
        XCTAssertEqual(CircadianEngine.signedHourDelta(from: 7, to: 9), 2, accuracy: 1e-12)
        XCTAssertEqual(CircadianEngine.signedHourDelta(from: 9, to: 7), -2, accuracy: 1e-12)
    }

    func testSignedDeltaIsBoundedToHalfADay() {
        for a in stride(from: 0.0, to: 24.0, by: 0.5) {
            for b in stride(from: 0.0, to: 24.0, by: 0.5) {
                let d = CircadianEngine.signedHourDelta(from: a, to: b)
                XCTAssertGreaterThan(d, -12.0001)
                XCTAssertLessThanOrEqual(d, 12.0)
            }
        }
    }
}
