import XCTest
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// 014 P1 — Rest renders the night you are BROWSING, and every number on it is derived as of that
/// night.
///
/// The failure these pin is silent by construction. A screen showing 12 July with a typical pooled
/// from the 30 nights ending TODAY, a debt balance counting nights that had not happened yet, or a
/// duration strip whose labelled last point is a different night from the hero above it — none of
/// those crash, none render empty, and every one of them states a comparison that could not have
/// existed on the night it is describing. The only thing that catches them is a fixture where
/// reaching one night too far moves a number.
///
/// So: 20 consecutive nights whose durations AND Rest scores all differ, browsed at night 10 and at
/// the newest. Every expected value below is derived by hand from the fixture, never by running the
/// code under test.
final class RestBrowseTests: XCTestCase {

    // MARK: - Fixture
    //
    // Nights 2026-06-01 … 2026-06-20, all comfortably in the past (`SleepRegularity` refuses to grid a
    // minute that has not happened yet, so a fixture dated ahead of the wall clock would measure
    // nothing), plus a 21st day row carrying no night at all — the shape `repo.days` really has all day
    // today, and the reason "cut the record at the selected night" has to be a NO-OP at the newest
    // night rather than merely a small change.
    //
    //   night i (1-based):  totalSleepMin = 460 + 4i  → 464 … 540; mean 482 over 1…10, 502 over 1…20
    //                       Rest score    = 50 + i    → 51 … 70
    //                       session       = ends 07:00 local on its own day, `totalSleepMin` long
    //
    // Both means clear `personalNeedHours`' 7.5 h floor and its 7-night cold-start gate, so the need
    // really does move with the browse instead of being pinned by either.

    /// The device's zone, as `SleepRegularity` and `NapCredit` both resolve it — the fixture's instants
    /// have to land on the same local days the production keyers derive. Built here rather than taken
    /// from `SleepRegularity.deviceCalendar`: a fixture must not be built by the code it tests.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private func key(_ night: Int) -> String { String(format: "2026-06-%02d", night) }

    /// 07:00 local on night `n` — the instant its session ends at, and the local day it is keyed under.
    private func wake(_ night: Int) -> Int {
        Int(cal.date(from: DateComponents(year: 2026, month: 6, day: night, hour: 7))!
            .timeIntervalSince1970)
    }

    private func sleptMin(_ night: Int) -> Double { 460 + 4 * Double(night) }

    private func score(_ night: Int) -> Double { 50 + Double(night) }

    private var days: [DailyMetric] {
        (1...20).map { Fixtures.dailyMetric(day: key($0), totalSleepMin: sleptMin($0)) }
            + [Fixtures.dailyMetric(day: "2026-06-21")]   // today's row: no night banked yet
    }

    private var sleeps: [CachedSleepSession] {
        (1...20).map {
            Fixtures.sleepSession(startTs: wake($0) - Int(sleptMin($0)) * 60, endTs: wake($0))
        }
    }

    private var restSeries: [String: Double] {
        Dictionary(uniqueKeysWithValues: (1...20).map { (key($0), score($0)) })
    }

    /// Credited nap minutes (007 F3) on two nights that sit on OPPOSITE sides of a browse: 06-05 is
    /// inside night 10's 14-night debt window and outside the newest night's; 06-15 the other way
    /// round. Nap ROWS need a second session on the day, which this fixture deliberately doesn't build
    /// — they walk `ledger.nights`, the same window `windowNapMin` sums, so the minutes pin it.
    private let napSeries = ["2026-06-05": 30.0, "2026-06-15": 45.0]

    private func assemble(_ selected: String?) -> RestModel.Assembly {
        RestModel.assemble(days: days, restSeries: restSeries, sleeps: sleeps,
                           napSeries: napSeries, habitualMidsleepSec: nil,
                           selectedKey: selected, daysWindowFloor: "2000-01-01")
    }

    private struct NotAReading: Error { let got: String }

    private func reading(_ outcome: SleepRegularity.Outcome?,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> SleepRegularity.Reading {
        guard case .reading(let r)? = outcome else {
            XCTFail("expected a reading, got \(String(describing: outcome))", file: file, line: line)
            throw NotAReading(got: String(describing: outcome))
        }
        return r
    }

    // MARK: - The night on screen

    /// The hero, and the session the arousal/posture loaders are handed, are the SELECTED night's —
    /// not the newest one's with an older date printed over it.
    func testTheBrowsedNightIsTheNightOnScreen() {
        let a = assemble(key(10))

        XCTAssertEqual(a.lastDay?.day, "2026-06-10")
        XCTAssertEqual(a.lastDay?.totalSleepMin ?? 0, 500, accuracy: 1e-9)
        // The forensics window: night 10's own session, 500 minutes ending at its 07:00.
        XCTAssertEqual(a.lastSession?.endTs, wake(10))
        XCTAssertEqual(a.lastSession?.startTs, wake(10) - 500 * 60)
    }

    /// A key with no night of its own falls back to the newest rather than rendering an empty screen —
    /// including a key that IS in `days` but carries no sleep (today's row), which is the browse
    /// population's whole point: nights, not days.
    func testAKeyWithNoNightFallsBackToTheNewest() {
        for stale in ["2026-05-15", "2027-01-01", "2026-06-21"] {
            let a = assemble(stale)
            XCTAssertEqual(a.lastDay?.day, "2026-06-20", "\(stale) should fall back to the newest")
            XCTAssertEqual(a.history.last?.dayKey, "2026-06-20")
        }
    }

    /// A record of days with no sleep in them makes NO claims: no night, no typical, no regularity, and
    /// an empty strip rather than a row of zero-minute bars. Days are not nights — a day the strap never
    /// recorded a night for is missing, not a night of no sleep, and the whole browse moves through
    /// `slept` for exactly that reason.
    func testDaysWithoutNightsAreNotNightsOfNoSleep() {
        let bare = (1...5).map { Fixtures.dailyMetric(day: key($0)) }
        let a = RestModel.assemble(days: bare, restSeries: restSeries, sleeps: [], napSeries: [:],
                                   habitualMidsleepSec: nil, selectedKey: key(3), daysWindowFloor: "2000-01-01")

        XCTAssertNil(a.lastDay)
        XCTAssertNil(a.lastSession)
        XCTAssertNil(a.typicalScore)
        XCTAssertNil(a.regularity)
        XCTAssertTrue(a.history.isEmpty, "an unrecorded day is not a bar at zero")
        XCTAssertEqual(a.ledger.nightCount, 0)
    }

    // MARK: - The typical the verdict compares against

    /// The hero's "vs typical" verdict is the claim most easily made false by a browse: night 10 is
    /// compared against nights 1–9 (mean 55), NEVER against nights 1–19 (mean 60), which is what the
    /// newest night is compared against.
    func testTypicalIsTheThirtyNightsBeforeTheBrowsedOne() {
        XCTAssertEqual(assemble(key(10)).typicalScore ?? 0, 55, accuracy: 1e-9)
        XCTAssertEqual(assemble(nil).typicalScore ?? 0, 60, accuracy: 1e-9)
    }

    /// Early in the record there is no typical to compare against, and the verdict withholds rather
    /// than calling two nights a 30-day norm (`TodayModel.minBaselineSamples`). Night 3 has two prior
    /// nights and gets nothing; night 4 has three and gets their mean.
    func testANightEarlyInTheRecordHasNoTypical() {
        XCTAssertNil(assemble(key(3)).typicalScore, "two prior nights are not a typical")
        XCTAssertEqual(assemble(key(4)).typicalScore ?? 0, 52, accuracy: 1e-9)
    }

    // MARK: - Need + debt

    /// The personal need is the record UP TO the night on screen: 482 min over nights 1–10 against
    /// 502 min over the whole 20. A need pooled from nights that had not happened is the same lie the
    /// typical would be, and it is the number the whole debt ledger is measured against.
    func testNeedIsTheRecordUpToTheBrowsedNight() {
        XCTAssertEqual(assemble(key(10)).needMin, 482, accuracy: 1e-6)
        XCTAssertEqual(assemble(nil).needMin, 502, accuracy: 1e-6)
    }

    /// The debt window truncates at the selected night: nights after it are in that night's future and
    /// cannot be part of its balance. Nights 1–10 against a 482 min need sum to exactly 0, +30 for the
    /// nap credited on 06-05 — and the 06-15 credit, which lands after the browse, is not in it.
    func testTheDebtLedgerStopsAtTheBrowsedNight() {
        let a = assemble(key(10))

        XCTAssertEqual(a.ledger.nights.count, 10)
        XCTAssertEqual(a.ledger.nights.last?.day, "2026-06-10")
        XCTAssertFalse(a.ledger.nights.contains { $0.day > "2026-06-10" },
                       "a night after the one on screen cannot be in its balance")
        XCTAssertEqual(a.ledger.needMin, 482, accuracy: 1e-6)
        XCTAssertEqual(a.ledger.balanceMin, 30, accuracy: 0.05)
        XCTAssertEqual(a.windowNapMin, 30, accuracy: 1e-9)
    }

    /// The newest night's window is the trailing 14 (nights 7–20) against a 502 min need: 7196 minutes
    /// slept − 7028 needed = 168, +45 for the nap on 06-15. The 06-05 credit is off the back of the
    /// window, which is the cap doing its job rather than the browse.
    func testTheNewestNightsLedgerIsTheTrailingFourteen() {
        let a = assemble(nil)

        XCTAssertEqual(a.ledger.nights.count, 14)
        XCTAssertEqual(a.ledger.nights.first?.day, "2026-06-07")
        XCTAssertEqual(a.ledger.nights.last?.day, "2026-06-20")
        XCTAssertEqual(a.ledger.balanceMin, 213, accuracy: 0.05)
        XCTAssertEqual(a.windowNapMin, 45, accuracy: 1e-9)
    }

    // MARK: - The duration strip

    /// The strip ends on the night on screen. `SparkHistory` dots and labels its LAST value and draws
    /// its typical band from the values it is handed, so a strip running past the browse would print
    /// another night's duration under this night's hero.
    func testTheHistoryStripEndsOnTheBrowsedNight() {
        let browsed = assemble(key(10)).history
        XCTAssertEqual(browsed.count, 10)
        XCTAssertEqual(browsed.first?.dayKey, "2026-06-01")
        XCTAssertEqual(browsed.last?.dayKey, "2026-06-10")
        XCTAssertEqual(browsed.last?.minutes ?? 0, 500, accuracy: 1e-9)

        let newest = assemble(nil).history
        XCTAssertEqual(newest.count, 14)
        XCTAssertEqual(newest.first?.dayKey, "2026-06-07")
        XCTAssertEqual(newest.last?.dayKey, "2026-06-20")
    }

    // MARK: - Regularity

    /// Regularity ends where the hero does, so the two describe the same stretch of record. Its window
    /// then reaches 14 nights back from there — nights 1–10 here, i.e. 9 comparisons.
    func testRegularityEndsOnTheBrowsedNight() throws {
        let browsed = try reading(assemble(key(10)).regularity)
        XCTAssertEqual(browsed.pairs.last?.dayKey, "2026-06-10")
        XCTAssertEqual(browsed.pairs.count, 9)
        XCTAssertFalse(browsed.pairs.contains { $0.dayKey > "2026-06-10" })

        let newest = try reading(assemble(nil).regularity)
        XCTAssertEqual(newest.pairs.last?.dayKey, "2026-06-20")
        XCTAssertEqual(newest.pairs.count, 13)
    }

    /// And it withholds for the same reason the typical does: browsed to night 4 the window holds three
    /// comparisons, under `minimumPairs`, so the section calibrates instead of printing the number the
    /// newest night would have.
    func testRegularityCalibratesEarlyInTheRecord() {
        XCTAssertEqual(assemble(key(4)).regularity,
                       SleepRegularity.Outcome.calibrating(pairs: 3,
                                                           needed: SleepRegularity.minimumPairs))
    }

    // MARK: - The default screen

    /// The refactor must not have moved the screen everyone actually sees. Selecting the newest night
    /// is the same as selecting nothing, and both reproduce the pre-014 derivations exactly — computed
    /// here the old way, over the WHOLE record (including the trailing sleep-less day row that the cut
    /// now drops, which is why dropping it has to be provably inert).
    func testSelectingTheNewestReproducesTheDefault() {
        let days = self.days, slept = days.filter { $0.totalSleepMin != nil }
        let a = assemble(nil)
        let explicit = assemble("2026-06-20")

        let oldNeedMin = ScoreEngine.personalNeedHours(days: days) * 60
        let oldLedger = SleepDebt.ledger(
            series: days.map { d in
                (day: d.day, totalSleepMin: d.totalSleepMin.map { $0 + (napSeries[d.day] ?? 0) })
            },
            needHours: oldNeedMin / 60.0)
        let oldTypical = TodayModel.typicalMean(
            Array(slept.dropLast().suffix(30).compactMap { restSeries[$0.day] }))
        let oldRegularity = SleepRegularity.analyze(days: days, sleeps: sleeps,
                                                    endKey: slept.last?.day, daysReachRecordStart: true)

        XCTAssertEqual(a.lastDay?.day, slept.last?.day)
        XCTAssertEqual(a.needMin, oldNeedMin, accuracy: 1e-9)
        XCTAssertEqual(a.ledger, oldLedger)
        XCTAssertEqual(a.typicalScore ?? 0, oldTypical ?? -1, accuracy: 1e-9)
        XCTAssertEqual(a.history.map(\.dayKey), slept.suffix(14).map(\.day))
        XCTAssertEqual(a.regularity, oldRegularity)

        // …and naming that night explicitly is the same screen, so stepping back and forward again
        // cannot land somewhere subtly different from where it started.
        XCTAssertEqual(explicit.lastDay?.day, a.lastDay?.day)
        XCTAssertEqual(explicit.needMin, a.needMin, accuracy: 1e-9)
        XCTAssertEqual(explicit.ledger, a.ledger)
        XCTAssertEqual(explicit.typicalScore ?? 0, a.typicalScore ?? -1, accuracy: 1e-9)
        XCTAssertEqual(explicit.history.map(\.dayKey), a.history.map(\.dayKey))
        XCTAssertEqual(explicit.regularity, a.regularity)
    }

    // MARK: - The stepper (P2)
    //
    // The population the arrows move through, stated by hand: the twenty nights of the fixture, oldest →
    // newest. The one assertion below ties it to what the screen actually steps over — `Assembly.slept`,
    // which is `repo.days` filtered to rows carrying a night — so these tests cannot be walking a
    // different record from `RestScreen`.

    private var nightKeys: [String] { (1...20).map(key) }

    /// What the arrows step over is every night in the record, oldest → newest — and ONLY nights. The
    /// 21st day has a row but no sleep on it, and an arrow that stopped there would land on a screen with
    /// nothing on it while the night before it was still reachable.
    func testTheBrowsePopulationIsEveryNightInTheRecord() {
        XCTAssertEqual(assemble(nil).slept.map(\.day), nightKeys,
                       "the stepper walks nights; 06-21 has a row but no night on it")
    }

    /// Both ends, because a stepper that never disables is as wrong as one that never moves: back dies on
    /// the oldest night the record holds and forward on the newest, and in between each arrow moves exactly
    /// one night. Bounded by the DATA (decision 9) — never a dead arrow into an empty screen, and never a
    /// stop short of a night that is there.
    func testTheStepperStopsAtBothEndsOfTheRecord() {
        let nights = nightKeys

        XCTAssertNil(RestBrowse.previousKey(from: key(1), in: nights),
                     "there is nothing older than the first night")
        XCTAssertNil(RestBrowse.nextKey(from: key(20), in: nights),
                     "there is nothing newer than the last night")

        XCTAssertEqual(RestBrowse.previousKey(from: key(10), in: nights), key(9))
        XCTAssertEqual(RestBrowse.nextKey(from: key(10), in: nights), key(11))

        // Back then forward returns to exactly where it started — and that night reads as the newest,
        // which is what releases the browse back to the live default.
        let back = RestBrowse.previousKey(from: key(20), in: nights)
        XCTAssertEqual(back, key(19))
        XCTAssertEqual(RestBrowse.nextKey(from: back, in: nights), key(20))
        XCTAssertTrue(RestBrowse.isNewest(key: key(20), in: nights))
    }

    /// And it walks the RECORD, not the calendar. Today steps day keys (`TodayModel.shiftKey`) because
    /// Today has a row for every day; Rest does not, and a week the strap wasn't worn would give the arrow
    /// seven presses that each land on a screen with nothing on it.
    func testTheStepperWalksNightsNotCalendarDays() {
        let sparse = ["2026-06-01", "2026-06-02", "2026-06-09"]   // a week off-wrist in the middle

        XCTAssertEqual(RestBrowse.previousKey(from: "2026-06-09", in: sparse), "2026-06-02")
        XCTAssertEqual(RestBrowse.nextKey(from: "2026-06-02", in: sparse), "2026-06-09")
    }

    /// The header names the night it is on: the relative name only while it is TRUE. "Last night" printed
    /// over a night from June is the quiet false claim this wave exists to remove — and an unparseable key
    /// prints itself rather than being called last night.
    func testTheHeaderNamesTheNightItIsOn() {
        XCTAssertEqual(RestBrowse.headerTitle(key: key(20), isNewest: true), "Last night")

        let browsed = RestBrowse.headerTitle(key: key(10), isNewest: false)
        XCTAssertNotEqual(browsed, "Last night")
        XCTAssertTrue(browsed.contains("10"), "a browsed night is captioned with its own date: \(browsed)")

        XCTAssertEqual(RestBrowse.headerTitle(key: "not-a-day", isNewest: false), "not-a-day")
    }

    /// The forward-looking sections (optimal bedtime, the wake window) belong to the newest night alone
    /// (decision 4). The gate is the night that RENDERS, never "a key is selected": a stale selection falls
    /// back to the newest night, and gating on the selection would hide tonight's bedtime under a screen
    /// that is in fact showing last night. An empty record answers true, so a fresh install keeps the
    /// sections it has always had.
    func testTheForwardLookingGateFollowsTheRenderedNight() {
        let nights = nightKeys

        XCTAssertTrue(RestBrowse.isNewest(key: key(20), in: nights))
        XCTAssertFalse(RestBrowse.isNewest(key: key(19), in: nights))

        let stale = assemble("2027-01-01")
        XCTAssertEqual(stale.lastDay?.day, key(20))
        XCTAssertTrue(RestBrowse.isNewest(key: stale.lastDay?.day, in: nights),
                      "a selection with no night resolves to the newest, and renders as the newest")

        XCTAssertTrue(RestBrowse.isNewest(key: nil, in: []))
    }

    /// Tapping a strip column selects the night that column was DRAWN from. The strip is oldest → newest
    /// left → right (`SparkHistory` spaces its values that way), so column 0 is the far left of the strip
    /// and the last column is the night the screen is already on — a mirrored mapping would silently select
    /// the wrong night, and every key here would still be a real one.
    func testAStripColumnSelectsItsOwnNight() {
        let history = assemble(nil).history
        XCTAssertEqual(history.count, 14)

        XCTAssertEqual(RestHistoryStrip.dayKey(atColumn: 0, in: history), "2026-06-07")
        XCTAssertEqual(RestHistoryStrip.dayKey(atColumn: 13, in: history), "2026-06-20")
        XCTAssertEqual(RestHistoryStrip.dayKey(atColumn: 3, in: history), history[3].dayKey,
                       "the key handed back is the strip's own row, never a second opinion")
        XCTAssertNil(RestHistoryStrip.dayKey(atColumn: 14, in: history))
        XCTAssertNil(RestHistoryStrip.dayKey(atColumn: -1, in: history))

        // …and the key a column hands back really does move the screen onto that night.
        let tapped = RestHistoryStrip.dayKey(atColumn: 3, in: history)
        XCTAssertEqual(tapped, "2026-06-10")
        let after = assemble(tapped)
        XCTAssertEqual(after.lastDay?.day, "2026-06-10")
        XCTAssertEqual(after.history.last?.dayKey, "2026-06-10",
                       "the strip re-ends on the night that was tapped")
    }

    // MARK: - The words follow the browse too

    /// The debt ledger is truncated at the selected night, so its NUMBER already followed the browse.
    /// The sentence around it did not: "over the last 14 nights" reads as "up to now", which is only
    /// true at the newest night. A March balance described as the last 14 nights is the quietest kind
    /// of wrong — the arithmetic is right and the claim is false.
    @MainActor
    func testTheDebtLineSaysWhichFourteenNightsItMeans() {
        let newest = SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14, lowConfidenceNights: 0, isNewest: true)
        XCTAssertTrue(newest.debtLine.contains("over the last 14 nights"), newest.debtLine)

        let browsed = SleepNeedLine(asleepMin: 432, balanceMin: -144, debtNights: 14, lowConfidenceNights: 0, isNewest: false)
        XCTAssertFalse(browsed.debtLine.contains("the last"),
                       "a browsed night's window does not end now: \(browsed.debtLine)")
        XCTAssertTrue(browsed.debtLine.contains("the 14 nights up to it"), browsed.debtLine)

        // The balance itself is untouched by the wording — same number both ways round.
        XCTAssertTrue(newest.debtLine.contains("2:24") && browsed.debtLine.contains("2:24"))
    }

    /// The surplus and on-target branches carry the same window phrase. A fix applied to one sentence
    /// and not its two siblings is the usual way this comes back.
    @MainActor
    func testEveryDebtBranchFollowsTheBrowse() {
        for balance in [-144.0, 144.0, 0.0] {
            let browsed = SleepNeedLine(asleepMin: 432, balanceMin: balance,
                                        debtNights: 14, lowConfidenceNights: 0, isNewest: false)
            XCTAssertFalse(browsed.debtLine.contains("the last"),
                           "balance \(balance): \(browsed.debtLine)")
        }
    }

    // MARK: - The cache's floor is not the record's

    /// THE CROSS-WAVE DEFECT 019 FIXED, and the one neither wave's own review could see.
    ///
    /// 011 clamps the regularity window to the oldest row it was handed. 014 made every night in the
    /// published 120-day cache reachable with the back chevron. Together, the oldest thirteen browsable
    /// nights had their 14-night window silently cut short at the CACHE floor — which the code then
    /// treated as the beginning of the user's history. A night 112 days back printed
    /// "Calibrating - 2 of 7 night-to-night comparisons so far" over a night with thirteen fully
    /// recorded predecessors and a stored full-window reading of its own.
    ///
    /// The false REFUSAL is the harm: it asserts a limitation of the record that does not exist. Rather
    /// than print a 9-night pool under a label that says 14, or claim calibration that finished months
    /// ago, the section says nothing.
    ///
    /// Turns red: pass `daysReachRecordStart: true` unconditionally from `RestModel.assemble`.
    @MainActor
    func testAWindowClippedByTheCacheSaysNothingRatherThanClaimingCalibration() {
        // A saturated cache: the oldest row sits exactly AT the window floor, so older nights may exist.
        let floor = key(1)

        // The 5th night's 14-night window reaches back past that floor.
        let clipped = RestModel.assemble(days: days, restSeries: [:], sleeps: sleeps, napSeries: [:],
                                         habitualMidsleepSec: nil, selectedKey: key(5),
                                         daysWindowFloor: floor)
        XCTAssertNil(clipped.regularity,
                     "the window ran off the CACHE, not off the record — say nothing")

        // The same night, when the caller can vouch that the record really does start there.
        let genuine = RestModel.assemble(days: days, restSeries: [:], sleeps: sleeps, napSeries: [:],
                                         habitualMidsleepSec: nil, selectedKey: key(5),
                                         daysWindowFloor: "2000-01-01")
        XCTAssertNotNil(genuine.regularity,
                        "a record that genuinely starts here is calibrating, and should say so")

        // …and a night far enough in that its window fits is unaffected either way.
        let whole = RestModel.assemble(days: days, restSeries: [:], sleeps: sleeps, napSeries: [:],
                                       habitualMidsleepSec: nil, selectedKey: key(20),
                                       daysWindowFloor: floor)
        XCTAssertNotNil(whole.regularity, "a full window never depended on the floor")
    }

    // MARK: - Regularity's copy follows the browse

    /// Every number on Rest is derived as of the selected night. Regularity's WORDS were the last that
    /// were not: "so far" means "up to now", printed under a night in March.
    ///
    /// Turns red: pass `isNewest: true` unconditionally, or drop the parameter and restore the fixed
    /// strings.
    func testRegularityCopyStopsSpeakingInThePresentWhenBrowsed() {
        let reading = SleepRegularity.Outcome.reading(
            SleepRegularity.Reading(sri: 78, pairs: [], nightsUsable: 14, nightsConsidered: 14))
        XCTAssertTrue(reading.summaryLine(isNewest: true).hasPrefix("Your "))
        XCTAssertFalse(reading.summaryLine(isNewest: false).hasPrefix("Your "),
                       "a night in March is not 'your' current pattern")

        let calibrating = SleepRegularity.Outcome.calibrating(pairs: 3, needed: 7)
        XCTAssertTrue(calibrating.summaryLine(isNewest: true).contains("so far"))
        XCTAssertFalse(calibrating.summaryLine(isNewest: false).contains("so far"),
                       "'so far' is a claim about now: \(calibrating.summaryLine(isNewest: false))")
    }
}
