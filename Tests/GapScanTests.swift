import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// GapScan (007 F4): a >15-min HR silence while WORN is a capture gap; the same silence while
/// off-wrist is expected and never reported. Coverage is the worn share of the 08:00–22:00 waking
/// window. Fixtures run at offsetSec 0 (UTC) so the window bounds are deterministic.
final class GapScanTests: XCTestCase {

    private let day = "2026-03-10"

    private func midnight(_ day: String) -> Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return Int(fmt.date(from: day)!.timeIntervalSince1970)
    }

    /// 2-min-cadence timestamps over `[from, to)`, optionally skipping a `[start, end)` hole.
    private func cadence(from: Int, to: Int, skipping hole: (Int, Int)? = nil) -> [Int] {
        stride(from: from, to: to, by: 120).filter { t in
            guard let hole else { return true }
            return t < hole.0 || t >= hole.1
        }
    }

    func testContinuousCaptureHasFullCoverageAndNoGaps() {
        let mid = midnight(day)
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 22 * 3_600)
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)
        XCTAssertTrue(cov.gaps.isEmpty)
        XCTAssertEqual(cov.coverage, 1.0, accuracy: 0.001)
    }

    func testThreeHourSilenceWhileWornIsAGap() throws {
        let mid = midnight(day)
        let hole = (mid + 13 * 3_600, mid + 16 * 3_600)                       // 13:00–16:00
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 22 * 3_600, skipping: hole)
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)
        XCTAssertEqual(cov.gaps.count, 1)
        let gap = try XCTUnwrap(cov.gaps.first)
        XCTAssertGreaterThanOrEqual(gap.durationS, 3 * 3_600,
                                    "the 13:00–16:00 silence must surface as a ≥3 h gap")
        // ~3 h missing from a 14 h waking window → coverage ≈ 0.78.
        XCTAssertEqual(cov.coverage, 1.0 - Double(gap.durationS) / Double(14 * 3_600),
                       accuracy: 0.001)
        XCTAssert((0.75...0.82).contains(cov.coverage), "coverage was \(cov.coverage)")
    }

    func testOffWristSilenceIsNotAGap() {
        let mid = midnight(day)
        let hole = (mid + 13 * 3_600, mid + 16 * 3_600)
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 22 * 3_600, skipping: hole)
        // Off-wrist spans the whole silence (opened a touch early, at the last sample before it).
        let off = [(start: hole.0 - 180, end: hole.1)]
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: off, offsetSec: 0)
        XCTAssertTrue(cov.gaps.isEmpty, "silence while off-wrist is expected, not a capture gap")
        XCTAssertEqual(cov.coverage, 1.0, accuracy: 0.001,
                       "off-wrist time leaves the worn window fully covered")
    }

    func testPartiallyOffWristSilenceReportsOnlyTheWornRemainder() {
        let mid = midnight(day)
        let hole = (mid + 13 * 3_600, mid + 16 * 3_600)
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 22 * 3_600, skipping: hole)
        // Off-wrist covers only 13:00–14:00 of the 3-h silence → a ~2 h worn gap remains.
        let off = [(start: hole.0, end: hole.0 + 3_600)]
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: off, offsetSec: 0)
        XCTAssertEqual(cov.gaps.count, 1)
        XCTAssertEqual(Double(cov.gaps[0].durationS), 2 * 3_600, accuracy: 200)
    }

    func testSilenceUnderThresholdIsNotAGap() {
        let mid = midnight(day)
        // Dropping the 13:00–13:12 samples leaves a 14-min inter-sample span (12:58 → 13:12),
        // under the 15-min threshold.
        let hole = (mid + 13 * 3_600, mid + 13 * 3_600 + 12 * 60)
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 22 * 3_600, skipping: hole)
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)
        XCTAssertTrue(cov.gaps.isEmpty)
        XCTAssertEqual(cov.coverage, 1.0, accuracy: 0.001)
    }

    func testClampEndStopsTodayFromReadingAsAGap() {
        let mid = midnight(day)
        // Samples only until 12:00 "now" — clamped, the un-lived remainder is not a gap.
        let ts = cadence(from: mid + 8 * 3_600, to: mid + 12 * 3_600)
        let clamped = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [],
                                          offsetSec: 0, clampEnd: mid + 12 * 3_600)
        XCTAssertTrue(clamped.gaps.isEmpty)
        XCTAssertEqual(clamped.coverage, 1.0, accuracy: 0.001)
        // Unclamped, the missing afternoon IS a gap.
        let open = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)
        XCTAssertEqual(open.gaps.count, 1)
    }

    func testWindowNotStartedIsDistinctFromZeroCoverage() {
        let mid = midnight(day)
        // At 07:00 "now", today's 08:00 window hasn't begun — callers must render "not graded
        // yet" (nil), never a false 0 % capture failure.
        XCTAssertTrue(GapScan.windowNotStarted(dayKey: day, offsetSec: 0,
                                               clampEnd: mid + 7 * 3_600))
        XCTAssertTrue(GapScan.windowNotStarted(dayKey: day, offsetSec: 0,
                                               clampEnd: mid + 8 * 3_600),
                      "exactly 08:00 still has a zero-width window — not started")
        XCTAssertFalse(GapScan.windowNotStarted(dayKey: day, offsetSec: 0,
                                                clampEnd: mid + 8 * 3_600 + 60))
    }

    func testNoDataDayIsOneFullGap() {
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: [], offWrist: [], offsetSec: 0)
        XCTAssertEqual(cov.gaps.count, 1)
        XCTAssertEqual(cov.gaps[0].durationS, 14 * 3_600)
        XCTAssertEqual(cov.coverage, 0.0, accuracy: 0.001)
    }

    // MARK: - The Effort low-coverage gate (the real 2026-07-15 shape)

    /// THE SHAPE THAT MOTIVATED WIRING COVERAGE INTO SCORING. On 2026-07-15 the real store has exactly one
    /// HR gap over 5 min: 00:05:35 → 12:38:32, 753.0 minutes, with NO `WRIST_OFF` event covering it (the
    /// store's 8 WRIST_OFF events are on other days), so it is genuine capture loss rather than explained
    /// non-wear. It grades ~0.67 here and trips `ScoreConfidence.effortSolidCoverage`.
    ///
    /// That day's Effort scored 27.01 — inside the 26.31–64.18 band of the 17 full days and numerically
    /// indistinguishable from 07-22 (99.8% coverage, 26.31). Nothing in the row, the series or the UI said
    /// 12.5 hours were missing, because `edwardsTRIMP` is a plain sum with no coverage term.
    func testTwelveHourMorningHoleGradesBelowTheEffortSolidBar() throws {
        let mid = midnight(day)
        // HR present only from 12:38 to midnight — the surviving half of the real day.
        let ts = stride(from: mid + 12 * 3_600 + 38 * 60, to: mid + 86_400, by: 60).map { $0 }
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)

        // The waking window is 08:00–22:00 (14 h); the hole eats 08:00–12:38 = 4 h 38 m of it.
        XCTAssertEqual(cov.coverage, 1.0 - (4.0 + 38.0 / 60.0) / 14.0, accuracy: 0.005)
        XCTAssertEqual(cov.gaps.count, 1)
        XCTAssertLessThan(cov.coverage, ScoreConfidence.effortSolidCoverage,
                          "this day's Effort must be flagged as partial capture")
    }

    /// The other side of the bar, so the threshold is a real discriminator and not "anything imperfect".
    /// 2026-07-25 grades 0.891 on the real data and must stay a full-confidence day; the 16 clean days all
    /// grade exactly 1.0. Zero false positives is what makes this safe to gate scoring on.
    func testShorterHoleStaysAboveTheEffortSolidBar() {
        let mid = midnight(day)
        // A ~1 h 20 m hole inside the waking window: 10:00 → 11:20.
        var ts = stride(from: mid + 8 * 3_600, to: mid + 10 * 3_600, by: 60).map { $0 }
        ts += stride(from: mid + 11 * 3_600 + 20 * 60, to: mid + 22 * 3_600, by: 60).map { $0 }
        let cov = GapScan.dayCoverage(dayKey: day, hrTimestamps: ts, offWrist: [], offsetSec: 0)

        XCTAssertGreaterThan(cov.coverage, ScoreConfidence.effortSolidCoverage,
                             "a ~1.3 h hole is not a partial-capture day")
    }
}
