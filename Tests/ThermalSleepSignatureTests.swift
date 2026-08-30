import XCTest
import StrapProtocol
import StrapAnalytics
@testable import whoopmaxx

/// The thermal sleep signature (011 W2.2) — the onset limb of the night, and the body-clock defect
/// reading it robustly fixes.
///
/// Four things have to hold.
///
/// (a) THE REGRESSION. `BodyClockEngine.nightlyTempMinClockHour` is a single-sample argmin, and every
///     long night in the real backup carries 16–110 isolated dropout samples that clear the 28 °C worn
///     gate by a hair. That argmin latches onto the earliest of them; `CircadianEngine.estimatePhase`
///     then OVERRIDES its cosinor fit with the result and rides it into `recommendBedtime`. The test
///     seeds exactly that fingerprint and pins both halves: the argmin lands on the spike hours away,
///     the binned-median nadir does not move.
/// (b) THE GATE IS THE SNR, NOT THE SHAPE. The two gate fixtures are the SAME night with the SAME
///     plateau — the only difference is how far the trace falls at onset. The shallow one is refused
///     against a MEASURED plateau SD (a night that reports no jitter would be a different, weaker test),
///     the deep one is read.
/// (c) NOTHING IS PRINTED THAT WASN'T MEASURED. Too short, too thin, and no history to rank against each
///     produce a refusal rather than a plausible number.
/// (d) THE REGISTER. 011 decision 5, over the copy the readout actually renders.
///
/// The readable-night assertions are BANDS, not point values, and deliberately so: the fixture's designed
/// drop (4.0 °C over 100 min = 2.4 °C/h) is what they pin, and a median filter reads a ramp with a known
/// lag. Pinning the exact output would be pinning the implementation's arithmetic back at itself.
final class ThermalSleepSignatureTests: XCTestCase {

    /// Mid-July, well away from any DST transition — the clock-hour comparisons below must not straddle one.
    private let start = 1_784_400_000
    private let nightS = 8 * 3_600
    /// Minutes into the session where the fixture's plateau bottoms out.
    private let nadirMin = 320.0

    // MARK: - Fixtures

    /// A synthetic 1 Hz night in the shape every readable night in the corpus has: a linear onset drop of
    /// `dropC` over `settleMin`, a slow decline to the plateau nadir, then a partial rise toward wake.
    ///
    /// `dropC` is the ONLY parameter the two gate fixtures vary. The plateau is defined relative to the
    /// post-drop level, so the jitter the readability gate measures the drop against is identical between
    /// them — which is the whole point of the pair.
    private func night(dropC: Double, onsetC: Double = 35.0, settleMin: Double = 100,
                       nadirDepthC: Double = 1.5, riseC: Double = 1.2) -> [SkinTempSample] {
        let settleS = settleMin * 60
        let nadirS = nadirMin * 60
        let spanS = Double(nightS)
        return (0...nightS).map { t in
            let x = Double(t)
            let c: Double
            if x < settleS {
                c = onsetC - dropC * (x / settleS)
            } else if x < nadirS {
                c = onsetC - dropC - nadirDepthC * (x - settleS) / (nadirS - settleS)
            } else {
                c = onsetC - dropC - nadirDepthC + riseC * (x - nadirS) / (spanS - nadirS)
            }
            return SkinTempSample(ts: start + t, raw: Int((c * 100).rounded()))
        }
    }

    /// Offsets of the seeded dropout samples — one sample each, every twelve minutes, the real backup's
    /// fingerprint. 28.05 °C clears the 28 °C worn gate by a hair, exactly as the measured ones do.
    private var spikeOffsets: [Int] { Array(stride(from: 1_200, through: nightS - 600, by: 720)) }

    private func spiking(_ samples: [SkinTempSample]) -> [SkinTempSample] {
        (samples + spikeOffsets.map { SkinTempSample(ts: start + $0, raw: 2_805) })
            .sorted { $0.ts < $1.ts }
    }

    private func read(_ samples: [SkinTempSample], span: Int? = nil) -> ThermalSleepSignature.Night? {
        ThermalSleepSignature.analyze(samples, family: .whoop5,
                                      start: start, end: start + (span ?? nightS))
    }

    /// Wrap-aware clock-hour difference. Test-local arithmetic — nothing under test computes this.
    private func hourDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        if d > 12 { d -= 24 }
        if d < -12 { d += 24 }
        return d
    }

    // MARK: - A warm-start night reads

    /// The night the readout exists for: a real drop at onset over a settled plateau. Every number is
    /// checked against the FIXTURE's design (4.0 °C over 100 min → 2.4 °C/h), not against a re-run of the
    /// engine's own arithmetic.
    func testAWarmStartNightReadsItsOnsetLimb() throws {
        let n = try XCTUnwrap(read(night(dropC: 4.0)))
        XCTAssertEqual(n.coverage, 1.0, accuracy: 0.01, "a 1 Hz night fills every bin")

        let onset = try XCTUnwrap(n.onset, "a 4 °C drop over a 0.4 °C-SD plateau is readable")
        XCTAssertTrue((75...115).contains(onset.settleMinutes),
                      "designed settle is 100 min, got \(onset.settleMinutes)")
        XCTAssertEqual(onset.amplitudeC, 4.0, accuracy: 0.9,
                       "the drop the fixture built, less the median filter's lag onto the ramp")
        XCTAssertEqual(onset.rateCPerHour, 2.4, accuracy: 0.8,
                       "the fixture falls 4.0 °C in 100 min — 2.4 °C/h")
    }

    // MARK: - The gate is the drop against the plateau's own jitter

    /// The cold-start night: the strap was already cool at onset, so the "drop" is a fifth of the one
    /// above over the SAME plateau. Refused — and refused against a jitter that was actually measured,
    /// which is what makes the refusal a reading rather than a shrug.
    func testAColdStartNightRefusesItsOnsetLimb() throws {
        let n = try XCTUnwrap(read(night(dropC: 0.5)))
        XCTAssertNil(n.onset, "a 0.5 °C drop does not clear 3× the plateau's own SD")
        let sd = try XCTUnwrap(n.plateauSdC, "the gate has to have measured the jitter it refused against")
        XCTAssertGreaterThan(sd, 0.2, "a plateau reporting no jitter would make this test vacuous")
    }

    /// And the pair together: the plateau, the session, the coverage and the shape are identical — only
    /// the depth of the drop changed, and that alone flips the verdict. Without this, the test above
    /// would pass for a `analyze` that simply never emitted an onset.
    func testOnlyTheDepthOfTheDropSeparatesTheTwoVerdicts() throws {
        let shallow = try XCTUnwrap(read(night(dropC: 0.5)))
        let deep = try XCTUnwrap(read(night(dropC: 4.0)))
        XCTAssertEqual(shallow.coverage, deep.coverage, accuracy: 0.001)
        XCTAssertNil(shallow.onset)
        let deepOnset = try XCTUnwrap(deep.onset)

        // Each night's plateau starts at its OWN settle bin, so the two windows differ by a few bins —
        // near enough that the gate's denominator is effectively the same on both sides…
        let shallowSd = try XCTUnwrap(shallow.plateauSdC)
        XCTAssertEqual(shallowSd, try XCTUnwrap(deep.plateauSdC), accuracy: 0.15)
        // …and the deep night clears the gate even measured against the SHALLOW night's jitter, so the
        // flipped verdict is the drop, not a difference in what each night was compared to.
        XCTAssertGreaterThan(deepOnset.amplitudeC, ThermalSleepSignature.snrK * shallowSd)
    }

    // MARK: - The regression: singleton dropout spikes

    /// THE DEFECT. Thirty-eight isolated sub-band samples across the night — the fingerprint measured on
    /// the real backup. The shipped single-sample argmin walks straight into the first one; the binned
    /// median cannot see any of them, because a bin's median is taken over hundreds of samples and then
    /// medianed again across seven bins.
    @MainActor
    func testDropoutSpikesMoveTheArgminByHoursAndTheRobustNadirNotAtAll() throws {
        let clean = night(dropC: 4.0)
        let dirty = spiking(clean)

        // (1) The old statistic, on the same two inputs.
        let cleanArgmin = try XCTUnwrap(BodyClockEngine.nightlyTempMinClockHour(clean, family: .whoop5))
        let dirtyArgmin = try XCTUnwrap(BodyClockEngine.nightlyTempMinClockHour(dirty, family: .whoop5))
        let firstSpike = try XCTUnwrap(spikeOffsets.first)
        XCTAssertEqual(dirtyArgmin, BodyClockEngine.localClockHour(start + firstSpike), accuracy: 1e-9,
                       "the argmin latches onto the earliest dropout sample, not the night's low point")
        XCTAssertGreaterThan(abs(hourDelta(dirtyArgmin, cleanArgmin)), 3.0,
                             "and that is hours of error, which fully overrides the cosinor fit")

        // (2) The statistic that ships.
        let cleanNight = try XCTUnwrap(read(clean))
        let dirtyNight = try XCTUnwrap(read(dirty))
        XCTAssertLessThanOrEqual(abs(dirtyNight.nadirTs - cleanNight.nadirTs),
                                 2 * ThermalSleepSignature.binSeconds,
                                 "thirty-eight singletons must not move a median-of-medians nadir")
        XCTAssertLessThanOrEqual(abs(cleanNight.nadirTs - (start + Int(nadirMin * 60))), 1_800,
                                 "and it sits on the plateau low point the fixture actually built")

        // (3) The onset limb is just as unmoved — the spikes land inside its bins too.
        let cleanOnset = try XCTUnwrap(cleanNight.onset)
        let dirtyOnset = try XCTUnwrap(dirtyNight.onset)
        XCTAssertEqual(dirtyOnset.amplitudeC, cleanOnset.amplitudeC, accuracy: 0.05)
        XCTAssertEqual(dirtyOnset.settleMinutes, cleanOnset.settleMinutes)
    }

    // MARK: - Nothing read is nothing printed

    /// Too short to have a settled plateau, and too thinly covered to describe — both are nil, not a
    /// confident reading of whatever happened to be there.
    func testASessionTooShortOrTooThinIsNotReadAtAll() {
        let full = night(dropC: 4.0)
        XCTAssertNil(read(full, span: 2 * 3_600), "under three hours there is no plateau to fall to")

        let cutoff = start + Int(Double(nightS) * 0.4)
        XCTAssertNil(read(full.filter { $0.ts < cutoff }),
                     "40 % of the session's bins is below the coverage floor")
    }

    // MARK: - The within-user ranking

    /// The ranking is against the user's OWN earlier nights, and it does not exist until there are
    /// enough of them. `Baselines.minNightsSeed` is the floor; the nils in the history are the nights
    /// whose onset didn't read, and they must be counted as absent rather than dropped silently.
    func testTheRankingWaitsForTheUsersOwnNights() {
        let latest = ThermalSleepSignature.Onset(amplitudeC: 3.3, settleMinutes: 95, rateCPerHour: 2.1)

        let thin = ThermalSleepSignature.heatDump(latest: latest, history: [nil, 3.0, nil])
        XCTAssertEqual(thin.settleMinutes, 95, "the duration is measured, so it is printed")
        XCTAssertNil(thin.steepness, "one readable night behind it is not a comparison")
        XCTAssertEqual(thin.comparedNights, 1)

        let fed = ThermalSleepSignature.heatDump(latest: latest, history: [2.0, 2.5, 3.0, 3.5, 4.0, 3.0])
        XCTAssertEqual(fed.comparedNights, 6)
        XCTAssertEqual(fed.steepness, .typical, "3.3 sits inside a 3.0 ± 0.71 spread")
    }

    /// The three verdicts, over one fixed history so only the night being ranked moves.
    func testTheVerdictFollowsTheNightsOwnDeviation() {
        let history: [Double?] = [2.0, 2.5, 3.0, 3.5, 4.0, 3.0]      // mean 3.0, SD ≈ 0.71
        func verdict(_ amplitude: Double) -> ThermalSleepSignature.Steepness? {
            let onset = ThermalSleepSignature.Onset(amplitudeC: amplitude, settleMinutes: 90,
                                                    rateCPerHour: 2.0)
            return ThermalSleepSignature.heatDump(latest: onset, history: history).steepness
        }
        XCTAssertEqual(verdict(5.0), .steeper)
        XCTAssertEqual(verdict(3.0), .typical)
        XCTAssertEqual(verdict(1.0), .shallower)
    }

    /// An unreadable onset prints no duration at all. This is the em-dash case: `.unreadable` is a
    /// distinct answer from "read fine, nothing to compare it to", and collapsing the two would let a
    /// night that never read borrow the other one's copy.
    func testAnUnreadableNightPrintsNoDuration() {
        let d = ThermalSleepSignature.heatDump(latest: nil, history: [3.0, 3.1, 2.9, 3.2, 3.0])
        XCTAssertNil(d.settleMinutes)
        XCTAssertEqual(d.steepness, .unreadable)
        XCTAssertEqual(d.comparedNights, 0, "there is no comparison, so there is no count to claim")
    }

    // MARK: - Register

    /// 011 decision 5, over every string the readout can render: descriptive, within-user, no condition
    /// name, no probability, no instruction. Pinned so a later copy edit cannot slide the heat dump into
    /// a verdict about the sleeper.
    @MainActor
    func testTheCopyStaysInTheDescriptiveRegister() {
        let onset = ThermalSleepSignature.Onset(amplitudeC: 3.9, settleMinutes: 100, rateCPerHour: 2.3)
        let states: [ThermalSleepSignature.HeatDump] = [
            .init(settleMinutes: nil, steepness: .unreadable, comparedNights: 0),
            .init(settleMinutes: 100, steepness: nil, comparedNights: 2),
            ThermalSleepSignature.heatDump(latest: onset, history: [2.0, 2.5, 3.0, 3.5, 4.0, 3.0]),
            ThermalSleepSignature.heatDump(latest: onset, history: [4.5, 5.0, 5.5, 5.0, 4.8, 5.2]),
            ThermalSleepSignature.heatDump(latest: onset, history: [1.0, 1.2, 1.1, 1.3, 1.0, 1.2]),
            ThermalSleepSignature.heatDump(latest: onset, history: [3.8, 3.9, 4.0, 3.9, 3.85, 3.95]),
        ]
        // Every branch of the copy is exercised: all four label cases plus the "read fine, nothing to
        // rank it against" state. A register check that missed a branch would let one slip.
        let expectedLabels: [ThermalSleepSignature.Steepness?] =
            [.unreadable, nil, .steeper, .shallower, .steeper, .typical]
        XCTAssertEqual(states.map(\.steepness), expectedLabels)
        let banned = ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                      "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"]
        var copy = [BodyClockReadoutSection.heatDumpFraming]
        for state in states {
            copy.append(BodyClockReadoutSection.heatDumpSentence(state))
            copy.append(BodyClockReadoutSection.heatDumpWord(state))
        }
        for line in copy {
            for word in banned {
                XCTAssertFalse(line.lowercased().contains(word), "\"\(word)\" is banned from \"\(line)\"")
            }
        }
        // And no absolute temperature ever reaches the page — the 4.0 raw→°C slope is provisional, so a
        // printed °C would be a number the app did not measure.
        for line in copy { XCTAssertFalse(line.contains("°C"), line) }
    }
}
