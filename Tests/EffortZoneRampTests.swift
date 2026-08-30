import XCTest
@testable import whoopmaxx

/// Regression pins for `EffortZoneRamp.index` (%-of-HRmax zone boundaries, inclusive `pct >= bound`) and
/// `EffortZoneRamp.rangeText` (the caption spans). Zone lower bounds: Z2 60%, Z3 70%, Z4 80%, Z5 90%.
final class EffortZoneRampTests: XCTestCase {

    // MARK: - index — inclusive lower boundary transitions (hrMax 100 → pct == bpm/100)

    func testIndexBoundaryTransitions() {
        XCTAssertEqual(EffortZoneRamp.index(bpm: 59, hrMax: 100), 0)   // < 60% → Z1
        XCTAssertEqual(EffortZoneRamp.index(bpm: 60, hrMax: 100), 1)   // == 60% → Z2 (inclusive)
        XCTAssertEqual(EffortZoneRamp.index(bpm: 69, hrMax: 100), 1)
        XCTAssertEqual(EffortZoneRamp.index(bpm: 70, hrMax: 100), 2)   // == 70% → Z3
        XCTAssertEqual(EffortZoneRamp.index(bpm: 79, hrMax: 100), 2)
        XCTAssertEqual(EffortZoneRamp.index(bpm: 80, hrMax: 100), 3)   // == 80% → Z4
        XCTAssertEqual(EffortZoneRamp.index(bpm: 89, hrMax: 100), 3)
        XCTAssertEqual(EffortZoneRamp.index(bpm: 90, hrMax: 100), 4)   // == 90% → Z5
        XCTAssertEqual(EffortZoneRamp.index(bpm: 100, hrMax: 100), 4)
        XCTAssertEqual(EffortZoneRamp.index(bpm: 200, hrMax: 100), 4)  // above max stays Z5
    }

    // MARK: - rangeText — captions (note the en-dash "–")

    func testRangeTextCaptions() {
        XCTAssertEqual(EffortZoneRamp.rangeText(0, hrMax: 187), "under 60% of max 187")
        XCTAssertEqual(EffortZoneRamp.rangeText(1, hrMax: 187), "60–70% of max 187")
        XCTAssertEqual(EffortZoneRamp.rangeText(2, hrMax: 187), "70–80% of max 187")
        XCTAssertEqual(EffortZoneRamp.rangeText(3, hrMax: 187), "80–90% of max 187")
        XCTAssertEqual(EffortZoneRamp.rangeText(4, hrMax: 187), "90–100% of max 187")
    }

    /// Out-of-range zone indices clamp into 0…4.
    func testRangeTextClampsOutOfRange() {
        XCTAssertEqual(EffortZoneRamp.rangeText(-1, hrMax: 187), "under 60% of max 187")
        XCTAssertEqual(EffortZoneRamp.rangeText(9, hrMax: 187), "90–100% of max 187")
    }
}
