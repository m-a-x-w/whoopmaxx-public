import XCTest
@testable import StrapAnalytics

final class SeriesStatTests: XCTestCase {

    func testBasicStatistics() {
        let s = ComparisonEngine.stat([2, 4, 6, 8])
        XCTAssertEqual(s.mean, 5, accuracy: 1e-9)
        XCTAssertEqual(s.median, 5, accuracy: 1e-9)
        XCTAssertEqual(s.min, 2)
        XCTAssertEqual(s.max, 8)
        XCTAssertEqual(s.n, 4)
    }

    func testMedianAndMeanDisagreeWhereItMatters() {
        // A fortnight of good nights and two terrible ones has a mean that describes neither.
        let nights = [Double](repeating: 460, count: 12) + [60, 90]
        let s = ComparisonEngine.stat(nights)
        XCTAssertLessThan(s.mean, s.median)
        XCTAssertEqual(s.median, 460, accuracy: 1e-9)
    }

    func testDeviationIsTheSampleForm() {
        // [2,4,6,8]: mean 5, ss 20, /3 = 6.67, sqrt ~2.58
        XCTAssertEqual(ComparisonEngine.stat([2, 4, 6, 8]).stdev, 2.582, accuracy: 0.001)
        XCTAssertEqual(ComparisonEngine.stat([5]).stdev, 0, "one value has no dispersion")
    }

    func testSlopeShowsDirectionAMeanCannotSee() {
        // A month that started badly and ended well has the same mean as its reverse.
        let rising = ComparisonEngine.stat([1, 2, 3, 4, 5])
        let falling = ComparisonEngine.stat([5, 4, 3, 2, 1])
        XCTAssertEqual(rising.mean, falling.mean, accuracy: 1e-9)
        XCTAssertEqual(rising.slopePerDay, 1, accuracy: 1e-9)
        XCTAssertEqual(falling.slopePerDay, -1, accuracy: 1e-9)
    }

    func testFlatAndSingletonSeries() {
        XCTAssertEqual(ComparisonEngine.stat([3, 3, 3]).slopePerDay, 0, accuracy: 1e-9)
        XCTAssertEqual(ComparisonEngine.stat([7]).slopePerDay, 0)
        XCTAssertEqual(ComparisonEngine.stat([]), .empty)
    }
}

final class PeriodComparisonTests: XCTestCase {

    func testImprovementAndDecline() {
        let up = ComparisonEngine.compare(current: [10, 12], previous: [8, 8])
        XCTAssertEqual(up.delta, 3, accuracy: 1e-9)
        XCTAssertEqual(up.direction, 1)
        XCTAssertEqual(up.pctChange!, 37.5, accuracy: 0.01)

        let down = ComparisonEngine.compare(current: [8, 8], previous: [10, 12])
        XCTAssertEqual(down.direction, -1)
        XCTAssertLessThan(down.pctChange!, 0)
    }

    func testNoChange() {
        let flat = ComparisonEngine.compare(current: [5, 5], previous: [5, 5])
        XCTAssertEqual(flat.direction, 0)
        XCTAssertEqual(flat.pctChange!, 0, accuracy: 1e-9)
    }

    func testAnEmptyPreviousPeriodIsNotADecline() {
        let c = ComparisonEngine.compare(current: [10, 12], previous: [])
        XCTAssertEqual(c.direction, 0, "no comparison is possible")
        XCTAssertNil(c.pctChange)
        XCTAssertEqual(c.previous.n, 0, "and the caller can tell why")
    }

    func testAZeroPreviousMeanHasNoPercentage() {
        // A percentage against nothing is undefined, not a large change.
        let c = ComparisonEngine.compare(current: [5], previous: [0])
        XCTAssertNil(c.pctChange)
        XCTAssertEqual(c.direction, 1, "the absolute delta is still meaningful")
    }

    func testPercentageUsesTheAbsolutePreviousMean() {
        // A metric that can go negative — a temperature deviation — must not flip the sign of
        // its own change.
        let c = ComparisonEngine.compare(current: [-1], previous: [-2])
        XCTAssertEqual(c.delta, 1, accuracy: 1e-9)
        XCTAssertEqual(c.pctChange!, 50, accuracy: 1e-9, "improving from -2 to -1 is +50%, not -50%")
    }

    func testBothPeriodsEmpty() {
        let c = ComparisonEngine.compare(current: [], previous: [])
        XCTAssertEqual(c.direction, 0)
        XCTAssertNil(c.pctChange)
    }
}

final class MonthOverMonthTests: XCTestCase {

    private let rows: [(day: String, value: Double)] = [
        (day: "2026-02-01", value: 10), (day: "2026-02-15", value: 20),
        (day: "2026-01-05", value: 4),  (day: "2026-01-20", value: 6),
        (day: "2025-12-31", value: 99),
    ]

    func testSplitsOnTheDayKeyPrefix() {
        let c = ComparisonEngine.monthOverMonth(byDay: rows, referenceDay: "2026-02-20")
        XCTAssertEqual(c.current.n, 2)
        XCTAssertEqual(c.previous.n, 2)
        XCTAssertEqual(c.current.mean, 15, accuracy: 1e-9)
        XCTAssertEqual(c.previous.mean, 5, accuracy: 1e-9)
        XCTAssertEqual(c.direction, 1)
    }

    func testDecemberRollsBackAYear() {
        let c = ComparisonEngine.monthOverMonth(byDay: rows, referenceDay: "2026-01-10")
        XCTAssertEqual(c.current.n, 2, "January")
        XCTAssertEqual(c.previous.n, 1, "December of the previous year")
        XCTAssertEqual(c.previous.mean, 99, accuracy: 1e-9)
    }

    func testSlopeIsChronologicalWhateverTheInputOrder() {
        let ascending: [(day: String, value: Double)] = [
            (day: "2026-03-01", value: 1), (day: "2026-03-02", value: 2), (day: "2026-03-03", value: 3),
        ]
        let a = ComparisonEngine.monthOverMonth(byDay: ascending, referenceDay: "2026-03-10")
        let b = ComparisonEngine.monthOverMonth(byDay: ascending.reversed(), referenceDay: "2026-03-10")
        XCTAssertEqual(a.current.slopePerDay, b.current.slopePerDay, accuracy: 1e-9)
        XCTAssertGreaterThan(a.current.slopePerDay, 0)
    }

    func testAnUnparseableReferenceDayComparesNothing() {
        let c = ComparisonEngine.monthOverMonth(byDay: rows, referenceDay: "nonsense")
        XCTAssertEqual(c.current.n, 0)
        XCTAssertEqual(c.previous.n, 0)
    }

    func testPrefixMatchingDoesNotBleedAcrossMonths() {
        // "2026-1" must not match "2026-12".
        let tricky: [(day: String, value: Double)] = [
            (day: "2026-01-05", value: 1), (day: "2026-12-05", value: 100),
        ]
        let c = ComparisonEngine.monthOverMonth(byDay: tricky, referenceDay: "2026-01-31")
        XCTAssertEqual(c.current.n, 1)
        XCTAssertEqual(c.current.mean, 1, accuracy: 1e-9)
    }

    func testMonthHelpers() {
        XCTAssertEqual(ComparisonEngine.monthPrefix(year: 2026, month: 3), "2026-03")
        XCTAssertEqual(ComparisonEngine.monthPrefix(year: 2026, month: 11), "2026-11")
        XCTAssertEqual(ComparisonEngine.previousMonth(year: 2026, month: 1).year, 2025)
        XCTAssertEqual(ComparisonEngine.previousMonth(year: 2026, month: 1).month, 12)
        XCTAssertNil(ComparisonEngine.yearMonth(of: "2026-13-01"), "month 13 is not a month")
        XCTAssertNil(ComparisonEngine.yearMonth(of: "oops"))
    }
}
