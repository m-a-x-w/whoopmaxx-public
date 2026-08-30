import XCTest
@testable import StrapAnalytics

final class CorrelationTests: XCTestCase {

    func testPerfectPositiveAndNegative() throws {
        let up = try XCTUnwrap(CorrelationEngine.pearson([(1, 2), (2, 4), (3, 6), (4, 8)]))
        XCTAssertEqual(up.r, 1.0, accuracy: 1e-12)
        XCTAssertEqual(up.slope, 2.0, accuracy: 1e-12)
        XCTAssertEqual(up.intercept, 0.0, accuracy: 1e-12)

        let down = try XCTUnwrap(CorrelationEngine.pearson([(1, 8), (2, 6), (3, 4), (4, 2)]))
        XCTAssertEqual(down.r, -1.0, accuracy: 1e-12)
    }

    func testRStaysInsideItsRange() {
        // Floating-point error can push a perfect fit a hair past 1, which breaks every consumer
        // that trusts the range.
        let xy = (0..<500).map { (Double($0), Double($0) * 3.7 + 11) }
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertLessThanOrEqual(abs(c.r), 1.0)
    }

    func testAConstantSeriesHasNoCorrelationRatherThanZero() {
        XCTAssertNil(CorrelationEngine.pearson([(1, 5), (2, 5), (3, 5)]))
        XCTAssertNil(CorrelationEngine.pearson([(5, 1), (5, 2), (5, 3)]))
    }

    func testTwoPointsAreRefused() {
        // Two points fit a line exactly and would report r = ±1 for any data at all.
        XCTAssertNil(CorrelationEngine.pearson([(1, 1), (2, 2)]))
        XCTAssertNil(CorrelationEngine.pearson([]))
    }

    func testPValueFallsAsEvidenceAccumulates() {
        func p(_ n: Int) -> Double {
            let xy: [(Double, Double)] = (0..<n).map { i in
                let jitter: Double = (i % 2 == 0) ? 1.0 : -1.0
                return (Double(i), Double(i) + jitter)
            }
            return CorrelationEngine.pearson(xy)!.pApprox
        }
        XCTAssertGreaterThan(p(5), p(50), "the same relationship is stronger evidence with more days")
        XCTAssertLessThan(p(50), 0.05)
    }

    func testNoRelationshipIsNotSignificant() {
        let xy: [(Double, Double)] = [(1, 5), (2, 3), (3, 8), (4, 1), (5, 7), (6, 2), (7, 6)]
        let c = CorrelationEngine.pearson(xy)!
        XCTAssertGreaterThan(c.pApprox, 0.05)
    }

    func testPValueIsBounded() {
        for n in [3, 10, 100] {
            for r in [-1.0, -0.5, 0.0, 0.5, 1.0] {
                let p = CorrelationEngine.pValue(r: r, n: n)
                XCTAssertGreaterThanOrEqual(p, 0, "r=\(r) n=\(n)")
                XCTAssertLessThanOrEqual(p, 1, "r=\(r) n=\(n)")
            }
        }
    }

    func testIncompleteBetaMatchesKnownValues() {
        // I_x(a,b) with a = b = 1 is just x.
        XCTAssertEqual(CorrelationEngine.regularizedIncompleteBeta(0.25, 1, 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(CorrelationEngine.regularizedIncompleteBeta(0.5, 2, 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CorrelationEngine.regularizedIncompleteBeta(0, 2, 3), 0)
        XCTAssertEqual(CorrelationEngine.regularizedIncompleteBeta(1, 2, 3), 1)
    }

    func testIncompleteBetaIsSymmetricAcrossThePivot() {
        // The two branches must agree, or the p-value jumps at the crossover.
        for x in stride(from: 0.05, to: 1.0, by: 0.05) {
            let a = CorrelationEngine.regularizedIncompleteBeta(x, 3, 5)
            let b = 1 - CorrelationEngine.regularizedIncompleteBeta(1 - x, 5, 3)
            XCTAssertEqual(a, b, accuracy: 1e-9, "x=\(x)")
        }
    }
}

final class AlignmentTests: XCTestCase {

    func testInnerJoinDropsUnmatchedDays() {
        // Filling a missing day with a mean or a zero manufactures agreement on exactly the days
        // with no evidence.
        let a = [(day: "2026-01-01", value: 1.0), (day: "2026-01-02", value: 2.0)]
        let b = [(day: "2026-01-02", value: 20.0), (day: "2026-01-03", value: 30.0)]
        let pairs = CorrelationEngine.alignByDay(a, b)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].0, 2.0)
        XCTAssertEqual(pairs[0].1, 20.0)
    }

    func testAlignmentIsDayOrdered() {
        let a = [(day: "2026-01-03", value: 3.0), (day: "2026-01-01", value: 1.0)]
        let b = [(day: "2026-01-01", value: 10.0), (day: "2026-01-03", value: 30.0)]
        XCTAssertEqual(CorrelationEngine.alignByDay(a, b).map(\.0), [1.0, 3.0])
    }

    func testShiftDayMovesThroughTheCalendar() {
        XCTAssertEqual(CorrelationEngine.shiftDay("2026-01-01", by: 1), "2026-01-02")
        XCTAssertEqual(CorrelationEngine.shiftDay("2026-01-01", by: -1), "2025-12-31")
        XCTAssertEqual(CorrelationEngine.shiftDay("2026-02-28", by: 1), "2026-03-01")
        XCTAssertNil(CorrelationEngine.shiftDay("not-a-day", by: 1))
    }

    func testLaggedShiftsThroughTheCalendarNotByIndex() {
        // A gap in either series must not silently slide the alignment.
        let x = [(day: "2026-01-01", value: 1.0), (day: "2026-01-02", value: 2.0),
                 (day: "2026-01-05", value: 5.0)]
        let y = [(day: "2026-01-02", value: 2.0), (day: "2026-01-03", value: 4.0),
                 (day: "2026-01-06", value: 10.0)]
        let c = CorrelationEngine.lagged(x: x, y: y, lagDays: 1)!
        XCTAssertEqual(c.n, 3, "each x day paired with the y day exactly one calendar day later")
        XCTAssertEqual(c.r, 1.0, accuracy: 1e-9)
    }
}

final class MultipleComparisonTests: XCTestCase {

    func testBenjaminiHochbergIsMonotoneAndInInputOrder() {
        // Without the step-up ceiling a smaller raw p can come back with a larger adjusted value,
        // which reads as nonsense next to its neighbour.
        let raw = [0.001, 0.04, 0.03, 0.5, 0.2]
        let adj = CorrelationEngine.benjaminiHochberg(raw)
        XCTAssertEqual(adj.count, raw.count)
        let byRawOrder = zip(raw, adj).sorted { $0.0 < $1.0 }.map(\.1)
        for i in 1..<byRawOrder.count {
            XCTAssertGreaterThanOrEqual(byRawOrder[i], byRawOrder[i - 1])
        }
        XCTAssertLessThan(adj[0], adj[3], "the strongest hit stays the strongest")
    }

    func testAdjustedValuesStayProbabilities() {
        let adj = CorrelationEngine.benjaminiHochberg([0.9, 0.95, 0.99])
        XCTAssertTrue(adj.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testCorrectionMattersAtScanScale() {
        // With 50 pairs at p < 0.05, two or three spurious hits are expected. A raw p is not a
        // finding until it has been through this.
        let raw = [0.01] + Array(repeating: 0.6, count: 49)
        let adj = CorrelationEngine.benjaminiHochberg(raw)
        XCTAssertGreaterThan(adj[0], raw[0], "a lone hit among fifty is weaker than it looks")
    }

    func testBonferroniIsStricterThanBenjaminiHochberg() {
        let raw = [0.01, 0.02, 0.03, 0.04]
        let bh = CorrelationEngine.benjaminiHochberg(raw)
        let bf = CorrelationEngine.bonferroni(raw)
        for i in raw.indices { XCTAssertGreaterThanOrEqual(bf[i], bh[i]) }
    }

    func testEmptyInput() {
        XCTAssertTrue(CorrelationEngine.benjaminiHochberg([]).isEmpty)
        XCTAssertTrue(CorrelationEngine.bonferroni([]).isEmpty)
    }
}
