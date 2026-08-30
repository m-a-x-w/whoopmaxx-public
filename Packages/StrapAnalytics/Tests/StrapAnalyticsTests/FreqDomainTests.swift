import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class HRVFreqDomainTests: XCTestCase {

    /// Beats carrying a sinusoidal modulation at `hz`, over roughly `seconds` of record.
    private func modulated(hz: Double, seconds: Double, meanRR: Double = 1000, amp: Double = 40) -> [Double] {
        let n = Int(seconds * 1000 / meanRR)
        var t = 0.0
        var out: [Double] = []
        for _ in 0..<n {
            let rr = meanRR + amp * sin(2 * .pi * hz * t)
            out.append(rr)
            t += rr / 1000.0
        }
        return out
    }

    func testAnHFRhythmLandsInTheHFBand() throws {
        // 0.25 Hz — a breathing rhythm at 15 breaths a minute.
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 400)))
        let lf = try XCTUnwrap(b.lf)
        XCTAssertGreaterThan(b.hf, lf, "the power is where the rhythm is")
    }

    func testAnLFRhythmLandsInTheLFBand() throws {
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.10, seconds: 400)))
        let lf = try XCTUnwrap(b.lf)
        XCTAssertGreaterThan(lf, b.hf)
        XCTAssertGreaterThan(try XCTUnwrap(b.lfhf), 1.0)
    }

    func testLFIsWithheldOnAShortRecord() {
        // Reporting LF from a minute of beats produces a number that is mostly the record length.
        let b = HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 90))
        XCTAssertNotNil(b)
        XCTAssertNil(b?.lf, "LF needs several minutes to resolve its slowest component")
        XCTAssertNil(b?.lfhf, "and the ratio goes with it")
        XCTAssertGreaterThan(b!.hf, 0)
    }

    func testTooShortForAnyBand() {
        XCTAssertNil(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 30)))
    }

    func testTooFewBeats() {
        XCTAssertNil(HRVFreqDomain.freqDomain(rawRR: [Double](repeating: 1000, count: 10)))
    }

    func testTotalPowerIsNeverBelowHF() throws {
        // A single wide integral samples an offset grid and can come out below hf — impossible for
        // a superset band, and it reads as a bug in any chart showing both.
        for hz in [0.05, 0.15, 0.25, 0.35] {
            let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: hz, seconds: 400)))
            XCTAssertGreaterThanOrEqual(b.totalPower, b.hf, "hz=\(hz)")
        }
    }

    func testTotalPowerCoversTheSubBands() throws {
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.10, seconds: 400)))
        XCTAssertGreaterThanOrEqual(b.totalPower, try XCTUnwrap(b.lf) + b.hf - 1e-9)
    }

    func testAFlatSeriesHasNoPower() {
        // No variation, nothing to find. The variance guard must not divide by zero either.
        let flat = [Double](repeating: 1000, count: 400)
        let b = HRVFreqDomain.freqDomain(rawRR: flat)
        XCTAssertEqual(b?.hf, 0)
        XCTAssertEqual(b?.totalPower, 0)
        XCTAssertNil(b?.lfhf, "a ratio over zero HF is not a number")
    }

    func testResultIsInvariantToWhereTheRecordStarts() throws {
        // tau exists for exactly this: without it the same rhythm measured from a different beat
        // reports a different power.
        let full = modulated(hz: 0.25, seconds: 500)
        let a = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: Array(full.prefix(300))))
        let b = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: Array(full.dropFirst(50).prefix(300))))
        XCTAssertEqual(a.hf, b.hf, accuracy: a.hf * 0.35, "same rhythm, comparable power")
    }

    func testBandPowerIsRelativeNotAbsolute() throws {
        // The periodogram is normalised by the signal's own variance, so amplitude cancels.
        // Sixfold stronger modulation leaves the band power essentially unchanged.
        //
        // This is pinned because it is easy to assume otherwise: charting `hf` across nights as if
        // it were absolute power would be charting the shape of the spectrum, not the amount of
        // variability. RMSSD is the metric for that.
        let weak = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 400, amp: 10)))
        let strong = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 400, amp: 60)))
        XCTAssertEqual(strong.hf, weak.hf, accuracy: 0.05)
    }

    func testTheLFHFRatioIsTheComparableQuantity() throws {
        // Both halves are normalised identically, so their ratio survives the normalisation and
        // IS comparable across records.
        let breathing = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.25, seconds: 400)))
        let slow = try XCTUnwrap(HRVFreqDomain.freqDomain(rawRR: modulated(hz: 0.10, seconds: 400)))
        XCTAssertLessThan(try XCTUnwrap(breathing.lfhf), try XCTUnwrap(slow.lfhf))
    }

    func testTheRRIntervalOverloadSortsFirst() throws {
        let beats = modulated(hz: 0.25, seconds: 400)
        var ts = 0
        let rr = beats.map { v -> RRInterval in
            ts += Int(v / 1000)
            return RRInterval(ts: ts, rrMs: Int(v))
        }
        XCTAssertNotNil(HRVFreqDomain.freqDomain(rr: rr.shuffled()))
    }

    func testBandEdgesAreContiguous() {
        XCTAssertEqual(HRVFreqDomain.lfHighHz, HRVFreqDomain.hfLowHz,
                       "no gap between LF and HF, or power falls down the crack")
        XCTAssertLessThan(HRVFreqDomain.vlfLowHz, HRVFreqDomain.lfLowHz)
    }

    func testBandPowerRejectsAnInvertedRange() {
        XCTAssertEqual(HRVFreqDomain.bandPower(times: [0, 1, 2], y: [1, -1, 1], fLow: 0.3, fHigh: 0.1), 0)
    }
}
