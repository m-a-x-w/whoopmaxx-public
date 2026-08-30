import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// W1.1 — the Live tab's Signals row: the HRV honesty gate that replaced the hand-rolled RMSSD, and
/// the stress band that must never render as a bare number.
///
/// The pins that matter here are the ones a later "cleanup" would quietly undo: that a noisy window
/// REFUSES where the old formula happily printed a figure, that a passable-but-noisy window reads
/// materially LOWER than that formula on the identical beats, that a genuinely clean window is
/// untouched, and that a degenerate R-R series yields nil rather than Infinity.
final class LiveHrvGateTests: XCTestCase {

    // MARK: - Fixtures

    /// A plausible resting tachogram: ~1000 ms with a gentle ±18 ms alternation, so every successive
    /// difference is exactly 36 ms and the expected RMSSD is exactly 36.
    private func restingBuffer(_ n: Int = 60) -> [Int] {
        (0..<n).map { 1000 + ($0.isMultiple(of: 2) ? 18 : -18) }
    }

    /// The formula `LiveScreen` used to hand-roll: mean of ALL successive squared differences over the
    /// RAW buffer — no range filter, no ectopic rejection, no splice exclusion. Kept here so the
    /// improvement is measured against the thing that shipped, not merely asserted non-nil.
    private func legacyRmssd(_ rr: [Int]) -> Double? {
        let v = rr.map(Double.init)
        guard v.count >= 8 else { return nil }
        var sum = 0.0
        for i in 1..<v.count {
            let d = v[i] - v[i - 1]
            sum += d * d
        }
        return (sum / Double(v.count - 1)).squareRoot()
    }

    /// `restingBuffer` with premature (600 ms) beats planted at `idx` — in range, so the Malik rule is
    /// what rejects them.
    private func withEctopics(at idx: [Int], count: Int = 60) -> [Int] {
        var rr = restingBuffer(count)
        for i in idx { rr[i] = 600 }
        return rr
    }

    // MARK: - The gate

    /// 25 planted ectopics in a 60-beat window: the reading is refused and the cell shows an em-dash —
    /// while the old formula would have printed a confident ~385 ms off the same beats.
    func testEctopicRiddenWindowRefusesWhereTheOldFormulaPrintedANumber() throws {
        let rr = withEctopics(at: (0..<60).filter { [1, 3, 5, 7, 9].contains($0 % 12) })
        XCTAssertEqual(rr.filter { $0 == 600 }.count, 25)

        guard case .insufficient = SpotHrvReading.compute(rr) else {
            return XCTFail("a window this noisy must not produce a reading")
        }
        let out = LiveSignalsReadout.signals(rr)
        XCTAssertEqual(out.hrv.value, LiveSignalsReadout.noValue)
        // The stress cell rides the same gate: one window can never give two verdicts.
        XCTAssertNil(out.stressIndex)

        // The point of the change: the shipped code was NOT silent here — it printed ~385 ms.
        XCTAssertGreaterThan(try XCTUnwrap(legacyRmssd(rr)), 300)
    }

    /// Six ectopics in 60 beats clears the 0.35 rejected-fraction gate, so a value IS reported — and it
    /// lands far below the hand-rolled figure on the identical input. The inflation is pinned, not just
    /// asserted away.
    func testPassableButNoisyWindowReadsFarBelowTheHandRolledFormula() throws {
        let rr = withEctopics(at: [7, 17, 25, 33, 41, 51])
        guard case .reading(let cleaned, _, _, _) = SpotHrvReading.compute(rr) else {
            return XCTFail("six ectopics in sixty beats clears the 0.35 rejected-fraction gate")
        }
        let old = try XCTUnwrap(legacyRmssd(rr))
        XCTAssertGreaterThan(old, cleaned)
        // ~191 ms vs 36 ms: differencing across the six removed beats manufactured 5× the variability.
        XCTAssertLessThan(cleaned / old, 0.5)

        let out = LiveSignalsReadout.signals(rr)
        XCTAssertEqual(out.hrv.value, "36")
        XCTAssertEqual(out.hrv.unit, "ms")
    }

    /// A window with nothing to reject is bit-identical to the old formula. The fix bites on noise
    /// only — it is not a blanket downward shift of everyone's live HRV.
    func testCleanWindowIsUnchangedByTheNewPipeline() throws {
        let rr = restingBuffer()
        guard case .reading(let cleaned, _, _, _) = SpotHrvReading.compute(rr) else {
            return XCTFail("a clean sixty-beat window must produce a reading")
        }
        XCTAssertEqual(cleaned, try XCTUnwrap(legacyRmssd(rr)), accuracy: 1e-9)
        XCTAssertEqual(LiveSignalsReadout.signals(rr).hrv.value, "36")
    }

    /// 22 out-of-range beats in 60 leave 38 clean — comfortably over `HRVAnalyzer.minBeats` — yet the
    /// spot gate still refuses, because 37% of the window was thrown away. The caption must name THAT
    /// reason: "too noisy", not "not enough beats".
    ///
    /// The package reports the TRUE survivor count on this path (38), so the refusal reason and the
    /// count no longer contradict each other. The app re-derives the count anyway, which is why the
    /// caption was already right when the package reported 0 here.
    func testTooNoisyRefusalNamesItsReasonRatherThanZeroCleanBeats() {
        var rr = restingBuffer()
        let spikes = (0..<60).filter { [1, 3, 5, 7].contains($0 % 11) }
        XCTAssertEqual(spikes.count, 22)
        for i in spikes { rr[i] = 2500 }   // above HRVAnalyzer.rrMaxMs

        XCTAssertEqual(HRVAnalyzer.cleanRR(rr.map(Double.init)).count, 38)
        guard case .insufficient(let clean, let needed, _) = SpotHrvReading.compute(rr) else {
            return XCTFail("a 37% rejected window must not produce a reading")
        }
        XCTAssertEqual(clean, 38, "the survivors are real; it is the discarded share that refuses")
        XCTAssertGreaterThan(clean, HRVAnalyzer.minBeats, "so the refusal is not about beat count")
        XCTAssertEqual(needed, HRVAnalyzer.minBeats)

        let out = LiveSignalsReadout.signals(rr)
        XCTAssertEqual(out.hrv.value, LiveSignalsReadout.noValue)
        XCTAssertEqual(out.hrv.unit, "too noisy")
    }

    /// Too few beats is a different fact and reads differently — the true survivor count, not zero.
    func testTooFewBeatsShowsTheSurvivingCount() {
        let out = LiveSignalsReadout.signals(restingBuffer(12))
        XCTAssertEqual(out.hrv.value, LiveSignalsReadout.noValue)
        XCTAssertEqual(out.hrv.unit, "12/\(HRVAnalyzer.minBeats) clean")
    }

    /// Off strap: a bare em-dash. "0/20 clean" would be counting a window that does not exist.
    func testEmptyBufferShowsABareEmDash() {
        let out = LiveSignalsReadout.signals([])
        XCTAssertEqual(out.hrv.value, LiveSignalsReadout.noValue)
        XCTAssertNil(out.hrv.unit)
        XCTAssertNil(out.stressIndex)
    }

    // MARK: - Stress

    /// SI needs a histogram to have a mode: under 20 clean beats there is none.
    func testStressIndexIsNilBelowTwentyCleanBeats() {
        XCTAssertNil(StressIndex.stressIndex(rawRR: restingBuffer(19).map(Double.init)))
        XCTAssertNotNil(StressIndex.stressIndex(rawRR: restingBuffer(30).map(Double.init)))
    }

    /// An all-equal series has zero variation range, so SI would divide by zero. It must be nil — and
    /// the app must show the em-dash rather than an Infinity that formats as a plausible numeral.
    func testStressIndexIsNilOnAnAllEqualSeriesRatherThanInfinite() {
        let flat = [Int](repeating: 1000, count: 30)
        XCTAssertNil(StressIndex.stressIndex(rawRR: flat.map(Double.init)))

        // The HRV cell still reports (30 clean beats, nothing rejected, every difference 0) — so this
        // is genuinely the SI path refusing, not the shared gate refusing for it.
        let out = LiveSignalsReadout.signals(flat)
        XCTAssertEqual(out.hrv.value, "0")
        XCTAssertNil(out.stressIndex)
    }

    /// A varied window yields a finite, positive SI — so the two nils above are a gate, not a
    /// permanently dead code path.
    func testStressIndexIsFiniteOnAVariedWindow() throws {
        let si = try XCTUnwrap(StressIndex.stressIndex(rawRR: restingBuffer(60).map(Double.init)))
        XCTAssertTrue(si.isFinite)
        XCTAssertGreaterThan(si, 0)
    }

    /// The band is a comparison, so it is withheld until there is something to compare against — one
    /// reading short of the minimum still renders an em-dash.
    func testBandIsWithheldUntilTheReferenceIsBigEnough() {
        let short = (0..<(LiveSignalsReadout.stressReferenceMin - 1)).map(Double.init)
        XCTAssertNil(LiveSignalsReadout.stressBand(si: 5, reference: short))
        XCTAssertNil(LiveSignalsReadout.stressBand(si: 5, reference: []))

        let enough = (0..<LiveSignalsReadout.stressReferenceMin).map(Double.init)
        XCTAssertNotNil(LiveSignalsReadout.stressBand(si: 5, reference: enough))
    }

    /// Band edges are the reference's own p20 / p80 — a within-user comparison with a deliberately wide
    /// typical core. Over the reference 0…44 those land on 9 and 35.
    func testBandEdgesAreTheReferencesOwnP20AndP80() {
        let ref = (0..<45).map(Double.init)
        XCTAssertEqual(LiveSignalsReadout.stressBand(si: 8, reference: ref), .low)
        XCTAssertEqual(LiveSignalsReadout.stressBand(si: 9, reference: ref), .typical)
        XCTAssertEqual(LiveSignalsReadout.stressBand(si: 22, reference: ref), .typical)
        XCTAssertEqual(LiveSignalsReadout.stressBand(si: 35, reference: ref), .typical)
        XCTAssertEqual(LiveSignalsReadout.stressBand(si: 36, reference: ref), .high)
    }

    /// The band words are the only thing the Stress cell ever renders — never the dimensionless SI.
    func testBandLabelsAreWordsNotNumbers() {
        XCTAssertEqual(LiveSignalsReadout.StressBand.low.label, "Low")
        XCTAssertEqual(LiveSignalsReadout.StressBand.typical.label, "Typical")
        XCTAssertEqual(LiveSignalsReadout.StressBand.high.label, "High")
    }

    // MARK: - Copy register

    /// Decision 5: the Signals copy stays descriptive and within-user. The caveat is the
    /// frozen package's own string, surfaced verbatim — this pins that it still carries no banned word
    /// and no condition name for either strap family.
    func testCaveatCarriesNoBannedVocabulary() {
        let banned = ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                      "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"]
        let sources: [SpotHrvReading.Source] = [.opticalPPG, .chestStrap, .unknown]
        for source in sources {
            let text = SpotHrvReading.caveatFor(source)
            XCTAssertFalse(text.isEmpty)
            for word in banned {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word),
                               "\(source) caveat must not say \"\(word)\"")
            }
        }
        // The optical-PPG note is the one source-specific addition, and it is about signal noise.
        XCTAssertGreaterThan(SpotHrvReading.caveatFor(.opticalPPG).count,
                             SpotHrvReading.caveatFor(.chestStrap).count)
    }
}
