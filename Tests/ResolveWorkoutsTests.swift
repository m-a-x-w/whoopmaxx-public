import XCTest
import StrapStore
@testable import whoopmaxx

/// Regression pins for `WorkoutRepository.resolveWorkouts` — the pure workout resolution pipeline: natural-key
/// dedup (source|startTs|sport), dismissed-span filtering of DETECTED rows, cross-source dedup, and a
/// newest-first sort.
final class ResolveWorkoutsTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String, source: String,
                     avgHr: Int? = nil, maxHr: Int? = nil, strain: Double? = nil,
                     distanceM: Double? = nil, energyKcal: Double? = nil,
                     zonesJSON: String? = nil) -> WorkoutRow {
        Fixtures.workoutRow(startTs: start, endTs: end, sport: sport, source: source,
                            durationS: Double(end - start), energyKcal: energyKcal, avgHr: avgHr,
                            maxHr: maxHr, strain: strain, distanceM: distanceM, zonesJSON: zonesJSON)
    }

    /// Two rows under the SAME natural key (source|startTs|sport) collapse to one; the LATER row in the
    /// input wins the dict merge.
    func testExactDuplicateCollapses() {
        let rows = [
            row(start: 1000, end: 2000, sport: "Running", source: "whoop", avgHr: 100),
            row(start: 1000, end: 2000, sport: "Running", source: "whoop", avgHr: 200),
        ]
        let out = WorkoutRepository.resolveWorkouts(rows, dismissedSpans: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.avgHr, 200)
    }

    /// A DETECTED row (source ends in "-computed") overlapping a dismissed span is removed…
    func testDismissedSpanRemovesDetectedRow() {
        let detected = row(start: 2000, end: 3000, sport: "detected", source: "my-whoop-computed")
        XCTAssertTrue(WorkoutRepository.resolveWorkouts([detected], dismissedSpans: [(2500, 2800)]).isEmpty)
    }

    /// …but survives with no dismissed span covering it.
    func testDetectedRowSurvivesWithoutDismissal() {
        let detected = row(start: 2000, end: 3000, sport: "detected", source: "my-whoop-computed")
        XCTAssertEqual(WorkoutRepository.resolveWorkouts([detected], dismissedSpans: []).count, 1)
    }

    /// A rich strap session and a thin Apple import of the SAME activity (overlapping window + same
    /// sport) resolve to the richer, strap-native row.
    func testCrossSourceKeepsPreferredRow() {
        let whoop = row(start: 5000, end: 8000, sport: "Running", source: "whoop",
                        avgHr: 150, maxHr: 180, strain: 12, distanceM: 5000, energyKcal: 400,
                        zonesJSON: #"{"z3":100}"#)
        let apple = row(start: 5000, end: 8000, sport: "Running", source: "apple-health",
                        energyKcal: 380)
        let out = WorkoutRepository.resolveWorkouts([whoop, apple], dismissedSpans: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.source, "whoop")
    }

    /// Distinct workouts are returned newest-first (by startTs).
    func testSortedNewestFirst() {
        let older = row(start: 1000, end: 1500, sport: "Yoga", source: "whoop")
        let newer = row(start: 9000, end: 9500, sport: "Cycling", source: "whoop")
        let out = WorkoutRepository.resolveWorkouts([older, newer], dismissedSpans: [])
        XCTAssertEqual(out.map(\.startTs), [9000, 1000])
    }
}
