import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// NapCredit (007 F3): main-night vs nap classification over a day's sleep sessions, the additive
/// credit cap, and the day-key edges (sessions key to the LOCAL calendar day their `endTs` lands
/// on — same keyer as dailyMetric — so post-midnight bouts and morning re-dozes land on the right
/// day). All fixtures run at offsetSec 0 (UTC) so the arithmetic is deterministic.
final class NapCreditTests: XCTestCase {

    private let day = "2026-03-10"

    /// Unix seconds of UTC midnight for a "yyyy-MM-dd" key.
    private func midnight(_ day: String) -> Int {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return Int(fmt.date(from: day)!.timeIntervalSince1970)
    }

    private func session(start: Int, end: Int) -> CachedSleepSession {
        Fixtures.sleepSession(startTs: start, endTs: end, efficiency: 0.9)
    }

    // MARK: - Classification

    func testAfternoonNapIsClassifiedAgainstMainNight() {
        let mid = midnight(day)
        let night = session(start: mid - 5_400, end: mid + 7 * 3_600)         // 22:30 → 07:00
        let nap = session(start: mid + 13 * 3_600 + 1_800,                    // 13:30 → 13:55
                          end: mid + 13 * 3_600 + 1_800 + 25 * 60)
        let naps = NapCredit.naps(for: day, sleeps: [nap, night], offsetSec: 0)
        XCTAssertEqual(naps.map { $0.startTs }, [nap.startTs],
                       "the short afternoon session is the nap; the overnight block is the main night")
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [nap, night], offsetSec: 0),
                       25, accuracy: 0.01)
    }

    func testSingleSessionDayHasNoNaps() {
        let mid = midnight(day)
        let night = session(start: mid - 5_400, end: mid + 7 * 3_600)
        XCTAssertTrue(NapCredit.naps(for: day, sleeps: [night], offsetSec: 0).isEmpty,
                      "a day's only session IS its main night — never a nap")
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [night], offsetSec: 0), 0)
    }

    func testMorningRedozeWithinBridgeIsPartOfTheMainNight() {
        // Main night ends 06:30, then a 40-min re-doze 07:30–08:10: a 60-min gap with an
        // overnight-band onset is exactly what `analyzeDay`'s selector BRIDGES into one main
        // night whose stages are SUMMED into `totalSleepMin` (#861 night-tail bridge). NapCredit
        // must agree — handing the fragment back as a nap would count the same 40 minutes twice
        // in the debt ledger and the persisted `nap_min` series.
        let mid = midnight(day)
        let night = session(start: mid - 3_600, end: mid + 6 * 3_600 + 1_800)   // 23:00 → 06:30
        let redoze = session(start: mid + 7 * 3_600 + 1_800, end: mid + 8 * 3_600 + 600)
        XCTAssertTrue(NapCredit.naps(for: day, sleeps: [night, redoze], offsetSec: 0).isEmpty,
                      "a bridged night-tail fragment is main night, never a nap")
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [night, redoze], offsetSec: 0), 0)
    }

    func testLateMorningRedozeBeyondBridgeIsANap() {
        // Main night ends 06:30; a 40-min re-doze at 11:30 — a 5-h gap with a daytime onset —
        // stands as its own block, so it credits as a nap.
        let mid = midnight(day)
        let night = session(start: mid - 3_600, end: mid + 6 * 3_600 + 1_800)   // 23:00 → 06:30
        let redoze = session(start: mid + 11 * 3_600 + 1_800, end: mid + 12 * 3_600 + 600)
        let naps = NapCredit.naps(for: day, sleeps: [night, redoze], offsetSec: 0)
        XCTAssertEqual(naps.map { $0.startTs }, [redoze.startTs])
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [night, redoze], offsetSec: 0),
                       40, accuracy: 0.01)
    }

    func testDaySleeperHabitualMidsleepFlipsNapVsColdStart() {
        // A day-sleeper: the TRUE main sleep is a 4 h daytime block (11:00–15:00), plus a 5 h overnight
        // bout (01:00–06:00). Cold-start (nil) anchors to the overnight band, so it mis-picks the overnight
        // bout as the main night and hands the DAY sleep back as a "nap". The learned habitual midsleep
        // (~13:00) anchors to daytime, correctly picking the day sleep as the main night and the overnight
        // bout as the nap. This is exactly the divergence that made the Rest screen credit `nap_min`
        // (habitual-classified) while its nap ROWS (cold-start) showed a different — or no — session; the
        // fix threads `repo.habitualMidsleepSec` into the row split so the two can't disagree.
        let mid = midnight(day)
        let daySleep = session(start: mid + 11 * 3_600, end: mid + 15 * 3_600)   // 11:00 → 15:00 (main)
        let overnight = session(start: mid + 1 * 3_600, end: mid + 6 * 3_600)    // 01:00 → 06:00 (the nap)

        let cold = NapCredit.naps(for: day, sleeps: [overnight, daySleep], offsetSec: 0)
        XCTAssertEqual(cold.map { $0.startTs }, [daySleep.startTs],
                       "cold-start anchors overnight and mis-picks the day sleep as the nap")

        let habitual = NapCredit.naps(for: day, sleeps: [overnight, daySleep], offsetSec: 0,
                                      habitualMidsleepSec: 13 * 3_600)
        XCTAssertEqual(habitual.map { $0.startTs }, [overnight.startTs],
                       "habitual anchors daytime and correctly picks the overnight bout as the nap")
        XCTAssertNotEqual(cold.map { $0.startTs }, habitual.map { $0.startTs },
                          "threading habitual changes which session is a nap — the fix's mechanism")
    }

    func testBridgedFragmentedNightHasNoNaps() {
        // The canonical fragmented night: 23:00–02:00 + 02:45–06:30 (a 45-min mid-night wake).
        // `analyzeDay` bridges both fragments into ONE main night and `totalSleepMin` already
        // sums them — NapCredit classifying the 3-h fragment as a (120-min-capped) nap would
        // silently understate sleep debt by hours.
        let mid = midnight(day)
        let first = session(start: mid - 3_600, end: mid + 2 * 3_600)            // 23:00 → 02:00
        let second = session(start: mid + 2 * 3_600 + 2_700, end: mid + 6 * 3_600 + 1_800)
        XCTAssertTrue(NapCredit.naps(for: day, sleeps: [first, second], offsetSec: 0).isEmpty,
                      "both fragments belong to the bridged main-night group")
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [first, second], offsetSec: 0), 0)
        XCTAssertNil(NapCredit.creditedMinByDay(sleeps: [first, second], offsetSec: 0)[day])
    }

    // MARK: - Day-key edges

    func testSessionsKeyToTheDayTheyEndOn() {
        let mid = midnight(day)
        // Ends 23:50 the PREVIOUS day — not this day's session at all.
        let previousEvening = session(start: mid - 3_600, end: mid - 600)
        // Ends 00:30 on this day (a post-midnight bout) — competes on THIS day. The gap to the main
        // night (4.5 h) is past ALL THREE bridge tiers — including the split-night tier's
        // `SleepGrouping.splitNightBridgeMaxMin` (4 h) ceiling — so it stays its own block and the
        // day-keying is what this test actually measures.
        let postMidnight = session(start: mid - 1_800, end: mid + 1_800)
        let night = session(start: mid + 5 * 3_600, end: mid + 10 * 3_600)      // 05:00 → 10:00
        let naps = NapCredit.naps(for: day,
                                  sleeps: [previousEvening, postMidnight, night], offsetSec: 0)
        XCTAssertEqual(naps.map { $0.startTs }, [postMidnight.startTs],
                       "the post-midnight bout ends on this day and is the nap; the previous "
                       + "evening's session belongs to yesterday's key")
        XCTAssertTrue(NapCredit.naps(for: "2026-03-09",
                                     sleeps: [previousEvening], offsetSec: 0).isEmpty,
                      "yesterday's single session is yesterday's main night")
    }

    // MARK: - Credit cap

    func testCreditCapsAtTwoHours() {
        let mid = midnight(day)
        let night = session(start: mid - 5_400, end: mid + 7 * 3_600)
        let naps = [
            session(start: mid + 10 * 3_600, end: mid + 11 * 3_600),            // 60 min
            session(start: mid + 13 * 3_600, end: mid + 13 * 3_600 + 50 * 60),  // 50 min
            session(start: mid + 17 * 3_600, end: mid + 17 * 3_600 + 40 * 60),  // 40 min
        ]
        XCTAssertEqual(NapCredit.naps(for: day, sleeps: naps + [night], offsetSec: 0).count, 3)
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: naps + [night], offsetSec: 0),
                       NapCredit.maxCreditedMinPerDay,
                       "150 min of naps must credit only the \(Int(NapCredit.maxCreditedMinPerDay))-min cap")
    }

    /// THE ANTI-DOUBLE-COUNT INVARIANT ON THE REAL 2026-07-25 SHAPE. In the user's own store that day is
    /// main 00:22–05:35 + second 07:24–11:14, a 109.8-min wake gap. Because the gap alone rejected the
    /// bridge, the 229.5-min second half became a "nap": `analyzeDay` dropped its 188.5 asleep minutes from
    /// `totalSleepMin` AND `maxCreditedMinPerDay` truncated the span to 120, so 68.5 minutes lived in
    /// NEITHER lane. `SleepGrouping.splitNightMinFragmentMin` now reclassifies the fragment upstream.
    ///
    /// This is the structural invariant, not a coincidence: `naps(for:)` returns the COMPLEMENT of the
    /// same `mainNightGroupIndices` group `analyzeDay` sums, so a minute is in exactly one lane by
    /// construction. Fixing the classification in `NapCredit` alone was impossible — zeroing nap_min here
    /// would have left those minutes in neither.
    func testSplitNightSecondHalfIsNotANapAndCreditsNothing() {
        let mid = midnight(day)
        let first = session(start: mid + 22 * 60, end: mid + 5 * 3_600 + 35 * 60)   // 00:22 → 05:35
        let second = session(start: mid + 7 * 3_600 + 25 * 60,                      // 07:25 → 11:15
                             end: mid + 11 * 3_600 + 15 * 60)
        XCTAssertTrue(NapCredit.naps(for: day, sleeps: [first, second], offsetSec: 0).isEmpty,
                      "the second half of a split night is main night, never a nap")
        XCTAssertEqual(NapCredit.creditedMin(for: day, sleeps: [first, second], offsetSec: 0), 0,
                       "no nap credit — the minutes are counted once, by analyzeDay, in totalSleepMin")
        XCTAssertNil(NapCredit.creditedMinByDay(sleeps: [first, second], offsetSec: 0)[day])
        // And the group really does hold BOTH sessions, so the minutes are not simply lost.
        let blocks = [first, second].map {
            SleepGrouping.NightBlock(start: $0.effectiveStartTs, end: $0.endTs)
        }
        XCTAssertEqual(SleepGrouping.mainNightGroupIndices(blocks, offsetSec: 0)?.sorted(), [0, 1],
                       "both fragments are inside the winning main-night group that analyzeDay SUMS")
    }
}
