import XCTest
import StrapStore
@testable import whoopmaxx

/// The one-shot repair that follows the round-3 sleep/HRV analytics fixes.
///
/// The heal has one job the widened rescore cannot do — clear a `solMin` on a day whose raw samples are
/// gone — and one property that matters just as much: it must NOT blank `avgHrv` / `recovery` on days it
/// cannot recompute. Blanking them would erase the only record those nights have AND shrink the causal
/// Charge seed prefix (`ScoreEngine.chargeSeedSequence` folds over exactly those persisted `avgHrv`
/// values), re-creating the history-shredding defect fixed in the same round. Both halves are pinned.
final class SleepHrvHealTests: XCTestCase {

    private let deviceId = "my-whoop"
    private var computedId: String { deviceId + "-computed" }

    private var from: String { DayKey.local(Date().addingTimeInterval(-Double(SleepHrvHeal.lookbackDays) * 86_400)) }
    private var to: String { DayKey.local(Date().addingTimeInterval(86_400)) }

    private func dayKey(daysAgo n: Int) -> String {
        DayKey.local(Date().addingTimeInterval(-Double(n) * 86_400))
    }

    func testClearsStaleSolMinIncludingDaysNoRescoreCanReach() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("sleephrv-heal-sol")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: SleepHrvHeal.doneKey)

        // One inside the widened rescore's reach and one far outside every rescore window — the second
        // is the row only this sweep can clean.
        let days = [dayKey(daysAgo: 3), dayKey(daysAgo: 300)]
        try await store.upsertDailyMetrics(days.map { Fixtures.dailyMetric(day: $0, solMin: 4.5) },
                                           deviceId: computedId)

        let cleared = await SleepHrvHeal.finish(store: store, deviceId: deviceId)

        XCTAssertEqual(cleared, 2)
        for row in try await store.dailyMetrics(deviceId: computedId, from: from, to: to) {
            XCTAssertNil(row.solMin, "\(row.day) still carries a latency the strap cannot measure")
        }
    }

    func testNeverBlanksHrvOrRecoveryOnDaysItCannotRecompute() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("sleephrv-heal-keeps")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: SleepHrvHeal.doneKey)

        // A day well past the raw-retention horizon: its `avgHrv` is pre-fix and cannot be re-derived,
        // but it is still the only record of that night AND a seed-prefix marker for the Charge gate.
        let old = dayKey(daysAgo: 300)
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: old, totalSleepMin: 420,
                                                                 deepMin: 18, remMin: 92,
                                                                 restingHr: 47, avgHrv: 115.6,
                                                                 recovery: 86.7, solMin: 4.5,
                                                                 remLatencyMin: 74, wasoMin: 21)],
                                           deviceId: computedId)

        await SleepHrvHeal.finish(store: store, deviceId: deviceId)

        let healed = try await store.dailyMetrics(deviceId: computedId, from: from, to: to)
        let row = try XCTUnwrap(healed.first)
        XCTAssertNil(row.solMin)
        XCTAssertEqual(row.avgHrv, 115.6, "blanking it would shrink the causal Charge seed prefix")
        XCTAssertEqual(row.recovery, 86.7, "an unrecomputable score must not be deleted")
        // The immutable rebuild must carry every other column through untouched.
        XCTAssertEqual(row.totalSleepMin, 420)
        XCTAssertEqual(row.deepMin, 18)
        XCTAssertEqual(row.remMin, 92)
        XCTAssertEqual(row.restingHr, 47)
        XCTAssertEqual(row.remLatencyMin, 74)
        XCTAssertEqual(row.wasoMin, 21)
    }

    func testImportedLaneIsNeverTouched() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("sleephrv-heal-imported")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: SleepHrvHeal.doneKey)

        // A WHOOP cloud export lands on the RAW device id. That vendor DOES have an in-bed reference, so
        // its sleep latency is a real measurement and clearing it would be data loss.
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: dayKey(daysAgo: 3), solMin: 14)],
                                           deviceId: deviceId)

        await SleepHrvHeal.finish(store: store, deviceId: deviceId)

        let imported = try await store.dailyMetrics(deviceId: deviceId, from: from, to: to)
        XCTAssertEqual(imported.first?.solMin, 14,
                       "the sweep is scoped to the computed \"-computed\" lane")
    }

    func testSweepIsOneShot() async throws {
        let restore = snapshotFlag(); defer { restore() }
        let (store, dir) = try await Fixtures.tempStore("sleephrv-heal-oneshot")
        defer { Fixtures.cleanUp(dir) }
        UserDefaults.standard.removeObject(forKey: SleepHrvHeal.doneKey)

        XCTAssertTrue(SleepHrvHeal.isPending)
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: dayKey(daysAgo: 1), solMin: 3)],
                                           deviceId: computedId)
        let firstPass = await SleepHrvHeal.finish(store: store, deviceId: deviceId)
        XCTAssertEqual(firstPass, 1)
        XCTAssertFalse(SleepHrvHeal.isPending, "a clean pass must consume the one-shot")
        let secondPass = await SleepHrvHeal.finish(store: store, deviceId: deviceId)
        XCTAssertEqual(secondPass, 0)
    }

    // MARK: - Support

    /// Snapshot the one-shot flag and hand back the undo. The unit bundle is HOSTED — the live app shares
    /// this UserDefaults suite, so a run must never leave the heal marked done on the real device.
    private func snapshotFlag() -> () -> Void {
        let d = UserDefaults.standard
        let saved = d.object(forKey: SleepHrvHeal.doneKey)
        return {
            if let saved { d.set(saved, forKey: SleepHrvHeal.doneKey) }
            else { d.removeObject(forKey: SleepHrvHeal.doneKey) }
        }
    }
}
