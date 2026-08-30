import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class HRZoneTests: XCTestCase {

    private let set = HRZones.zones(maxHR: 200, source: "manual")

    func testZoneEdgesFollowPercentOfMax() {
        XCTAssertEqual(set.zones.count, 5)
        XCTAssertEqual(set.zones[0].lower, 100, accuracy: 1e-9)   // 50%
        XCTAssertEqual(set.zones[4].lower, 180, accuracy: 1e-9)   // 90%
        XCTAssertEqual(set.zones[4].upper, 200, accuracy: 1e-9)
    }

    func testMaxHRItselfLandsInZoneFive() {
        // Falling out of every zone at exactly the hardest moment of a session would be absurd.
        XCTAssertEqual(set.zoneNumber(forBPM: 200), 5)
        XCTAssertEqual(set.zoneNumber(forBPM: 250), 5, "and above it too")
    }

    func testBelowTheFirstThresholdIsZoneZero() {
        XCTAssertEqual(set.zoneNumber(forBPM: 60), 0)
        XCTAssertEqual(set.zoneNumber(forBPM: 99.9), 0)
        XCTAssertEqual(set.zoneNumber(forBPM: 100), 1)
    }

    func testEveryZoneIsReachable() {
        for (i, z) in set.zones.enumerated() {
            let mid = (z.lower + z.upper) / 2
            XCTAssertEqual(set.zoneNumber(forBPM: mid), i + 1)
        }
    }

    func testTanakaDivergesFrom220MinusAgeInBothDirections() {
        // The two rules cross at 40. Below it 220-age reads higher, above it lower — being wrong
        // in opposite directions either side of forty is what Tanaka avoids.
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 30), 187, accuracy: 1e-9)
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 60), 166, accuracy: 1e-9)
        XCTAssertLessThan(HRZones.tanakaMaxHR(age: 25), 220 - 25)
        XCTAssertGreaterThan(HRZones.tanakaMaxHR(age: 60), 220 - 60)
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 40), 220 - 40, accuracy: 1e-9, "they meet at 40")
    }

    func testSourceIsCarried() {
        XCTAssertEqual(HRZones.zones(age: 30).source, "tanaka")
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).source, "manual")
        XCTAssertEqual(HRZones.zones(age: 30, maxHROverride: 195).maxHR, 195)
    }

    func testTimeInZoneAccumulates() {
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 150) }   // 75% of 200 → zone 3
        let t = HRZones.timeInZone(hr, zoneSet: set)
        XCTAssertEqual(t.seconds[2], 600, accuracy: 1)
        XCTAssertEqual(t.seconds[0], 0)
        XCTAssertEqual(t.belowZone1, 0)
    }

    func testBelowZoneOneIsKeptSeparate() {
        // Folding it into zone 1 would overstate a session spent mostly under the threshold.
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 70) }
        let t = HRZones.timeInZone(hr, zoneSet: set)
        XCTAssertEqual(t.belowZone1, 600, accuracy: 1)
        XCTAssertEqual(t.seconds.reduce(0, +), 0)
    }

    func testAWearGapDoesNotDominateTheProfile() {
        // Uncapped, one gap credits hours to whichever zone the sample beside it happened to be in.
        var hr = (0..<300).map { HRSample(ts: $0, bpm: 150) }
        hr.append(HRSample(ts: 300 + 6 * 3600, bpm: 150))
        let t = HRZones.timeInZone(hr, zoneSet: set)
        XCTAssertLessThan(t.seconds[2], 400, "the gap is capped at the median interval")
    }

    func testTheLastSampleIsCounted() {
        let hr = (0..<10).map { HRSample(ts: $0, bpm: 150) }
        XCTAssertEqual(HRZones.timeInZone(hr, zoneSet: set).seconds[2], 10, accuracy: 0.001)
    }

    func testEmptyStream() {
        let t = HRZones.timeInZone([], zoneSet: set)
        XCTAssertEqual(t.seconds, [0, 0, 0, 0, 0])
        XCTAssertEqual(t.belowZone1, 0)
    }
}

final class SleepDebtTests: XCTestCase {

    private func series(_ mins: [Double?], from: Int = 1) -> [(day: String, totalSleepMin: Double?)] {
        mins.enumerated().map { (day: String(format: "2026-01-%02d", from + $0.offset), totalSleepMin: $0.element) }
    }

    func testShortNightsAccumulateDebt() {
        let l = SleepDebt.ledger(series: series([420, 420, 420]), needHours: 8)
        XCTAssertEqual(l.needMin, 480)
        XCTAssertEqual(l.balanceMin, -180, accuracy: 0.01, "three nights an hour short")
        XCTAssertEqual(l.nights.count, 3)
        XCTAssertEqual(l.nights[0].deltaMin, -60, accuracy: 0.01)
    }

    func testLongNightsBankSurplus() {
        let l = SleepDebt.ledger(series: series([540, 540]), needHours: 8)
        XCTAssertEqual(l.balanceMin, 120, accuracy: 0.01)
    }

    func testTheWindowCountsNightsWithDataNotCalendarDays() {
        // Counting calendar days would let a week without the strap age real nights out of the
        // window, so a returning user's debt resets itself. An unworn night is not a night of no
        // sleep.
        let sparse: [Double?] = [420, nil, nil, nil, nil, nil, nil, 420]
        let l = SleepDebt.ledger(series: series(sparse), needHours: 8, window: 14)
        XCTAssertEqual(l.nights.count, 2)
        XCTAssertEqual(l.balanceMin, -120, accuracy: 0.01, "both short nights still count")
    }

    func testWindowKeepsTheMostRecentNights() {
        let l = SleepDebt.ledger(series: series([300, 300, 480, 480]), needHours: 8, window: 2)
        XCTAssertEqual(l.nights.count, 2)
        XCTAssertEqual(l.balanceMin, 0, accuracy: 0.01, "only the two recent on-target nights")
    }

    func testZeroAndNilNightsAreExcluded() {
        let l = SleepDebt.ledger(series: series([nil, 0, 480]), needHours: 8)
        XCTAssertEqual(l.nights.count, 1)
    }

    func testEmptySeries() {
        let l = SleepDebt.ledger(series: [], needHours: 8)
        XCTAssertEqual(l.balanceMin, 0)
        XCTAssertTrue(l.nights.isEmpty)
        XCTAssertEqual(l.needMin, 480)
    }

    func testNegativeNeedIsClampedToZero() {
        let l = SleepDebt.ledger(series: series([420]), needHours: -5)
        XCTAssertEqual(l.needMin, 0)
        XCTAssertEqual(l.balanceMin, 420, accuracy: 0.01)
    }

    func testWindowOfZeroStillKeepsANight() {
        XCTAssertEqual(SleepDebt.ledger(series: series([420, 420]), window: 0).nights.count, 1)
    }
}
