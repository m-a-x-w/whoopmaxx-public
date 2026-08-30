import XCTest
@testable import StrapAnalytics

final class SleepGroupingTests: XCTestCase {

    /// Local midnight, UTC — every test runs at offset 0 so the clock reads plainly.
    private let mid = 1_800_000_000 - 1_800_000_000 % 86_400
    private func h(_ x: Double) -> Int { Int(x * 3600) }
    private func block(_ from: Int, _ to: Int) -> SleepGrouping.NightBlock {
        SleepGrouping.NightBlock(start: from, end: to)
    }

    // MARK: - Clock

    func testTheOvernightBandWrapsMidnight() {
        XCTAssertTrue(SleepGrouping.isOvernightOnset(mid + h(23), offsetSec: 0))
        XCTAssertTrue(SleepGrouping.isOvernightOnset(mid + h(3), offsetSec: 0))
        XCTAssertTrue(SleepGrouping.isOvernightOnset(mid + h(20), offsetSec: 0), "band start")
        XCTAssertFalse(SleepGrouping.isOvernightOnset(mid + h(11), offsetSec: 0), "band end")
        XCTAssertFalse(SleepGrouping.isOvernightOnset(mid + h(14), offsetSec: 0))
    }

    func testCircularDistanceTakesTheShortWayRound() {
        XCTAssertEqual(SleepGrouping.circularDistanceSec(h(23.5), h(0.5)), h(1))
        XCTAssertEqual(SleepGrouping.circularDistanceSec(h(1), h(13)), h(12))
    }

    func testTheOffsetMovesTheLocalClock() {
        // 03:00 UTC is 22:00 the previous evening at −5 h: still overnight either way, but the
        // second-of-day must actually move.
        XCTAssertEqual(SleepGrouping.localSecOfDay(mid + h(3), offsetSec: -5 * 3600), h(22))
    }

    func testTheColdStartAnchorIsTheMiddleOfTheBand() {
        // 20:00 → 11:00 is 15 h; its middle is 03:30.
        XCTAssertEqual(SleepGrouping.coldStartAnchorSec, h(3.5))
    }

    // MARK: - Alignment bonus

    func testTheBonusIsFullNearTheAnchorAndFadesToNothing() {
        let anchor = h(4)
        XCTAssertEqual(SleepGrouping.alignmentBonusMinutes(blockMidSec: anchor, targetMidSec: anchor),
                       90)
        XCTAssertEqual(SleepGrouping.alignmentBonusMinutes(blockMidSec: anchor + h(2),
                                                          targetMidSec: anchor), 90)
        XCTAssertEqual(SleepGrouping.alignmentBonusMinutes(blockMidSec: anchor + h(3.5),
                                                          targetMidSec: anchor), 45, accuracy: 1e-9)
        XCTAssertEqual(SleepGrouping.alignmentBonusMinutes(blockMidSec: anchor + h(5),
                                                          targetMidSec: anchor), 0)
        XCTAssertEqual(SleepGrouping.alignmentBonusMinutes(blockMidSec: anchor + h(9),
                                                          targetMidSec: anchor), 0)
    }

    // MARK: - Selection

    func testTheLongestBlockWinsWhenTimingSaysNothing() {
        let blocks = [block(mid + h(13), mid + h(14)), block(mid + h(1), mid + h(7))]
        XCTAssertEqual(SleepGrouping.mainNightIndex(blocks, offsetSec: 0), 1)
    }

    func testTimingCanBeatLength() {
        // A well-placed 6 h night against a badly-placed 7 h daytime sleep.
        let night = block(mid + h(1), mid + h(7))          // mid 04:00, full bonus
        let day = block(mid + h(12), mid + h(19))          // mid 15:30, no bonus
        XCTAssertEqual(SleepGrouping.mainNightIndex([day, night], offsetSec: 0), 1)
    }

    func testALongEnoughDaytimeSleepStillWins() {
        // No hard overnight gate: a night-shift worker's sleep is their main sleep.
        let day = block(mid + h(9), mid + h(17))           // 8 h, no bonus
        let night = block(mid + h(1), mid + h(4))          // 3 h, full bonus
        XCTAssertEqual(SleepGrouping.mainNightIndex([day, night], offsetSec: 0), 0)
    }

    func testTiesBreakTowardTheEarlierOnset() {
        let a = block(mid + h(1), mid + h(4))
        let b = block(mid + h(1) + 60, mid + h(4) + 60)
        XCTAssertEqual(SleepGrouping.mainNightIndex([b, a], offsetSec: 0), 1)
    }

    func testALearnedAnchorMovesThePick() {
        // A shift worker whose habitual midsleep is midday.
        let day = block(mid + h(9), mid + h(15))
        let night = block(mid + h(1), mid + h(7) + 600)
        XCTAssertEqual(SleepGrouping.mainNightIndex([day, night], offsetSec: 0), 1)
        XCTAssertEqual(SleepGrouping.mainNightIndex([day, night], offsetSec: 0,
                                                    habitualMidsleepSec: h(12)), 0)
    }

    func testAnEmptyDayHasNoNight() {
        XCTAssertNil(SleepGrouping.mainNightIndex([], offsetSec: 0))
        XCTAssertNil(SleepGrouping.mainNightGroupIndices([], offsetSec: 0))
    }

    // MARK: - Bridging

    func testASingleBlockIsTheWholeNight() {
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([block(mid, mid + h(7))], offsetSec: 0),
                       [0])
    }

    func testAShortWakeDoesNotEndTheNight() {
        // 23:00–02:00 then 02:45–06:30: a 45-minute mid-night waking.
        let a = block(mid - h(1), mid + h(2))
        let b = block(mid + h(2.75), mid + h(6.5))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([a, b], offsetSec: 0), [0, 1])
    }

    func testAnOvernightTailBridgesAWiderGap() {
        // 75 minutes is past the unconditional tier but the fragment still starts overnight.
        let a = block(mid, mid + h(4))
        let b = block(mid + h(5.25), mid + h(6.5))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([a, b], offsetSec: 0), [0, 1])
    }

    func testADaytimeNapNeverJoinsTheNightAtTheSameGap() {
        // Same 75-minute gap, but the fragment begins at midday.
        let a = block(mid + h(10.5), mid + h(11.5))
        let b = block(mid + h(12.75), mid + h(13.5))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([a, b], offsetSec: 0), [0])
    }

    func testTheSecondHalfOfASplitNightIsNotANap() {
        // The real shape: 00:22–05:35, up for 110 minutes, then 07:25–11:15. The gap alone would
        // reject the bridge; the later fragment's own length is what makes it a split night.
        let first = block(mid + 22 * 60, mid + h(5) + 35 * 60)
        let second = block(mid + h(7) + 25 * 60, mid + h(11) + 15 * 60)
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([first, second], offsetSec: 0), [0, 1])
    }

    func testAShortMorningDozeAfterTheSameGapStaysANap() {
        // Identical gap, half-hour fragment: it can never clear the fragment bar.
        let first = block(mid + 22 * 60, mid + h(5) + 35 * 60)
        let doze = block(mid + h(7) + 25 * 60, mid + h(7) + 55 * 60)
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([first, doze], offsetSec: 0), [0])
    }

    func testPastTheWidestTierABlockStandsAlone() {
        // 4.5 h awake, then a 3 h sleep: long enough and overnight, but the night has ended.
        let first = block(mid - h(1), mid + h(4))
        let later = block(mid + h(8.5), mid + h(11.5))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([first, later], offsetSec: 0), [0])
    }

    func testOverlappingBlocksAreLeftAlone() {
        // The detector's periods are disjoint, so an overlap is a defect in the caller's data
        // rather than a shape to interpret.
        let a = block(mid, mid + h(5))
        let b = block(mid + h(4), mid + h(7))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([a, b], offsetSec: 0), [0])
    }

    func testGroupIndicesRefertoTheInputOrderNotTheSortedOrder() {
        let late = block(mid + h(2.5), mid + h(6))
        let early = block(mid, mid + h(2))
        let nap = block(mid + h(14), mid + h(15))
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices([late, early, nap], offsetSec: 0), [0, 1])
    }

    func testTheNightAndTheNapsPartitionTheDay() {
        let night = [block(mid, mid + h(4)), block(mid + h(4.5), mid + h(7))]
        let nap = block(mid + h(14), mid + h(15))
        let all = night + [nap]
        let group = Set(SleepGrouping.mainNightGroupIndices(all, offsetSec: 0)!)
        let naps = Set(all.indices).subtracting(group)
        XCTAssertEqual(group, [0, 1])
        XCTAssertEqual(naps, [2])
    }

    // MARK: - Habitual midsleep

    private func history(_ count: Int, midHour: Double, jitterS: Int = 0) -> [SleepGrouping.HistoryBlock] {
        (0..<count).map { d in
            let dayStart = mid + d * 86_400
            let centre = dayStart + Int(midHour * 3600) + (d % 2 == 0 ? jitterS : -jitterS)
            return SleepGrouping.HistoryBlock(start: centre - h(3.5), end: centre + h(3.5),
                                              dayKey: "day-\(d)")
        }
    }

    func testABarelyLongEnoughHistoryLearnsTheAnchor() {
        let sec = SleepGrouping.habitualMidsleepSec(history(14, midHour: 4), offsetSec: 0)
        XCTAssertEqual(try! XCTUnwrap(sec), h(4), accuracy: 60)
    }

    func testTooLittleHistoryAbstains() {
        XCTAssertNil(SleepGrouping.habitualMidsleepSec(history(13, midHour: 4), offsetSec: 0))
        XCTAssertNil(SleepGrouping.habitualMidsleepSec([], offsetSec: 0))
    }

    func testDaysAreCountedNotBlocks() {
        // Twenty blocks over five days is still five days of history.
        var blocks: [SleepGrouping.HistoryBlock] = []
        for d in 0..<5 {
            for k in 0..<4 {
                let s = mid + d * 86_400 + k * 3600
                blocks.append(SleepGrouping.HistoryBlock(start: s, end: s + 1800,
                                                         dayKey: "day-\(d)"))
            }
        }
        XCTAssertNil(SleepGrouping.habitualMidsleepSec(blocks, offsetSec: 0))
    }

    func testTheLongestBlockOfEachDayIsUsed() {
        // A daily 20-minute nap at noon must not drag the anchor off the 4 a.m. night.
        var blocks = history(14, midHour: 4)
        for d in 0..<14 {
            let noon = mid + d * 86_400 + h(12)
            blocks.append(SleepGrouping.HistoryBlock(start: noon, end: noon + 1200,
                                                     dayKey: "day-\(d)"))
        }
        let sec = try! XCTUnwrap(SleepGrouping.habitualMidsleepSec(blocks, offsetSec: 0))
        XCTAssertEqual(sec, h(4), accuracy: 60)
    }

    func testAMidnightSleeperIsLearnedCorrectly() {
        // Alternating 23:30 and 00:30: an arithmetic mean would answer midday.
        let secs = (0..<14).map { $0 % 2 == 0 ? h(23.5) : h(0.5) }
        let mean = try! XCTUnwrap(SleepGrouping.circularMeanSec(secs))
        XCTAssertTrue(mean < 60 || mean > 86_340, "got \(mean)")
    }

    func testEvenlySpreadTimesHaveNoMean() {
        // Returning whatever angle falls out would present noise as an anchor.
        let secs = (0..<24).map { $0 * 3600 }
        XCTAssertNil(SleepGrouping.circularMeanSec(secs))
        XCTAssertNil(SleepGrouping.circularMeanSec([]))
    }

    func testTheMeanIsInsideOneDay() {
        let mean = try! XCTUnwrap(SleepGrouping.circularMeanSec([h(3), h(4), h(5)]))
        XCTAssertTrue((0..<86_400).contains(mean))
        XCTAssertEqual(mean, h(4), accuracy: 60)
    }
}
