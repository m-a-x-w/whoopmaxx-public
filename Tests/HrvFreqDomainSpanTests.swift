import XCTest
import Foundation
import StrapProtocol
import StrapAnalytics
@testable import whoopmaxx

/// The Signal Lab HRV panel's frequency family (LF / HF / LF-HF / total power) and the ONE thing the
/// frozen engine cannot check for itself.
///
/// `HRVFreqDomain` times each beat by the CUMULATIVE SUM of the cleaned R-R, not by its own wall clock
/// (`HRVFreqDomain.swift:106-114`). A dropout is therefore sewn shut invisibly: the record keeps its beats,
/// loses its real duration, and every frequency it reports is scaled by 1/coverage — with no nil to warn
/// anyone. That is measured on the real corpus, where stored R-R tiles only 85.4 % of a session's clock
/// (`HRVAnalyzer.swift:181-187`). `HRVFreqReadout` measures the ratio and WITHHOLDS the four cells below
/// its floor, so these tests pin two separate things:
///
///   1. the engine's own span gates, which decide when LF exists at all, and
///   2. that the gate withholds bands the engine was perfectly happy to return — the failure mode is a
///      plausible number, not a crash, so the interesting assertion is always "the engine said yes AND we
///      still rendered an em-dash".
final class HrvFreqDomainSpanTests: XCTestCase {

    /// The em-dash the readout renders for every withheld band. Matched literally on purpose.
    private let dash = "—"

    // MARK: - Fixtures

    /// R-R values (ms) for `count` beats around `baseMs`, modulated at `hz` — the planted component the
    /// periodogram has to find. At the defaults (1000 ms, 0.25 Hz) the series is 1000 / 1040 / 1000 / 960,
    /// i.e. all of its power sits inside the HF band and none inside LF.
    private func intervals(count: Int, baseMs: Double = 1000, ampMs: Double = 40,
                           hz: Double = 0.25) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(count)
        var tSec = 0.0
        for _ in 0..<count {
            let v = (baseMs + ampMs * sin(2 * Double.pi * hz * tSec)).rounded()
            out.append(v)
            tSec += v / 1000.0
        }
        return out
    }

    /// Timestamp each beat by its OWN cumulative duration, so the wall clock and the tachogram agree and
    /// coverage is 1.0 — unless `gapSec` of clock that no beat accounts for is inserted before `gapAfter`.
    private func timed(_ ms: [Double], gapAfter: Int? = nil, gapSec: Int = 0,
                       startTs: Int = 1_760_000_000) -> [RRInterval] {
        var out: [RRInterval] = []
        out.reserveCapacity(ms.count)
        var cumMs = 0.0
        var planted = 0
        for (i, v) in ms.enumerated() {
            if let gapAfter, i == gapAfter { planted += gapSec }
            out.append(RRInterval(ts: startTs + Int((cumMs / 1000).rounded()) + planted,
                                  rrMs: Int(v.rounded())))
            cumMs += v
        }
        return out
    }

    /// Timestamp each beat on a fixed `stepSec` grid, ignoring how long the interval actually was.
    /// `stepSec: 0` is the degenerate case — every row on one timestamp, no clock to measure against.
    private func gridTimed(_ ms: [Double], stepSec: Int, startTs: Int = 1_760_000_000) -> [RRInterval] {
        ms.enumerated().map {
            RRInterval(ts: startTs + $0.offset * stepSec, rrMs: Int($0.element.rounded()))
        }
    }

    // MARK: - The engine's span gates, through the readout the panel actually renders

    /// 5.5 min of tachogram with a planted 0.25 Hz component: past the LF span gate, so all four cells
    /// carry a number — and the planted component lands in HF, so HF > LF by construction.
    func testFiveAndAHalfMinutesPutsThePlantedComponentInHF() throws {
        let rr = timed(intervals(count: 330))
        XCTAssertGreaterThanOrEqual(Double(rr[rr.count - 1].ts - rr[0].ts),
                                    HRVFreqDomain.minSpanForLFSec,
                                    "fixture must clear the LF span gate or the test proves nothing")

        let readout = HRVFreqReadout.measure(rr)
        let bands = try XCTUnwrap(readout.bands, "a full-coverage 5.5 min window must produce bands")
        let lf = try XCTUnwrap(bands.lf, "LF must exist past \(HRVFreqDomain.minSpanForLFSec) s of span")
        let lfhf = try XCTUnwrap(bands.lfhf)

        XCTAssertGreaterThan(bands.hf, lf, "the planted 0.25 Hz component is inside the HF band")
        XCTAssertLessThan(lfhf, 1.0, "LF/HF must agree with hf > lf")
        // The engine sums its sub-bands rather than taking one wide integral precisely so the superset
        // band can never come out below HF; the "total power" cell reads that field directly.
        XCTAssertGreaterThanOrEqual(bands.totalPower, bands.hf)

        XCTAssertEqual(readout.cells.map { $0.0 }, ["LF", "HF", "LF/HF", "total power"])
        XCTAssertFalse(readout.cells.contains { $0.1 == dash }, "no band should be withheld here")
    }

    /// A 90 s window sits between the two span gates: HF is honest, LF is not, so the LF and LF/HF cells
    /// render an em-dash while HF and total power render numbers. Total power falls back to the HF band.
    func testNinetySecondWindowGivesHFOnlyAndDashesLF() throws {
        let readout = HRVFreqReadout.measure(timed(intervals(count: 90)))
        let bands = try XCTUnwrap(readout.bands, "90 s clears the HF span gate")

        XCTAssertNil(bands.lf, "90 s is under the \(HRVFreqDomain.minSpanForLFSec) s LF gate")
        XCTAssertNil(bands.lfhf, "LF/HF cannot exist without LF")
        XCTAssertGreaterThan(bands.hf, 0)
        XCTAssertEqual(bands.totalPower, bands.hf, accuracy: 1e-9,
                       "on a HF-only window total power must be the HF band, never a partial sum")

        let values = readout.cells.map { $0.1 }
        XCTAssertEqual(values[0], dash, "LF cell")
        XCTAssertEqual(values[2], dash, "LF/HF cell")
        XCTAssertNotEqual(values[1], dash, "HF cell")
        XCTAssertNotEqual(values[3], dash, "total power cell")
    }

    /// Under the HF span gate, and under the clean-beat floor, nothing is reported at all.
    func testWindowsBelowTheEngineGatesReportNothing() {
        for rr in [timed(intervals(count: 40)),   // 39 s of span — under minSpanForHFSec
                   timed(intervals(count: 15))] { // 15 beats — under minBeats
            let readout = HRVFreqReadout.measure(rr)
            XCTAssertEqual(readout, .tooShort)
            XCTAssertEqual(readout.cells.map { $0.1 }, [dash, dash, dash, dash])
        }
    }

    // MARK: - The coverage gate (the trap: the engine says yes on a gapped record)

    /// 400 beats over 570 s of wall clock — 30 % of the window is clock no beat accounts for. The engine
    /// is perfectly happy to return four numbers for it, because it never sees a timestamp. The readout
    /// measures the ratio, finds ~0.70 against the 0.80 floor, and renders em-dashes instead.
    func testThirtyPercentOfTheClockMissingWithholdsTheBands() {
        let ms = intervals(count: 400)
        let gapped = timed(ms, gapAfter: 200, gapSec: 171)

        // The whole point: the frozen engine returns a full result here. Only the app-side gate refuses.
        XCTAssertNotNil(HRVFreqDomain.freqDomain(rr: gapped),
                        "if the engine already refused a gapped record the gate would be redundant")

        let readout = HRVFreqReadout.measure(gapped)
        guard case .gapped(let coverage) = readout else {
            return XCTFail("expected the coverage gate to withhold the bands, got \(readout)")
        }
        XCTAssertEqual(coverage, 0.70, accuracy: 0.02,
                       "coverage is Σ(kept R-R in SECONDS) ÷ wall-clock span")
        XCTAssertLessThan(coverage, HRVFreqReadout.minCoverage)
        XCTAssertNil(readout.bands)
        XCTAssertEqual(readout.cells.map { $0.1 }, [dash, dash, dash, dash],
                       "a shifted frequency must render as an em-dash, never as a number")
        XCTAssertTrue(readout.caption.contains("70%"), "the caption states the measured coverage")
    }

    /// The identical fixture with the gap removed renders — so the gate is a measurement, not a blanket
    /// refusal that would make the four cells dead code.
    func testTheSameWindowWithoutTheGapRenders() throws {
        let readout = HRVFreqReadout.measure(timed(intervals(count: 400)))
        guard case .measured(_, let coverage) = readout else {
            return XCTFail("full-coverage window must clear the gate, got \(readout)")
        }
        XCTAssertEqual(coverage, 1.0, accuracy: 0.01)
        let bands = try XCTUnwrap(readout.bands)
        XCTAssertNotNil(bands.lf, "the ungapped twin must reach the LF band")
        XCTAssertFalse(readout.cells.contains { $0.1 == dash })
    }

    /// Rows denser than the beats they describe (1 s apart carrying 1.9 s intervals) would compute a
    /// coverage of 1.9. Clamped: beats cannot cover more clock than exists, and the caption must never
    /// print "190%".
    func testCoverageIsClampedToOne() {
        let readout = HRVFreqReadout.measure(gridTimed(intervals(count: 80, baseMs: 1900, ampMs: 60),
                                                        stepSec: 1))
        guard case .measured(_, let coverage) = readout else {
            return XCTFail("an over-dense clock must not fail the floor, got \(readout)")
        }
        XCTAssertEqual(coverage, 1.0, accuracy: 1e-9)
        XCTAssertTrue(readout.caption.contains("100%"))
        XCTAssertFalse(readout.caption.contains("190%"))
    }

    /// Band powers land anywhere from ~0.00003 to hundreds depending on the window. A fixed two decimal
    /// places would print two genuinely different bands as the same "0.00" right beside an LF/HF ratio
    /// saying they differ, so the formatter keeps three significant figures instead.
    func testBandFormatterKeepsSmallBandsDistinguishable() {
        XCTAssertNotEqual(HRVFreqReadout.power(0.0306), HRVFreqReadout.power(0.0266))
        XCTAssertEqual(HRVFreqReadout.power(0.892), "0.892")
        XCTAssertEqual(HRVFreqReadout.power(123.4), "123")
        XCTAssertEqual(HRVFreqReadout.power(0), "0")
        XCTAssertFalse(HRVFreqReadout.power(0.00003).contains("e"), "never scientific notation")
    }

    // MARK: - Sources with no clock at all

    /// The live comet is intervals only (`LiveState.rrRecent` is `[Int]`), so there is nothing to measure
    /// the tachogram against and the bands stay blank.
    func testLiveLaneWithoutTimestampsWithholdsTheBands() {
        let readout = HRVFreqReadout.measure(nil)
        XCTAssertEqual(readout, .noTimeBase)
        XCTAssertNil(readout.bands)
        XCTAssertEqual(readout.cells.map { $0.1 }, [dash, dash, dash, dash])
    }

    /// Every row on one timestamp: a zero wall-clock span. The engine still returns bands; coverage is
    /// undefined, so the readout refuses rather than dividing by zero or inventing a ratio.
    func testDegenerateClockIsRefusedRatherThanDividedByZero() {
        let flat = gridTimed(intervals(count: 100), stepSec: 0)
        XCTAssertNotNil(HRVFreqDomain.freqDomain(rr: flat))
        XCTAssertNil(HRVFreqReadout.coverage(flat))
        XCTAssertEqual(HRVFreqReadout.measure(flat), .noTimeBase)
    }

    // MARK: - Copy register (locked decision 5)

    /// Every caption the panel can print, checked against the banned list and against the one reading
    /// LF/HF must never be given.
    func testNoCaptionLeavesTheDescriptiveRegister() {
        let banned = ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                      "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"]
        let states: [HRVFreqReadout] = [
            HRVFreqReadout.measure(timed(intervals(count: 330))),
            HRVFreqReadout.measure(timed(intervals(count: 400), gapAfter: 200, gapSec: 171)),
            HRVFreqReadout.measure(timed(intervals(count: 15))),
            HRVFreqReadout.measure(nil),
        ]
        XCTAssertEqual(Set(states.map { "\($0)" }).count, states.count, "each state must be distinct")

        for state in states {
            let caption = state.caption
            for word in banned {
                XCTAssertFalse(caption.localizedCaseInsensitiveContains(word),
                               "\"\(word)\" is banned from health-framing copy — found in: \(caption)")
            }
            // LF/HF is the ratio of two band powers and nothing more.
            XCTAssertFalse(caption.localizedCaseInsensitiveContains("sympathetic"))
            XCTAssertFalse(caption.localizedCaseInsensitiveContains("balance"))
        }
    }
}
