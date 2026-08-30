import XCTest
import Foundation
@testable import whoopmaxx

/// Regression pins for `MetricMath.slopePerDay` (least-squares slope in units/day) and
/// `MetricMath.standardDeviation` (sample SD, n−1).
final class MetricMathTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func day(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 86_400) }

    // MARK: - slopePerDay

    /// A clean line rising 2 units/day → slope exactly 2.0. Points: 10, 12, 14, 16 on days 0…3.
    func testSlopeOfKnownLine() throws {
        let pts = [(day(0), 10.0), (day(1), 12.0), (day(2), 14.0), (day(3), 16.0)]
            .map { (date: $0.0, value: $0.1) }
        XCTAssertEqual(try XCTUnwrap(MetricMath.slopePerDay(pts)), 2.0, accuracy: 1e-9)
    }

    /// A constant series has zero slope.
    func testSlopeOfConstantIsZero() throws {
        let pts = [(day(0), 5.0), (day(1), 5.0), (day(2), 5.0)].map { (date: $0.0, value: $0.1) }
        XCTAssertEqual(try XCTUnwrap(MetricMath.slopePerDay(pts)), 0.0, accuracy: 1e-12)
    }

    /// Fewer than 2 points → nil.
    func testSlopeSinglePointIsNil() {
        XCTAssertNil(MetricMath.slopePerDay([(date: day(0), value: 5.0)]))
    }

    /// All points on one day → degenerate fit (den 0) → nil.
    func testSlopeAllSameDayIsNil() {
        let pts = [(date: day(0), value: 5.0), (date: day(0), value: 9.0)]
        XCTAssertNil(MetricMath.slopePerDay(pts))
    }

    // MARK: - standardDeviation

    /// A constant series has zero standard deviation.
    func testSDOfConstantIsZero() throws {
        XCTAssertEqual(try XCTUnwrap(MetricMath.standardDeviation([5, 5, 5])), 0.0, accuracy: 1e-12)
    }

    /// Hand-computed: [2, 4, 6] → mean 4, ss = 4+0+4 = 8, /(3−1) = 4, √4 = 2.
    func testSDHandComputed() throws {
        XCTAssertEqual(try XCTUnwrap(MetricMath.standardDeviation([2, 4, 6])), 2.0, accuracy: 1e-9)
    }

    /// Fewer than 2 points → nil.
    func testSDBelowTwoPointsIsNil() {
        XCTAssertNil(MetricMath.standardDeviation([5]))
        XCTAssertNil(MetricMath.standardDeviation([]))
    }
}
