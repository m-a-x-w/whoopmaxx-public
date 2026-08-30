import XCTest
import StrapStore
@testable import whoopmaxx

/// `DailyMetric.efficiency` is a 0–1 fraction (engine: asleep/in-bed); `RestNight.efficiency` is a 0–100
/// percent (the Rest screen renders it with "%"). The conversion must scale ×100 — a latent bug that
/// showed sleep efficiency as "1 %" for real data (a prior DemoSeed stored 0–100 and masked it).
final class RestNightEfficiencyTests: XCTestCase {

    func testEfficiencyFractionScaledToPercent() {
        let night = RestNight(day: Fixtures.dailyMetric(day: "2026-07-16", totalSleepMin: 400,
                                                       efficiency: 0.83),
                              score: 80, session: nil)
        XCTAssertEqual(night.efficiency ?? -1, 83, accuracy: 0.0001)   // 0.83 → 83%
    }

    func testEfficiencyNilStaysNil() {
        XCTAssertNil(RestNight(day: Fixtures.dailyMetric(day: "2026-07-16", totalSleepMin: 400),
                               score: 80, session: nil).efficiency)
    }
}
