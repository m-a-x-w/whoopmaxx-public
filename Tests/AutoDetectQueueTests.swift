import XCTest
import StrapAnalytics
@testable import whoopmaxx

/// Pure-core tests of `WorkoutRepository.autoDetectQueue` — the shared candidate pipeline behind BOTH the
/// Today suggestion row (`autoDetectCandidates` / `autoDetectCandidate`) and the Signal Lab
/// Detection panel's ranking labels. Contract under test:
///
///  * the queue holds EVERY surviving candidate, sorted newest-first (head = what the row shows);
///  * a dismissed span removes its candidate and PROMOTES the next-newest to the head;
///  * a saved span overlapping the head suppresses it the same way;
///  * exclusion filters run on the TRIMMED span (production order trim → filter): a dismissal that
///    only touches trimmed-off cooldown drift does NOT hide the workout, while one overlapping the
///    surviving work band does;
///  * the reserve-anchored elevated floor + intensity dose filter keep an ordinary elevated waking
///    day out of the queue entirely, without losing a real bout.
///
/// The FIRST four pass `hrmaxBpm: nil` deliberately. That is the documented "no profile HRmax, so
/// no reserve to anchor against" path, which leaves the floor and the dose filter exactly where
/// they were — so those tests keep pinning span/merge/dismissal ORDER semantics, which are
/// orthogonal to the gates, instead of silently re-testing the gates. The gate behaviour has its
/// own fixtures at the bottom.
final class AutoDetectQueueTests: XCTestCase {

    // MARK: - Fixtures

    /// 5-s-cadence HR at `bpm` for `minutes`, starting at `start` — the same (ts, bpm) shape as
    /// `WorkoutRepository.autoDetectHR`'s bucket means.
    private func bout(start: Int, minutes: Int, bpm: Int) -> [(ts: Int, bpm: Int)] {
        stride(from: start, to: start + minutes * 60, by: 5).map { (ts: $0, bpm: bpm) }
    }

    /// Two disjoint qualifying base bouts (20 min at 150 bpm, resting 60 → floor 90), six hours
    /// apart. Neither trims (all samples sit above the work mark), so queue spans equal detector
    /// spans exactly.
    private let olderStart = 1_700_000_000
    private var newerStart: Int { olderStart + 6 * 3600 }
    private let resting = 60

    private func twoBoutHR() -> [(ts: Int, bpm: Int)] {
        // Explicit sub-floor REST between and around the bouts: the base detector only closes a
        // span on a > 90 s run of sub-floor SAMPLES — a silent gap would fuse the bouts into one.
        bout(start: olderStart - 10 * 60, minutes: 10, bpm: 60)
            + bout(start: olderStart, minutes: 20, bpm: 150)
            + bout(start: olderStart + 20 * 60, minutes: 340, bpm: 60)
            + bout(start: newerStart, minutes: 20, bpm: 150)
            + bout(start: newerStart + 20 * 60, minutes: 10, bpm: 60)
    }

    // MARK: - Queue order

    func testTwoDisjointBoutsQueueNewestFirst() {
        let queue = WorkoutRepository.autoDetectQueue(hr: twoBoutHR(), restingBpm: resting,
                                               savedSpans: [], dismissedSpans: [], hrmaxBpm: nil)
        XCTAssertEqual(queue.count, 2, "both qualifying bouts must survive into the queue")
        XCTAssertEqual(queue[0].startSec, newerStart, "head must be the NEWEST bout")
        XCTAssertEqual(queue[1].startSec, olderStart, "the older bout queues behind it")
    }

    // MARK: - Dismissal advances the head

    func testDismissingNewerPromotesOlderToHead() throws {
        let hr = twoBoutHR()
        let full = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: resting,
                                              savedSpans: [], dismissedSpans: [], hrmaxBpm: nil)
        let newer = try XCTUnwrap(full.first)
        let after = WorkoutRepository.autoDetectQueue(
            hr: hr, restingBpm: resting, savedSpans: [],
            dismissedSpans: [(start: newer.startSec, end: newer.endSec)], hrmaxBpm: nil)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.startSec, olderStart,
                       "dismissing the newer bout must promote the older one to the head")
    }

    // MARK: - Saved span suppresses the head

    func testSavedSpanOverlappingHeadSuppressesIt() {
        let hr = twoBoutHR()
        // A saved workout overlapping only the tail of the NEWER bout (touching counts).
        let saved = [(start: newerStart + 15 * 60, end: newerStart + 40 * 60)]
        let queue = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: resting,
                                               savedSpans: saved, dismissedSpans: [], hrmaxBpm: nil)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.startSec, olderStart,
                       "a saved span overlapping the head must suppress it, promoting the older bout")
    }

    // MARK: - Trimmed-span-vs-raw-span dismissal edge

    /// Low resting HR (40 → floor 70): 15 min of work at 150, then 40 min of cooldown/EPOC drift at
    /// 80 bpm — above the floor (so the RAW detector span runs to the end of the drift) but far
    /// below the work mark (40 + 0.6 × 110 = 106), so the trimmer cuts the span back to the work
    /// band + 300 s grace.
    private let epocStart = 1_700_100_000
    private let epocResting = 40
    private var trimmedEnd: Int { epocStart + 895 + WorkoutTailTrimmer.cooldownGraceS }   // last work sample + grace

    private func epocHR() -> [(ts: Int, bpm: Int)] {
        bout(start: epocStart, minutes: 15, bpm: 150)
            + bout(start: epocStart + 15 * 60, minutes: 40, bpm: 80)
    }

    func testDismissalOverRawOnlyDriftTailKeepsCandidateQueued() {
        // Sanity: the candidate really is trimmed (raw would run ~55 min).
        let clean = WorkoutRepository.autoDetectQueue(hr: epocHR(), restingBpm: epocResting,
                                               savedSpans: [], dismissedSpans: [], hrmaxBpm: nil)
        XCTAssertEqual(clean.count, 1)
        XCTAssertEqual(clean.first?.endSec, trimmedEnd, "the EPOC drift tail must be trimmed off")

        // Dismissed window entirely inside the trimmed-off drift: overlaps the RAW span, not the
        // TRIMMED one. Production filters the survivor (trim → filter) → stays in the queue.
        let dismissed = [(start: epocStart + 2000, end: epocStart + 2600)]
        let queue = WorkoutRepository.autoDetectQueue(hr: epocHR(), restingBpm: epocResting,
                                               savedSpans: [], dismissedSpans: dismissed, hrmaxBpm: nil)
        XCTAssertEqual(queue.count, 1,
                       "a dismissal touching only the trimmed-off drift must NOT hide the workout")
        XCTAssertEqual(queue.first?.endSec, trimmedEnd)
    }

    func testDismissalOverTrimmedWorkBandSuppressesCandidate() {
        // The reverse: the dismissed window overlaps the surviving work band → filtered out.
        let dismissed = [(start: epocStart + 300, end: epocStart + 600)]
        let queue = WorkoutRepository.autoDetectQueue(hr: epocHR(), restingBpm: epocResting,
                                               savedSpans: [], dismissedSpans: dismissed, hrmaxBpm: nil)
        XCTAssertTrue(queue.isEmpty,
                      "a dismissal overlapping the trimmed (surviving) span must suppress the candidate")
    }

    // MARK: - Reserve-anchored floor + intensity dose
    //
    // The real user's numbers: resting 46, Tanaka HRmax 194 → reserve 148. The SHIPPED absolute
    // floor is 46 + 30 = 76 bpm = 20.2 %HRR, a level he holds 43.3 % of every recorded second
    // (601 min/day), which produced 91 candidates totalling 153.2 h over 17 days (max 767.7 min)
    // and a rolling 7-day queue of 35–45 entries. Anchored: 46 + 50 % × 148 = 120 bpm; dose cut
    // 46 + 70 % × 148 = 149.6 bpm.

    private let realResting = 46
    private let realHRmax = 194
    private let dayStart = 1_700_200_000

    /// Ordinary elevated waking HR: 95 bpm — comfortably above the SHIPPED floor (76) and
    /// comfortably below the anchored one (120) — held for three unbroken hours.
    private func ordinaryWakingHR() -> [(ts: Int, bpm: Int)] {
        bout(start: dayStart, minutes: 180, bpm: 95)
    }

    func testOrdinaryElevatedWakingDayYieldsNoSuggestions() {
        let hr = ordinaryWakingHR()
        // Without the anchoring this day IS a suggestion — a three-hour "workout" at 95 bpm.
        let shipped = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: realResting,
                                                       savedSpans: [], dismissedSpans: [],
                                                       hrmaxBpm: nil)
        XCTAssertEqual(shipped.count, 1,
                       "fixture no longer reproduces the defect — it must be offered without anchoring")
        XCTAssertGreaterThan(shipped[0].durationMin, 120)

        let anchored = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: realResting,
                                                        savedSpans: [], dismissedSpans: [],
                                                        hrmaxBpm: realHRmax)
        XCTAssertTrue(anchored.isEmpty,
                      "ordinary elevated waking HR must not be suggested, got \(anchored.count)")
    }

    func testRealBoutStillSurfacesUnderReserveAnchoredFloor() {
        // 30 min ordinary → 40 min at 165 (80 %HRR, above the 149.6 dose cut) → 30 min ordinary.
        let boutStart = dayStart + 30 * 60
        let hr = bout(start: dayStart, minutes: 30, bpm: 95)
            + bout(start: boutStart, minutes: 40, bpm: 165)
            + bout(start: boutStart + 40 * 60, minutes: 30, bpm: 95)
        let queue = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: realResting,
                                                     savedSpans: [], dismissedSpans: [],
                                                     hrmaxBpm: realHRmax)
        XCTAssertEqual(queue.count, 1, "a real bout must still surface, got \(queue.count)")
        XCTAssertEqual(queue.first?.startSec, boutStart)
        // And the surrounding ordinary hours are NOT welded onto it (the 767-minute failure mode).
        XCTAssertLessThanOrEqual(queue.first?.durationMin ?? 0, 45)
    }

    func testSustainedButLowDoseCandidateIsFilteredOut() {
        // An hour at 130 bpm: above the anchored floor (120) yet under the 70 %HRR dose cut
        // (149.6) throughout — brisk, sustained, not a workout. The floor alone still admits it
        // (this is why BOTH halves of the fix are needed: floor-only left 31 candidates with a
        // 224-minute maximum on the real data).
        let hr = bout(start: dayStart, minutes: 60, bpm: 130)
        let floorOnly = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: realResting,
                                                         savedSpans: [], dismissedSpans: [],
                                                         hrmaxBpm: nil)
        XCTAssertEqual(floorOnly.count, 1, "fixture must be admitted by the un-anchored pipeline")

        let queue = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: realResting,
                                                     savedSpans: [], dismissedSpans: [],
                                                     hrmaxBpm: realHRmax)
        XCTAssertTrue(queue.isEmpty,
                      "a sustained sub-zone-3 span must be filtered by the dose gate, got \(queue.count)")
    }

    func testAnchoringNeverLowersTheElevatedFloor() {
        // A degenerate profile whose 50 %HRR sits BELOW the frozen +30 margin: the shift clamps at
        // 0, so the anchoring can only ever RAISE the floor, never loosen the detector.
        let hr = bout(start: dayStart, minutes: 30, bpm: 95)
        let loose = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: 60, savedSpans: [],
                                                     dismissedSpans: [], hrmaxBpm: 100)
        let plain = WorkoutRepository.autoDetectQueue(hr: hr, restingBpm: 60, savedSpans: [],
                                                     dismissedSpans: [], hrmaxBpm: nil)
        XCTAssertEqual(loose.map(\.startSec), plain.map(\.startSec),
                       "a sub-margin reserve must leave the shipped floor untouched")
    }

    // MARK: - Dose measurement

    func testZone3PlusMinutesCountsBucketSecondsNotSamples() {
        // The series is 5-s buckets, not 1 Hz: 10 minutes above the cut is 120 samples, and the
        // measurement must report 10 minutes — not 2 (samples/60) and not something a gap inflates.
        let start = dayStart
        let series = bout(start: start, minutes: 10, bpm: 165)
            + bout(start: start + 20 * 60, minutes: 10, bpm: 165)   // 10-min hole in between
        let cand = DetectedWorkout(startSec: start, endSec: start + 30 * 60,
                                   avgBpm: 165, peakBpm: 165, durationMin: 30)
        let mins = WorkoutRepository.zone3PlusMinutes(cand, hr: series,
                                                      restingBpm: Double(realResting),
                                                      hrReserve: Double(realHRmax - realResting))
        XCTAssertEqual(mins, 20.0, accuracy: 0.1,
                       "20 min of above-cut buckets must measure 20 min, gap notwithstanding")
    }
}
