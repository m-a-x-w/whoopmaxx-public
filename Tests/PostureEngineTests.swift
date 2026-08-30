import XCTest
import SwiftUI
import StrapProtocol
@testable import whoopmaxx

/// The wrist-orientation tape (011 W2.3). Five things have to hold or it becomes the thing it exists to
/// avoid.
///
/// (a) It must tell genuinely different orientations apart and NOT split one — the merge radius is what
/// separates "you turned over" from floating-point wobble. (b) A dynamic-acceleration burst points
/// perfectly consistently while being nothing like 1 g, so only the MAGNITUDE gate can catch it; if the
/// spread test alone were relied on, an arm swing would be filed as an orientation. (c) A gap in the
/// gravity stream is a gap — never a guessed band, and never counted against the stillness fraction as
/// if it were movement. (d) The clustering seeds in TIME order off the epoch grid, so the same night
/// must read identically no matter what order the store hands the rows back in. (e) And the whole
/// surface must stay honest about what it knows: a wrist is not a torso, so the orientations carry
/// NUMBERS, never supine / left / right / prone.
final class PostureEngineTests: XCTestCase {

    /// A round unix second, so every epoch boundary in the fixtures is exact.
    private let start = 1_753_400_000

    private typealias Dir = (x: Double, y: Double, z: Double)

    /// A direction `deg` off straight-down, in the x–z plane.
    private func direction(_ deg: Double) -> Dir {
        let r = deg * .pi / 180
        return (x: sin(r), y: 0, z: cos(r))
    }

    private func vec(_ deg: Double) -> PostureEngine.Vec {
        let d = direction(deg)
        return PostureEngine.Vec(x: d.x, y: d.y, z: d.z)
    }

    /// 1 Hz gravity along `dir`, `seconds` long from `from`, at `magnitude` g.
    ///
    /// Each sample carries a deterministic sub-degree wobble, so the epoch's p90 spread is a real
    /// measurement rather than an exact zero — and still far inside `stableSpreadDeg`, so a held stretch
    /// stays held. `everyS` thins the cadence, which is how the "too few samples to average" case is
    /// built.
    private func stream(_ dir: Dir, from: Int, seconds: Int,
                        magnitude: Double = 1.0, everyS: Int = 1) -> [GravitySample] {
        stride(from: 0, to: seconds, by: everyS).map { t in
            let wobble = 0.004 * Double((t % 5) - 2)
            return GravitySample(ts: from + t,
                                 x: (dir.x + wobble) * magnitude,
                                 y: (dir.y - wobble) * magnitude,
                                 z: dir.z * magnitude)
        }
    }

    /// Four alternating 30-minute blocks, 40° apart — two recurring orientations over two hours.
    private var alternatingNight: [GravitySample] {
        (0..<4).flatMap { block in
            stream(direction(block % 2 == 0 ? 0 : 40), from: start + block * 1800, seconds: 1800)
        }
    }

    // MARK: - Telling orientations apart

    /// The merge radius, exercised on the clustering itself rather than through a whole night: 20°
    /// apart is one orientation the wrist drifted inside, 40° apart is two.
    func testDirectionsInsideTheMergeRadiusBecomeOneOrientation() {
        XCTAssertEqual(Set(PostureEngine.cluster([vec(0), vec(20), vec(0), vec(20)]).labels).count, 1,
                       "20° apart is drift inside one orientation, not two of them")
        XCTAssertEqual(Set(PostureEngine.cluster([vec(0), vec(40), vec(0), vec(40)]).labels).count, 2,
                       "40° apart is two orientations and must not be collapsed into one")
    }

    /// And the radius is where it says it is, not merely "somewhere between 20 and 40".
    func testTheMergeRadiusSitsAtItsConstant() {
        XCTAssertEqual(PostureEngine.mergeAngleDeg, 25.0)
        XCTAssertEqual(Set(PostureEngine.cluster([vec(0), vec(24)]).labels).count, 1)
        XCTAssertEqual(Set(PostureEngine.cluster([vec(0), vec(26)]).labels).count, 2)
    }

    /// End to end: two held orientations over a two-hour night come out as two, with the counts and the
    /// change count the blocks actually contain.
    func testTwoHeldOrientationsSurfaceAsTwo() throws {
        let night = try XCTUnwrap(PostureEngine.analyze(gravity: alternatingNight,
                                                        start: start, end: start + 7200))
        XCTAssertEqual(night.epochs.count, 240)
        XCTAssertEqual(night.orientations.count, 2)
        XCTAssertEqual(night.orientations.map(\.epochs), [120, 120])
        XCTAssertEqual(night.summary.switches, 3, "four alternating blocks change orientation three times")
        XCTAssertEqual(night.summary.stableFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(night.summary.dominantFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(night.summary.entropyBits, 1.0, accuracy: 1e-9,
                       "two equally-occupied orientations is exactly one bit")
        XCTAssertEqual(night.orientations.map(\.longestHoldEpochs), [60, 60],
                       "each block is one unbroken half-hour, not the pair of them")
    }

    // MARK: - What is not an orientation

    /// THE TRAP. A dynamic-acceleration burst points as consistently as a held wrist does — its angular
    /// spread is the same sub-degree wobble — so the spread test cannot see it and only the magnitude
    /// gate can. The control run is the proof: the identical samples scaled back to 1 g DO cluster, so
    /// what rejected the burst was its 1.6 g and nothing else.
    func testADynamicBurstIsRejectedByItsMagnitudeNotItsDirection() throws {
        func read(burstG: Double) -> PostureEngine.Night? {
            var s = stream(direction(0), from: start, seconds: 3600)                      // 120 epochs
            s += stream(direction(0), from: start + 3600, seconds: 600, magnitude: burstG) //  20 epochs
            s += stream(direction(40), from: start + 4200, seconds: 3600)                 // 120 epochs
            return PostureEngine.analyze(gravity: s, start: start, end: start + 7800)
        }

        let burst = try XCTUnwrap(read(burstG: 1.6))
        XCTAssertEqual(Array(burst.epochs[120..<140]), Array(repeating: PostureEngine.Epoch.moving, count: 20),
                       "1.6 g is not an orientation, whichever way it points")
        XCTAssertEqual(burst.epochs.compactMap { $0.orientationIndex }.count, 240,
                       "no orientation absorbed the burst")
        XCTAssertEqual(burst.orientations.map(\.epochs), [120, 120])
        XCTAssertEqual(burst.summary.stableFraction, 240.0 / 260.0, accuracy: 1e-9)

        let control = try XCTUnwrap(read(burstG: 1.0))
        XCTAssertEqual(Array(control.epochs[120..<140]), Array(repeating: PostureEngine.Epoch.orientation(0), count: 20),
                       "the same directions at 1 g are a held orientation — the magnitude was the gate")
        XCTAssertEqual(control.orientations.map(\.epochs), [140, 120])
    }

    /// A gap is a gap. An unbanked stretch and a stretch too thin to average both read `.noData`, and
    /// NEITHER is counted against the stillness fraction — an unmeasured minute is not a restless one.
    func testAGravityGapIsNoDataAndNeverAnOrientation() throws {
        var s = stream(direction(0), from: start, seconds: 3600)                       // 120 held
        // 3600…4800 banked nothing at all; 4800…6000 banks 3 samples an epoch, under `minEpochSamples`.
        s += stream(direction(0), from: start + 4800, seconds: 1200, everyS: 10)       //  40 thin
        s += stream(direction(0), from: start + 6000, seconds: 3600)                   // 120 held
        let night = try XCTUnwrap(PostureEngine.analyze(gravity: s, start: start, end: start + 9600))

        XCTAssertEqual(night.epochs.count, 320)
        XCTAssertEqual(Array(night.epochs[120..<160]), Array(repeating: PostureEngine.Epoch.noData, count: 40),
                       "a stretch the strap never banked is a gap, not a band")
        XCTAssertEqual(Array(night.epochs[160..<200]), Array(repeating: PostureEngine.Epoch.noData, count: 40),
                       "three samples in thirty seconds is a sample, not a direction")
        XCTAssertEqual(night.summary.stableFraction, 1.0, accuracy: 1e-9,
                       "unmeasured slots leave the denominator, they do not count as movement")
        XCTAssertEqual(night.orientations.count, 1)
        XCTAssertEqual(night.orientations[0].epochs, 240)
        XCTAssertEqual(night.orientations[0].longestHoldEpochs, 120,
                       "the gap ends the stretch — nothing there says the wrist stayed put")
    }

    /// A direction the night passed through but never returned to is `.other`, not a fifth orientation.
    /// Ten epochs out of 370 is 2.7%, under `minClusterShare`.
    func testADirectionTheNightDidNotReturnToIsNotPromoted() throws {
        var s = stream(direction(0), from: start, seconds: 10_800)                      // 360 epochs
        s += stream(direction(90), from: start + 10_800, seconds: 300)                  //  10 epochs
        let night = try XCTUnwrap(PostureEngine.analyze(gravity: s, start: start, end: start + 11_100))

        XCTAssertEqual(night.orientations.count, 1)
        XCTAssertEqual(Array(night.epochs[360..<370]), Array(repeating: PostureEngine.Epoch.other, count: 10))
        XCTAssertEqual(night.summary.switches, 0, "passing through is not a change of orientation")
        XCTAssertEqual(night.summary.entropyBits, 0.0, accuracy: 1e-12)
        XCTAssertEqual(night.summary.dominantFraction, 1.0, accuracy: 1e-12)
    }

    // MARK: - The refusals

    /// A night that was never held still has no orientations to compare, so there is no reading — not a
    /// reading of zero (011 decision 4).
    func testANightThatNeverHeldStillHasNoReading() {
        let s = stream(direction(0), from: start, seconds: 7200, magnitude: 1.6)
        XCTAssertNil(PostureEngine.analyze(gravity: s, start: start, end: start + 7200))
    }

    /// And the held-time floor is where it says it is: half an hour refuses, an hour reads.
    func testTheHeldTimeFloorIsInclusiveAndWhereItSays() {
        let short = stream(direction(0), from: start, seconds: 1800)     // 60 epochs
        XCTAssertNil(PostureEngine.analyze(gravity: short, start: start, end: start + 1800))
        let atFloor = stream(direction(0), from: start, seconds: 3600)   // 120 epochs = the floor
        XCTAssertNotNil(PostureEngine.analyze(gravity: atFloor, start: start, end: start + 3600),
                        "exactly \(PostureEngine.minStableEpochs) held epochs clears the floor")
    }

    // MARK: - Order independence

    /// Every sample is binned by its OWN timestamp and the clusters are seeded in slot order, so the
    /// store handing the rows back in a different order cannot move a band. A scrambled fixture must
    /// read byte-identically to the sorted one.
    func testTheReadDoesNotDependOnTheInputOrder() throws {
        let samples = alternatingNight
        let ordered = try XCTUnwrap(PostureEngine.analyze(gravity: samples, start: start, end: start + 7200))

        var rng = SeededGenerator(state: 0x5DEE_CE66_D000_0001)
        let scrambled = samples.shuffled(using: &rng)
        XCTAssertNotEqual(scrambled.map(\.ts), samples.map(\.ts),
                          "the fixture has to actually be out of order for this to test anything")

        let shuffled = try XCTUnwrap(PostureEngine.analyze(gravity: scrambled, start: start, end: start + 7200))
        XCTAssertEqual(shuffled.epochs, ordered.epochs)
        XCTAssertEqual(shuffled.orientations.map(\.index), ordered.orientations.map(\.index))
        XCTAssertEqual(shuffled.orientations.map(\.epochs), ordered.orientations.map(\.epochs))
        XCTAssertEqual(shuffled.orientations.map(\.longestHoldEpochs),
                       ordered.orientations.map(\.longestHoldEpochs))
        XCTAssertEqual(shuffled.summary.switches, ordered.summary.switches)
        XCTAssertEqual(shuffled.summary.orientationCount, ordered.summary.orientationCount)
    }

    // MARK: - The cross-tab

    /// Each epoch is attributed by its MIDPOINT, so a slot straddling a stage boundary is counted once,
    /// on the side it spent most of itself in — and an orientation the stager never covered comes back
    /// with `staged == 0` so the surface can refuse instead of printing "0% deep".
    func testTheStageCrossTabAttributesByMidpointAndRefusesWhatItCannotSee() {
        let epochs = Array(repeating: PostureEngine.Epoch.orientation(0), count: 60)
            + Array(repeating: PostureEngine.Epoch.orientation(1), count: 60)
        let night = PostureEngine.Night(
            start: start, end: start + 3600, epochs: epochs,
            orientations: [
                PostureEngine.Orientation(index: 0, epochs: 60, share: 0.5, longestHoldEpochs: 60),
                PostureEngine.Orientation(index: 1, epochs: 60, share: 0.5, longestHoldEpochs: 60),
            ],
            summary: PostureEngine.Summary(switches: 1, stableFraction: 1, dominantFraction: 0.5,
                                           entropyBits: 1, orientationCount: 2))
        // Deep for the first 15 minutes, REM for the next 15, then nothing staged at all.
        let stages: [(start: Int, end: Int, stage: SleepStage)] = [
            (start: start, end: start + 900, stage: .deep),
            (start: start + 900, end: start + 1800, stage: .rem),
        ]

        let mix = PostureEngine.stageMix(night: night, stages: stages)
        XCTAssertEqual(mix.count, 2)
        XCTAssertEqual(mix[0].staged, 60)
        XCTAssertEqual(mix[0].deep, 30, "the epoch straddling 15:00 lands on the side its midpoint is in")
        XCTAssertEqual(mix[0].rem, 30)
        XCTAssertEqual(mix[0].light, 0)
        XCTAssertEqual(mix[0].wake, 0)
        XCTAssertEqual(mix[0].share(mix[0].deep), 0.5, accuracy: 1e-12)

        XCTAssertEqual(mix[1].staged, 0, "an orientation no span covers has no mix to print")
        XCTAssertEqual(mix[1].share(mix[1].deep), 0.0,
                       "and its share is not a reading — the surface gates on `staged`")

        XCTAssertTrue(PostureEngine.stageMix(night: night, stages: []).isEmpty,
                      "a night with no stage timeline gets no cross-tab at all")
    }

    // MARK: - The framing

    /// A wrist is not a torso: gravity leaves yaw unobservable and the forearm rotates freely inside any
    /// torso position, so nothing here can know which way the sleeper faced. The orientations are
    /// NUMBERED — and the surface copy must neither name a body position nor slip into the clinical
    /// register 011 decision 5 bans.
    func testOrientationsAreNumberedAndTheCopyNamesNoBodyPosition() {
        for i in 0..<8 {
            XCTAssertEqual(PostureEngine.label(for: i), "Orientation \(i + 1)")
        }

        let copy = ((0..<8).map { PostureEngine.label(for: $0) }.joined(separator: " ")
            + " " + PostureSection.honestyLine).lowercased()

        for position in ["supine", "prone", "left side", "right side", "stomach", "on your back",
                         "side sleep", "back sleep"] {
            XCTAssertFalse(copy.contains(position),
                           "the tape must not claim a body position it cannot observe: \(position)")
        }
        for word in ["thermoregulation", "vasodilation", "impaired", "poor", "abnormal", "apnea",
                     "insomnia", "hypoxemia", "arrhythmia", "consider", "you should", "talk to"] {
            XCTAssertFalse(copy.contains(word), "011 decision 5 bans \"\(word)\" from this copy")
        }
    }

    // MARK: - The longest hold counts epochs that were HELD

    /// A brief shift that lands where it started bridges a stretch — but the moving epochs it bridges
    /// are not part of the hold. Folding them in let "longest stretch" exceed the orientation's own
    /// dwell time on the same row, so the row contradicted itself.
    func testABridgedStretchDoesNotCountTheMovementItBridged() {
        let e: [PostureEngine.Epoch] = Array(repeating: .orientation(0), count: 10)
            + Array(repeating: .moving, count: 2)
            + Array(repeating: .orientation(0), count: 10)
        XCTAssertEqual(PostureEngine.longestHolds(e, orientations: 1), [20],
                       "20 epochs were held; the 2 bridged ones were measured as movement")
    }

    /// The bridge is for a shift, not for a wander: past `maxBridgeEpochs` the wrist moved long enough
    /// that calling the whole span one hold would claim minutes nothing measured as still.
    func testAMovementRunLongerThanTheBridgeEndsTheHold() {
        let over = PostureEngine.maxBridgeEpochs + 1
        let e: [PostureEngine.Epoch] = Array(repeating: .orientation(0), count: 10)
            + Array(repeating: .moving, count: over)
            + Array(repeating: .orientation(0), count: 4)
        XCTAssertEqual(PostureEngine.longestHolds(e, orientations: 1), [10],
                       "the run restarts after a bridge too long to be a shift")
    }

    /// The invariant the row depends on: a hold can never be longer than the time spent in that
    /// orientation. Checked over the mixed sequence a real night produces.
    func testALongestHoldNeverExceedsItsOwnDwell() {
        let e: [PostureEngine.Epoch] = [
            .orientation(0), .moving, .orientation(0), .noData, .orientation(1), .moving, .moving,
            .orientation(1), .other, .orientation(0), .moving, .orientation(0), .orientation(0),
        ]
        let holds = PostureEngine.longestHolds(e, orientations: 2)
        for rank in 0..<2 {
            let dwell = e.filter { if case .orientation(let i) = $0 { return i == rank }; return false }.count
            XCTAssertLessThanOrEqual(holds[rank], dwell,
                                     "orientation \(rank) claims a hold longer than it was ever held")
        }
    }
}

/// A deterministic RNG, so the order-independence fixture is scrambled the SAME way on every run — a
/// system-random shuffle would make any failure unreproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
