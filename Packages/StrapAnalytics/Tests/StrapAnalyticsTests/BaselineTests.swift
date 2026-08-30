import XCTest
@testable import StrapAnalytics

final class BaselineTests: XCTestCase {

    private let hrv = Baselines.hrvCfg

    func testFirstNightSeedsTheCentreOnTheValueItself() {
        let s = Baselines.update(nil, value: 60, cfg: hrv)
        XCTAssertEqual(s.baseline, 60)
        XCTAssertEqual(s.nValid, 1)
        XCTAssertEqual(s.status, .calibrating)
    }

    func testStatusLadder() {
        var s: Baselines.BaselineState?
        for i in 1...20 {
            s = Baselines.update(s, value: 60, cfg: hrv)
            switch i {
            case ..<4:   XCTAssertEqual(s!.status, .calibrating, "night \(i)")
            case ..<14:  XCTAssertEqual(s!.status, .provisional, "night \(i)")
            default:     XCTAssertEqual(s!.status, .trusted, "night \(i)")
            }
        }
        XCTAssertTrue(s!.trusted)
        XCTAssertTrue(s!.usable)
    }

    func testAMissingNightHoldsRatherThanRelearning() {
        // A week off the wrist must leave the baseline where it was, marked stale — not quietly
        // relearned from nothing, and never folded in as a zero.
        var s = Baselines.foldHistory(Array(repeating: 60, count: 20), cfg: hrv)
        let before = s.baseline
        for _ in 0..<20 { s = Baselines.update(s, value: nil, cfg: hrv) }
        XCTAssertEqual(s.baseline, before, accuracy: 1e-12)
        XCTAssertEqual(s.nValid, 20, "a missing night is not a valid night")
        XCTAssertEqual(s.status, .stale)
        XCTAssertFalse(s.usable)
    }

    func testImplausibleValueIsSkippedNotFolded() {
        var s = Baselines.foldHistory(Array(repeating: 60, count: 20), cfg: hrv)
        let before = s.baseline
        s = Baselines.update(s, value: 900, cfg: hrv)      // outside the hard bounds
        XCTAssertEqual(s.baseline, before, accuracy: 1e-12)
    }

    func testYoungBaselineTracksARealShiftInsteadOfAnchoring() {
        // The anti-anchoring case. A high first reading followed by the user's true, lower nights
        // must move the baseline. Without the early-life relaxation the true values sit more than
        // five floor-spreads out, are rejected as outliers forever, and the app reports a deficit
        // that does not exist.
        var s = Baselines.update(nil, value: 95, cfg: hrv)
        for _ in 0..<7 { s = Baselines.update(s, value: 54, cfg: hrv) }
        XCTAssertLessThan(s.baseline, 70, "the baseline followed the real readings")
    }

    func testASettledBaselineStillRejectsAWildOneOff() {
        // Youth is counted in valid nights, not in spread: a long flat history is settled even
        // though its spread never lifted off the floor.
        var s = Baselines.foldHistory(Array(repeating: 60, count: 30), cfg: hrv)
        let before = s.baseline
        s = Baselines.update(s, value: 200, cfg: hrv)
        XCTAssertEqual(s.baseline, before, accuracy: 1e-12, "a single wild night is not folded")
        XCTAssertEqual(s.nightsSinceUpdate, 0, "but it still counts as a night that was seen")
    }

    func testWinsorizationBoundsHowFarOneNightCanMoveTheCentre() {
        var s = Baselines.foldHistory(Array(repeating: 60, count: 30), cfg: hrv)
        let before = s.baseline
        // Inside the hard-outlier gate but outside the clamp band.
        s = Baselines.update(s, value: 60 + 4 * s.spread, cfg: hrv)
        let moved = s.baseline - before
        XCTAssertGreaterThan(moved, 0)
        XCTAssertLessThan(moved, 4 * s.spread, "clamped before folding")
    }

    func testSpreadNeverFallsBelowItsFloor() {
        // Without a floor a long flat stretch collapses the band and every later night reads as a
        // dramatic deviation.
        let s = Baselines.foldHistory(Array(repeating: 60, count: 200), cfg: hrv)
        XCTAssertGreaterThanOrEqual(s.spread, hrv.floorSpread)
        let d = Baselines.deviation(65, state: s)
        XCTAssertLessThan(abs(d.z), 2, "5 ms off a flat baseline is not an emergency")
    }

    func testDeviationConvertsMadToSigma() {
        let s = Baselines.BaselineState(baseline: 60, spread: 10, nValid: 30,
                                        nightsSinceUpdate: 0, status: .trusted)
        let d = Baselines.deviation(72.53, state: s)
        XCTAssertEqual(d.z, 1.0, accuracy: 0.001, "sigma = 1.253 x MAD")
        XCTAssertEqual(d.delta, 12.53, accuracy: 0.001)
        // Checked just inside and well outside rather than exactly on |z| = 1: the boundary
        // itself lands on a floating-point tie, and which side it falls on is not a fact worth
        // pinning.
        XCTAssertTrue(Baselines.deviation(70, state: s).inNormalRange)
        XCTAssertFalse(Baselines.deviation(90, state: s).inNormalRange)
    }

    func testDeviationRatioIsRelativeToTheBaseline() {
        let s = Baselines.BaselineState(baseline: 50, spread: 5, nValid: 30,
                                        nightsSinceUpdate: 0, status: .trusted)
        XCTAssertEqual(Baselines.deviation(60, state: s).ratio, 0.2, accuracy: 1e-9)
    }

    func testRollingMeanIsTheAuditableForm() {
        // A user asking "what is my baseline" can check this one by hand.
        let s = Baselines.rollingMeanSD([50, 55, 60, 65, 70], cfg: hrv, window: 5)
        XCTAssertEqual(s.baseline, 60, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 5)
    }

    func testRollingWindowOnlyUsesTheTail() {
        let values: [Double?] = Array(repeating: 100, count: 30) + Array(repeating: 50, count: 30)
        let s = Baselines.rollingMeanSD(values, cfg: hrv, window: 30)
        XCTAssertEqual(s.baseline, 50, accuracy: 1e-9)
    }

    func testRollingSkipsImplausibleValuesEntirely() {
        let s = Baselines.rollingMeanSD([60, 900, 60, nil, 60], cfg: hrv, window: 30)
        XCTAssertEqual(s.baseline, 60, accuracy: 1e-9)
        XCTAssertEqual(s.nValid, 3)
    }

    func testSingleSampleFallsBackToTheFloorRatherThanZeroSpread() {
        // Zero spread would make the next night read as an infinite deviation.
        let s = Baselines.rollingMeanSD([60], cfg: hrv, window: 30)
        XCTAssertGreaterThanOrEqual(s.spread, hrv.floorSpread)
        XCTAssertTrue(Baselines.deviation(62, state: s).z.isFinite)
    }

    func testEmptyHistoryIsCalibratingNotZero() {
        let s = Baselines.rollingMeanSD([], cfg: hrv)
        XCTAssertEqual(s.status, .calibrating)
        XCTAssertEqual(s.nValid, 0)
        XCTAssertGreaterThan(s.baseline, 0, "seeded mid-range so a first night has somewhere to move from")
    }

    func testHalfLifeBehavesLikeAHalfLife() {
        // After halfLifeB nights of a step change, roughly half the gap should be closed.
        var s = Baselines.foldHistory(Array(repeating: 60, count: 40), cfg: hrv)
        let start = s.baseline
        let target = 80.0
        for _ in 0..<Int(hrv.halfLifeB) { s = Baselines.update(s, value: target, cfg: hrv) }
        let closed = (s.baseline - start) / (target - start)
        XCTAssertGreaterThan(closed, 0.15, "the centre is moving")
        XCTAssertLessThan(closed, 0.85, "but not chasing the newest night")
    }

    func testEveryStandardConfigIsPresentAndOrdered() {
        for cfg in [Baselines.hrvCfg, Baselines.restingHRCfg, Baselines.respCfg, Baselines.skinTempCfg] {
            XCTAssertLessThan(cfg.minVal, cfg.maxVal)
            XCTAssertGreaterThan(cfg.floorSpread, 0)
            XCTAssertGreaterThan(cfg.halfLifeS, cfg.halfLifeB,
                                 "the spread must adapt slower than the centre, or the band chases the night it is judging")
        }
    }
}
