import XCTest
import StrapStore
@testable import whoopmaxx

/// The one-shot repair of the FABRICATED nightly SpO2 rows the pre-fix `Spo2Estimator` persisted (it
/// clamped a sub-physiologic linearization onto 85.0 instead of rejecting it; on a real 17-night backup
/// that pinned 17 of 18 `dailyMetric` rows to exactly 85.0 — a severe-hypoxemia number the Data screen
/// showed and the Health bridge exported).
///
/// Four properties matter and each has a test: the computed lane IS cleared (including days no rescore
/// can reach), the IMPORTED lane is NOT (those are real WHOOP cloud values), the rest of the row
/// survives the rebuild, and the one-shot really is one-shot so a later legitimate estimate is safe.
final class Spo2HealTests: XCTestCase {

    private let deviceId = "my-whoop"
    private var computedId: String { deviceId + "-computed" }

    /// The whole sweep window, so a seeded day is always in range regardless of the day the suite runs.
    private var from: String { DayKey.local(Date().addingTimeInterval(-Double(Spo2Heal.lookbackDays) * 86_400)) }
    private var to: String { DayKey.local(Date().addingTimeInterval(86_400)) }

    /// A day key `n` days before today — used to seed a row far OUTSIDE `analyzeRecent`'s 21-day rescore
    /// window, which is the whole reason this sweep exists.
    private func dayKey(daysAgo n: Int) -> String {
        DayKey.local(Date().addingTimeInterval(-Double(n) * 86_400))
    }

    func testClearsFabricatedSpo2OnComputedLaneIncludingDaysNoRescoreReaches() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("spo2-heal-clear")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: Spo2Heal.doneKey)

        // Two inside `analyzeRecent(maxDays: 21)`'s reach and one far outside it — the second is the row
        // a rescore can NEVER revisit, so only this sweep can clear it.
        let days = [dayKey(daysAgo: 1), dayKey(daysAgo: 10), dayKey(daysAgo: 200)]
        try await store.upsertDailyMetrics(days.map { Fixtures.dailyMetric(day: $0, spo2Pct: 85.0) },
                                           deviceId: computedId)

        let cleared = await Spo2Heal.runIfNeeded(store: store, deviceId: deviceId)

        XCTAssertEqual(cleared, 3)
        let after = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
        XCTAssertEqual(after.count, 3)
        for row in after {
            XCTAssertNil(row.spo2Pct,
                         "the clamp-pinned 85.0 on \(row.day) must be gone — it was never a measurement")
        }
    }

    func testImportedLaneSpo2IsNeverTouched() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("spo2-heal-imported")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: Spo2Heal.doneKey)

        // A WHOOP cloud export lands on the RAW device id. That value is genuinely measured by the
        // vendor's calibrated pipeline; clearing it would be data loss, not a repair.
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: dayKey(daysAgo: 3), spo2Pct: 96.5)],
                                           deviceId: deviceId)

        await Spo2Heal.runIfNeeded(store: store, deviceId: deviceId)

        let imported = try await store.dailyMetrics(deviceId: deviceId, from: from, to: to)
        XCTAssertEqual(imported.first?.spo2Pct, 96.5,
                       "the sweep is scoped to the computed \"-computed\" lane; an imported cloud SpO2 must survive")
    }

    func testRestOfTheRowSurvivesTheRebuild() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("spo2-heal-columns")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: Spo2Heal.doneKey)

        // `DailyMetric` is immutable, so clearing one column means rebuilding all 20. A dropped field
        // here would silently nil out a scored night — pin the ones that are easiest to forget.
        let day = dayKey(daysAgo: 2)
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: day, totalSleepMin: 431,
                                                                 restingHr: 48, avgHrv: 71.5,
                                                                 recovery: 66, strain: 12.5,
                                                                 spo2Pct: 85.0, skinTempDevC: -0.3,
                                                                 respRateBpm: 14.2, steps: 8_100,
                                                                 solMin: 12, remLatencyMin: 74,
                                                                 wasoMin: 21)],
                                           deviceId: computedId)

        await Spo2Heal.runIfNeeded(store: store, deviceId: deviceId)

        let rows = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.spo2Pct)
        XCTAssertEqual(row.totalSleepMin, 431)
        XCTAssertEqual(row.restingHr, 48)
        XCTAssertEqual(row.avgHrv, 71.5)
        XCTAssertEqual(row.recovery, 66)
        XCTAssertEqual(row.strain, 12.5)
        XCTAssertEqual(row.skinTempDevC, -0.3)
        XCTAssertEqual(row.respRateBpm, 14.2)
        XCTAssertEqual(row.steps, 8_100)
        XCTAssertEqual(row.solMin, 12)
        XCTAssertEqual(row.remLatencyMin, 74)
        XCTAssertEqual(row.wasoMin, 21)
    }

    func testSweepIsOneShotSoALaterLegitimateEstimateSurvives() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("spo2-heal-oneshot")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: Spo2Heal.doneKey)
        let day = dayKey(daysAgo: 1)

        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: day, spo2Pct: 85.0)],
                                           deviceId: computedId)
        await Spo2Heal.runIfNeeded(store: store, deviceId: deviceId)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Spo2Heal.doneKey),
                      "a clean pass must consume the one-shot")

        // A strap that DOES bank a pulsatile stream would now score an honest value. The sweep must not
        // come back for it — it exists to undo the old clamp, not to ban SpO2 forever.
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: day, spo2Pct: 97.0)],
                                           deviceId: computedId)
        let cleared = await Spo2Heal.runIfNeeded(store: store, deviceId: deviceId)

        XCTAssertEqual(cleared, 0)
        let rows = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.spo2Pct, 97.0, "a post-heal legitimate estimate must survive the second launch")
    }

    // MARK: - Support

    /// Snapshot the one-shot flag and hand back the undo. The unit bundle is HOSTED — the live app
    /// shares this UserDefaults suite, so a run must never leave the heal marked done on the real device.
    private func snapshotFlag() -> () -> Void {
        let d = UserDefaults.standard
        let saved = d.object(forKey: Spo2Heal.doneKey)
        return {
            if let saved { d.set(saved, forKey: Spo2Heal.doneKey) }
            else { d.removeObject(forKey: Spo2Heal.doneKey) }
        }
    }
}
