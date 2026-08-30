import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SedentaryWindowTests: XCTestCase {

    func testAWrappingWindowIsHandled() {
        // Quiet hours normally wrap — 22:00 to 07:00 — and a plain range comparison silences
        // nothing at all for exactly the hours it was configured to cover.
        let start = 22 * 60, end = 7 * 60
        XCTAssertTrue(SedentaryDetector.windowContains(23 * 60, startMin: start, endMin: end))
        XCTAssertTrue(SedentaryDetector.windowContains(2 * 60, startMin: start, endMin: end))
        XCTAssertFalse(SedentaryDetector.windowContains(12 * 60, startMin: start, endMin: end))
    }

    func testANonWrappingWindow() {
        let start = 9 * 60, end = 17 * 60
        XCTAssertTrue(SedentaryDetector.windowContains(12 * 60, startMin: start, endMin: end))
        XCTAssertFalse(SedentaryDetector.windowContains(8 * 60, startMin: start, endMin: end))
        XCTAssertFalse(SedentaryDetector.windowContains(17 * 60, startMin: start, endMin: end),
                       "the end is exclusive")
    }

    func testLocalMinuteOfDayHandlesNegativeOffsets() {
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(0, tzOffsetSec: 0), 0)
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(0, tzOffsetSec: -5 * 3600), 19 * 60)
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(12 * 3600, tzOffsetSec: 8 * 3600), 20 * 60)
    }
}

final class SedentaryNudgeTests: XCTestCase {

    /// A still hour ending at `endTs`.
    private func stillHour(endingAt endTs: Int) -> [GravitySample] {
        (0..<3600).map { GravitySample(ts: endTs - 3600 + $0, x: 0, y: 0, z: 1) }
    }

    /// Midday on a day, so active hours contain it.
    private let noon = 12 * 3600

    private func config(_ mutate: (inout SedentaryDetector.SedentaryConfig) -> Void = { _ in })
        -> SedentaryDetector.SedentaryConfig {
        var c = SedentaryDetector.SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                                  thresholdMinutes: 15)
        mutate(&c)
        return c
    }

    func testASittingHourInsideActiveHoursNudges() {
        let g = stillHour(endingAt: noon)
        let d = SedentaryDetector.evaluate(g, state: .initial, config: config(),
                                           worn: true, nowSec: noon, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldBuzz)
        XCTAssertNotNil(d.bout)
        XCTAssertEqual(d.nextState.lastBuzzAt, noon)
    }

    func testDisabledNeverNudges() {
        var c = config(); c.enabled = false
        XCTAssertFalse(SedentaryDetector.evaluate(stillHour(endingAt: noon), state: .initial,
                                                  config: c, worn: true, nowSec: noon,
                                                  tzOffsetSec: 0).shouldBuzz)
    }

    func testTheMasterNotificationSwitchSilencesWithoutForgetting() {
        // Turning notifications off must not also forget the feature was enabled.
        var c = config(); c.notificationsMasterOn = false
        let d = SedentaryDetector.evaluate(stillHour(endingAt: noon), state: .initial, config: c,
                                           worn: true, nowSec: noon, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz)
        XCTAssertNotNil(d.bout, "the bout is still reported so a caller can explain the silence")
    }

    func testOutsideActiveHoursIsSilent() {
        let g = stillHour(endingAt: 3 * 3600)     // 03:00
        XCTAssertFalse(SedentaryDetector.evaluate(g, state: .initial, config: config(),
                                                  worn: true, nowSec: 3 * 3600,
                                                  tzOffsetSec: 0).shouldBuzz)
    }

    func testQuietHoursAreJudgedAtTheBoutsEndNotNow() {
        // A sync arriving at midnight about an afternoon of sitting must not be silenced by
        // quiet hours the bout was never in.
        var c = config(); c.quietHoursEnabled = true; c.activeHoursEnabled = false
        let afternoon = stillHour(endingAt: 15 * 3600)
        let d = SedentaryDetector.evaluate(afternoon, state: .initial, config: c, worn: true,
                                           nowSec: 23 * 3600, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldBuzz)
    }

    func testABoutInsideQuietHoursIsSilent() {
        var c = config(); c.quietHoursEnabled = true; c.activeHoursEnabled = false
        let night = stillHour(endingAt: 23 * 3600)
        XCTAssertFalse(SedentaryDetector.evaluate(night, state: .initial, config: c, worn: true,
                                                  nowSec: 23 * 3600, tzOffsetSec: 0).shouldBuzz)
    }

    func testNotWornIsSilentWhenTheGateIsOn() {
        XCTAssertFalse(SedentaryDetector.evaluate(stillHour(endingAt: noon), state: .initial,
                                                  config: config(), worn: false, nowSec: noon,
                                                  tzOffsetSec: 0).shouldBuzz)
        var c = config(); c.onlyWhenWorn = false
        XCTAssertTrue(SedentaryDetector.evaluate(stillHour(endingAt: noon), state: .initial,
                                                 config: c, worn: false, nowSec: noon,
                                                 tzOffsetSec: 0).shouldBuzz)
    }

    func testAReplayedSyncIsInert() {
        // A re-sync of the same rows must not fire a second buzz.
        let g = stillHour(endingAt: noon)
        let first = SedentaryDetector.evaluate(g, state: .initial, config: config(),
                                               worn: true, nowSec: noon, tzOffsetSec: 0)
        XCTAssertTrue(first.shouldBuzz)
        let replay = SedentaryDetector.evaluate(g, state: first.nextState, config: config(),
                                                worn: true, nowSec: noon + 60, tzOffsetSec: 0)
        XCTAssertFalse(replay.shouldBuzz)
    }

    func testAContinuingBoutWaitsOutTheCadence() {
        let g1 = stillHour(endingAt: noon)
        let first = SedentaryDetector.evaluate(g1, state: .initial, config: config(),
                                               worn: true, nowSec: noon, tzOffsetSec: 0)
        // Same bout, extended by ten more minutes — inside the 30-minute re-nudge window.
        let g2 = g1 + (0..<600).map { GravitySample(ts: noon + $0, x: 0, y: 0, z: 1) }
        let soon = SedentaryDetector.evaluate(g2, state: first.nextState, config: config(),
                                              worn: true, nowSec: noon + 600, tzOffsetSec: 0)
        XCTAssertFalse(soon.shouldBuzz, "still sitting, but not yet time to nudge again")

        let g3 = g1 + (0..<2400).map { GravitySample(ts: noon + $0, x: 0, y: 0, z: 1) }
        let later = SedentaryDetector.evaluate(g3, state: first.nextState, config: config(),
                                               worn: true, nowSec: noon + 2400, tzOffsetSec: 0)
        XCTAssertTrue(later.shouldBuzz, "the cadence elapsed")
    }

    func testAStaleBoutDoesNotNudge() {
        // A nudge about sitting that ended hours ago is noise.
        var g = stillHour(endingAt: noon)
        g += (0..<10).map { GravitySample(ts: noon + 4 * 3600 + $0, x: Double($0 % 2), y: 0, z: 1) }
        let d = SedentaryDetector.evaluate(g, state: .initial, config: config(), worn: true,
                                           nowSec: noon + 4 * 3600, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz)
    }

    func testNoGravityAtAll() {
        let d = SedentaryDetector.evaluate([], state: .initial, config: config(),
                                           worn: true, nowSec: noon, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz)
        XCTAssertNil(d.bout)
    }

    func testTheDecisionCarriesTheStateToStore() {
        // Splitting the two invites a nudge that fires without recording that it did, and then
        // repeats on the next sync.
        let d = SedentaryDetector.evaluate(stillHour(endingAt: noon), state: .initial,
                                           config: config(), worn: true, nowSec: noon, tzOffsetSec: 0)
        XCTAssertEqual(d.nextState.lastBuzzedBoutEnd, d.bout?.end)
        XCTAssertGreaterThan(d.nextState.lastProcessedGravityTs, 0)
    }
}
