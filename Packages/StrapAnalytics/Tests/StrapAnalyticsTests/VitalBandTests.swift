import XCTest
@testable import StrapAnalytics

final class VitalBandTests: XCTestCase {

    private let hrv = Baselines.hrvCfg
    private let popRange: ClosedRange<Double> = 20...120

    func testNoValueIsNoDataNotOutOfRange() {
        let r = VitalBands.band(value: nil, history: [], populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.band, .noData)
    }

    func testWithoutEnoughHistoryTheVerdictIsPopulationBased() {
        // A personal claim from a handful of nights is worse than an honest population range.
        let r = VitalBands.band(value: 60, history: [60, 61], populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.basis, .population)
        XCTAssertEqual(r.band, .inRange)
    }

    func testATrustedBaselineEarnsAPersonalVerdict() {
        let history = [Double?](repeating: 60, count: 30)
        let r = VitalBands.band(value: 60, history: history, populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.basis, .personal)
        XCTAssertEqual(r.band, .inRange)
        XCTAssertGreaterThanOrEqual(r.nights, Baselines.minNightsTrust)
    }

    func testAPersonalOutlierIsFlaggedEvenInsideThePopulationRange() {
        // This is the whole point: 40 is a perfectly normal HRV, and a disaster for someone who
        // never goes below 75.
        let history = [Double?](repeating: 80, count: 40)
        let r = VitalBands.band(value: 40, history: history, populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.basis, .personal)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertTrue(popRange.contains(40), "the population would have called this fine")
    }

    func testAbsoluteBoundsOverrideAWidePersonalSpread() {
        // A user with erratic history would otherwise acquire a band so broad nothing is abnormal.
        let erratic: [Double?] = (0..<40).map { $0 % 2 == 0 ? 20 : 200 }
        let r = VitalBands.band(value: 500, history: erratic, populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.band, .outOfRange)
    }

    func testNoConfigFallsStraightToThePopulationRange() {
        let r = VitalBands.band(value: 200, history: [], populationRange: popRange, cfg: nil)
        XCTAssertEqual(r.band, .outOfRange)
        XCTAssertEqual(r.basis, .population)
        XCTAssertEqual(r.nights, 0)
    }

    func testTwoSigmaNotOne() {
        // At one sigma roughly a third of ordinary nights would raise a health flag.
        XCTAssertEqual(VitalBands.sigmaK, 2.0)
        let history = [Double?](repeating: 60, count: 40)
        let state = Baselines.foldHistory(history, cfg: hrv)
        let justOverOneSigma = 60 + 1.3 * Baselines.sigmaPerMAD * state.spread
        let r = VitalBands.band(value: justOverOneSigma, history: history,
                                populationRange: popRange, cfg: hrv)
        XCTAssertEqual(r.band, .inRange, "one and a bit sigmas is an ordinary night")
    }
}

final class SkinTempScaleTests: XCTestCase {

    func testTheTwoScalesAreDistinguished() {
        XCTAssertTrue(VitalBands.isAbsoluteSkinTemp(33))
        XCTAssertFalse(VitalBands.isAbsoluteSkinTemp(0.4))
        XCTAssertFalse(VitalBands.isAbsoluteSkinTemp(-0.4))
    }

    func testHistoryIsFilteredToTheMatchingScale() {
        // A history half in absolute degrees and half in deviations centres near 16, and then
        // every real reading is an outlier.
        let mixed: [Double?] = [33.1, 0.2, 33.4, -0.1, 32.9]
        let forAbsolute = VitalBands.skinTempHistory(matching: 33.0, in: mixed)
        XCTAssertEqual(forAbsolute.compactMap { $0 }, [33.1, 33.4, 32.9])
        let forDeviation = VitalBands.skinTempHistory(matching: 0.3, in: mixed)
        XCTAssertEqual(forDeviation.compactMap { $0 }, [0.2, -0.1])
    }

    func testFilteringPreservesLengthSoTheCalendarIsIntact() {
        let mixed: [Double?] = [33.1, 0.2, nil, 33.4]
        XCTAssertEqual(VitalBands.skinTempHistory(matching: 33.0, in: mixed).count, mixed.count)
    }

    func testDeviationConfigIsCentredOnZero() {
        let cfg = VitalBands.skinTempDeviationCfg
        XCTAssertLessThan(cfg.minVal, 0)
        XCTAssertGreaterThan(cfg.maxVal, 0)
    }
}

final class CalendarSeriesTests: XCTestCase {

    func testMissingDaysBecomeNilRatherThanVanishing() {
        // The baseline counts nights-since-update to decide staleness, so it must SEE the gaps —
        // otherwise a month-old baseline presents itself as current.
        let rows: [(day: String, value: Double?)] = [
            (day: "2026-01-01", value: 60), (day: "2026-01-05", value: 62),
        ]
        let series = VitalBands.calendarSeries(rows)
        XCTAssertEqual(series.count, 5)
        XCTAssertEqual(series[0], 60)
        XCTAssertNil(series[1] ?? nil)
        XCTAssertEqual(series[4], 62)
    }

    func testOutOfOrderRowsStillProduceACalendar() {
        let rows: [(day: String, value: Double?)] = [
            (day: "2026-01-03", value: 3), (day: "2026-01-01", value: 1),
        ]
        XCTAssertEqual(VitalBands.calendarSeries(rows).count, 3)
    }

    func testLastWriteWinsForADuplicatedDay() {
        let rows: [(day: String, value: Double?)] = [
            (day: "2026-01-01", value: 1), (day: "2026-01-01", value: 2),
        ]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [2])
    }

    func testUnparseableDaysAreIgnored() {
        let rows: [(day: String, value: Double?)] = [
            (day: "nonsense", value: 1), (day: "2026-01-01", value: 5),
        ]
        XCTAssertEqual(VitalBands.calendarSeries(rows), [5])
    }

    func testEmptyInput() {
        XCTAssertTrue(VitalBands.calendarSeries([]).isEmpty)
    }

    func testSpansAMonthBoundary() {
        let rows: [(day: String, value: Double?)] = [
            (day: "2026-01-30", value: 1), (day: "2026-02-02", value: 2),
        ]
        XCTAssertEqual(VitalBands.calendarSeries(rows).count, 4)
    }
}
