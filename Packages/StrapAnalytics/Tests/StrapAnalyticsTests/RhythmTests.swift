import XCTest
@testable import StrapAnalytics

final class RhythmScreenerTests: XCTestCase {

    /// A metronomic rhythm with mild sinus variation.
    private func steadyBeats(_ n: Int = 200) -> [Double] {
        (0..<n).map { i -> Double in
            let wobble: Double = 12.0 * sin(Double(i) * Double.pi / 12.0)
            return 1000.0 + wobble
        }
    }

    /// Beat-to-beat chaos: large alternating swings.
    private func chaoticBeats(_ n: Int = 200) -> [Double] {
        (0..<n).map { i -> Double in
            let swing: Double = (i % 2 == 0) ? 220.0 : -200.0
            let jitter: Double = Double((i * 37) % 30)
            return 1000.0 + swing + jitter
        }
    }

    /// A smooth rhythm with occasional early beats.
    private func ectopicBeats(_ n: Int = 200) -> [Double] {
        (0..<n).map { i -> Double in
            if i % 15 == 0 { return 620.0 }
            let wobble: Double = 8.0 * sin(Double(i) * Double.pi / 12.0)
            return 1000.0 + wobble
        }
    }

    private func input(_ rr: [Double], still: Bool = true, hr: Double = 60,
                       ppg: [Double]? = nil) -> RhythmScreener.WindowInput {
        .init(rrMs: rr, ppgIBIms: ppg, motionStill: still, meanHR: hr)
    }

    func testMovementIsNeverRead() {
        // Movement masquerades as irregularity and is the biggest source of false signal — a
        // screener that read a moving wrist would fire on anyone who fidgets.
        let r = RhythmScreener.screenWindow(input(chaoticBeats(), still: false))
        XCTAssertEqual(r.label, .unreadable)
        XCTAssertEqual(r.nBeats, 0)
    }

    func testASteadyRhythmReadsSteady() {
        XCTAssertEqual(RhythmScreener.screenWindow(input(steadyBeats())).label, .steady)
    }

    func testAChaoticRhythmReadsVaried() {
        XCTAssertEqual(RhythmScreener.screenWindow(input(chaoticBeats())).label, .varied)
    }

    func testOccasionalExtraBeatsAreNotCalledVaried() {
        // Sparse couplets on an otherwise smooth rhythm are a different thing from disorganised
        // timing, and the turning-point condition is what separates them.
        let r = RhythmScreener.screenWindow(input(ectopicBeats()))
        XCTAssertEqual(r.label, .occasionalEctopy)
    }

    func testTooFewBeatsIsUnreadable() {
        let r = RhythmScreener.screenWindow(input(Array(steadyBeats().prefix(30))))
        XCTAssertEqual(r.label, .unreadable)
        XCTAssertEqual(r.confidence, .calibrating)
    }

    func testAnImplausibleRestingRateIsUnreadable() {
        XCTAssertEqual(RhythmScreener.screenWindow(input(steadyBeats(), hr: 150)).label, .unreadable)
        XCTAssertEqual(RhythmScreener.screenWindow(input(steadyBeats(), hr: 25)).label, .unreadable)
    }

    func testConfidenceLadder() {
        XCTAssertEqual(RhythmScreener.confidence(for: 10), .calibrating)
        XCTAssertEqual(RhythmScreener.confidence(for: 100), .building)
        XCTAssertEqual(RhythmScreener.confidence(for: 250), .solid)
    }

    func testTurningPointRateIsRelativeToNoise() {
        // A random series turns on two thirds of its interior points; that reference is what makes
        // the threshold mean something rather than being an arbitrary count.
        let alternating: [Double] = (0..<100).map { i -> Double in Double(i % 2) * 100.0 + 900.0 }
        XCTAssertEqual(RhythmScreener.turningPointRate(alternating)!, 1.5, accuracy: 0.05,
                       "every interior point turns: 1.0 / (2/3)")
        let monotone: [Double] = (0..<100).map { i -> Double in 900.0 + Double(i) }
        XCTAssertEqual(RhythmScreener.turningPointRate(monotone)!, 0, accuracy: 1e-9)
        XCTAssertNil(RhythmScreener.turningPointRate([1, 2]))
    }

    func testNormalisedRmssdDoesNotSimplyTrackHeartRate() {
        // A fast rhythm has smaller intervals and would look less variable by construction.
        let slow: [Double] = (0..<200).map { i -> Double in 1000.0 + 50.0 * sin(Double(i)) }
        let fast = slow.map { $0 / 2 }
        let s = RhythmScreener.computeStats(slow).normRmssd!
        let f = RhythmScreener.computeStats(fast).normRmssd!
        XCTAssertEqual(s, f, accuracy: 1e-9, "halving every interval leaves the ratio unchanged")
    }

    func testEctopicFractionCountsWhatTheFilterWouldRemove() {
        XCTAssertEqual(RhythmScreener.ectopicFraction([]), 0)
        XCTAssertEqual(RhythmScreener.ectopicFraction([Double](repeating: 1000, count: 50)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(RhythmScreener.ectopicFraction(ectopicBeats()), 0)
    }

    func testPoincareCloudPairsConsecutiveIntervals() {
        let pts = RhythmScreener.poincareCloud([100, 200, 300])
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[0], .init(x: 100, y: 200))
        XCTAssertEqual(pts[1], .init(x: 200, y: 300))
        XCTAssertTrue(RhythmScreener.poincareCloud([100]).isEmpty)
    }

    func testAnAgreeingSecondSensorIsReportedNotRequired() {
        // Most windows have no optical channel; demanding one would silence the screener.
        let alone = RhythmScreener.screenWindow(input(steadyBeats()))
        XCTAssertFalse(alone.agreedAcrossSources)
        let together = RhythmScreener.screenWindow(input(steadyBeats(), ppg: steadyBeats()))
        XCTAssertTrue(together.agreedAcrossSources)
    }

    func testDisagreeingSensorsAreNotReportedAsAgreement() {
        let r = RhythmScreener.screenWindow(input(steadyBeats(), ppg: chaoticBeats()))
        XCTAssertFalse(r.agreedAcrossSources)
    }

    func testVariedRequiresAllThreeConditions() {
        // Any one alone is reached often by ordinary noise; the conservative AND is the main lever
        // against over-reading it.
        let roundOnly = RhythmScreener.Stats(sd1: 50, sd2: 60, sd1sd2: 0.83, normRmssd: 0.01,
                                             turningPointRate: 0.2, ectopicFraction: 0)
        XCTAssertEqual(RhythmScreener.classify(roundOnly), .steady)
        let all = RhythmScreener.Stats(sd1: 50, sd2: 60, sd1sd2: 0.83, normRmssd: 0.3,
                                       turningPointRate: 1.2, ectopicFraction: 0)
        XCTAssertEqual(RhythmScreener.classify(all), .varied)
    }

    func testMissingStatisticsAreUnreadable() {
        let none = RhythmScreener.Stats(sd1: nil, sd2: nil, sd1sd2: nil, normRmssd: nil,
                                        turningPointRate: nil, ectopicFraction: nil)
        XCTAssertEqual(RhythmScreener.classify(none), .unreadable)
    }
}

final class NightRhythmTests: XCTestCase {

    private func window(_ label: RhythmRegularity) -> RhythmScreener.WindowResult {
        .init(label: label, nBeats: 200, confidence: .solid)
    }

    func testOneOddWindowDoesNotMakeTheNightVaried() {
        // One odd window is what a single roll-over or a loose strap looks like.
        let s = RhythmScreener.summarizeNight([window(.steady), window(.steady), window(.varied)])
        XCTAssertEqual(s.overall, .occasionalEctopy)
        XCTAssertFalse(s.variationRecurred)
    }

    func testRecurringVariationCarriesTheNight() {
        let s = RhythmScreener.summarizeNight(Array(repeating: window(.varied), count: 3)
                                              + [window(.steady)])
        XCTAssertEqual(s.overall, .varied)
        XCTAssertTrue(s.variationRecurred)
        XCTAssertEqual(s.variedWindows, 3)
    }

    func testAnAllSteadyNight() {
        let s = RhythmScreener.summarizeNight(Array(repeating: window(.steady), count: 10))
        XCTAssertEqual(s.overall, .steady)
        XCTAssertEqual(s.readableWindows, 10)
    }

    func testUnreadableWindowsDoNotCount() {
        let s = RhythmScreener.summarizeNight([window(.unreadable), window(.unreadable)])
        XCTAssertEqual(s.overall, .unreadable)
        XCTAssertEqual(s.readableWindows, 0)
    }

    func testNoWindowsAtAll() {
        XCTAssertEqual(RhythmScreener.summarizeNight([]).overall, .unreadable)
    }
}
