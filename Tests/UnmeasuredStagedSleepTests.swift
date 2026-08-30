import XCTest
import StrapAnalytics
import StrapStore
@testable import whoopmaxx

/// 030 Track A — the night worn-silence lane, pinned at both ends of the contract it spans.
///
/// THE DEFECT. `SleepStagingV2` answers an epoch with no data by skipping it (`SleepStagingV2.swift:286`)
/// and the tiling that follows (`:118-131`) stretches the PRECEDING label across the hole — the segment's
/// `end` becomes the next STAGED epoch's start, not the end of the evidence. So the hypnogram claims
/// stage over clock the strap never watched, silently: nothing in `stagesJSON` marks the stretch. On the
/// real corpus the night ending 2026-08-02 banks a 176-minute `deep` segment across a 166-minute hole
/// with no HR, no other channel and no WRIST_OFF event, and those minutes flow unmodified into
/// `deepMin`, `totalSleepMin` and the highest `sleep_performance` the user has ever seen — while the
/// SIBLING lane already books the same minutes as a capture failure (`effort_coverage` 0.80, under the
/// solid-coverage floor) and withholds that day's Effort.
///
/// THE LANE. `ScoreEngine` measures the staged ASLEEP minutes sitting over unexplained worn silence,
/// raises the EXISTING `CachedSleepSession.lowConfidence` flag on the session, and publishes the minutes
/// as `sleep_unmeasured_min` on the computed lane. It changes NOTHING else: not `stagesJSON`, not any
/// stage total, not the Rest composite. Both restraints are load-bearing and both are pinned below —
/// rewriting a hypnogram from a scoring pass would make `HealthExport.writeSleepStages` prefix-DELETE
/// every Apple Health sample it previously wrote for that session, destroying data that lives OUTSIDE
/// this app, and quietly shrinking a total would replace one unmeasured number with a smaller invented
/// one.
///
/// WHY THIS FILE EXISTS AT ALL. The producer (`ScoreEngine`) and the consumers (`Repository`,
/// `MetricCatalog`) were built to a contract stated in advance — one literal key, minutes, the night's
/// day key, and an explicit 0 that the read side filters. A drift in any of those compiles perfectly and
/// renders NOTHING, which is the worst failure mode available: the app would quietly stop reporting a
/// defect it had already found. The seams below are `nonisolated static` and pure precisely so the
/// contract can be asserted rather than commented.
final class UnmeasuredStagedSleepTests: XCTestCase {

    /// A wake instant well clear of any DST edge in the device zone.
    private let base = 1_800_000_000
    /// `GapScan.gapThresholdS` — the same 15-minute bar the waking-window scan uses.
    private var threshold: Int { GapScan.gapThresholdS }

    /// A once-per-minute HR mark train over `[from, to)`. Minute cadence is far under the 15-minute bar,
    /// so a stretch built from it reads as continuously watched.
    private func marks(from: Int, to: Int, everyS: Int = 60) -> [Int] {
        stride(from: from, to: to, by: everyS).map { $0 }
    }

    private func stages(_ segments: [(Int, Int, String)]) -> String {
        DayEngine.encodeStages(segments.map { StageSegment(start: $0.0, end: $0.1, stage: $0.2) }) ?? ""
    }

    // MARK: - The measurement

    /// THE CORPUS NIGHT, to the shape and roughly the arithmetic of 2026-08-02: a long `deep` segment
    /// laid across a hole with no HR in it and no off-wrist event to explain it. The answer is the
    /// INTERSECTION of the two — not the segment, not the silence.
    ///
    /// Turns red: intersect the silence with the session span instead of with the staged segments, or
    /// count the whole segment once any part of it is unwatched.
    func testStagedSleepLaidAcrossAHoleIsMeasuredAsTheOverlap() {
        let start = base
        let end = start + 6 * 3_600
        // Watched for the first hour, then silent for three, then watched to the end.
        let holeStart = start + 3_600
        let holeEnd = start + 4 * 3_600
        let hr = marks(from: start, to: holeStart) + marks(from: holeEnd, to: end)
        // One `deep` block straddling the hole: half an hour of it is watched, the rest is not.
        let deepStart = holeStart - 1_800
        let deepEnd = holeEnd
        let s = Fixtures.sleepSession(startTs: start, endTs: end,
                                      stagesJSON: stages([(start, deepStart, "light"),
                                                          (deepStart, deepEnd, "deep"),
                                                          (deepEnd, end, "light")]))

        let unmeasured = ScoreEngine.unmeasuredStagedSeconds(session: s, hrTimestamps: hr, offWrist: [])

        // The silence begins at the last mark before the hole, not at the hole's nominal start — the
        // scan can only know the strap went quiet from the last thing it said.
        let lastMark = holeStart - 60
        XCTAssertEqual(unmeasured, Double(holeEnd - lastMark), accuracy: 1,
                       "the answer is staged-asleep ∩ silence, not either one whole")
        XCTAssertLessThan(unmeasured, Double(deepEnd - deepStart),
                          "…so it must be under the segment's own length")
    }

    /// THE OTHER DIRECTION, and the one that decides whether this lane is a measurement or a mute button:
    /// a night watched throughout measures ZERO, so a flag can never be a permanent property of a night.
    func testANightWatchedThroughoutMeasuresNothing() {
        let start = base
        let end = start + 6 * 3_600
        let s = Fixtures.sleepSession(startTs: start, endTs: end,
                                      stagesJSON: stages([(start, end, "light")]))

        XCTAssertEqual(ScoreEngine.unmeasuredStagedSeconds(session: s,
                                                           hrTimestamps: marks(from: start, to: end),
                                                           offWrist: []), 0)
    }

    /// AN EXPLAINED ABSENCE IS NOT THE DEFECT. A strap on the nightstand is a silence the user themself
    /// created and the app already knows about; only silence with no event behind it is the thing this
    /// lane is about. Subtracting off-wrist can only ever produce FEWER flags, never more.
    ///
    /// Turns red: drop the `offWrist` argument from `wornSilences`, or subtract it after the threshold
    /// test rather than before.
    func testSilenceExplainedByOffWristIsNotCountedAgainstTheNight() {
        let start = base
        let end = start + 6 * 3_600
        let holeStart = start + 3_600
        let holeEnd = start + 4 * 3_600
        let hr = marks(from: start, to: holeStart) + marks(from: holeEnd, to: end)
        let s = Fixtures.sleepSession(startTs: start, endTs: end,
                                      stagesJSON: stages([(start, end, "deep")]))

        let unexplained = ScoreEngine.unmeasuredStagedSeconds(session: s, hrTimestamps: hr, offWrist: [])
        XCTAssertGreaterThan(unexplained, 0)

        // The same hole, now with a wrist-off pairing across it.
        let explained = ScoreEngine.unmeasuredStagedSeconds(
            session: s, hrTimestamps: hr,
            offWrist: [(start: holeStart - 120, end: holeEnd + 120)])
        XCTAssertEqual(explained, 0, "an absence the app can account for is not an unmeasured claim")
    }

    /// A STAGED WAKE SPAN OVER SILENCE IS NOT COUNTED. It is a mis-stated absence too, but it asserts no
    /// SLEEP: it inflates nothing in `totalSleepMin` / `deepMin` / `remMin` / `lightMin` and nothing in
    /// the Rest composite. Folding it in would inflate the very number that exists to size the
    /// over-claim.
    ///
    /// Turns red: count every decoded segment instead of the three asleep lanes.
    func testStagedWakeOverSilenceIsNotAnOverClaimOfSleep() {
        let start = base
        let end = start + 6 * 3_600
        let holeStart = start + 3_600
        let holeEnd = start + 4 * 3_600
        let hr = marks(from: start, to: holeStart) + marks(from: holeEnd, to: end)

        for token in ["wake", "awake"] {
            let s = Fixtures.sleepSession(startTs: start, endTs: end,
                                          stagesJSON: stages([(start, end, token)]))
            XCTAssertEqual(ScoreEngine.unmeasuredStagedSeconds(session: s, hrTimestamps: hr,
                                                               offWrist: []), 0,
                           "\(token) over silence claims no sleep")
        }
    }

    /// THE BAR ITSELF, pinned from both sides. The threshold is `GapScan.gapThresholdS` and the test is
    /// STRICTLY greater, exactly as the waking-window grader's is — a per-night bar of its own, or a
    /// `>=`, would let the two lanes disagree about the same minute.
    ///
    /// The gap is measured from the LAST MARK to the next one, not from a nominal hole boundary: the scan
    /// can only know the strap went quiet from the last thing it said. So the fixtures below are built
    /// backwards from that pair.
    func testTheSilenceBarIsTheSharedThresholdAndIsStrict() {
        let start = base
        let end = start + 3 * 3_600
        let lastMark = start + 3_600 - 60          // marks(from:to:) stops one cadence short of `to`
        let s = Fixtures.sleepSession(startTs: start, endTs: end,
                                      stagesJSON: stages([(start, end, "deep")]))

        func unmeasured(gapS: Int) -> Double {
            let hr = marks(from: start, to: lastMark + 1) + marks(from: lastMark + gapS, to: end)
            return ScoreEngine.unmeasuredStagedSeconds(session: s, hrTimestamps: hr, offWrist: [])
        }

        XCTAssertEqual(unmeasured(gapS: threshold), 0,
                       "a gap of exactly the threshold is not over it")
        XCTAssertEqual(unmeasured(gapS: threshold + 1), Double(threshold + 1), accuracy: 1,
                       "one second over the bar is a silence, and all of it counts")
    }

    /// A night with NO stored hypnogram claims no stage at all, so there is nothing to over-claim — even
    /// when the whole session is silent. Absence of a claim is not a claim.
    func testASessionWithNoHypnogramClaimsNothingHoweverSilent() {
        let start = base
        let end = start + 6 * 3_600
        let s = Fixtures.sleepSession(startTs: start, endTs: end, stagesJSON: nil)

        XCTAssertEqual(ScoreEngine.unmeasuredStagedSeconds(session: s, hrTimestamps: [], offWrist: []), 0)
    }

    // MARK: - What the lane is forbidden to touch

    /// THE ONE THING THAT MUST NEVER DRIFT. `flaggedLowConfidence` may move the flag and NOTHING else.
    /// `stagesJSON` above all: `HealthExport.writeSleepStages` reacts to a changed stages fingerprint by
    /// prefix-DELETING every Apple Health sample it previously wrote for that session, so a scoring pass
    /// that rewrote a hypnogram would irreversibly destroy health data living OUTSIDE this app.
    ///
    /// Turns red: rebuild the row from re-derived stages, round a stored figure, or "tidy" any field
    /// while the flag is being set.
    func testRaisingTheFlagCopiesEveryOtherFieldVerbatim() {
        let start = base
        let end = start + 7 * 3_600
        let json = stages([(start, start + 3_600, "light"), (start + 3_600, end, "deep")])
        let s = Fixtures.sleepSession(startTs: start, endTs: end, efficiency: 0.91,
                                      restingHr: 48, avgHrv: 72.5, stagesJSON: json,
                                      userEdited: true, startTsAdjusted: start + 600)

        let flagged = ScoreEngine.flaggedLowConfidence(s)

        XCTAssertTrue(flagged.lowConfidence)
        XCTAssertEqual(flagged.stagesJSON, json, "the hypnogram must be the SAME string, byte for byte")
        XCTAssertEqual(flagged.startTs, s.startTs)
        XCTAssertEqual(flagged.endTs, s.endTs)
        XCTAssertEqual(flagged.efficiency, s.efficiency)
        XCTAssertEqual(flagged.restingHr, s.restingHr)
        XCTAssertEqual(flagged.avgHrv, s.avgHrv)
        XCTAssertEqual(flagged.userEdited, s.userEdited)
        XCTAssertEqual(flagged.startTsAdjusted, s.startTsAdjusted)
    }

    /// The flag is OR-ed, never overwritten and never cleared: the stager raises the SAME bit for its own
    /// reason (a run longer than `SleepDetection.maxMainSleepSpanS`), and clearing that would delete a caveat
    /// the user is already being shown.
    func testAnAlreadyFlaggedSessionSurvivesUnchanged() {
        let start = base
        let end = start + 17 * 3_600
        let s = Fixtures.sleepSession(startTs: start, endTs: end, lowConfidence: true)

        XCTAssertEqual(ScoreEngine.flaggedLowConfidence(s), s,
                       "the stager's own flag is not this lane's to re-decide")
    }

    // MARK: - The producer/consumer contract

    /// THE SILENT-FAILURE GUARD. `MetricCatalog` reads the series by literal key out of
    /// `MetricSeriesSet.unmeasuredMin`, which `Repository` fills from `store.metricSeries(key:)` by the
    /// same literal, which `ScoreEngine` writes by the same literal again. Nothing in the type system
    /// joins those three strings: a typo in any one of them compiles, passes every other test, and shows
    /// the user NOTHING — the app quietly ceasing to report a defect it had already measured.
    ///
    /// The catalog entry is the end of that chain, so asserting it resolves is the cheapest place to
    /// catch a break in any link.
    func testTheCatalogEntryIsKeyedToTheSeriesTheEngineWrites() throws {
        let def = try XCTUnwrap(MetricCatalog.all.first { $0.key == "sleep_unmeasured_min" },
                                "the Data wall entry is keyed to ScoreEngine's literal series key")
        XCTAssertEqual(def.unit, "min", "the engine publishes MINUTES")
        // A fact about the recording, not about the sleeper: fewer unmeasured minutes can simply mean a
        // shorter night, so a coloured delta would grade the strap's capture as good or bad for the
        // person wearing it.
        XCTAssertEqual(def.sense, .neutral)

        let day = "2026-08-02"
        let d = Fixtures.dailyMetric(day: day, totalSleepMin: 610)
        XCTAssertEqual(def.read(d, MetricSeriesSet(unmeasuredMin: [day: 166.1])), 166.1)
    }

    /// ZERO IS NOT A READING. ScoreEngine writes an explicit 0 for a scanned-clean night — deliberately,
    /// because `metricSeries` has no delete API while the session flag DOES reconcile, so publishing
    /// nothing on a clean night would let a stale non-zero outlive the flag that justified it. That 0 is
    /// a reconciling row, not a measurement, and BOTH read paths must drop it: `.integer` would print it
    /// "0", which on the wall reads as the measured claim "no gap tonight".
    ///
    /// Turns red: relax either filter — `Repository`'s `where p.value > 0` or the catalog's own floor.
    func testAScannedCleanNightIsAbsentOnTheWallAndNeverAZero() throws {
        let def = try XCTUnwrap(MetricCatalog.all.first { $0.key == "sleep_unmeasured_min" })
        let day = "2026-08-03"
        let d = Fixtures.dailyMetric(day: day, totalSleepMin: 470)

        XCTAssertNil(def.read(d, MetricSeriesSet(unmeasuredMin: [day: 0])),
                     "the engine's reconciling zero must render as absence")
        XCTAssertNil(def.read(d, MetricSeriesSet()),
                     "a day never scanned at all is absent for a different reason and reads the same")
        XCTAssertNil(def.read(d, MetricSeriesSet(unmeasuredMin: [day: 0.4])),
                     "under half a minute cannot be shown as a digit without rounding it to a lie")
    }

    /// The copy on both Rest surfaces stays inside the register: descriptive, within-user, no verdict and
    /// no instruction. The night's own caveat and the debt line's clause are written by different files
    /// and must not drift apart on that.
    func testNeitherRestSurfaceGradesTheNightOrTheSleeper() {
        let banned = ["poor", "bad", "impaired", "abnormal", "unhealthy", "should", "consider",
                      "try to", "talk to", "improve", "risk"]
        let ordinarySpan = 6 * 3_600 + 45 * 60      // the corpus night: flagged, but of ordinary length
        let silenceCaption = RestNight.lowConfidenceCaption(spanS: ordinarySpan).lowercased()
        let overlongCaption = RestNight.lowConfidenceCaption(spanS: SleepDetection.maxMainSleepSpanS + 720)
            .lowercased()

        for word in banned {
            XCTAssertFalse(silenceCaption.contains(word), "\(word) in: \(silenceCaption)")
            XCTAssertFalse(overlongCaption.contains(word), "\(word) in: \(overlongCaption)")
        }
        // And the one falsehood this branch exists to prevent: a 6 h 45 m night must not be described as
        // longer than a night can be.
        XCTAssertFalse(silenceCaption.contains("longer than a night can be"),
                       "an ordinary-length night was captioned with the over-long gate's wording")
    }
}
