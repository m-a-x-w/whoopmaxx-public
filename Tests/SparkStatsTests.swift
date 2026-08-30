import XCTest
@testable import whoopmaxx

/// Regression pins for `SparkStats.percentile` (numpy-style linear interpolation) and
/// `SparkStats.iqrBand` (the 25th…75th percentile "typical range" band SparkHistory shades), including
/// the small-n safety the band renderer relies on (empty → nil, single → degenerate).
final class SparkStatsTests: XCTestCase {

    // MARK: - percentile

    /// n = 5, position lands exactly on an index → no interpolation. 25th → index 1 (=2), 75th → index 3 (=4).
    func testPercentileExactIndex() throws {
        let xs: [Double] = [1, 2, 3, 4, 5]
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 25)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 75)), 4.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 50)), 3.0, accuracy: 1e-9)
    }

    /// n = 4, positions land between indices → linear interpolation.
    /// 25th: pos = 0.75 → 1 + 0.75·(2−1) = 1.75. 75th: pos = 2.25 → 3 + 0.25·(4−3) = 3.25.
    func testPercentileInterpolates() throws {
        let xs: [Double] = [1, 2, 3, 4]
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 25)), 1.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 75)), 3.25, accuracy: 1e-9)
    }

    /// Two points, 50th percentile → the midpoint (pure interpolation).
    func testPercentileMidpoint() throws {
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile([10, 20], 50)), 15.0, accuracy: 1e-9)
    }

    /// Percentile is order-independent (it sorts internally).
    func testPercentileSortsInput() throws {
        let unordered: [Double] = [5, 1, 4, 2, 3]
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(unordered, 25)), 2.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(unordered, 75)), 4.0, accuracy: 1e-9)
    }

    /// 0th → min, 100th → max.
    func testPercentileEndpoints() throws {
        let xs: [Double] = [3, 8, 1, 9, 4]
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 0)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(SparkStats.percentile(xs, 100)), 9.0, accuracy: 1e-9)
    }

    /// Empty → nil; single element → that element for any pct.
    func testPercentileSmallN() {
        XCTAssertNil(SparkStats.percentile([], 25))
        XCTAssertNil(SparkStats.percentile([], 75))
        XCTAssertEqual(SparkStats.percentile([7], 25), 7.0)
        XCTAssertEqual(SparkStats.percentile([7], 75), 7.0)
        XCTAssertEqual(SparkStats.percentile([7], 50), 7.0)
    }

    // MARK: - iqrBand

    /// The band is exactly the 25th…75th percentile pair.
    func testBandBounds() throws {
        let band = try XCTUnwrap(SparkStats.iqrBand([1, 2, 3, 4, 5]))
        XCTAssertEqual(band.lowerBound, 2.0, accuracy: 1e-9)
        XCTAssertEqual(band.upperBound, 4.0, accuracy: 1e-9)
    }

    /// Interpolated band bounds for n = 4.
    func testBandBoundsInterpolated() throws {
        let band = try XCTUnwrap(SparkStats.iqrBand([4, 1, 3, 2]))
        XCTAssertEqual(band.lowerBound, 1.75, accuracy: 1e-9)
        XCTAssertEqual(band.upperBound, 3.25, accuracy: 1e-9)
    }

    /// Empty → no band; single element → degenerate v…v band (a valid, zero-width range).
    func testBandSmallN() throws {
        XCTAssertNil(SparkStats.iqrBand([]))
        let degenerate = try XCTUnwrap(SparkStats.iqrBand([7]))
        XCTAssertEqual(degenerate.lowerBound, 7.0)
        XCTAssertEqual(degenerate.upperBound, 7.0)
    }
}
