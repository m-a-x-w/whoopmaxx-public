import XCTest
import StrapProtocol
import StrapAnalytics
@testable import whoopmaxx

/// The capture caption under "Why you woke" — the one line that says how much of the night the stager
/// actually had to look at.
///
/// Three things have to hold or the caption becomes the thing it exists to prevent. (a) It may only fire
/// on the nights the STAGER itself calls sparse: the gate is `SleepDetection.sparseGravitySpanFrac`, read
/// from the package, never a second copy of 0.5 that can drift out of agreement with the staging path it
/// claims to describe. (b) A window too short to measure returns nil, not a fraction of nothing —
/// `hrDensityPerMinute` is the reference gate, and its degenerate case is two samples at the SAME
/// timestamp (count ≥ 2, span 0), which is where a naive ratio divides by zero. (c) Every printed number
/// is one that was measured: an empty gravity stream over a real HR window is a true 0 %, and a night
/// sampled 0.04×/min must not round to "0.0×/min" and read as no HR at all beside a ledger built of HR.
final class CaptureQualityTests: XCTestCase {

    /// An eight-hour night — the window a sparse WHOOP-5 backfill lands in.
    private let start = 1_749_513_600
    private let nightS = 8 * 3_600

    private func hr(everyS: Int, spanS: Int) -> [HRSample] {
        stride(from: 0, through: spanS, by: everyS).map { HRSample(ts: start + $0, bpm: 52) }
    }

    /// Gravity over `spanS` of the window. The last sample lands exactly on `spanS` — the SPAN is what
    /// is being measured, so a cadence that doesn't divide it evenly must not shorten it.
    private func gravity(spanS: Int, everyS: Int = 60) -> [GravitySample] {
        var offsets = Array(stride(from: 0, to: spanS, by: everyS))
        offsets.append(spanS)
        return offsets.map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    // MARK: - Nothing to measure

    /// Fewer than two HR samples is not a window. Nil, not a zero.
    func testTooFewHrSamplesMeasureNothing() {
        XCTAssertNil(CaptureQuality.measure(hr: [], gravity: gravity(spanS: nightS)))
        XCTAssertNil(CaptureQuality.measure(hr: [HRSample(ts: start, bpm: 52)],
                                            gravity: gravity(spanS: nightS)))
    }

    /// THE DIVIDE-BY-ZERO CASE: two samples that share a timestamp pass any count check and still span
    /// no time at all. There is no density, and no share of the window to report.
    func testADegenerateHrSpanMeasuresNothing() {
        let sameInstant = [HRSample(ts: start, bpm: 52), HRSample(ts: start, bpm: 53)]
        XCTAssertNil(CaptureQuality.measure(hr: sameInstant, gravity: gravity(spanS: nightS)),
                     "an HR window of zero seconds has no density to divide out")
    }

    // MARK: - The gate

    /// A night whose gravity spans the whole HR window ran the ordinary staging path — there is nothing
    /// to explain, so there is no caption.
    func testAFullyCoveredNightSaysNothing() throws {
        let q = try XCTUnwrap(CaptureQuality.measure(hr: hr(everyS: 1, spanS: 600),
                                                     gravity: gravity(spanS: 600, everyS: 1)))
        XCTAssertGreaterThan(q.gravityCoverage, 0.99)
        XCTAssertFalse(q.gravityIsSparse)
        XCTAssertNil(q.caption, "a dense night is not captioned about its own recording")
    }

    /// And a night below the stager's own gate does say so, with both measured numbers in it.
    func testASparseNightIsCaptioned() throws {
        // HR every 150 s = 0.4×/min; gravity spanning 34 % of the eight-hour window.
        let q = try XCTUnwrap(CaptureQuality.measure(hr: hr(everyS: 150, spanS: nightS),
                                                     gravity: gravity(spanS: Int(Double(nightS) * 0.34))))
        XCTAssertTrue(q.gravityIsSparse)
        XCTAssertEqual(q.gravityCoverage, 0.34, accuracy: 0.005)
        XCTAssertEqual(q.hrPerMinute, 0.4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(q.caption),
                       "HR sampled 0.4\u{00D7}/min and the wrist-motion stream spanned 34% of the night.")
    }

    /// The gate is the PACKAGE constant, and it is strictly-below — the same direction
    /// `SleepDetection.isGravitySparse` uses (`gravSpan < frac * hrSpan`). Exactly at the fraction, staging
    /// took the dense path and the caption stays silent.
    func testTheGateIsTheStagersOwnConstantAndItsDirection() {
        let atGate = CaptureQuality(hrPerMinute: 1.0, gravityCoverage: SleepDetection.sparseGravitySpanFrac)
        XCTAssertFalse(atGate.gravityIsSparse)
        XCTAssertNil(atGate.caption)

        let below = CaptureQuality(hrPerMinute: 1.0,
                                   gravityCoverage: SleepDetection.sparseGravitySpanFrac - 0.01)
        XCTAssertTrue(below.gravityIsSparse)
        XCTAssertNotNil(below.caption)
    }

    // MARK: - Only measured numbers

    /// A night with no gravity at all is the night this caption exists for. The HR window is the
    /// reference, so nothing is guessed: the wrist-motion stream genuinely spanned none of it.
    func testAnAbsentGravityStreamIsAMeasuredZeroNotAnUnknown() throws {
        let q = try XCTUnwrap(CaptureQuality.measure(hr: hr(everyS: 150, spanS: nightS), gravity: []))
        XCTAssertEqual(q.gravityCoverage, 0)
        XCTAssertEqual(try XCTUnwrap(q.caption),
                       "HR sampled 0.4\u{00D7}/min and the wrist-motion stream spanned 0% of the night.")
    }

    /// The measure is first-sample-to-last and is BLIND to every gap between: two dense hours, one stray
    /// sample at 3.5 h, then nothing, SPANS 44 % of the night while carrying motion across roughly 25 %
    /// of it. The number itself stays as it is — `gravityIsSparse` must keep mirroring
    /// `SleepDetection.isGravitySparse`, so re-deriving it from gap-summed coverage would decouple the
    /// caption from the staging path it exists to explain. The wording is what has to be honest: this
    /// pins "spanned" and forbids "covered", which would claim a density nothing here measures.
    func testTheCaptionSaysSpannedBecauseTheMeasureIsBlindToGaps() throws {
        let clumped = gravity(spanS: 2 * 3_600)
            + [GravitySample(ts: start + 12_600, x: 0, y: 0, z: 1.0)]   // one stray sample at 3.5 h
        let q = try XCTUnwrap(CaptureQuality.measure(hr: hr(everyS: 150, spanS: nightS), gravity: clumped))

        XCTAssertEqual(q.gravityCoverage, 0.4375, accuracy: 0.005)
        XCTAssertTrue(q.gravityIsSparse)
        let caption = try XCTUnwrap(q.caption)
        XCTAssertTrue(caption.contains("spanned 44%"), caption)
        XCTAssertFalse(caption.contains("covered"), "\"covered\" claims a density this never measures")
    }

    /// A night sampled twice an hour is 0.04×/min, and printing "0.0×/min" would claim the app read no
    /// HR — beside a ledger it built out of HR. Below a tenth, the second decimal is printed.
    func testAVerySparseDensityKeepsItsSecondDecimal() throws {
        let q = try XCTUnwrap(CaptureQuality.measure(hr: hr(everyS: 1_800, spanS: nightS),
                                                     gravity: gravity(spanS: nightS / 4)))
        XCTAssertLessThan(q.hrPerMinute, 0.1)
        let caption = try XCTUnwrap(q.caption)
        XCTAssertTrue(caption.contains("0.04\u{00D7}/min"), caption)
        XCTAssertFalse(caption.contains("0.0\u{00D7}/min"), "a rounded-away density reads as no HR at all")
    }

    // MARK: - Register

    /// 011 decision 5: the line describes the RECORDING, within-user, with no condition name, no
    /// probability and no instruction. Pinned so a later copy edit cannot slide the caption into a
    /// verdict about the sleeper.
    func testTheCaptionStaysInTheDescriptiveRegister() throws {
        let caption = try XCTUnwrap(CaptureQuality(hrPerMinute: 0.4, gravityCoverage: 0.34).caption)
        let banned = ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                      "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"]
        for word in banned {
            XCTAssertFalse(caption.lowercased().contains(word), "\"\(word)\" is banned from this copy")
        }
    }
}
