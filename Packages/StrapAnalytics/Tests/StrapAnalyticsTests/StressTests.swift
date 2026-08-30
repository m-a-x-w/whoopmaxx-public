import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class DaytimeStressTests: XCTestCase {

    /// One hour of HR at `bpm`, starting at local hour `hour` on day zero.
    private func hourOfHR(_ hour: Int, bpm: Int, samples: Int = 400) -> [HRSample] {
        let start = hour * 3600
        return (0..<samples).map { HRSample(ts: start + $0 * (3600 / samples), bpm: bpm) }
    }

    private func day(_ hours: [(Int, Int)]) -> [HRSample] {
        hours.flatMap { hourOfHR($0.0, bpm: $0.1) }
    }

    func testAFlatDayReadsNearBaseline() {
        // Scoring against the day's own calm is what keeps an unremarkable day unremarkable.
        let hrs = day((6..<22).map { ($0, 65) })
        let r = DaytimeStress.analyze(hr: hrs, rr: [])
        XCTAssertFalse(r.sustainedHigh)
        XCTAssertEqual(r.dayMean!, 1.5, accuracy: 0.2, "mid-scale, no tense hours")
    }

    func testASpikyDaySurfacesItsTenseHours() {
        var hours = (6..<22).map { ($0, 60) }
        hours[8] = (14, 110)
        let r = DaytimeStress.analyze(hr: day(hours), rr: [])
        XCTAssertEqual(r.peak?.hour, 14)
        XCTAssertGreaterThan(r.peak!.level!, r.dayMean!)
    }

    func testSleepHoursNeverEnterTheReference() {
        // The window starts at local midnight, so a day carries sleep hours. Letting them anchor
        // "calm" drags it below every waking hour and inflates an ordinary day toward high.
        let withSleep = day([(1, 48), (2, 48), (3, 48), (4, 48), (5, 48)]
                            + (6..<22).map { ($0, 68) })
        let wakingOnly = day((6..<22).map { ($0, 68) })
        let a = DaytimeStress.analyze(hr: withSleep, rr: [])
        let b = DaytimeStress.analyze(hr: wakingOnly, rr: [])
        XCTAssertEqual(a.dayMean!, b.dayMean!, accuracy: 1e-9)
        XCTAssertFalse(a.sustainedHigh, "a calm day with sleep in the window must not read as high")
    }

    func testSleepHoursAreNotEvenScored() {
        let r = DaytimeStress.analyze(hr: day([(3, 50)] + (6..<22).map { ($0, 65) }), rr: [])
        XCTAssertFalse(r.hours.contains { $0.hour == 3 })
    }

    func testAnHourWithTooFewSamplesIsUnscoredNotZero() {
        let sparse = hourOfHR(9, bpm: 70, samples: 10)
        let rest = day((10..<22).map { ($0, 65) })
        let r = DaytimeStress.analyze(hr: sparse + rest, rr: [])
        let hour9 = r.hours.first { $0.hour == 9 }
        XCTAssertNotNil(hour9, "the hour is still shown")
        XCTAssertNil(hour9?.level, "but not scored from a handful of readings")
    }

    func testAnEntirelyUnscorableDayStillReturnsItsTimeline() {
        // A surface needs something to say "not enough data" against.
        let r = DaytimeStress.analyze(hr: hourOfHR(9, bpm: 70, samples: 5), rr: [])
        XCTAssertFalse(r.hours.isEmpty)
        XCTAssertNil(r.dayMean)
        XCTAssertNil(r.peak)
    }

    func testNoDataAtAll() {
        XCTAssertEqual(DaytimeStress.analyze(hr: [], rr: []).hours.count, 0)
    }

    func testTheSustainedRunIsCountedBackwardFromNow() {
        // The flag is about the state someone is in now, not the worst stretch of their morning.
        var hours = (6..<22).map { ($0, 55) }
        for i in 0..<3 { hours[i] = (6 + i, 130) }        // a tense morning, then calm
        let morningSpike = DaytimeStress.analyze(hr: day(hours), rr: [])
        XCTAssertFalse(morningSpike.sustainedHigh)

        var late = (6..<22).map { ($0, 55) }
        for i in 13..<16 { late[i] = (6 + i, 130) }       // tense right up to the end
        XCTAssertTrue(DaytimeStress.analyze(hr: day(late), rr: []).sustainedHigh)
    }

    func testFallingVariabilityCountsAsStress() {
        let hrs = day((6..<22).map { ($0, 70) })
        func rr(_ hour: Int, ms: Int, n: Int = 120) -> [RRInterval] {
            (0..<n).map { RRInterval(ts: hour * 3600 + $0 * 20, rrMs: ms + ($0 % 2 == 0 ? 30 : -30)) }
        }
        var beats: [RRInterval] = []
        for h in 6..<22 { beats += rr(h, ms: 900) }
        var lowVar = beats.filter { $0.ts < 14 * 3600 || $0.ts >= 15 * 3600 }
        lowVar += (0..<120).map { RRInterval(ts: 14 * 3600 + $0 * 20, rrMs: 900) }  // flat hour
        let r = DaytimeStress.analyze(hr: hrs, rr: lowVar)
        let hour14 = r.hours.first { $0.hour == 14 }
        XCTAssertNotNil(hour14?.level)
    }

    func testSquashIsBoundedAndMonotone() {
        XCTAssertEqual(DaytimeStress.squash(0), 1.5, accuracy: 1e-9)
        XCTAssertGreaterThan(DaytimeStress.squash(3), DaytimeStress.squash(0))
        for raw in [-100.0, -1, 0, 1, 100] {
            let v = DaytimeStress.squash(raw)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThanOrEqual(v, 3)
        }
    }

    func testCalmReferenceAnchorsOnTheQuietQuartileNotTheMean() {
        // A mean sits mid-day, which would make half of every day read as stressed by construction.
        let hrs = [60.0, 62, 64, 66, 90, 95]
        let calm = DaytimeStress.calmReference(hrs, calmIsLow: true)!
        XCTAssertLessThan(calm, DaytimeStress.mean(hrs)!)
        let hrv = [20.0, 25, 30, 35, 80, 90]
        XCTAssertGreaterThan(DaytimeStress.calmReference(hrv, calmIsLow: false)!,
                             DaytimeStress.mean(hrv)!)
    }

    func testCalmReferenceFallsBackOnThinData() {
        XCTAssertEqual(DaytimeStress.calmReference([60, 70], calmIsLow: true)!, 65, accuracy: 1e-9)
        XCTAssertNil(DaytimeStress.calmReference([], calmIsLow: true))
    }

    func testFloorDivRoundsTowardNegativeInfinity() {
        // Swift's / truncates toward zero, which puts a negative-offset timestamp in the wrong
        // hour bucket — an off-by-one that only shows up west of UTC.
        XCTAssertEqual(DaytimeStress.floorDiv(-1, 3600), -1)
        XCTAssertEqual(DaytimeStress.floorDiv(-3600, 3600), -1)
        XCTAssertEqual(DaytimeStress.floorDiv(-3601, 3600), -2)
        XCTAssertEqual(DaytimeStress.floorDiv(3599, 3600), 0)
    }

    func testTimeZoneOffsetShiftsWhichHoursAreWaking() {
        let utcNight = day([(2, 70), (3, 70)])
        XCTAssertTrue(DaytimeStress.analyze(hr: utcNight, rr: []).hours.isEmpty,
                      "02:00 and 03:00 UTC are asleep")
        let shifted = DaytimeStress.analyze(hr: utcNight, rr: [], tzOffsetSeconds: 8 * 3600)
        XCTAssertFalse(shifted.hours.isEmpty, "the same instants are 10:00 and 11:00 locally")
    }
}
