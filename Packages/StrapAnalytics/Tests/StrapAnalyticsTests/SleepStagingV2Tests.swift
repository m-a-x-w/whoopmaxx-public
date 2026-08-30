import XCTest
import StrapProtocol
@testable import StrapAnalytics

final class SleepStagingV2Tests: XCTestCase {

    // MARK: - Viterbi

    private func em(_ deep: Double, _ rem: Double, _ light: Double, _ awake: Double)
        -> [String: Double] {
        ["deep": deep, "rem": rem, "light": light, "awake": awake]
    }

    func testAConfidentSequenceIsFollowed() {
        let seq = (0..<10).map { _ in em(5, 0, 0, 0) }
        XCTAssertEqual(SleepStagingV2.viterbi(seq), [String](repeating: "deep", count: 10))
    }

    func testALoneDissenterIsOverruledByStickiness() {
        // Taking each epoch's own best label would put one deep epoch in the middle of REM, which
        // the transition matrix says is nearly impossible.
        var seq = (0..<11).map { _ in em(0, 3, 0, 0) }
        seq[5] = em(3.2, 0, 0, 0)
        XCTAssertEqual(SleepStagingV2.viterbi(seq)[5], "rem")
    }

    func testOverwhelmingEvidenceStillWins() {
        var seq = (0..<11).map { _ in em(0, 3, 0, 0) }
        seq[5] = em(0, 0, 0, 40)
        XCTAssertEqual(SleepStagingV2.viterbi(seq)[5], "awake")
    }

    func testWakeIsMostlyReachedFromLight() {
        // The matrix, not one path: waking straight out of deep or REM is rare and light is the
        // corridor. A single neutral epoch between confident deep and confident wake still stays
        // deep — deep's own stickiness outweighs the two-step route, which is the model working
        // as built, not a hole in it.
        let t = SleepStagingV2.transition
        XCTAssertGreaterThan(t["light"]!["awake"]!, t["deep"]!["awake"]!)
        XCTAssertGreaterThan(t["light"]!["awake"]!, t["rem"]!["awake"]!)
        XCTAssertGreaterThan(t["awake"]!["light"]!, t["awake"]!["deep"]! + t["awake"]!["rem"]!)
        let path = SleepStagingV2.viterbi([em(6, 0, 0, 0), em(0, 0, 0, 0), em(0, 0, 0, 6)])
        XCTAssertEqual(path.first, "deep")
        XCTAssertEqual(path.last, "awake")
    }

    func testEmptyAndSingle() {
        XCTAssertTrue(SleepStagingV2.viterbi([]).isEmpty)
        XCTAssertEqual(SleepStagingV2.viterbi([em(0, 0, 1, 0)]), ["light"])
    }

    func testTheTransitionMatrixIsAProperDistribution() {
        for (from, row) in SleepStagingV2.transition {
            XCTAssertEqual(row.values.reduce(0, +), 1.0, accuracy: 1e-9, "row \(from)")
            XCTAssertEqual(Set(row.keys), Set(SleepStagingV2.stageNames))
            XCTAssertTrue(row.values.allSatisfy { $0 > 0 }, "log(0) would break the path")
        }
        XCTAssertEqual(SleepStagingV2.baseLogPrior.values.map(exp).reduce(0, +), 1.0, accuracy: 1e-9)
    }

    // MARK: - Cycle prior

    func testDeepFrontLoadsAndREMBuilds() {
        let early = SleepStagingV2.cyclePrior(0.05)
        let mid = SleepStagingV2.cyclePrior(0.5)
        let late = SleepStagingV2.cyclePrior(0.95)
        XCTAssertGreaterThan(early["deep"]!, late["deep"]!)
        XCTAssertGreaterThan(late["rem"]!, mid["rem"]!)
        XCTAssertLessThan(early["rem"]!, -2, "REM is suppressed right after onset")
        XCTAssertEqual(late["deep"]!, 0, "deep is gone past the middle of the night")
        XCTAssertEqual(mid["light"]!, 0, "light is the reference stage")
    }

    // MARK: - Breathing regularity

    /// Beat intervals modulated by a `bpm`-per-minute breathing rhythm.
    private func rsaBeats(seconds: Int, breathsPerMin: Double, depth: Double = 40,
                          noise: Double = 0) -> [(t: Double, v: Double)] {
        (0..<seconds).map { i in
            let t = Double(i)
            let phase = 2 * Double.pi * breathsPerMin / 60 * t
            let jitter = noise == 0 ? 0 : noise * sin(t * 7.3)
            return (t, 1000 + depth * sin(phase) + jitter)
        }
    }

    func testRegularBreathingIsPeaked() {
        // 15 breaths/min = 0.25 Hz, in the middle of the band.
        let r = try! XCTUnwrap(SleepStagingV2.respRegularity(rsaBeats(seconds: 120,
                                                                     breathsPerMin: 15)))
        XCTAssertGreaterThan(r, 0.8)
        XCTAssertLessThanOrEqual(r, 1.0)
    }

    func testIrregularBreathingIsNot() {
        // A sum of several rates in the band spreads the power across bins.
        let beats = (0..<120).map { i -> (t: Double, v: Double) in
            let t = Double(i)
            let v = 1000 + 20 * sin(2 * .pi * 0.16 * t) + 20 * sin(2 * .pi * 0.28 * t)
                + 20 * sin(2 * .pi * 0.38 * t)
            return (t, v)
        }
        let regular = try! XCTUnwrap(SleepStagingV2.respRegularity(rsaBeats(seconds: 120,
                                                                           breathsPerMin: 15)))
        let messy = try! XCTUnwrap(SleepStagingV2.respRegularity(beats))
        XCTAssertLessThan(messy, regular)
    }

    func testPeakednessIsIndependentOfBreathDepth() {
        let shallow = try! XCTUnwrap(SleepStagingV2.respRegularity(
            rsaBeats(seconds: 120, breathsPerMin: 15, depth: 5)))
        let deep = try! XCTUnwrap(SleepStagingV2.respRegularity(
            rsaBeats(seconds: 120, breathsPerMin: 15, depth: 80)))
        XCTAssertEqual(shallow, deep, accuracy: 1e-6)
    }

    func testAnUnresolvableWindowAbstains() {
        XCTAssertNil(SleepStagingV2.respRegularity([]))
        XCTAssertNil(SleepStagingV2.respRegularity(rsaBeats(seconds: 5, breathsPerMin: 15)))
        // Long enough in count, too short in time to resolve a breath.
        let squashed = (0..<20).map { (t: Double($0) * 0.05, v: 1000.0) }
        XCTAssertNil(SleepStagingV2.respRegularity(squashed))
    }

    func testAFlatBeatSeriesHasNoSpectrum() {
        let flat = (0..<120).map { (t: Double($0), v: 1000.0) }
        XCTAssertNil(SleepStagingV2.respRegularity(flat))
    }

    // MARK: - Features

    private func stream(seconds: Int, from: Int = 0, bpm: Int = 55, jitter: Double = 0)
        -> (g: [GravitySample], h: [HRSample], r: [RRInterval]) {
        var g: [GravitySample] = [], h: [HRSample] = [], r: [RRInterval] = []
        for i in 0..<seconds {
            let ts = from + i
            g.append(GravitySample(ts: ts, x: Double(i % 2) * jitter, y: 0, z: 1))
            h.append(HRSample(ts: ts, bpm: bpm))
            r.append(RRInterval(ts: ts, rrMs: 60_000 / bpm))
        }
        return (g, h, r)
    }

    func testEpochsAreAlignedToTheWallClock() {
        let s = stream(seconds: 600, from: 1_000_007)
        let f = SleepStagingV2.features(start: 1_000_007, end: 1_000_607,
                                        grav: s.g, hr: s.h, rr: s.r)
        XCTAssertFalse(f.isEmpty)
        XCTAssertTrue(f.allSatisfy { $0.start % 30 == 0 })
        for (a, b) in zip(f, f.dropFirst()) { XCTAssertEqual(b.start - a.start, 30) }
    }

    func testAnEpochWithNoEvidenceIsSkippedNotInvented() {
        // A gap has no evidence; an emitted epoch there would just publish the priors.
        var s = stream(seconds: 600)
        s.g.removeAll { (150..<300).contains($0.ts) }
        s.h.removeAll { (150..<300).contains($0.ts) }
        let f = SleepStagingV2.features(start: 0, end: 600, grav: s.g, hr: s.h, rr: s.r)
        XCTAssertFalse(f.contains { (150..<300).contains($0.start) })
        XCTAssertTrue(f.contains { $0.start == 300 })
    }

    func testTheJerkFloorIsTheNightsOwnMedian() {
        // Same movement, two decode scales: moveFrac must not change.
        let quiet = stream(seconds: 600, jitter: 0.001)
        let loud = (0..<600).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.1, y: 0, z: 1) }
        let a = SleepStagingV2.features(start: 0, end: 600, grav: quiet.g, hr: quiet.h, rr: [])
        let b = SleepStagingV2.features(start: 0, end: 600, grav: loud, hr: quiet.h, rr: [])
        XCTAssertEqual(a.map(\.moveFrac), b.map(\.moveFrac))
        XCTAssertNotEqual(a[0].jerkScale, b[0].jerkScale)
    }

    func testMissingHeartRateLeavesTheFeatureNilNotZero() {
        let g = (0..<600).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        let f = SleepStagingV2.features(start: 0, end: 600, grav: g, hr: [], rr: [])
        XCTAssertFalse(f.isEmpty)
        XCTAssertTrue(f.allSatisfy { $0.hr == nil && $0.hrVar == nil && $0.hrFlat11 == nil })
    }

    func testTheClockRunsAcrossTheWindow() {
        let s = stream(seconds: 3600)
        let f = SleepStagingV2.features(start: 0, end: 3600, grav: s.g, hr: s.h, rr: s.r)
        XCTAssertEqual(f.first!.clock, 15.0 / 3600, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(f.last!.clock, 1.0)
        for (a, b) in zip(f, f.dropFirst()) { XCTAssertGreaterThan(b.clock, a.clock) }
    }

    func testEmptyWindow() {
        XCTAssertTrue(SleepStagingV2.features(start: 100, end: 100, grav: [], hr: [], rr: []).isEmpty)
        XCTAssertTrue(SleepStagingV2.features(start: 200, end: 100, grav: [], hr: [], rr: []).isEmpty)
    }

    // MARK: - End to end

    func testAWholeWindowIsTiled() {
        let s = stream(seconds: 4 * 3600, bpm: 52, jitter: 0.0005)
        let segs = SleepStagingV2.stageSession(start: 0, end: 4 * 3600,
                                               grav: s.g, hr: s.h, rr: s.r)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last?.end, 4 * 3600)
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertTrue(segs.allSatisfy { ["wake", "light", "deep", "rem"].contains($0.stage) })
    }

    func testAWindowWithNoEvidenceIsLight() {
        XCTAssertEqual(SleepStagingV2.stageSession(start: 0, end: 3600, grav: [], hr: []),
                       [StageSegment(start: 0, end: 3600, stage: "light")])
    }

    func testABurstInAQuietNightReadsAsWake() {
        // Motion is measured against the night's own floor, so what counts is a burst against
        // stillness, not motion in the abstract.
        var g = (0..<3 * 3600).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        for i in 3600..<4500 { g[i] = GravitySample(ts: i, x: Double(i % 2) * 0.5, y: 0, z: 1) }
        let hr = (0..<3 * 3600).map { i in
            HRSample(ts: i, bpm: (3600..<4500).contains(i) ? 78 : 52)
        }
        let segs = SleepStagingV2.stageSession(start: 0, end: 3 * 3600, grav: g, hr: hr)
        let wakeInBurst = segs
            .filter { $0.stage == "wake" && $0.start < 4500 && $0.end > 3600 }
            .reduce(0) { $0 + $1.durationS }
        XCTAssertGreaterThan(wakeInBurst, 300, "fifteen minutes of thrashing is not sleep")
    }

    func testUniformMotionHasNoQuietReference() {
        // The honest limit of a self-calibrating model: a night that moved the same amount all the
        // way through has no floor for anything to stand out from.
        let uniform = (0..<3600).map { GravitySample(ts: $0, x: Double($0 % 2) * 0.5, y: 0, z: 1) }
        let f = SleepStagingV2.features(start: 0, end: 3600, grav: uniform,
                                        hr: (0..<3600).map { HRSample(ts: $0, bpm: 60) }, rr: [])
        XCTAssertTrue(f.allSatisfy { $0.moveFrac == 0 })
    }

    func testTheStagerReadsOutsideTheWindowItStages() {
        // The 11-minute flatness window reaches past both ends; clipping it changes the result at
        // onset and final waking, which is where it matters most.
        let s = stream(seconds: 5000, bpm: 54, jitter: 0.0005)
        let padded = SleepStagingV2.stageSession(start: 1000, end: 4000,
                                                 grav: s.g, hr: s.h, rr: s.r)
        let clipped = SleepStagingV2.stageSession(
            start: 1000, end: 4000,
            grav: s.g.filter { (1000..<4000).contains($0.ts) },
            hr: s.h.filter { (1000..<4000).contains($0.ts) },
            rr: s.r.filter { (1000..<4000).contains($0.ts) })
        XCTAssertEqual(padded.first?.start, 1000)
        XCTAssertEqual(clipped.first?.start, 1000)
        XCTAssertEqual(padded.last?.end, 4000)
    }
}
