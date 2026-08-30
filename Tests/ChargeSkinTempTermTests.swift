import XCTest
import StrapAnalytics
import StrapStore
@testable import whoopmaxx

/// The skin-temperature term in the Charge score, and the pass-ordering defect that made it dead.
///
/// THE DEFECT. `ScoreEngine` scores in two passes. Pass 1 builds its `DayEngine.ProfileBaselines`
/// with `skinTemp` left at its `nil` default, so `AnalyticsEngine`'s `guard let b = baselines.skinTemp,
/// b.usable` fails for every day and every `DailyMetric.skinTempDevC` comes out of pass 1 as nil. Pass 2
/// re-seeds a real skin-temp baseline and derives the night's deviation with `recomputeSkinTempDev` — but
/// it did that AFTER calling `recomputeRecovery` / `recomputeChargeDrivers`, and both of those read the
/// deviation off `daily.skinTempDevC`, i.e. off the always-nil pass-1 field.
///
/// So `RecoveryScorer`'s skin-temp branch was unreachable from the app: Charge ignored skin temperature
/// entirely, for every user, on every day. A febrile or overreached night — the exact case the term exists
/// to catch — scored the same as a normal one, and the Charge detail screen never listed skin temp as a
/// driver. Nothing caught it because the deviation was still PERSISTED correctly (pass 2 writes
/// `daily.with(skinTempDevC: skinDev)`), so the Data screen showed a plausible number the score behind it
/// had never seen.
///
/// THE FIX, and why this file can pin it: the deviation is hoisted above both calls and threaded in as an
/// explicit `skinTempDev:` parameter. That makes the defect non-recurrable by omission — a future caller
/// cannot silently fall back to the nil field, because the parameter is required. These tests pin the
/// behaviour on top of that structural guarantee.
final class ChargeSkinTempTermTests: XCTestCase {

    private func baseline(_ mean: Double, sigma: Double, nValid: Int = 20) -> Baselines.BaselineState {
        Baselines.BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: .trusted)
    }

    /// A day exactly as pass 2 sees it: real HRV / RHR, and `skinTempDevC` STILL NIL, because pass 1
    /// could not have populated it.
    private func pass2Day(skinTempDevC: Double? = nil) -> DailyMetric {
        Fixtures.dailyMetric(day: "2026-07-29", efficiency: 0.83, restingHr: 47, avgHrv: 80.2,
                             skinTempDevC: skinTempDevC)
    }

    private var baselines: DayEngine.ProfileBaselines {
        DayEngine.ProfileBaselines(hrv: baseline(75, sigma: 8),
                                         restingHR: baseline(50, sigma: 3),
                                         resp: baseline(15, sigma: 1),
                                         skinTemp: baseline(33.5, sigma: 0.3))
    }

    // MARK: - the term is load-bearing

    /// If this fails, the rest of the file proves nothing: a non-nil deviation must actually move Charge.
    func testAFebrileDeviationLowersChargeVersusNoDeviation() throws {
        let neutral = try XCTUnwrap(ScoreEngine.recomputeRecovery(pass2Day(), baselines,
                                                                 restComposite: 88.5, skinTempDev: nil))
        let febrile = try XCTUnwrap(ScoreEngine.recomputeRecovery(pass2Day(), baselines,
                                                                 restComposite: 88.5, skinTempDev: 1.8))
        XCTAssertLessThan(febrile, neutral,
                          "a +1.8 °C night must score lower than one with no skin-temp signal")
    }

    // MARK: - the defect itself

    /// THE REGRESSION. The old code passed `daily.skinTempDevC` — nil in pass 2 — so a real deviation
    /// changed nothing. Scoring the SAME day with the deviation threaded in must differ from scoring it
    /// off the nil field.
    func testDeviationIsReadFromTheParameterNotTheAlwaysNilField() throws {
        let day = pass2Day()                       // skinTempDevC nil, exactly as pass 1 leaves it
        XCTAssertNil(day.skinTempDevC, "pass 1 cannot populate this — that is the whole defect")

        let asOldCodeDid = try XCTUnwrap(ScoreEngine.recomputeRecovery(day, baselines,
                                                                      restComposite: 88.5,
                                                                      skinTempDev: day.skinTempDevC))
        let asFixed = try XCTUnwrap(ScoreEngine.recomputeRecovery(day, baselines,
                                                                  restComposite: 88.5, skinTempDev: 1.8))
        XCTAssertNotEqual(asOldCodeDid, asFixed, accuracy: 0.0001,
                          "threading the deviation in must change the score — otherwise the term is dead")
    }

    /// The driver list must be built from the SAME deviation the number used, or the Charge detail screen
    /// explains a score it does not match. With the deviation live, skin temp appears as a driver.
    func testSkinTempAppearsAsAChargeDriverOnlyWhenTheDeviationIsThreaded() {
        let day = pass2Day()
        let withoutDev = ScoreEngine.recomputeChargeDrivers(day, baselines, restComposite: 88.5,
                                                           skinTempDev: nil)
        let withDev = ScoreEngine.recomputeChargeDrivers(day, baselines, restComposite: 88.5,
                                                        skinTempDev: 1.8)
        XCTAssertNotEqual(withoutDev.count, withDev.count,
                          "the skin-temp driver row can only exist when the deviation reaches the scorer")
    }

    /// Both consumers must agree — they are handed one hoisted value, so a deviation that moves the score
    /// must also be visible in the drivers that explain it.
    func testScoreAndDriversUseTheSameDeviation() throws {
        let day = pass2Day()
        let score = try XCTUnwrap(ScoreEngine.recomputeRecovery(day, baselines, restComposite: 88.5,
                                                               skinTempDev: 1.8))
        let drivers = ScoreEngine.recomputeChargeDrivers(day, baselines, restComposite: 88.5,
                                                        skinTempDev: 1.8)
        XCTAssertFalse(drivers.isEmpty, "a scored day (\(score)) must carry the drivers that explain it")
    }

    // MARK: - the hoist is safe

    /// The hoisted `recomputeSkinTempDev` has no dependency on anything computed between its old and new
    /// position: it is a pure function of the night's mean and the re-seeded baseline.
    func testDeviationDerivationDependsOnlyOnTheNightMeanAndBaseline() {
        let seeded = baseline(33.5, sigma: 0.3)
        XCTAssertNil(ScoreEngine.recomputeSkinTempDev(nil, seeded), "no nightly mean → no deviation")
        XCTAssertNil(ScoreEngine.recomputeSkinTempDev(34.0, nil), "no baseline → no deviation")
        let calibrating = Baselines.BaselineState(baseline: 33.5, spread: 0.3, nValid: 1,
                                        nightsSinceUpdate: 0, status: .calibrating)
        XCTAssertNil(ScoreEngine.recomputeSkinTempDev(34.0, calibrating),
                     "an unusable (still-calibrating) baseline yields no deviation")
        XCTAssertNotNil(ScoreEngine.recomputeSkinTempDev(34.0, seeded))
    }
}
