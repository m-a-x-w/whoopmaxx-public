import XCTest
@testable import whoopmaxx

/// Capture coverage must never be graded over time that predates the install.
///
/// `GapScan`'s waking window always opened at 08:00 local. On a fresh install that made the app invent
/// history: every day before setup graded 0 % with one 08:00–22:00 "gap while worn", under Strap Health
/// copy stating the recording is permanently lost — for days the app did not exist. It also punished the
/// install day itself: paired at 15:00, the day was graded from 08:00, scored ~0.70, and fell under the
/// 0.80 bar that badges Effort "partial capture" and drops the day from the Effort baseline.
///
/// `clampStart` is the symmetric twin of the existing `clampEnd`.
final class CoverageFloorTests: XCTestCase {

    private let day = "2026-07-30"

    /// Local midnight for the test day, at a fixed offset so the arithmetic is exact.
    private func midnight(offsetSec: Int) -> Int {
        GapScan.localDayStart(day, offsetSec: offsetSec)!
    }

    /// A strap paired at 15:00 must be graded from 15:00, not from 08:00 — the seven hours before it
    /// existed are not a capture failure.
    func testAMidAfternoonPairIsNotGradedFromEightAM() {
        let off = -4 * 3_600
        let start = midnight(offsetSec: off)
        let pairedAt = start + 15 * 3_600
        // 1 Hz from the pair instant to 22:00.
        let ts = Array(stride(from: pairedAt, to: start + 22 * 3_600, by: 60))

        let unfloored = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: off)
        let floored = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: off,
                                          clampEnd: nil, clampStart: pairedAt)

        XCTAssertLessThan(unfloored.coverage, 0.80,
                          "ungrounded, the pairing day scores under the partial-capture bar")
        XCTAssertGreaterThan(floored.coverage, 0.99,
                             "grounded at the first sample, the day is fully captured — because it was")
        XCTAssertTrue(floored.gaps.isEmpty, "the hours before setup are not a gap")
    }

    /// A day entirely before the first sample collapses to a zero-width window: no coverage, no gaps.
    /// This is the "app wasn't installed" case Strap Health rendered as a 14-hour permanent loss.
    func testADayBeforeAnyDataYieldsNoGaps() {
        let off = -4 * 3_600
        let firstEver = midnight(offsetSec: off) + 3 * 86_400   // data starts three days later
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: [], offWrist: [], offsetSec: off,
                                      clampEnd: nil, clampStart: firstEver)
        XCTAssertTrue(cov.gaps.isEmpty, "a day before the app existed cannot have lost recording")
        XCTAssertEqual(cov.coverage, 0)
    }

    /// THE CASE THE FLOOR MUST NOT BREAK: a day the user genuinely wore the strap through, with a real
    /// mid-day gap, still reports it. The floor only ever removes time before the store's first sample.
    func testAGenuineGapIsStillReported() {
        let off = -4 * 3_600
        let start = midnight(offsetSec: off)
        let firstEver = start - 5 * 86_400          // store has days of prior history
        // Worn 08:00–12:00 and 16:00–22:00 — a real four-hour gap in the middle.
        var ts = Array(stride(from: start + 8 * 3_600, to: start + 12 * 3_600, by: 60))
        ts += Array(stride(from: start + 16 * 3_600, to: start + 22 * 3_600, by: 60))

        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: off,
                                      clampEnd: nil, clampStart: firstEver)
        XCTAssertFalse(cov.gaps.isEmpty, "a real gap on a real worn day must still be reported")
        XCTAssertLessThan(cov.coverage, 0.8)
    }

    /// Absent a floor, behaviour is byte-identical to before — the parameter defaults to nil and every
    /// existing caller and test is untouched.
    func testNoFloorIsUnchanged() {
        let off = -4 * 3_600
        let start = midnight(offsetSec: off)
        let ts = Array(stride(from: start + 8 * 3_600, to: start + 22 * 3_600, by: 60))
        let a = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: off)
        let b = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: off,
                                    clampEnd: nil, clampStart: nil)
        XCTAssertEqual(a.coverage, b.coverage, accuracy: 1e-12)
    }
}
