import XCTest
import StrapProtocol
import StrapStore
import StrapAnalytics
@testable import whoopmaxx

/// 024 Intake — the rules that decide what gets written, what gets drawn, and what is refused.
///
/// Everything here is PURE. `IntakeStore`'s write paths go through `journal.set`, which runs a full
/// forced `analyzeRecent` in a HOSTED bundle sharing the live app's UserDefaults (the
/// `WeedProjectionTests` finding) — so the decisions are pinned through the pure statics and the
/// store round-trip is left to the manual verification pass.
final class IntakeTests: XCTestCase {

    /// Fixed-offset calendar so the 14:00 caffeine boundary is tested against a known wall clock
    /// rather than whatever zone the machine running CI happens to be in.
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func ts(_ day: String, hour: Int, minute: Int = 0) -> Int {
        let base = utc.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0),
                                                 year: Int(day.prefix(4)),
                                                 month: Int(day.dropFirst(5).prefix(2)),
                                                 day: Int(day.suffix(2))))!
        return Int(base.timeIntervalSince1970) + hour * 3_600 + minute * 60
    }

    // MARK: - Projection: which tag an event owes

    func testAlcoholRaisesAlcoholAtAnyHour() {
        for hour in [9, 14, 21, 23] {
            XCTAssertEqual(IntakeKind.alcohol.journalTag(at: ts("2026-05-04", hour: hour),
                                                         calendar: utc), .alcohol,
                           "a drink is a drink whatever o'clock it was")
        }
    }

    func testCaffeineRaisesLateOnlyFromTwoPM() {
        // The tag's own definition (`JournalStore.swift:13`, "Caffeine after ~14:00") — the boundary
        // is INCLUSIVE at 14:00 and nothing before it projects at all.
        XCTAssertNil(IntakeKind.caffeine.journalTag(at: ts("2026-05-04", hour: 13, minute: 59),
                                                    calendar: utc))
        XCTAssertEqual(IntakeKind.caffeine.journalTag(at: ts("2026-05-04", hour: 14),
                                                      calendar: utc), .caffeineLate)
        XCTAssertEqual(IntakeKind.caffeine.journalTag(at: ts("2026-05-04", hour: 22),
                                                      calendar: utc), .caffeineLate)
    }

    func testMealAndWaterProjectNothing() {
        // `late_meal` has no threshold anywhere in this codebase — "late" is whatever the user meant
        // when they tapped the chip — so inventing one here would restate the meaning of every past
        // tap. Water has no tag at all. 024 decision 5.
        for hour in [8, 13, 19, 23] {
            XCTAssertNil(IntakeKind.meal.journalTag(at: ts("2026-05-04", hour: hour), calendar: utc))
            XCTAssertNil(IntakeKind.water.journalTag(at: ts("2026-05-04", hour: hour), calendar: utc))
        }
    }

    // MARK: - Projection: what the launch repair owes

    func testRepairOwesOnlyTagsTheDayDoesNotAlreadyCarry() {
        let day = "2026-05-04"
        let events = [day: [IntakeEvent(id: "a", day: day, ts: ts(day, hour: 21), kind: .alcohol)]]
        // Already carried → nothing owed, so no redundant forced rescore.
        XCTAssertTrue(IntakeStore.missingTagDays(eventsByDay: events,
                                                 tagsByDay: [day: ["alcohol"]],
                                                 calendar: utc).isEmpty)
        // Missing → owed exactly once.
        let owed = IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:], calendar: utc)
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.day, day)
        XCTAssertEqual(owed.first?.tag, .alcohol)
    }

    func testRepairDedupesManyEventsOnOneDayAndOrdersOldestFirst() {
        let older = "2026-05-01", newer = "2026-05-04"
        let events = [
            newer: [IntakeEvent(id: "a", day: newer, ts: ts(newer, hour: 20), kind: .alcohol),
                    IntakeEvent(id: "b", day: newer, ts: ts(newer, hour: 22), kind: .alcohol)],
            older: [IntakeEvent(id: "c", day: older, ts: ts(older, hour: 15), kind: .caffeine)],
        ]
        let owed = IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:], calendar: utc)
        // Four drinks on one day owe ONE tag, not four — `repair` upserts the batch and runs a single
        // forced pass off the oldest, so a duplicate would cost a redundant rescore.
        XCTAssertEqual(owed.count, 2)
        XCTAssertEqual(owed[0].day, older, "oldest first: the one forced pass reaches back from it")
        XCTAssertEqual(owed[1].day, newer)
    }

    func testRepairNeverReRaisesATagTheUserCleared() {
        // THE HIGH FINDING FROM THE 024 AUDIT. `tagsByDay` holds only YES answers, so a day the user
        // explicitly cleared looks identical there to a day nobody ever answered. The heal read that
        // as "missing" and re-raised it on every launch — overwriting the user's NO and burning a
        // forced rescore each time, so the chip could never be turned off while the event existed.
        let day = "2026-05-04"
        let events = [day: [IntakeEvent(id: "a", day: day, ts: ts(day, hour: 21), kind: .alcohol)]]

        // Nobody ever answered → the heal is FOR this, and still fires.
        XCTAssertEqual(IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:],
                                                  clearedByUser: [], calendar: utc).count, 1)

        // The user turned it off → leave it alone.
        XCTAssertTrue(IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:],
                                                 clearedByUser: [day + "|alcohol"],
                                                 calendar: utc).isEmpty,
                      "the launch heal must not argue with an answer the user gave")

        // A clear on a DIFFERENT tag, or a different day, must not suppress this one.
        XCTAssertEqual(IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:],
                                                  clearedByUser: [day + "|caffeine_late",
                                                                  "2026-05-03|alcohol"],
                                                  calendar: utc).count, 1)
    }

    func testRepairIgnoresEventsThatOweNothing() {
        let day = "2026-05-04"
        let events = [day: [
            IntakeEvent(id: "m", day: day, ts: ts(day, hour: 19), kind: .meal),
            IntakeEvent(id: "w", day: day, ts: ts(day, hour: 15), kind: .water),
            IntakeEvent(id: "c", day: day, ts: ts(day, hour: 8), kind: .caffeine),
        ]]
        XCTAssertTrue(IntakeStore.missingTagDays(eventsByDay: events, tagsByDay: [:],
                                                 calendar: utc).isEmpty,
                      "a meal, a glass of water and a morning coffee owe no boolean")
    }

    // MARK: - The back-dated stamp

    func testALiveLogIsExactAndABackDatedOneIsADeclaredPlaceholder() {
        let now = Date()
        let anchor = DayKey.local(now)
        let live = IntakeStore.stamp(day: anchor, anchorKey: anchor, now: now)
        XCTAssertTrue(live.exact)
        XCTAssertEqual(live.ts, Int(now.timeIntervalSince1970))

        let backDated = IntakeStore.stamp(day: "2026-05-01", anchorKey: anchor, now: now)
        XCTAssertFalse(backDated.exact,
                       "we know the day and nothing about the clock — the placeholder must say so")
    }

    func testAnInexactEventDrawsNoTape() {
        // `tsExact == false` is the second gate on the tape, and it is not cosmetic: a 3-hour window
        // drawn around a fabricated noon would be arithmetic over a guess presented as measurement.
        let e = IntakeEvent(id: "x", day: "2026-05-04", ts: ts("2026-05-04", hour: 12),
                            tsExact: false, kind: .meal)
        XCTAssertFalse(e.supportsResponseTape)
    }

    // MARK: - Windows

    func testWindowSpansDifferPerKindAndCarryThePreRoll() {
        let day = "2026-05-04", at = ts(day, hour: 13)
        let meal = IntakeTapeBuilder.window(for: IntakeEvent(id: "m", day: day, ts: at, kind: .meal),
                                            sleepOnset: nil)
        XCTAssertEqual(meal?.start, at - IntakeTape.preRollSeconds)
        XCTAssertEqual(meal?.end, at + 3 * 3_600)
        // Caffeine's half-life is ~5 h, so a 3 h window would truncate it at about half.
        let coffee = IntakeTapeBuilder.window(
            for: IntakeEvent(id: "c", day: day, ts: at, kind: .caffeine), sleepOnset: nil)
        XCTAssertEqual(coffee?.end, at + 6 * 3_600)
    }

    func testWaterHasNoWindowAtAll() {
        // The refusal, at its root: there is no window, so there is nothing for the screen to draw
        // and it says why instead. 024 decision 11.
        XCTAssertNil(IntakeTapeBuilder.window(
            for: IntakeEvent(id: "w", day: "2026-05-04", ts: ts("2026-05-04", hour: 15), kind: .water),
            sleepOnset: nil))
        XCTAssertFalse(IntakeKind.water.hasResponseTape)
    }

    func testAlcoholWindowEndsAtSleepOnsetAndIsCappedWithoutOne() {
        let day = "2026-05-04", at = ts(day, hour: 21)
        let onset = at + 2 * 3_600

        let ended = IntakeTapeBuilder.window(
            for: IntakeEvent(id: "a", day: day, ts: at, kind: .alcohol), sleepOnset: onset)
        XCTAssertEqual(ended?.end, onset)
        XCTAssertEqual(ended?.endedAtSleepOnset, true,
                       "past onset the signal is a sleeping body's — Rest renders that properly")

        // No known onset → the cap, and NOT flagged as a sleep hand-off.
        let capped = IntakeTapeBuilder.window(
            for: IntakeEvent(id: "a", day: day, ts: at, kind: .alcohol), sleepOnset: nil)
        XCTAssertEqual(capped?.end, at + 10 * 3_600)
        XCTAssertEqual(capped?.endedAtSleepOnset, false)

        // An onset BEFORE the drink belongs to a different night and must not end this window.
        let earlier = IntakeTapeBuilder.window(
            for: IntakeEvent(id: "a", day: day, ts: at, kind: .alcohol), sleepOnset: at - 3_600)
        XCTAssertEqual(earlier?.end, at + 10 * 3_600)
        XCTAssertEqual(earlier?.endedAtSleepOnset, false)
    }

    // MARK: - Moving spans

    func testMovingSpansAreTheComplementOfTheSedentaryBouts() {
        let bouts = [SedentaryDetector.InactivityPeriod(start: 100, end: 199, durationS: 99),
                     SedentaryDetector.InactivityPeriod(start: 300, end: 399, durationS: 99)]
        let moving = IntakeTapeBuilder.movingSpans(bouts: bouts, from: 100, to: 400)
        XCTAssertEqual(moving, [200...299, 400...400])
    }

    func testNoGravityMeansNoMovingSpansRatherThanAllMoving() {
        // Absence of the motion stream is not evidence of motion. Marking the whole window as moving
        // would suppress every summary number on a technicality.
        XCTAssertTrue(IntakeTapeBuilder.movingSpans(bouts: [], from: 0, to: 1_000).isEmpty)
    }

    // MARK: - The tape

    /// A dinner with a still pre-roll, an 8-minute walk across the event, and a clean rise after.
    private func dinnerTape(sleepOnset: Int? = nil) -> IntakeTape? {
        let day = "2026-05-04", at = ts(day, hour: 19, minute: 40)
        var hr: [HRSample] = [], grav: [GravitySample] = [], skin: [SkinTempSample] = []
        for s in (-30 * 60)...(180 * 60) {
            let minute = Double(s) / 60.0
            let moving = minute >= -2 && minute <= 6
            let rise = minute < 0 ? 0 : 10 * exp(-pow((minute - 40) / 40, 2))
            let walk = moving ? 25.0 : 0
            hr.append(HRSample(ts: at + s, bpm: Int((60 + rise + walk).rounded())))
            let swing = moving ? 0.6 : 0.005
            grav.append(GravitySample(ts: at + s, x: sin(Double(s) / 1.7) * swing,
                                      y: cos(Double(s) / 2.3) * swing, z: 1 - swing * 0.2))
            skin.append(SkinTempSample(ts: at + s, raw: 826))
        }
        return IntakeTapeBuilder.build(event: IntakeEvent(id: "d", day: day, ts: at, kind: .meal),
                                       hr: hr, skinTemp: skin, rr: [], gravity: grav,
                                       family: .whoop4, sleepOnset: sleepOnset)
    }

    func testTheReferenceComesFromStillPreEventMinutesOnly() throws {
        let tape = try XCTUnwrap(dinnerTape())
        let reference = try XCTUnwrap(tape.heartRate?.reference)
        // The pre-roll sits at 60 bpm except for the two walking minutes before the meal. A
        // reference that let those in would sit high and make the meal look like it LOWERED HR.
        XCTAssertEqual(reference, 60, accuracy: 0.5)
    }

    func testThePeakExcludesMovingMinutesAndReportsWhenItLanded() throws {
        let tape = try XCTUnwrap(dinnerTape())
        let peak = try XCTUnwrap(tape.heartRate?.peak)
        // The walk hits +25 bpm and is the largest excursion in the window — the gate is what keeps
        // it out. What survives is the ~+10 bpm post-prandial arc near +40 min.
        XCTAssertLessThan(peak.delta, 15, "the kitchen walk must not become the meal's response")
        XCTAssertGreaterThan(peak.delta, 5)
        // Somewhere on the arc, well after the walk and well before the window closes.
        XCTAssertGreaterThan(peak.minute, 15)
        XCTAssertLessThan(peak.minute, 60)
    }

    func testPeakTiesResolveToTheEarliestMinute() throws {
        // HR is whole bpm, so the top of a broad arc is a PLATEAU many minutes wide — this fixture
        // makes that explicit with a flat top from +20 to +50. The screen prints the minute as "how
        // long it took to arrive", so the first minute at the extreme is the honest one; the last
        // would overstate the delay by half an hour on data this ordinary.
        let day = "2026-05-04", at = ts(day, hour: 19)
        var hr: [HRSample] = [], grav: [GravitySample] = []
        for s in (-30 * 60)...(90 * 60) {
            let minute = Double(s) / 60.0
            let elevated = minute >= 20 && minute <= 50
            hr.append(HRSample(ts: at + s, bpm: elevated ? 75 : 60))
            grav.append(GravitySample(ts: at + s, x: 0.001, y: 0.001, z: 1))
        }
        let tape = try XCTUnwrap(IntakeTapeBuilder.build(
            event: IntakeEvent(id: "d", day: day, ts: at, kind: .meal),
            hr: hr, skinTemp: [], rr: [], gravity: grav, family: .whoop4, sleepOnset: nil))
        let peak = try XCTUnwrap(tape.heartRate?.peak)
        XCTAssertEqual(peak.minute, 20)
        XCTAssertEqual(peak.delta, 15, accuracy: 0.5)
    }

    func testTheDisclosedStillMinuteCountExcludesTheWalk() throws {
        let tape = try XCTUnwrap(dinnerTape())
        // 181 post-event minutes exist (0…180); the walk covers roughly seven of them.
        XCTAssertLessThan(tape.stillMinutes, 181)
        XCTAssertGreaterThan(tape.stillMinutes, 165)
        XCTAssertFalse(tape.isEmpty)
    }

    func testTheWalkIsMarkedRatherThanRemoved() throws {
        let tape = try XCTUnwrap(dinnerTape())
        XCTAssertFalse(tape.movingSpans.isEmpty, "movement is marked, not dropped (decision 3)")
        let points = try XCTUnwrap(tape.heartRate?.points)
        XCTAssertTrue(points.contains { $0.moving }, "the moving minutes are still DRAWN")
        XCTAssertTrue(points.contains { $0.minute < 0 }, "the pre-roll is drawn too")
    }

    func testAnEmptyWindowYieldsAnEmptyTapeRatherThanZeroes() throws {
        let day = "2026-05-04", at = ts(day, hour: 19)
        let tape = try XCTUnwrap(IntakeTapeBuilder.build(
            event: IntakeEvent(id: "d", day: day, ts: at, kind: .meal),
            hr: [], skinTemp: [], rr: [], gravity: [], family: .whoop4, sleepOnset: nil))
        // The distinction the response screen's copy rests on: nothing was BANKED, which is not the
        // same claim as nothing happened.
        XCTAssertTrue(tape.isEmpty)
        XCTAssertNil(tape.heartRate)
        XCTAssertEqual(tape.stillMinutes, 0)
    }

    func testALaneWithNoStillPreRollHasNoReferenceAndNoPeak() throws {
        let day = "2026-05-04", at = ts(day, hour: 19)
        var hr: [HRSample] = [], grav: [GravitySample] = []
        for s in (-30 * 60)...(60 * 60) {
            hr.append(HRSample(ts: at + s, bpm: 70))
            // Moving for the ENTIRE window, pre-roll included.
            grav.append(GravitySample(ts: at + s, x: sin(Double(s) / 1.7) * 0.6,
                                      y: cos(Double(s) / 2.3) * 0.6, z: 0.9))
        }
        let tape = try XCTUnwrap(IntakeTapeBuilder.build(
            event: IntakeEvent(id: "d", day: day, ts: at, kind: .meal),
            hr: hr, skinTemp: [], rr: [], gravity: grav, family: .whoop4, sleepOnset: nil))
        XCTAssertNil(tape.heartRate?.reference,
                     "no still pre-roll ⇒ no reference; never the window's own mean, which would "
                     + "compare the response to itself")
        XCTAssertNil(tape.heartRate?.peak, "and with no reference there is no delta to report")
    }

    // MARK: - The demo seed's load-bearing invariant

    func testDemoSeedRaisesNoNewTags() async throws {
        // WHY THIS EXISTS. `IntakeStore.repair` raises the tag an event owes, so an alcohol event on
        // a day the demo did not already tag would add a real alcohol day to the seed — and 009's
        // weed statistics are hand-calibrated against the exact alcohol day set ("the ONLY way to
        // keep alcohol out of weed's numbers is to give both groups the same share of it"). One extra
        // alcohol day silently re-balances the demo's headline weed finding.
        //
        // `DemoSeed.intakeEventPlan` upholds this by placing alcohol and late-caffeine events only on
        // days the drawn `tagPlan` already tags. Until now nothing pinned it, while a comment in
        // DemoSeed claimed this very test did — which the 024 audit caught.
        let (store, dir) = try await Fixtures.tempStore("intake-seed-tests")
        defer { Fixtures.cleanUp(dir) }
        try await DemoSeed.seed(into: store)

        let wide = ("0000-01-01", "9999-12-31")
        let events = try await store.ingestionEvents(deviceId: StrapStore.intakeSourceId,
                                                     from: wide.0, to: wide.1)
        XCTAssertFalse(events.isEmpty, "the seed must actually plant intake events")

        let tagged = try await store.journalEntries(deviceId: DemoSeed.journalLane,
                                                    from: wide.0, to: wide.1)
        var yes: Set<String> = []
        for e in tagged where e.answeredYes { yes.insert(e.day + "|" + e.question) }

        // Exactly the check `repair` would make at launch.
        var eventsByDay: [String: [IntakeEvent]] = [:]
        for r in events { eventsByDay[r.day, default: []].append(IntakeEvent(r)) }
        var tagsByDay: [String: Set<String>] = [:]
        for key in yes {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            tagsByDay[parts[0], default: []].insert(parts[1])
        }
        let owed = IntakeStore.missingTagDays(eventsByDay: eventsByDay, tagsByDay: tagsByDay)
        XCTAssertTrue(owed.isEmpty,
                      "the seed must owe no new journal tags, or it moves 009's calibrated alcohol "
                      + "day set. Owed: \(owed.map { $0.day + "|" + $0.tag.rawValue })")

        // And the other half of the rule: morning caffeine must be present AND owe nothing, so the
        // test would fail if the plan simply stopped planting the early-coffee case.
        let morning = events.filter {
            $0.kind == IntakeKind.caffeine.rawValue
                && IntakeKind.caffeine.journalTag(at: $0.ts) == nil
        }
        XCTAssertFalse(morning.isEmpty, "the before-14:00 caffeine specimen must exist")
    }

    // MARK: - The horizon refusal

    func testTheHorizonLineIsDrivenByTheRetentionConstant() {
        let now = Date()
        let cal = Calendar.current
        func key(_ daysAgo: Int) -> String {
            DayKey.local(cal.date(byAdding: .day, value: -daysAgo, to: now)!)
        }
        // The boundary is the sweep's own: the day exactly `retentionDays` back is INSIDE.
        XCTAssertFalse(RawHorizon.hasAgedOut(dayKey: key(SampleRetention.retentionDays), now: now))
        XCTAssertTrue(RawHorizon.hasAgedOut(dayKey: key(SampleRetention.retentionDays + 1), now: now))
    }
}

/// The typical-hour band (024 wave B) — the piece whose whole design is about what it does NOT claim.
final class IntakeTypicalBandTests: XCTestCase {

    /// n days each holding the same three minutes, with the given values.
    private func days(_ values: [[Double]]) -> [[Int: Double]] {
        values.map { day in Dictionary(uniqueKeysWithValues: day.enumerated().map { ($0.offset, $0.element) }) }
    }

    func testPercentilesAreInterpolatedNotNearestRank() {
        let sorted = [10.0, 20, 30, 40, 50]
        XCTAssertEqual(IntakeTypicalBandBuilder.percentile(sorted, 0.5), 30, accuracy: 0.001)
        XCTAssertEqual(IntakeTypicalBandBuilder.percentile(sorted, 0.25), 20, accuracy: 0.001)
        // The reason for interpolating: at small n, nearest-rank collapses p25 onto the median and
        // the band would draw with no width on exactly the days it is thinnest.
        let four = [10.0, 20, 30, 40]
        XCTAssertNotEqual(IntakeTypicalBandBuilder.percentile(four, 0.25),
                          IntakeTypicalBandBuilder.percentile(four, 0.50))
    }

    func testBandNeedsEnoughDaysBeforeItIsShownAtAll() {
        let minutes = [0, 1, 2]
        let thin = IntakeTypicalBandBuilder.build(days: days([[60, 61, 62], [58, 59, 60]]),
                                                  minutes: minutes)
        XCTAssertFalse(thin.isShowable, "two days is a line through two points, not a typical hour")

        let enough = IntakeTypicalBandBuilder.build(
            days: days([[60, 61, 62], [58, 59, 60], [62, 63, 64], [59, 60, 61], [61, 62, 63]]),
            minutes: minutes)
        XCTAssertTrue(enough.isShowable)
        XCTAssertEqual(enough.coveredDays, 5)
        XCTAssertEqual(enough.points.count, 3)
    }

    func testAMinuteMostDaysAreMissingIsDroppedRatherThanDrawnThin() {
        // Six days, but minute 2 exists on only one of them — its percentiles would describe a single
        // evening while sitting inside a band labelled "typical".
        var d = days([[60, 61], [58, 59], [62, 63], [59, 60], [61, 62], [60, 61]])
        d[0][2] = 99
        let band = IntakeTypicalBandBuilder.build(days: d, minutes: [0, 1, 2])
        XCTAssertEqual(band.points.map(\.minute), [0, 1], "the one-day minute must not be drawn")
    }

    func testTheBandIsOrderedLowMedianHigh() {
        let band = IntakeTypicalBandBuilder.build(
            days: days([[50, 50], [60, 60], [70, 70], [80, 80], [90, 90]]), minutes: [0, 1])
        for p in band.points {
            XCTAssertLessThanOrEqual(p.lo, p.mid)
            XCTAssertLessThanOrEqual(p.mid, p.hi)
            XCTAssertEqual(p.days, 5, "every contributing day must be counted, per minute")
        }
    }
}

/// The Home Screen outbox (028) — the rules that keep a tap from being lost or double-counted.
final class IntakeOutboxTests: XCTestCase {

    private func entry(_ id: String, ts: Int = 1_700_000_000) -> IntakeOutbox.Pending {
        .init(id: id, kind: IntakeKind.caffeine.rawValue, ts: ts)
    }

    func testTheCapDropsOldestNotNewest() {
        // Dropping the NEWEST would discard the tap the user just made, which is the worst thing a
        // logging feature can do. Oldest-first is the only acceptable direction.
        let all = (0..<6).map { entry("e\($0)", ts: 1_700_000_000 + $0) }
        let (kept, dropped) = IntakeOutbox.capped(all, max: 4)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(kept.map(\.id), ["e2", "e3", "e4", "e5"])
    }

    func testUnderTheCapNothingIsDropped() {
        let all = (0..<3).map { entry("e\($0)") }
        let (kept, dropped) = IntakeOutbox.capped(all, max: 4)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(kept.count, 3)
    }

    func testAPendingEntryRoundTripsThroughCoding() throws {
        // The widget encodes it and the app decodes it, in two different processes and potentially
        // two different builds — so the wire shape has to survive on its own.
        let original = IntakeOutbox.Pending(id: "abc", kind: "caffeine", ts: 1_700_000_000,
                                            variant: "pill", countValue: nil,
                                            sizeOrdinal: nil, amountMg: 200)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(IntakeOutbox.Pending.self, from: data)
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.amountMg, 200)
        XCTAssertEqual(back.variant, "pill")
    }

    func testTheTapsOwnInstantDecidesItsDayNotTheDrains() {
        // THE WAVE-2 DEFECT. `drainOutbox` resolved the day with `anchorKey(days:)` at its DEFAULT
        // `now` — the DRAIN clock — so a tap at 19:30 drained after the next 04:00 rollover was filed
        // on the FOLLOWING day: the row printed its own clock under tomorrow's heading, and the
        // projection raised a tag on a day the user had not drunk, which feeds the health-monitor
        // confounders. The widget exists so the app is NOT opened, so tap-tonight-drain-tomorrow is
        // the ordinary path rather than an edge case.
        //
        // Pinned where the bug lived: the resolved day must be a function of the instant handed in.
        let cal = Calendar.current
        let tap = cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 19, minute: 30))!
        let drain = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 14, minute: 5))!

        // Empty `days` takes anchorKey's documented fallback to `logicalDayKey(now)`, which is the
        // instant-dependence under test without needing a DailyMetric fixture.
        let tapKey = Repository.anchorKey(days: [], now: tap)
        let drainKey = Repository.anchorKey(days: [], now: drain)

        XCTAssertEqual(tapKey, "2026-08-08", "a tap's day is its own instant's day")
        XCTAssertEqual(drainKey, "2026-08-09")
        XCTAssertNotEqual(tapKey, drainKey,
                          "these must straddle the rollover, or the test proves nothing")
    }

    func testTheOutboxLaneIsStampedSoConfiguredAmountsStaySeparable() {
        // A widget-configured amount is the user's own standing declaration, but it was declared in
        // ADVANCE — so it must never be mistaken for a quantity typed at the moment of consumption.
        XCTAssertEqual(IntakeOutbox.source, "widget")
        XCTAssertNotEqual(IntakeOutbox.source, IntakeEvent.manualSource)
    }
}
