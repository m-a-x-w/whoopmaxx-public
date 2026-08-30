import XCTest
@testable import StrapAnalytics

final class BatteryEstimatorTests: XCTestCase {

    private let rated = BatteryEstimator.ratedLifeHoursWhoop4

    /// Readings every hour, dropping `pctPerHour`, starting at `from`.
    private func discharge(from: Double, pctPerHour: Double, hours: Int,
                           startTs: Int = 0) -> [(ts: Int, soc: Double)] {
        (0...hours).map { (ts: startTs + $0 * 3600, soc: from - Double($0) * pctPerHour) }
    }

    func testAMeasuredRateBeatsTheRatedFigure() throws {
        // Rated life assumes a usage pattern nobody has. Telling a heavy user twelve days when
        // they have two is worse than not answering.
        let heavy = discharge(from: 100, pctPerHour: 4, hours: 10)
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: heavy, ratedHours: rated))
        XCTAssertEqual(e.source, .measured)
        XCTAssertEqual(e.remainingHours, 60.0 / 4.0, accuracy: 0.5)
        XCTAssertLessThan(e.remainingHours, rated)
    }

    func testTooShortASpanFallsBackToRated() {
        let brief = discharge(from: 100, pctPerHour: 2, hours: 1)
        let e = BatteryEstimator.estimate(samples: brief, ratedHours: rated)!
        XCTAssertEqual(e.source, .rated)
    }

    func testTooSmallADropFallsBackToRated() {
        // Below the gate the slope is dominated by the resolution of the reported percentage.
        let flat = discharge(from: 100, pctPerHour: 0.1, hours: 10)
        XCTAssertEqual(BatteryEstimator.estimate(samples: flat, ratedHours: rated)!.source, .rated)
    }

    func testAChargeInsideTheBufferDoesNotDefeatTheFit() throws {
        // Net change across the whole buffer is positive, so an unwindowed fit sees no discharge
        // and silently falls back to rated.
        var s = discharge(from: 40, pctPerHour: 2, hours: 5)                    // old discharge
        s += [(ts: 6 * 3600, soc: 100)]                                          // charged
        s += discharge(from: 100, pctPerHour: 3, hours: 8, startTs: 7 * 3600)   // new discharge
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours: rated))
        XCTAssertEqual(e.source, .measured, "the window skipped past the charge")
        XCTAssertEqual(e.currentSoc, 76, accuracy: 1e-9)

        // The fit anchors ON the charge reading, so the window spans 9 h for a 24-point drop
        // rather than 8 h — 2.67%/h, not 3. That dilution is real and slightly conservative:
        // the hour sitting at full charge genuinely elapsed. Pinned rather than smoothed over.
        XCTAssertEqual(e.remainingHours, 76.0 / (24.0 / 9.0), accuracy: 0.5)
        XCTAssertLessThan(e.remainingHours, rated)
    }

    func testAPartialTopUpDoesNotFlattenTheRate() throws {
        // A few minutes on the charger mid-discharge would otherwise halve the apparent rate.
        let clean = discharge(from: 100, pctPerHour: 3, hours: 10)
        var withTopUp = clean
        withTopUp += [(ts: 11 * 3600, soc: 80)]                                  // partial top-up
        withTopUp += discharge(from: 80, pctPerHour: 3, hours: 3, startTs: 12 * 3600)
        let a = try XCTUnwrap(BatteryEstimator.estimate(samples: clean, ratedHours: rated))
        let b = try XCTUnwrap(BatteryEstimator.estimate(samples: withTopUp, ratedHours: rated))
        XCTAssertEqual(a.source, .measured)
        XCTAssertEqual(b.source, .measured)
        // Both fit ~3%/h; b is anchored on its own lower current charge.
        XCTAssertEqual(b.remainingHours, b.currentSoc / 3.0, accuracy: 1.5)
    }

    func testAStrapThatNeverReachesNearFullStillFits() throws {
        // Routine on a 12-day strap. Anchoring at the oldest reading instead of the highest makes
        // the window net to a RISE and leaves the estimate stuck on rated forever.
        var s = discharge(from: 60, pctPerHour: 2, hours: 4)
        s += [(ts: 5 * 3600, soc: 85)]                                           // top-up below 90
        s += discharge(from: 85, pctPerHour: 2, hours: 10, startTs: 6 * 3600)
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours:
                                                        BatteryEstimator.ratedLifeHoursWhoop5))
        XCTAssertEqual(e.source, .measured)
    }

    func testTheEstimateIsAnchoredOnTheLatestCharge() throws {
        // The question is how long from NOW, not from the end of the last clean segment.
        let s = discharge(from: 100, pctPerHour: 5, hours: 12)
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours: rated))
        XCTAssertEqual(e.currentSoc, 40, accuracy: 1e-9)
        XCTAssertEqual(e.remainingHours, 8, accuracy: 0.5)
    }

    func testAnAbsurdRateIsClamped() throws {
        // A near-flat run that squeaked past the drop gate would otherwise promise months.
        let s: [(ts: Int, soc: Double)] = [(ts: 0, soc: 100), (ts: 100 * 3600, soc: 97.5)]
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours: rated))
        XCTAssertLessThanOrEqual(e.remainingHours, rated * 1.5)
    }

    func testAFlatDeadBattery() throws {
        let s = discharge(from: 3, pctPerHour: 0.2, hours: 12)
        let e = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours: rated))
        XCTAssertGreaterThanOrEqual(e.remainingHours, 0)
    }

    func testNoReadings() {
        XCTAssertNil(BatteryEstimator.estimate(samples: [], ratedHours: rated))
    }

    func testUnsortedInputIsOrdered() throws {
        let s = discharge(from: 100, pctPerHour: 4, hours: 10)
        let a = try XCTUnwrap(BatteryEstimator.estimate(samples: s, ratedHours: rated))
        let b = try XCTUnwrap(BatteryEstimator.estimate(samples: s.shuffled(), ratedHours: rated))
        XCTAssertEqual(a.remainingHours, b.remainingHours, accuracy: 1e-9)
    }

    func testLabelSwitchesUnitsAtTwoDays() {
        XCTAssertEqual(BatteryEstimator.label(hours: 6), "~6h")
        XCTAssertEqual(BatteryEstimator.label(hours: 47), "~47h")
        XCTAssertEqual(BatteryEstimator.label(hours: 48), "~2.0 days")
        XCTAssertEqual(BatteryEstimator.label(hours: 108), "~4.5 days")
    }
}
