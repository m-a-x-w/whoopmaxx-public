import XCTest
import StrapStore
@testable import whoopmaxx

/// The three Repository seams the whole dashboard reads through: the daily merge (`mergeDaily`), the
/// sleep merge (`mergeSleep`), and `refresh()`'s diff guard. Every screen sees `days` / `sleeps` only
/// after these have run, and every heavy screen keys its reloads on `refreshSeq` — so a regression in
/// any of the three is invisible until data silently disappears or the UI reloads on every idle tick.
final class RepositoryMergeTests: XCTestCase {

    // MARK: - mergeSleep (#715 + imported-over-computed per end-day)

    /// Two contracts at once. #715: a day with more than one session keeps EVERY session (the pre-fix
    /// per-day dictionary overwrote on collision and silently dropped the nap). Precedence: if ANY
    /// imported session ends on a local day, that day's computed sessions yield entirely; days no import
    /// covers keep theirs. The merge keys by the LOCAL day a session ENDS on, so the fixtures are built
    /// off `Calendar.current`'s own midnights — deterministic in any simulator zone.
    func testMergeSleepKeepsEverySessionAndLetsImportedWinPerEndDay() throws {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let midnight = Int(dayStart.timeIntervalSince1970)
        let nextMidnight = Int(try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: dayStart))
                                   .timeIntervalSince1970)

        // Day 1, imported lane: a night AND an afternoon nap. Both end on the same local day, and both
        // must come back (#715).
        let night = Fixtures.sleepSession(startTs: midnight - 3 * 3_600, endTs: midnight + 7 * 3_600)
        let nap = Fixtures.sleepSession(startTs: midnight + 14 * 3_600, endTs: midnight + 15 * 3_600)
        // Day 1, computed lane: the engine's own take on that night — the import owns the day, so it goes.
        let computedTwin = Fixtures.sleepSession(startTs: midnight + 3_600, endTs: midnight + 6 * 3_600)
        // Day 2 has no imported session at all, so the computed one stands.
        let computedOnlyDay = Fixtures.sleepSession(startTs: nextMidnight + 3_600,
                                                    endTs: nextMidnight + 7 * 3_600)

        let merged = Repository.mergeSleep(imported: [night, nap],
                                           computed: [computedTwin, computedOnlyDay])

        XCTAssertEqual(merged.map(\.startTs), [night.startTs, nap.startTs, computedOnlyDay.startTs],
                       "both imported sessions survive the shared end-day, the computed twin yields to "
                       + "them, the uncovered day keeps its computed session — sorted by start")
    }

    // MARK: - mergeDaily (field-by-field nil-fill)

    /// Imported values win FIELD BY FIELD; the computed row fills only the fields the import left nil,
    /// and whole days a lane doesn't cover pass through untouched. Every one of `DailyMetric`'s 19
    /// value fields is exercised, half from each side, so a merge that started copying whole rows (in
    /// either direction) fails here. (`HealthExportMappingTests` asserts the same rule incidentally,
    /// through the Health bridge; this is the contract itself.)
    func testMergeDailyFillsOnlyTheNilImportedFields() {
        // The import carries roughly half the fields — a raw WHOOP export with no local analysis.
        let imported = Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, deepMin: 60,
                                            disturbances: 3, avgHrv: 70, strain: 12, spo2Pct: 96,
                                            respRateBpm: 14, activeKcalEst: 500, remLatencyMin: 80)
        // The computed row carries ALL 19 with deliberately different values, so "imported won" and
        // "computed filled" can never be confused.
        let computed = Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 1, efficiency: 0.9,
                                            deepMin: 2, remMin: 90, lightMin: 250, disturbances: 4,
                                            restingHr: 52, avgHrv: 3, recovery: 61, strain: 4,
                                            exerciseCount: 2, spo2Pct: 5, skinTempDevC: 0.4,
                                            respRateBpm: 6, steps: 9_000, activeKcalEst: 7,
                                            solMin: 15, remLatencyMin: 8, wasoMin: 25)
        let computedOnlyDay = Fixtures.dailyMetric(day: "2026-07-13", recovery: 55)
        let importedOnlyDay = Fixtures.dailyMetric(day: "2026-07-15", totalSleepMin: 430)

        let merged = Repository.mergeDaily(imported: [imported, importedOnlyDay],
                                           computed: [computed, computedOnlyDay])

        XCTAssertEqual(merged.map(\.day), ["2026-07-13", "2026-07-14", "2026-07-15"], "oldest → newest")
        let m = merged[1]
        // Imported wins wherever it carries a value…
        XCTAssertEqual(m.totalSleepMin, 400)
        XCTAssertEqual(m.deepMin, 60)
        XCTAssertEqual(m.disturbances, 3)
        XCTAssertEqual(m.avgHrv, 70)
        XCTAssertEqual(m.strain, 12)
        XCTAssertEqual(m.spo2Pct, 96)
        XCTAssertEqual(m.respRateBpm, 14)
        XCTAssertEqual(m.activeKcalEst, 500)
        XCTAssertEqual(m.remLatencyMin, 80)
        // …and the computed row fills ONLY the fields the import left nil.
        XCTAssertEqual(m.efficiency, 0.9)
        XCTAssertEqual(m.remMin, 90)
        XCTAssertEqual(m.lightMin, 250)
        XCTAssertEqual(m.restingHr, 52)
        XCTAssertEqual(m.recovery, 61)
        XCTAssertEqual(m.exerciseCount, 2)
        XCTAssertEqual(m.skinTempDevC, 0.4)
        XCTAssertEqual(m.steps, 9_000)
        XCTAssertEqual(m.solMin, 15)
        XCTAssertEqual(m.wasoMin, 25)
        // Days only one lane covers survive whole.
        XCTAssertEqual(merged[0], computedOnlyDay)
        XCTAssertEqual(merged[2], importedOnlyDay)
    }

    // MARK: - refresh() diff guard

    /// A refresh that produces byte-identical caches must publish NOTHING — no `refreshSeq` bump. Heavy
    /// screens (and the auto-detector) reload off that counter, so a guard that fell through would put
    /// them on the 15-minute idle tick forever. Driven against a throwaway fixture store: the unit bundle
    /// is hosted, so the live app is running its own engine against the default DB.
    @MainActor
    func testRefreshSeqHoldsOnAByteIdenticalSecondRefresh() async throws {
        let (store, dir) = try await Fixtures.tempStore("repository-refresh")
        defer { Fixtures.cleanUp(dir) }
        let repo = Repository()
        repo.adoptStore(store)
        try await store.upsertDevice(id: repo.deviceId, mac: nil, name: "WHOOP")

        let today = Repository.localDayKey(Date())
        let yesterday = try XCTUnwrap(TodayModel.shiftKey(today, by: -1))
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: yesterday, totalSleepMin: 400, recovery: 61)],
            deviceId: repo.deviceId)

        await repo.refresh(days: 7)
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(repo.days.map(\.day), [yesterday])
        let afterFirst = repo.refreshSeq
        XCTAssertEqual(afterFirst, 1, "the first refresh always publishes (nothing was loaded before)")

        // Nothing wrote in between → same rows → same caches → no republish.
        await repo.refresh(days: 7)
        XCTAssertEqual(repo.refreshSeq, afterFirst,
                       "a refresh that changes nothing must not bump refreshSeq")

        // …and the guard is not simply always-false: a real new row still gets through.
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: today, totalSleepMin: 420, recovery: 72)],
            deviceId: repo.deviceId)
        await repo.refresh(days: 7)
        XCTAssertEqual(repo.days.map(\.day), [yesterday, today])
        XCTAssertEqual(repo.refreshSeq, afterFirst + 1, "a real change still publishes exactly once")
    }
}
