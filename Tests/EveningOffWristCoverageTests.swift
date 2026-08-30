import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// TODAY's night read is capped at 18:00 (the #500 sleep-window guard), but the capture-coverage grade
/// runs to min(22:00, now) — and `GapScan` explains HR silence away ONLY with an off-wrist interval. When
/// the wrist-event read was bounded by that same 18:00 cap, an evening spent off the wrist was invisible
/// to the grader: its silence was booked as a genuine capture gap while the same seconds still counted
/// toward the worn denominator, so `effort_coverage` came out false-low. That is persisted and consumed
/// everywhere — Today dims the Effort column and captions "partial capture", and the Data tab withholds
/// the day's Effort and Calories entirely, so its tile silently shows the previous day's number.
final class EveningOffWristCoverageTests: XCTestCase {

    /// Fixed UTC so the day arithmetic is deterministic regardless of the host zone.
    private let utc = 0
    private let dayKey = "2026-08-05"

    private func dayStart() -> Int {
        GapScan.localDayStart(dayKey, offsetSec: utc)!
    }

    /// Dense 1-per-minute HR across a span.
    private func hr(from: Int, to: Int) -> [Int] {
        stride(from: from, through: to, by: 60).map { $0 }
    }

    /// The evening off-wrist run, seen by the grader: the silence is explained, coverage is whole.
    func testEveningOffWristIsExplainedWhenTheEventsAreVisible() {
        let d = dayStart()
        // Worn 08:00–15:00, off the wrist 15:00–21:00, back on and worn 21:00–22:00.
        let worn = hr(from: d + 8 * 3_600, to: d + 15 * 3_600) + hr(from: d + 21 * 3_600, to: d + 22 * 3_600)
        let offWrist = [(start: d + 15 * 3_600, end: d + 21 * 3_600)]   // off 15:00–21:00

        let c = GapScan.dayCoverage(dayKey: dayKey, hrTimestamps: worn, offWrist: offWrist,
                                    offsetSec: utc, clampEnd: d + 22 * 3_600)

        XCTAssertEqual(c.coverage, 1.0, accuracy: 0.001,
                       "an off-wrist stretch is removed from the graded window, not counted as a gap")
        XCTAssertTrue(c.gaps.isEmpty)
    }

    /// The regression: the SAME day graded with the off-wrist run truncated at 18:00 — which is exactly
    /// what a wrist-event read bounded by the night window produced.
    func testTruncatedOffWristRunFabricatesAGapAndDeflatesCoverage() {
        let d = dayStart()
        // Identical wear reality as above — only the VISIBILITY of the 21:00 WRIST_ON differs.
        let worn = hr(from: d + 8 * 3_600, to: d + 15 * 3_600) + hr(from: d + 21 * 3_600, to: d + 22 * 3_600)
        let truncated = [(start: d + 15 * 3_600, end: d + 18 * 3_600)]   // WRIST_ON at 21:00 unseen

        let c = GapScan.dayCoverage(dayKey: dayKey, hrTimestamps: worn, offWrist: truncated,
                                    offsetSec: utc, clampEnd: d + 22 * 3_600)

        XCTAssertLessThan(c.coverage, 0.8,
                          "this is the false-low grade that withheld the day's Effort and Calories")
        XCTAssertFalse(c.gaps.isEmpty, "the unexplained 18:00–21:00 silence is booked as a capture gap")
    }

    /// A day genuinely uncaptured while worn must STILL grade low — the widened event read only explains
    /// silence a real WRIST_OFF/WRIST_ON pair covers.
    func testGenuineGapWhileWornStillGradesLow() {
        let d = dayStart()
        let worn = hr(from: d + 8 * 3_600, to: d + 15 * 3_600)

        let c = GapScan.dayCoverage(dayKey: dayKey, hrTimestamps: worn, offWrist: [],
                                    offsetSec: utc, clampEnd: d + 22 * 3_600)

        XCTAssertLessThan(c.coverage, 0.8, "no off-wrist evidence means the silence is a real gap")
    }

    /// An off-wrist run extending past the clamp is harmless — it just removes the rest of the window.
    func testOffWristPastTheClampIsClamped() {
        let d = dayStart()
        let worn = hr(from: d + 8 * 3_600, to: d + 15 * 3_600)
        let offWrist = [(start: d + 15 * 3_600, end: d + 30 * 3_600)]

        let c = GapScan.dayCoverage(dayKey: dayKey, hrTimestamps: worn, offWrist: offWrist,
                                    offsetSec: utc, clampEnd: d + 22 * 3_600)

        XCTAssertEqual(c.coverage, 1.0, accuracy: 0.001)
        XCTAssertTrue(c.gaps.isEmpty)
    }
}
