import XCTest
import StrapStore
@testable import whoopmaxx

/// Regression pins for `WorkoutZones.percents` (imported per-workout HR-zone JSON → clamped Z1…Z5
/// percentages) and `WorkoutZones.summary` (duration-weighted zone minutes across rows).
final class WorkoutZonesTests: XCTestCase {

    private func row(zonesJSON: String?, durationS: Double?, startTs: Int = 0, endTs: Int = 0) -> WorkoutRow {
        Fixtures.workoutRow(startTs: startTs, endTs: endTs, sport: "Running", source: "whoop",
                            durationS: durationS, zonesJSON: zonesJSON)
    }

    // MARK: - percents

    /// The "z1"… and the Android "zone1"… spellings parse identically.
    func testZAndZonePrefixesParseIdentically() {
        let z = WorkoutZones.percents(#"{"z1":10,"z2":20,"z3":30,"z4":25,"z5":15}"#)
        let zone = WorkoutZones.percents(#"{"zone1":10,"zone2":20,"zone3":30,"zone4":25,"zone5":15}"#)
        XCTAssertEqual(z, [10, 20, 30, 25, 15])
        XCTAssertEqual(zone, [10, 20, 30, 25, 15])
    }

    /// Values > 100 clamp to 100, negatives clamp to 0.
    func testClampsToZeroHundred() {
        XCTAssertEqual(WorkoutZones.percents(#"{"z1":150,"z2":-5,"z3":50}"#), [100, 0, 50, 0, 0])
    }

    /// An all-zero object carries no usable data → nil.
    func testAllZeroIsNil() {
        XCTAssertNil(WorkoutZones.percents(#"{"z1":0,"z2":0,"z3":0,"z4":0,"z5":0}"#))
    }

    /// Nil and non-JSON garbage → nil.
    func testNilAndGarbageAreNil() {
        XCTAssertNil(WorkoutZones.percents(nil))
        XCTAssertNil(WorkoutZones.percents("not json at all"))
    }

    // MARK: - summary

    /// Duration-weights zone minutes across two rows and falls back to endTs−startTs when durationS is
    /// nil. Row A: 50/50 over 600s (10 min) → 5 min Z1, 5 min Z2. Row B: 100% Z3 over an endTs−startTs
    /// span of 1200s (20 min) → 20 min Z3. Sum → [5, 5, 20, 0, 0].
    func testSummaryDurationWeightsAndFallsBackToSpan() throws {
        let rows = [
            row(zonesJSON: #"{"z1":50,"z2":50}"#, durationS: 600),
            row(zonesJSON: #"{"z3":100}"#, durationS: nil, startTs: 0, endTs: 1200),
        ]
        let s = try XCTUnwrap(WorkoutZones.summary(from: rows))
        XCTAssertEqual(s.sessionsWithZones, 2)
        for (i, want) in [5.0, 5.0, 20.0, 0.0, 0.0].enumerated() {
            XCTAssertEqual(s.minutes[i], want, accuracy: 1e-9, "zone index \(i)")
        }
        XCTAssertEqual(s.totalMinutes, 30, accuracy: 1e-9)
    }

    /// Rows carrying no zone data → nil summary.
    func testSummaryNoZonesIsNil() {
        XCTAssertNil(WorkoutZones.summary(from: [row(zonesJSON: nil, durationS: 600)]))
    }
}
