import XCTest
import StrapStore
@testable import whoopmaxx

/// The weed session/boolean coexistence rules (009 F2).
///
/// THE INVARIANT UNDER TEST: a day is a weed day iff its merged `journal` row for "weed" is
/// `answeredYes`. Sessions are additive DETAIL — they never define weed days, they add detail to days
/// that already are. Everything the confounder and insights paths read is that boolean, so a legacy
/// chip-only day (every weed day from Jul 22 to 009) keeps working with zero sessions and nothing
/// migrates.
///
/// WHY THE STORE-BACKED CASES PRE-SEED THE BOOLEAN: `WeedStore` projects through `journal.set`, which
/// runs a full FORCED `analyzeRecent`. The unit bundle is HOSTED — the live app shares this
/// UserDefaults suite — so a test that fired a real pass would burn the engine's one-shot rescore keys
/// against the running app. Each case below is therefore staged so the projection is a NO-OP, which
/// isolates the session half of the write, and `journal.onChanged` (called by `set` and nothing else)
/// is the probe that proves no boolean write happened. The boolean DECISION itself is pinned purely
/// by the `projection` cases.
@MainActor
final class WeedProjectionTests: XCTestCase {

    // MARK: - The projection decision (pure)

    func testChipOnProjectsTrueAndChipOffProjectsFalse() {
        // One session on a day that read false → the boolean is raised.
        XCTAssertEqual(WeedStore.projection(sessionCount: 1, current: false), true)
        // Every session cleared off a day that read true → the boolean is written FALSE (an explicit
        // answeredYes=false under the native lane, never a delete — `JournalStore` type doc).
        XCTAssertEqual(WeedStore.projection(sessionCount: 0, current: true), false)
    }

    func testRemovingTheLastSessionProjectsFalseButRemovingOneOfSeveralDoesNot() {
        XCTAssertEqual(WeedStore.projection(sessionCount: 0, current: true), false)
        XCTAssertNil(WeedStore.projection(sessionCount: 2, current: true),
                     "a day that still has sessions is still a weed day — nothing to write")
    }

    func testAddingToAnAlreadyLoggedDayProjectsNothing() {
        // The gate that keeps a second session on an already-logged day from costing a redundant
        // forced rescore: `journal.set` re-runs `analyzeRecent` on EVERY call.
        XCTAssertNil(WeedStore.projection(sessionCount: 2, current: true))
        XCTAssertNil(WeedStore.projection(sessionCount: 4, current: true))
        // …and the symmetric no-op: a day with no sessions that already reads false.
        XCTAssertNil(WeedStore.projection(sessionCount: 0, current: false))
    }

    // MARK: - The launch repair (pure)

    func testRepairOnlyEverRaisesTheBoolean() {
        let sessionDays = ["2026-07-10", "2026-07-12"]
        let weedDays: Set<String> = ["2026-07-12", "2026-07-14"]
        // 07-10 has a session and no boolean → raised. 07-14 is a LEGACY chip-only day: a weed day
        // with zero sessions is consistent, and clearing it would delete real history.
        XCTAssertEqual(WeedStore.missingBooleanDays(sessionDays: sessionDays, weedDays: weedDays),
                       ["2026-07-10"])
        XCTAssertEqual(WeedStore.missingBooleanDays(sessionDays: [], weedDays: weedDays), [],
                       "a boolean-only history owes no repair at all")
    }

    func testRepairListIsAscendingSoTheOldestDayCarriesTheRescore() {
        // The oldest missing day is the one routed through `journal.set`, because its rescore reach
        // (`JournalStore.rescoreReach`) is the widest and so covers every day in the batch.
        let missing = WeedStore.missingBooleanDays(
            sessionDays: ["2026-07-12", "2026-06-30", "2026-07-01", "2026-06-30"], weedDays: [])
        XCTAssertEqual(missing, ["2026-06-30", "2026-07-01", "2026-07-12"])
    }

    // MARK: - The chip's timestamp (pure)

    func testLiveTapOnTheAnchorDayIsAnExactObservation() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let clock = WeedStore.stamp(day: "2026-07-14", anchorKey: "2026-07-14", now: now)
        XCTAssertEqual(clock.ts, Int(now.timeIntervalSince1970))
        XCTAssertTrue(clock.exact)
    }

    func testBackDatedTapDeclaresAPlaceholderClock() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let clock = WeedStore.stamp(day: "2026-07-10", anchorKey: "2026-07-14", now: now)
        XCTAssertFalse(clock.exact, "a back-dated tap knows the day and nothing about the clock")
        // The placeholder is 21:00 LOCAL on the day the chip wrote, so the row still sorts into its
        // own evening — but `exact == false` is what makes the UI say "Time not recorded" instead of
        // rendering it as an observation.
        let placeholder = Date(timeIntervalSince1970: TimeInterval(clock.ts))
        XCTAssertEqual(DayKey.local(placeholder), "2026-07-10")
        XCTAssertEqual(Calendar.current.component(.hour, from: placeholder), WeedStore.placeholderHour)
    }

    func testADayKeyWithNoLocalMidnightStillDeclaresItselfInexact() {
        // Junk, and the case that is NOT junk: in the zones whose DST springs forward at midnight
        // (Havana, Cairo, Beirut, Azores) `DayKey.date(from:)` returns nil for one valid key a year.
        // Both land here, and a guessed clock must never claim to be an observation.
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        for day in ["not-a-day", "2026-13-01", ""] {
            let clock = WeedStore.stamp(day: day, anchorKey: "2026-07-14", now: now)
            XCTAssertEqual(clock.ts, Int(now.timeIntervalSince1970), day)
            XCTAssertFalse(clock.exact, day)
        }
    }

    func testAPostMidnightTapKeepsTheChipsDayEvenThoughItsClockSaysTomorrow() throws {
        // THE reason `day` is never re-derived from `ts`. At 01:30 the anchor day is still
        // YESTERDAY (#144 04:00 rollover), so the session belongs to yesterday — while its exact
        // timestamp falls on today's local date. Deriving the key from the clock would land the
        // session and its own boolean on different days.
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 15; c.hour = 1; c.minute = 30
        let now = try XCTUnwrap(Calendar.current.date(from: c))
        let clock = WeedStore.stamp(day: "2026-07-14", anchorKey: "2026-07-14", now: now)
        XCTAssertTrue(clock.exact)
        XCTAssertEqual(DayKey.local(Date(timeIntervalSince1970: TimeInterval(clock.ts))), "2026-07-15",
                       "the clock reads tomorrow — and the session is still logged against 07-14")
    }

    // MARK: - Row round-trip

    func testSessionRoundTripsThroughItsStorageRow() {
        let session = WeedSession(id: "s1", day: "2026-07-14", ts: 1_784_000_000, tsExact: true,
                                  method: .vape, potency: .heavy, source: WeedSession.manualSource,
                                  createdAt: 1_784_000_100)
        let back = WeedSession(session.row)
        XCTAssertEqual(back, session)
        XCTAssertEqual(session.row.deviceId, StrapStore.weedSourceId, "one constant lane, always")
        XCTAssertEqual(session.row.method, "vape")
        XCTAssertEqual(session.row.potency, 3)
    }

    func testBareOneTapSessionCarriesNoFabricatedDetail() {
        let session = WeedSession(id: "s1", day: "2026-07-14", ts: 1_784_000_000)
        XCTAssertNil(session.row.method)
        XCTAssertNil(session.row.potency)
        XCTAssertFalse(session.hasRecordedDetail)
        XCTAssertEqual(WeedSession(session.row), session)
    }

    func testUnknownStoredDetailDecodesWithoutInventingAnAbsence() {
        let row = WeedSessionRow(id: "s1", deviceId: StrapStore.weedSourceId, day: "2026-07-14",
                                 ts: 1_784_000_000, tsExact: false, method: "tincture", potency: 9,
                                 source: "manual", createdAt: 1_784_000_000)
        let session = WeedSession(row)
        XCTAssertEqual(session.method, .other,
                       "a future build's method was RECORDED — decoding it as nil would fabricate an absence")
        XCTAssertNil(session.potency,
                     "an out-of-range ordinal carries no order to honour, so it reads as unrecorded")
        XCTAssertTrue(session.hasRecordedDetail)
    }

    // MARK: - Store-backed coexistence

    func testChipOnWritesOneBareSessionOnTheKeyTheChipWrote() async throws {
        let fx = try await makeStores("weed-chip-on")
        defer { Fixtures.cleanUp(fx.dir) }
        let anchor = Repository.anchorKey(days: [])
        try await seedWeedBoolean(fx, day: anchor)          // stages the projection as a no-op

        await fx.weed.setDay(anchor, on: true)

        let rows = try await fx.store.weedSessions(deviceId: StrapStore.weedSourceId,
                                                   from: anchor, to: anchor)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.day, anchor)
        XCTAssertTrue(row.tsExact, "a live tap on the anchor day is a real observation")
        XCTAssertNil(row.method)
        XCTAssertNil(row.potency)
        XCTAssertEqual(row.source, WeedSession.manualSource)
        XCTAssertEqual(fx.weed.sessions(on: anchor).count, 1)
        XCTAssertTrue(fx.weed.everLogged)
        XCTAssertFalse(fx.wroteBoolean.value, "the day already read true — nothing to project")
    }

    func testChipOnABackDatedDayWritesAPlaceholderClockOnThatDaysKey() async throws {
        let fx = try await makeStores("weed-chip-on-backdated")
        defer { Fixtures.cleanUp(fx.dir) }
        let day = try XCTUnwrap(TodayModel.shiftKey(Repository.anchorKey(days: []), by: -3))
        try await seedWeedBoolean(fx, day: day)

        await fx.weed.setDay(day, on: true)

        let rows = try await fx.store.weedSessions(deviceId: StrapStore.weedSourceId,
                                                   from: day, to: day)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.day, day, "the stored key is the one the chip wrote, verbatim")
        XCTAssertFalse(row.tsExact)
        XCTAssertEqual(Calendar.current.component(
            .hour, from: Date(timeIntervalSince1970: TimeInterval(row.ts))), WeedStore.placeholderHour)
    }

    func testChipOffClearsThatDaysSessions() async throws {
        let fx = try await makeStores("weed-chip-off")
        defer { Fixtures.cleanUp(fx.dir) }
        let day = Repository.anchorKey(days: [])
        // Sessions seeded straight into the store, boolean left absent, so the OFF tap's projection
        // is a no-op and only the deletion is under test.
        _ = try await fx.store.upsertWeedSessions([
            WeedSession(id: "a", day: day, ts: 1_784_000_000).row,
            WeedSession(id: "b", day: day, ts: 1_784_003_600).row])

        await fx.weed.setDay(day, on: false)

        let rows = try await fx.store.weedSessions(deviceId: StrapStore.weedSourceId, from: day, to: day)
        XCTAssertTrue(rows.isEmpty, "the chip going OFF clears the day's sessions")
        XCTAssertTrue(fx.weed.sessions(on: day).isEmpty)
        XCTAssertFalse(fx.wroteBoolean.value)
    }

    func testAddingToAnAlreadyLoggedDayWritesNoBoolean() async throws {
        let fx = try await makeStores("weed-add-existing")
        defer { Fixtures.cleanUp(fx.dir) }
        let day = Repository.anchorKey(days: [])
        try await seedWeedBoolean(fx, day: day)
        _ = try await fx.store.upsertWeedSessions([WeedSession(id: "a", day: day, ts: 1_784_000_000).row])
        await fx.weed.refresh()

        await fx.weed.add(WeedSession(id: "b", day: day, ts: 1_784_003_600, method: .edible))

        XCTAssertEqual(fx.weed.sessions(on: day).map(\.id), ["a", "b"], "ordered by ts")
        XCTAssertFalse(fx.wroteBoolean.value,
                       "the day already reads true — a second session must not cost a forced rescore")
        XCTAssertTrue(fx.weed.needsClearConfirmation(on: day),
                      "one session now carries a method the user typed, so clearing must ask first")
    }

    func testFourSessionsStillContributeExactlyOneWeedDay() async throws {
        let fx = try await makeStores("weed-no-double-count")
        defer { Fixtures.cleanUp(fx.dir) }
        let day = Repository.anchorKey(days: [])
        try await seedWeedBoolean(fx, day: day)
        _ = try await fx.store.upsertWeedSessions((0..<4).map {
            WeedSession(id: "s\($0)", day: day, ts: 1_784_000_000 + $0 * 3_600).row
        })
        await fx.weed.refresh()

        // `tagDays` — what `JournalInsightsModel` and the confounder path rank over — is a day SET
        // read from the journal alone. It cannot see sessions, so four of them cannot double-count.
        let tagDays = await fx.journal.tagDays(from: day, to: day)
        XCTAssertEqual(tagDays[JournalTag.weed.rawValue]?.count, 1)
        XCTAssertEqual(fx.weed.sessions(on: day).count, 4)
        XCTAssertEqual(fx.weed.weedDays, [day])
        XCTAssertFalse(fx.wroteBoolean.value)
    }

    func testLegacyBooleanOnlyDayIsAWeedDayWithZeroSessions() async throws {
        let fx = try await makeStores("weed-legacy-day")
        defer { Fixtures.cleanUp(fx.dir) }
        let day = try XCTUnwrap(TodayModel.shiftKey(Repository.anchorKey(days: []), by: -5))
        try await seedWeedBoolean(fx, day: day)

        await fx.weed.refresh()

        XCTAssertTrue(fx.weed.weedDays.contains(day), "the boolean alone makes it a weed day")
        XCTAssertTrue(fx.weed.sessions(on: day).isEmpty, "absence of detail, never a fabricated session")
        XCTAssertNil(fx.weed.latestSession)
        XCTAssertTrue(fx.weed.everLogged,
                      "a chip-only user has written no session and must not be told 'nothing logged yet'")
        let tagDays = await fx.journal.tagDays(from: day, to: day)
        XCTAssertEqual(tagDays[JournalTag.weed.rawValue], [day])
        XCTAssertFalse(fx.wroteBoolean.value, "a legacy day is consistent — the repair owes it nothing")
    }

    // MARK: - Support

    /// A `WeedStore` + `JournalStore` over one throwaway on-disk store, plus the probe that trips iff
    /// `journal.set` ran (it is `set`'s last step and nothing else calls it).
    private struct Stores {
        let weed: WeedStore
        let journal: JournalStore
        let store: StrapStore
        let dir: URL
        let wroteBoolean: Box
    }

    /// Reference cell for the `onChanged` probe — the closure escapes, so a local `var` won't do.
    private final class Box { var value = false }

    private func makeStores(_ label: String) async throws -> Stores {
        let (store, dir) = try await Fixtures.tempStore(label)
        let repo = Repository()
        repo.adoptStore(store)
        let scores = ScoreEngine(repo: repo, profile: ProfileStore(), deviceId: repo.deviceId)
        let journal = JournalStore(repo: repo, scores: scores)
        let box = Box()
        journal.onChanged = { box.value = true }
        return Stores(weed: WeedStore(repo: repo, journal: journal), journal: journal,
                      store: store, dir: dir, wroteBoolean: box)
    }

    /// Write the day's weed boolean under the native lane and load it into the chip cache, so the
    /// projection under test is a no-op (see the type doc).
    private func seedWeedBoolean(_ fx: Stores, day: String) async throws {
        _ = try await fx.store.upsertJournal(
            [JournalEntry(day: day, question: JournalTag.weed.rawValue, answeredYes: true, notes: nil)],
            deviceId: JournalStore.nativeSourceId)
        await fx.journal.refresh()
    }
}
