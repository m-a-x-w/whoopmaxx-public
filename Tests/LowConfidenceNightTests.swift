import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// 016 — the night the stager kept but wasn't sure of.
///
/// `SleepStager` caps a single assembled main sleep at `maxMainSleepSpanS` and, rather than DROPPING an
/// over-long run (which erased the night, its Rest score and its slot in the debt ledger), it KEEPS the
/// run and marks the session `lowConfidence` (`SleepStaging.swift:1042-1048`). The flag reached the store
/// — migration v24 added the column *"so display can caveat it"* — and then nothing displayed it: a
/// 17-hour artefact rendered exactly like a real night, hero and debt ledger alike.
///
/// These pin the caveat this wave adds, in BOTH directions. A caveat that always shows is as wrong as one
/// that never does, so every flagged assertion has a confident twin.
///
/// NOTHING here is about scoring. The night is still summed, still scored, still banked (decision 1) —
/// only the words around it changed.
final class LowConfidenceNightTests: XCTestCase {

    /// A wake instant in mid-January 2027, well clear of any DST edge in the device zone.
    private let base = 1_800_000_000
    /// 17 h 12 min — the span the plan's worked example quotes.
    private let overlongSpanS = 61_920

    private func dayKey(endingAt ts: Int) -> String {
        Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// A one-fragment night ending at `end`. `spanS` is the DETECTED clock span (`endTs - startTs`) —
    /// the quantity the stager's cap gates on.
    private func session(endingAt end: Int, spanS: Int, flagged: Bool = false,
                         startTsAdjusted: Int? = nil) -> CachedSleepSession {
        Fixtures.sleepSession(startTs: end - spanS, endTs: end, efficiency: 0.9,
                              startTsAdjusted: startTsAdjusted, lowConfidence: flagged)
    }

    // MARK: - The night carries the flag, and quotes the right number

    /// THE TRAP. The flag fires on the SESSION SPAN, never on `totalSleepMin` — the staged asleep total,
    /// a different and much smaller number. A caveat that quoted the asleep total would read
    /// "9:40 … against a 16 h limit", which is self-evidently not why the gate fired.
    ///
    /// Turns red: derive `flaggedSpanS` in `RestNight.init(day:score:sessions:)` from
    /// `day.totalSleepMin` instead of from the session's `endTs - startTs`.
    func testTheCaveatQuotesTheSessionSpanNotTheAsleepTotal() throws {
        let end = base
        // 9 h 40 min of staged sleep inside a 17 h 12 min recorded stretch: exactly the shape the cap
        // exists to catch, and exactly the two numbers that must not be confused.
        let day = Fixtures.dailyMetric(day: dayKey(endingAt: end), totalSleepMin: 580)
        let night = RestNight(day: day, score: 61,
                              sessions: [session(endingAt: end, spanS: overlongSpanS, flagged: true)])

        XCTAssertTrue(night.lowConfidence)
        XCTAssertEqual(night.lowConfidenceSpanS, overlongSpanS)

        let caption = try XCTUnwrap(night.lowConfidenceCaption)
        XCTAssertTrue(caption.contains("17 h 12 min"),
                      "the caveat must quote the recorded SPAN: \(caption)")
        XCTAssertFalse(caption.contains(RestFormat.hmm(580)),
                       "the asleep total (9:40) is not what tripped the cap: \(caption)")
        XCTAssertFalse(caption.contains("9 h 40 min"),
                       "…in any spelling: \(caption)")
    }

    /// The limit in the sentence is READ from the stager's own constant, so the copy and the gate that
    /// produced it move together. (A literal that happens to agree with today's constant would pass this
    /// — what it really pins is that the two are equal, which is what a future cap change breaks.)
    ///
    /// Turns red: write "16 h" (or any literal) into `RestNight.lowConfidenceCaption` instead of
    /// formatting `SleepDetection.maxMainSleepSpanS`.
    func testTheCaveatQuotesTheStagerConstantForTheLimit() {
        let limit = WMFormat.duration(seconds: SleepDetection.maxMainSleepSpanS, style: .spelled)
        let caption = RestNight.lowConfidenceCaption(spanS: SleepDetection.maxMainSleepSpanS + 720)
        XCTAssertTrue(caption.contains("\(limit) limit"), caption)
        // …and the span it quotes really is longer than that limit, which is the whole claim.
        XCTAssertTrue(caption.contains(WMFormat.duration(seconds: SleepDetection.maxMainSleepSpanS + 720,
                                                         style: .spelled)), caption)
    }

    /// Decisions 2 and 5: the sentence names what was OBSERVED and stops. The app cannot tell a wrong
    /// clock from a flight from a frozen strap, and none of it is a statement about the sleeper.
    ///
    /// Turns red: add any of these words back to `RestNight.lowConfidenceCaption`.
    func testTheCaveatSaysWhatWasObservedAndNothingElse() {
        let caption = RestNight.lowConfidenceCaption(spanS: overlongSpanS).lowercased()
        for forbidden in ["clock", "wrong", "travel", "time zone", "timezone", "strap froze",
                          "oversleep", "overslept", "too much", "unhealthy", "error"] {
            XCTAssertFalse(caption.contains(forbidden),
                           "the caveat must not guess \"\(forbidden)\": \(caption)")
        }
        XCTAssertTrue(caption.hasSuffix("limit."), "it ends on the measurement: \(caption)")
    }

    /// The span is the DETECTED one (`endTs - startTs`), not `endTs - effectiveStartTs`. A hand-corrected
    /// onset would otherwise be able to produce a caveat quoting a span UNDER the limit it claims to have
    /// passed — a sentence that contradicts itself.
    ///
    /// Turns red: swap `$0.endTs - $0.startTs` for `$0.endTs - $0.effectiveStartTs` in `RestNight`.
    func testTheCaveatQuotesTheDetectedSpanNotAnAdjustedOnset() throws {
        let end = base
        let day = Fixtures.dailyMetric(day: dayKey(endingAt: end), totalSleepMin: 580)
        // A 15 h effective onset inside a 17 h 12 min detected run — under the cap, so quoting it would
        // caption "15 h recorded against a 16 h limit".
        let night = RestNight(day: day, score: 61,
                              sessions: [session(endingAt: end, spanS: overlongSpanS, flagged: true,
                                                 startTsAdjusted: end - 54_000)])

        XCTAssertEqual(night.lowConfidenceSpanS, overlongSpanS)
        let caption = try XCTUnwrap(night.lowConfidenceCaption)
        XCTAssertTrue(caption.contains("17 h 12 min"), caption)
        XCTAssertFalse(caption.contains("15 h "), caption)
    }

    /// THE OTHER DIRECTION. An ordinary night carries no flag, no span, and no caption — the hero renders
    /// byte-identically to before this wave.
    ///
    /// Turns red: make `RestNight.lowConfidence` return anything other than `lowConfidenceSpanS != nil`,
    /// or set `flaggedSpanS` from the span rather than from the session's own flag.
    func testAConfidentNightCarriesNoCaveatAtAll() {
        let end = base
        let day = Fixtures.dailyMetric(day: dayKey(endingAt: end), totalSleepMin: 432)
        let night = RestNight(day: day, score: 82,
                              sessions: [session(endingAt: end, spanS: 8 * 3_600)])

        XCTAssertFalse(night.lowConfidence)
        XCTAssertNil(night.lowConfidenceSpanS)
        XCTAssertNil(night.lowConfidenceCaption)
    }

    /// The app trusts the STAGER's flag; it does not re-run the gate. A long night that the stager kept
    /// without flagging (it clears the cap, or an imported summary row that never went through the gate)
    /// stays confident.
    ///
    /// Turns red: derive `lowConfidence` from `endTs - startTs > SleepDetection.maxMainSleepSpanS` in
    /// `RestNight` instead of from `CachedSleepSession.lowConfidence`.
    func testAnUnflaggedSessionStaysConfidentHoweverLongItIs() {
        let end = base
        let day = Fixtures.dailyMetric(day: dayKey(endingAt: end), totalSleepMin: 700)
        let night = RestNight(day: day, score: 70,
                              sessions: [session(endingAt: end, spanS: overlongSpanS)])
        XCTAssertFalse(night.lowConfidence,
                       "the flag is the stager's to set — the screen must not re-derive the gate")
    }

    // MARK: - The debt window

    /// A flagged night INSIDE the ledger window but not on screen still moved the balance, so it still
    /// counts. The `windowNapMin` / `windowNapCount` precedent exists for exactly this reason.
    ///
    /// Turns red: pass only the displayed night's key to `RestNight.lowConfidenceNightCount`, or scope
    /// the count to `assembly.lastDay` in `RestScreen`.
    func testTheWindowCountIncludesAFlaggedNightThatIsNotOnScreen() {
        let shownEnd = base
        let flaggedEnd = base - 3 * 86_400
        let shownKey = dayKey(endingAt: shownEnd)
        let flaggedKey = dayKey(endingAt: flaggedEnd)
        XCTAssertNotEqual(shownKey, flaggedKey, "fixture sanity: two different nights")

        let sleeps = [session(endingAt: shownEnd, spanS: 8 * 3_600),
                      session(endingAt: flaggedEnd, spanS: overlongSpanS, flagged: true)]

        // The night ON SCREEN is confident…
        let shownDay = Fixtures.dailyMetric(day: shownKey, totalSleepMin: 432)
        let shown = RestNight(day: shownDay, score: 82,
                              sessions: RestNight.sessions(for: shownDay, in: sleeps))
        XCTAssertFalse(shown.lowConfidence)

        // …and the window it is measured over is not.
        XCTAssertEqual(RestNight.lowConfidenceNightCount(dayKeys: [flaggedKey, shownKey],
                                                         sleeps: sleeps), 1)
    }

    /// THE OTHER DIRECTION, on the window: a window of ordinary nights answers zero.
    ///
    /// Turns red: drop the `contains(where: \.lowConfidence)` guard in
    /// `RestNight.lowConfidenceNightCount` so every night with a group counts (this window would read 2).
    func testTheWindowCountIsZeroOnAnOrdinaryWindow() {
        let sleeps = [session(endingAt: base, spanS: 8 * 3_600),
                      session(endingAt: base - 86_400, spanS: 7 * 3_600)]
        let keys = [dayKey(endingAt: base - 86_400), dayKey(endingAt: base)]
        XCTAssertEqual(RestNight.lowConfidenceNightCount(dayKeys: keys, sleeps: sleeps), 0)
    }

    /// A bridged night is ONE night however many fragments it holds, and the caveat quotes the longest
    /// flagged fragment — the stretch the sentence is about.
    ///
    /// Turns red: take `.first` (or `.min()`) of the flagged spans in `RestNight` instead of `.max()`.
    func testABridgedNightQuotesItsLongestFlaggedFragment() throws {
        let end = base
        let day = Fixtures.dailyMetric(day: dayKey(endingAt: end), totalSleepMin: 580)
        // Two flagged fragments: an earlier short one and the over-long one the cap actually caught.
        let short = session(endingAt: end - 70_000, spanS: 3 * 3_600, flagged: true)
        let long = session(endingAt: end, spanS: overlongSpanS, flagged: true)
        let night = RestNight(day: day, score: 61, sessions: [short, long])

        XCTAssertEqual(night.lowConfidenceSpanS, overlongSpanS)
        XCTAssertTrue(try XCTUnwrap(night.lowConfidenceCaption).contains("17 h 12 min"))
    }

    // MARK: - The debt line (decision 3: the two surfaces land together)

    /// The ledger names the flagged night as a reason it swung. A hero that caveats while the debt line
    /// silently banks the surplus is worse than neither — the ledger would be trusted BECAUSE the hero
    /// looked careful.
    ///
    /// Turns red: drop `lowConfidenceWindowNote` from `SleepNeedLine.debtLine`.
    @MainActor
    func testTheDebtLineNamesTheWindowsFlaggedNights() {
        let one = SleepNeedLine(asleepMin: 580, balanceMin: 342, debtNights: 14,
                                lowConfidenceNights: 1).debtLine
        XCTAssertEqual(one,
                       "5:42 of sleep surplus over the last 14 nights, "
                       + "including 1 night with unmeasured minutes or a stretch longer than a night can be.")

        let two = SleepNeedLine(asleepMin: 580, balanceMin: 342, debtNights: 14,
                                lowConfidenceNights: 2).debtLine
        XCTAssertTrue(two.contains("including 2 nights with unmeasured minutes "
                                   + "or a stretch longer than a night can be"), two)
    }

    /// THE OTHER DIRECTION, on the debt line: a window with no flagged night prints the sentence it
    /// printed before this wave, character for character.
    ///
    /// Turns red: drop the `guard lowConfidenceNights > 0` early-out in `lowConfidenceWindowNote`.
    @MainActor
    func testAnOrdinaryWindowsDebtLineIsUnchanged() {
        XCTAssertEqual(SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14,
                                     lowConfidenceNights: 0).debtLine,
                       "2:24 of sleep debt over the last 14 nights.")
        // …and unchanged across every branch, not just the debt one. A note appended to some of the
        // three sentences and not the others is how the last wave's caption defect got in.
        for balance in [-144.0, 342.0, 0.0] {
            let line = SleepNeedLine(asleepMin: 432, balanceMin: balance, debtNights: 14,
                                     lowConfidenceNights: 0).debtLine
            XCTAssertFalse(line.contains("longer than a night"), "balance \(balance): \(line)")
        }
    }

    /// `lowConfidenceNights` carries NO default, on purpose.
    ///
    /// The hero caveat and this line have to arrive together (016 decision 3): a hero that hedges while
    /// the ledger silently banks the surplus is worse than neither, because the ledger reads as careful
    /// BECAUSE the hero did. A defaulted argument is precisely how a call site drops one half of a pair
    /// — 013's receipt, 014's aged-out states and 015's calibrating note each shipped dead behind one,
    /// with green tests throughout.
    ///
    /// This cannot be asserted at runtime: the guarantee IS the compile error. What this pins instead
    /// is that an explicit zero is a real, reachable, unchanged state, so requiring it cost the
    /// ordinary path nothing.
    ///
    /// Turns red: nothing — stated plainly so the next reader knows the enforcement lives in the type,
    /// and that re-adding `= 0` removes it without failing a single test.
    @MainActor
    func testTheExplicitZeroIsTheOrdinaryPath() {
        XCTAssertEqual(SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14,
                                     lowConfidenceNights: 0).debtLine,
                       "2:24 of sleep debt over the last 14 nights.")
    }

    /// The flagged note COMPOSES with the nap note; it does not replace it. A window can have both, and
    /// substituting one for the other would delete the explanation it was meant to sharpen.
    ///
    /// Turns red: `let n = lowConfidenceWindowNote` (instead of `napWindowNote + lowConfidenceWindowNote`)
    /// in `SleepNeedLine.debtLine`.
    @MainActor
    func testTheFlaggedNoteKeepsTheNapNoteBesideIt() {
        let line = SleepNeedLine(asleepMin: 580, balanceMin: 342, debtNights: 14,
                                 windowNapMin: 70, windowNapCount: 2,
                                 lowConfidenceNights: 1).debtLine
        XCTAssertEqual(line,
                       "5:42 of sleep surplus over the last 14 nights (incl. +1:10 from 2 naps), "
                       + "including 1 night with unmeasured minutes or a stretch longer than a night can be.")
    }

    /// All three balance branches carry the note. A fix applied to one sentence and not its two siblings
    /// is the usual way this comes back (`RestBrowseTests.testEveryDebtBranchFollowsTheBrowse`).
    ///
    /// Turns red: append `lowConfidenceWindowNote` inside one branch only.
    @MainActor
    func testEveryDebtBranchCarriesTheFlaggedNote() {
        for balance in [-144.0, 144.0, 0.0] {
            let line = SleepNeedLine(asleepMin: 432, balanceMin: balance, debtNights: 14,
                                     lowConfidenceNights: 1).debtLine
            XCTAssertTrue(line.contains("including 1 night with unmeasured minutes "
                                        + "or a stretch longer than a night can be"),
                          "balance \(balance): \(line)")
        }
    }

    /// Browsing (014): the debt line's window wording and the flagged note travel together, so a browsed
    /// night's caveat describes the window that ends on it.
    ///
    /// Turns red: build `lowConfidenceWindowNote` before the window phrase, or hard-code "the last".
    @MainActor
    func testTheFlaggedNoteFollowsTheBrowse() {
        let browsed = SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14,
                                    lowConfidenceNights: 1, isNewest: false).debtLine
        XCTAssertEqual(browsed,
                       "2:24 of sleep debt over the 14 nights up to it, "
                       + "including 1 night with unmeasured minutes or a stretch longer than a night can be.")
    }

    // MARK: - The two surfaces agree

    /// Decision 3, at the model boundary: when the displayed night is flagged AND it is inside the
    /// ledger window, the hero's caveat and the debt line's count are both non-empty — resolved through
    /// the same `mainNightSessions` selector, so they cannot describe different nights.
    ///
    /// Turns red: resolve the window count with a different selector (e.g. `RestNight.session(for:in:)`,
    /// the bare longest-span pick).
    @MainActor
    func testTheHeroCaveatAndTheDebtCountAgreeOnTheDisplayedNight() {
        let end = base
        let key = dayKey(endingAt: end)
        let day = Fixtures.dailyMetric(day: key, totalSleepMin: 580)
        let sleeps = [session(endingAt: end, spanS: overlongSpanS, flagged: true)]

        let night = RestNight(day: day, score: 61,
                              sessions: RestNight.sessions(for: day, in: sleeps))
        let count = RestNight.lowConfidenceNightCount(dayKeys: [key], sleeps: sleeps)

        XCTAssertNotNil(night.lowConfidenceCaption)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(SleepNeedLine(asleepMin: 580, balanceMin: 342, debtNights: 14,
                                    lowConfidenceNights: count).debtLine
                        .contains("including 1 night with unmeasured minutes "
                                  + "or a stretch longer than a night can be"))
    }
}
