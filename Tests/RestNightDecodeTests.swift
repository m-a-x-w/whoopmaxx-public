import XCTest
import StrapStore
@testable import whoopmaxx

/// Regression pins for `RestNight.decodeSegments` (stagesJSON → hypnogram codes, now a projection over
/// the shared `SleepStage.decode`) and the `RestNight.init` stageTotals fallback. Stage convention
/// (`SleepStage.laneCode`, which `StepHypnogram` renders top→bottom): 0 = awake, 1 = REM, 2 = light,
/// 3 = deep. A deep/REM code swap or a stage-total mis-indexing is exactly what these lock down.
final class RestNightDecodeTests: XCTestCase {

    /// light(10m) → deep(20m) → rem(30m) → wake(5m). Distinct minutes so a code swap is detectable.
    private let fullTimeline = """
    [{"start":0,"end":600,"stage":"light"},\
    {"start":600,"end":1800,"stage":"deep"},\
    {"start":1800,"end":3600,"stage":"rem"},\
    {"start":3600,"end":3900,"stage":"wake"}]
    """

    private func session(_ json: String?) -> CachedSleepSession {
        Fixtures.sleepSession(startTs: 0, endTs: 3900, efficiency: 90, stagesJSON: json)
    }

    // MARK: - decodeSegments

    /// A light/deep/rem/wake timeline decodes to codes [2, 3, 1, 0].
    func testDecodesStageCodesInOrder() {
        let segs = RestNight.decodeSegments(fullTimeline)
        XCTAssertEqual(segs.map(\.stage), [2, 3, 1, 0])
    }

    /// An unknown stage string drops JUST that segment (compactMap over a successful decode).
    func testUnknownStageDropsOnlyThatSegment() {
        let json = """
        [{"start":0,"end":600,"stage":"light"},{"start":600,"end":1200,"stage":"banana"}]
        """
        XCTAssertEqual(RestNight.decodeSegments(json).map(\.stage), [2])
    }

    /// Zero- and negative-span segments are dropped (end must be strictly after start).
    func testZeroAndNegativeSpansDropped() {
        let json = """
        [{"start":100,"end":100,"stage":"deep"},\
        {"start":300,"end":200,"stage":"rem"},\
        {"start":0,"end":600,"stage":"light"}]
        """
        XCTAssertEqual(RestNight.decodeSegments(json).map(\.stage), [2])
    }

    /// Structurally-malformed / nil JSON → whole decode is empty (a single bad element kills the array).
    func testMalformedOrNilJSONDecodesEmpty() {
        XCTAssertTrue(RestNight.decodeSegments("garbage").isEmpty)
        XCTAssertTrue(RestNight.decodeSegments(nil).isEmpty)
        // One element missing its required `stage` field fails the WHOLE decode.
        XCTAssertTrue(RestNight.decodeSegments("""
        [{"start":0,"end":600,"stage":"light"},{"start":600,"end":1200}]
        """).isEmpty)
    }

    // MARK: - RestNight.init stageTotals fallback

    /// With a decodable timeline, per-stage minutes come from the timeline, NOT the day row — and each
    /// stage lands in its own bucket (deep 20 / rem 30 / light 10 / wake 5). Day fields set to bogus
    /// values prove the timeline wins.
    func testTimelineTotalsWinOverDayRow() throws {
        let night = RestNight(day: Fixtures.dailyMetric(day: "2026-06-01", totalSleepMin: 420,
                                                       efficiency: 90, deepMin: 999, remMin: 999,
                                                       lightMin: 999, wasoMin: 999),
                              score: 80, session: session(fullTimeline))
        XCTAssertEqual(try XCTUnwrap(night.deepMin), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.remMin), 30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.lightMin), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.wakeMin), 5, accuracy: 1e-9)
    }

    /// A malformed timeline → no totals → fall back to the day row's deepMin/remMin/lightMin/wasoMin.
    func testMalformedTimelineFallsBackToDayRow() throws {
        let night = RestNight(day: Fixtures.dailyMetric(day: "2026-06-01", totalSleepMin: 420,
                                                       efficiency: 90, deepMin: 111, remMin: 222,
                                                       lightMin: 333, wasoMin: 444),
                              score: 80, session: session("garbage"))
        XCTAssertEqual(try XCTUnwrap(night.deepMin), 111, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.remMin), 222, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.lightMin), 333, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.wakeMin), 444, accuracy: 1e-9)   // wakeMin ← day.wasoMin
    }

    /// No session at all → no timeline → same day-row fallback.
    func testNilSessionFallsBackToDayRow() throws {
        let night = RestNight(day: Fixtures.dailyMetric(day: "2026-06-01", totalSleepMin: 420,
                                                       efficiency: 90, deepMin: 111, remMin: 222,
                                                       lightMin: 333, wasoMin: 444),
                              score: nil, session: nil)
        XCTAssertEqual(try XCTUnwrap(night.deepMin), 111, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.wakeMin), 444, accuracy: 1e-9)
    }
}
