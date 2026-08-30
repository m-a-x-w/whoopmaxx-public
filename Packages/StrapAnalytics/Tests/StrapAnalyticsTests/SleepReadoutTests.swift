import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SleepReadoutTests: XCTestCase {

    func testDensityIsOverTheStreamsOwnSpan() {
        // A stream that stopped at 2 a.m. was dense while it ran.
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 60) }
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: hr), 60, accuracy: 0.2)
    }

    func testASparseStreamReadsSparse() {
        let hr = stride(from: 0, to: 3600, by: 60).map { HRSample(ts: $0, bpm: 60) }
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: hr), 1, accuracy: 0.05)
    }

    func testDensityNeedsTwoSamplesAndSomeSpan() {
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: []), 0)
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: [HRSample(ts: 5, bpm: 60)]), 0)
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: [HRSample(ts: 5, bpm: 60),
                                                            HRSample(ts: 5, bpm: 61)]), 0)
    }

    func testUnsortedInputIsHandled() {
        let hr = [HRSample(ts: 600, bpm: 60), HRSample(ts: 0, bpm: 60), HRSample(ts: 300, bpm: 60)]
        XCTAssertEqual(SleepReadout.hrDensityPerMinute(hr: hr), 0.3, accuracy: 1e-9)
    }

    func testGravityCoverageIsARatioOfSpans() {
        let hr = (0..<3600).map { HRSample(ts: $0, bpm: 60) }
        let half = (0..<1800).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertEqual(SleepReadout.gravityCoverageFraction(gravity: half, hr: hr),
                       0.5, accuracy: 0.01)
    }

    func testCoverageIsClampedToOne() {
        let hr = [HRSample(ts: 0, bpm: 60), HRSample(ts: 60, bpm: 60)]
        let g = (0..<3600).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        XCTAssertEqual(SleepReadout.gravityCoverageFraction(gravity: g, hr: hr), 1)
    }

    func testCoverageNeedsBothStreams() {
        let hr = (0..<100).map { HRSample(ts: $0, bpm: 60) }
        XCTAssertEqual(SleepReadout.gravityCoverageFraction(gravity: [], hr: hr), 0)
        XCTAssertEqual(SleepReadout.gravityCoverageFraction(gravity: [], hr: []), 0)
    }

    func testCoverageAgreesWithTheSparseGate() {
        // The point of the number: it says which staging path ran.
        let hr = (0..<3600).map { HRSample(ts: $0, bpm: 60) }
        let thin = (0..<1000).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let frac = SleepReadout.gravityCoverageFraction(gravity: thin, hr: hr)
        XCTAssertLessThan(frac, SleepDetection.sparseGravitySpanFrac)
    }

    // MARK: - Epoch motion

    func testEpochMotionIsEmptyWithoutAMotionChannel() {
        // A row of zeros would read as perfect stillness.
        XCTAssertTrue(SleepStaging.sessionEpochMotion(start: 0, end: 600, grav: []).isEmpty)
        XCTAssertTrue(SleepStaging.sessionEpochMotion(start: 0, end: 600,
                                                      grav: [GravitySample(ts: 0, x: 0, y: 0, z: 1)])
                        .isEmpty)
    }

    func testEpochMotionTracksMovement()  {
        let still = (0..<600).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let moving = (0..<600).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.4, y: 0, z: 1) }
        let a = SleepStaging.sessionEpochMotion(start: 0, end: 600, grav: still)
        let b = SleepStaging.sessionEpochMotion(start: 0, end: 600, grav: moving)
        XCTAssertEqual(a.count, 20)
        XCTAssertTrue(a.allSatisfy { $0 == 0 })
        XCTAssertTrue(b.allSatisfy { $0 > 0 })
    }

    // MARK: - Respiration gate

    func testAFlatRespirationChannelIsUnusable() {
        let flat = (0..<600).map { RespSample(ts: $0, raw: 512) }
        XCTAssertFalse(SleepStaging.respChannelUsable(flat))
    }

    func testATwoLevelChannelIsUnusable() {
        // Every "peak" of a square wave is a plateau between equals.
        let square = (0..<600).map { RespSample(ts: $0, raw: $0 % 2 == 0 ? 500 : 520) }
        XCTAssertFalse(SleepStaging.respChannelUsable(square))
    }

    func testThreeLevelsIsEnough() {
        let real = (0..<600).map { RespSample(ts: $0, raw: 500 + $0 % 3) }
        XCTAssertTrue(SleepStaging.respChannelUsable(real))
    }

    func testAShortWindowIsUnusableWhateverItHolds() {
        let short = (0..<7).map { RespSample(ts: $0, raw: 500 + $0) }
        XCTAssertFalse(SleepStaging.respChannelUsable(short))
    }
}
