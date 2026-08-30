import XCTest
import GRDB
import StrapProtocol
@testable import StrapStore

private func store() async throws -> StrapStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try await StrapStore(path: dir.appendingPathComponent("s.sqlite").path)
}

final class LogTests: XCTestCase {

    func testJournalUpsertReplacesAnAnswer() async throws {
        let s = try await store()
        try await s.upsertJournal([JournalEntry(day: "2026-01-01", question: "q", answeredYes: true)], deviceId: "d")
        try await s.upsertJournal([JournalEntry(day: "2026-01-01", question: "q", answeredYes: false)], deviceId: "d")
        let got = try await s.journalEntries(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(got.count, 1, "changing an answer edits it, it does not add a second row")
        XCTAssertFalse(got[0].answeredYes)
    }

    func testWorkoutNoteSurvivesARedetection() async throws {
        // Re-detection re-emits the workout from signal alone and knows nothing about the note.
        let s = try await store()
        try await s.upsertWorkouts([WorkoutRow(startTs: 10, endTs: 20, sport: "run", source: "manual", notes: "felt good")], deviceId: "d")
        try await s.upsertWorkouts([WorkoutRow(startTs: 10, endTs: 25, sport: "run", source: "auto")], deviceId: "d")
        let got = try await s.workouts(deviceId: "d", from: 0, to: 100)
        XCTAssertEqual(got[0].notes, "felt good")
        XCTAssertEqual(got[0].endTs, 25, "everything the detector does know is updated")
    }

    func testDeleteWorkoutsIsScopedToSportAndRange() async throws {
        let s = try await store()
        try await s.upsertWorkouts([WorkoutRow(startTs: 10, endTs: 20, sport: "run", source: "a"),
                                    WorkoutRow(startTs: 30, endTs: 40, sport: "bike", source: "a")], deviceId: "d")
        let v1 = try await s.deleteWorkouts(deviceId: "d", sport: "run", from: 0, to: 100)
        XCTAssertEqual(v1, 1)
        let left = try await s.workouts(deviceId: "d", from: 0, to: 100)
        XCTAssertEqual(left.map(\.sport), ["bike"])
    }

    func testAppleDailyReplacesTheWholeRow() async throws {
        // Same rule as dailyMetric: the caller owns the whole row, so a nil clears.
        let s = try await store()
        try await s.upsertAppleDaily([AppleDaily(day: "2026-01-01", steps: 100)], deviceId: "d")
        try await s.upsertAppleDaily([AppleDaily(day: "2026-01-01", vo2max: 50)], deviceId: "d")
        let got = try await s.appleDaily(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertNil(got[0].steps)
        XCTAssertEqual(got[0].vo2max, 50)
    }

    func testLiveSessionUpsertAndRecentOrdering() async throws {
        let s = try await store()
        for t in [10, 30, 20] {
            _ = try await s.upsertLiveSession(LiveSessionRow(startTs: t, floorBpm: 100, ceilingBpm: 140, hrSource: "whoop"), deviceId: "d")
        }
        let got = try await s.recentLiveSessions(deviceId: "d", limit: 10)
        XCTAssertEqual(got.map(\.startTs), [30, 20, 10], "newest first")
    }

    func testDeletingAHabitTakesItsLogsWithIt() async throws {
        // Orphan logs would still be counted by anything grouping by day rather than by habit.
        let s = try await store()
        try await s.upsertHabits([HabitDef(id: "h", name: "n", kind: "manual", cadence: "daily", createdAt: 0)], deviceId: "d")
        try await s.upsertHabitLogs([HabitLog(habitId: "h", day: "2026-01-01", done: true, source: "manual", stampedAt: 0)], deviceId: "d")
        _ = try await s.deleteHabit(deviceId: "d", id: "h")
        let logs = try await s.habitLogs(deviceId: "d", from: "2026-01-01", to: "2026-12-31")
        XCTAssertTrue(logs.isEmpty)
    }

    func testLabMarkersDedupeOnTheNaturalKeyNotTheRowId() async throws {
        // Re-importing the same panel generates fresh ids; keying on those files a duplicate of
        // every result each time.
        let s = try await store()
        let a = LabMarkerRow(id: "id-1", deviceId: "d", markerKey: "ferritin", category: "blood",
                             day: "2026-01-01", takenAt: 1000, value: 50, unit: "ng/mL", source: "import")
        var b = a; b.id = "id-2"; b.value = 55
        try await s.upsertLabMarkers([a])
        try await s.upsertLabMarkers([b])
        let got = try await s.labMarkers(deviceId: "d", markerKey: "ferritin")
        XCTAssertEqual(got.count, 1, "the same result re-imported is one row")
        XCTAssertEqual(got[0].value, 55)
    }

    func testMarkerKeysPresent() async throws {
        let s = try await store()
        try await s.upsertLabMarkers([LabMarkerRow(id: "1", deviceId: "d", markerKey: "b12", category: "blood",
                                                   day: "2026-01-01", takenAt: 1, unit: "x", source: "s")])
        let v2 = try await s.markerKeysPresent(deviceId: "d")
        XCTAssertEqual(v2, ["b12"])
    }
}

final class IntakeStoreTests: XCTestCase {

    func testTsExactRoundTrips() async throws {
        // A back-dated entry has a day but no real moment. Drawing a tape around a placeholder
        // minute would present an invented time as a recorded one.
        let s = try await store()
        try await s.upsertIngestionEvents([
            IngestionEventRow(id: "1", deviceId: "d", day: "2026-01-01", ts: 100, tsExact: false,
                              kind: "meal", source: "manual", createdAt: 0)])
        let got = try await s.ingestionEvents(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertFalse(got[0].tsExact)
    }

    func testDeleteBySourceLeavesTheUsersOwnEntries() async throws {
        let s = try await store()
        try await s.upsertIngestionEvents([
            IngestionEventRow(id: "1", deviceId: "d", day: "2026-01-01", ts: 1, tsExact: true, kind: "meal", source: "demo", createdAt: 0),
            IngestionEventRow(id: "2", deviceId: "d", day: "2026-01-01", ts: 2, tsExact: true, kind: "meal", source: "manual", createdAt: 0)])
        let v3 = try await s.deleteIngestionEvents(deviceId: "d", source: "demo")
        XCTAssertEqual(v3, 1)
        let left = try await s.ingestionEvents(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(left.map(\.source), ["manual"])
    }

    func testWeedSessionDaysAreDistinctDaysNotSessionCounts() async throws {
        let s = try await store()
        try await s.upsertWeedSessions([
            WeedSessionRow(id: "1", deviceId: "d", day: "2026-01-01", ts: 1, tsExact: true, source: "wm-weed", createdAt: 0),
            WeedSessionRow(id: "2", deviceId: "d", day: "2026-01-01", ts: 2, tsExact: true, source: "wm-weed", createdAt: 0),
            WeedSessionRow(id: "3", deviceId: "d", day: "2026-01-03", ts: 3, tsExact: true, source: "wm-weed", createdAt: 0)])
        let v4 = try await s.weedSessionDays(deviceId: "d")
        XCTAssertEqual(v4, ["2026-01-01", "2026-01-03"])
    }

    func testLatestWeedSession() async throws {
        let s = try await store()
        try await s.upsertWeedSessions([
            WeedSessionRow(id: "1", deviceId: "d", day: "2026-01-01", ts: 10, tsExact: true, source: "s", createdAt: 0),
            WeedSessionRow(id: "2", deviceId: "d", day: "2026-01-02", ts: 99, tsExact: true, source: "s", createdAt: 0)])
        let v5 = try await s.latestWeedSession(deviceId: "d")?.id
        XCTAssertEqual(v5, "2")
    }
}

final class RawOutboxTests: XCTestCase {

    func testFramesRoundTripThroughPackAndCompress() async throws {
        let s = try await store()
        let frames: [[UInt8]] = [[1, 2, 3], [], [4, 5, 6, 7, 8]]
        try await s.enqueueRawBatch(RawBatchMeta(batchId: "b", deviceId: "d",
                                                 clockRef: ClockRef(device: 1, wall: 2),
                                                 capturedAt: 3, startTs: 4, endTs: 5,
                                                 frameCount: 3, byteSize: 8), frames: frames)
        let v6 = try await s.rawFrames(batchId: "b")
        XCTAssertEqual(v6, frames)
    }

    func testTruncatedBlobStillYieldsTheIntactFrames() {
        // The archive exists for records that already failed to decode once; refusing the whole
        // batch over a damaged tail throws away the part that survived.
        let packed = StrapStore.packFrames([[1, 2], [3, 4]])
        let truncated = packed.prefix(packed.count - 1)
        XCTAssertEqual(StrapStore.unpackFrames(Data(truncated)), [[1, 2]])
    }

    func testReenqueueDoesNotOverwriteAnExistingArchive() async throws {
        let s = try await store()
        let meta = RawBatchMeta(batchId: "b", deviceId: "d", clockRef: ClockRef(device: 1, wall: 2),
                                capturedAt: 3, startTs: 4, endTs: 5, frameCount: 1, byteSize: 2)
        try await s.enqueueRawBatch(meta, frames: [[1, 2]])
        try await s.enqueueRawBatch(meta, frames: [[9, 9]])
        let v7 = try await s.rawFrames(batchId: "b")
        XCTAssertEqual(v7, [[1, 2]])
    }

    func testPendingAndMarkSynced() async throws {
        let s = try await store()
        try await s.enqueueRawBatch(RawBatchMeta(batchId: "b", deviceId: "d", clockRef: ClockRef(device: 0, wall: 0),
                                                 capturedAt: 1, startTs: 0, endTs: 0, frameCount: 0, byteSize: 0), frames: [])
        let v8 = try await s.pendingRawBatches().map(\.batchId)
        XCTAssertEqual(v8, ["b"])
        try await s.markRawBatchSynced(batchId: "b", at: 99)
        let v9 = try await s.pendingRawBatches().isEmpty
        XCTAssertTrue(v9)
    }

    func testPruneDropsPastTheWindowBeforeTrimmingForSize() async throws {
        let s = try await store()
        for (i, at) in [100, 200, 5000].enumerated() {
            try await s.enqueueRawBatch(RawBatchMeta(batchId: "b\(i)", deviceId: "d",
                                                     clockRef: ClockRef(device: 0, wall: 0), capturedAt: at,
                                                     startTs: 0, endTs: 0, frameCount: 0, byteSize: 10), frames: [])
        }
        _ = try await s.pruneRaw(now: 5000, keepWindowSeconds: 1000, maxUnsyncedBytes: 1_000_000)
        let v10 = try await s.allBatchIdsForTest()
        XCTAssertEqual(v10, ["b2"], "only what is inside the window survives")
    }
}

final class DeviceRegistryTests: XCTestCase {

    private func device(_ id: String, status: DeviceStatus = .paired) -> PairedDevice {
        PairedDevice(id: id, brand: "WHOOP", model: "4.0", sourceKind: .liveBLE,
                     capabilities: [.hr, .hrv], status: status, addedAt: 0, lastSeenAt: 0)
    }

    func testAddAndReadBack() async throws {
        let r = try await store().deviceRegistry
        try r.add(device("a"))
        let all = try r.all()
        XCTAssertEqual(all.map(\.id), ["a"])
        XCTAssertEqual(all[0].capabilities, [.hr, .hrv])
    }

    func testOnlyOneDeviceIsEverActive() async throws {
        // Two active rows would make the app appear to switch straps at random between launches.
        let r = try await store().deviceRegistry
        try r.add(device("a")); try r.add(device("b"))
        try r.setActive("a")
        try r.setActive("b")
        XCTAssertEqual(try r.activeDeviceId(), "b")
        XCTAssertEqual(try r.all().filter { $0.status == .active }.count, 1)
    }

    func testNicknameSurvivesAReAdd() async throws {
        let r = try await store().deviceRegistry
        try r.add(device("a"))
        try r.rename("a", nickname: "Left wrist")
        try r.add(device("a"))
        XCTAssertEqual(try r.all()[0].nickname, "Left wrist")
        XCTAssertEqual(try r.all()[0].displayName, "Left wrist")
    }

    func testLookupByPeripheralId() async throws {
        let r = try await store().deviceRegistry
        try r.add(device("a"))
        try r.setPeripheralId("a", peripheralId: "P-1")
        XCTAssertEqual(try r.device(forPeripheralId: "P-1")?.id, "a")
        XCTAssertNil(try r.device(forPeripheralId: "nope"))
    }

    func testLockedDayOwnershipIsNotUndoneByTheResolver() async throws {
        // The resolver runs on a schedule; without the guard it quietly reverses a decision
        // someone made.
        let r = try await store().deviceRegistry
        try r.setDayOwner(day: "2026-01-01", deviceId: "a", locked: true)
        try r.setDayOwner(day: "2026-01-01", deviceId: "b", locked: false)
        XCTAssertEqual(try r.dayOwner("2026-01-01")?.deviceId, "a")
        XCTAssertEqual(try r.dayOwner("2026-01-01")?.locked, true)
    }

    func testAnExplicitDecisionStillOverridesALock() async throws {
        let r = try await store().deviceRegistry
        try r.setDayOwner(day: "2026-01-01", deviceId: "a", locked: true)
        try r.setDayOwner(day: "2026-01-01", deviceId: "b", locked: true)
        XCTAssertEqual(try r.dayOwner("2026-01-01")?.deviceId, "b")
    }
}

final class AggregateReadTests: XCTestCase {

    func testHrBucketsAverageRatherThanSample() async throws {
        // A chart that picks one sample per bucket redraws differently at a different zoom.
        let s = try await store()
        try await s.insert(Streams(hr: [HRSample(ts: 0, bpm: 60), HRSample(ts: 1, bpm: 80)]), deviceId: "d")
        let b = try await s.hrBuckets(deviceId: "d", from: 0, to: 100, bucketSeconds: 60)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].bpm, 70)
    }

    func testHrFingerprintTracksBothCountAndNewest() async throws {
        let s = try await store()
        try await s.insert(Streams(hr: [HRSample(ts: 5, bpm: 60)]), deviceId: "d")
        let f = try await s.hrFingerprint(deviceId: "d", from: 0, to: 100)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.maxTs, 5)
    }

    func testMetricKeysAndSpan() async throws {
        let s = try await store()
        try await s.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "rhr", value: 1),
                                        MetricPoint(day: "2026-01-05", key: "rhr", value: 2)], deviceId: "d")
        let v11 = try await s.metricKeys(deviceId: "d")
        XCTAssertEqual(v11, ["rhr"])
        let span = try await s.metricDays(deviceId: "d", key: "rhr")
        XCTAssertEqual(span?.earliest, "2026-01-01")
        XCTAssertEqual(span?.latest, "2026-01-05")
        let none = try await s.metricDays(deviceId: "d", key: "absent")
        XCTAssertNil(none)
    }

    func testSessionMotionAndSleepStateCaches() async throws {
        let s = try await store()
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 100, endTs: 200)], deviceId: "d")
        _ = try await s.persistSessionMotion(deviceId: "d", sessionStart: 100, motionEpochs: [0.1, 0.2])
        _ = try await s.persistSessionSleepState(deviceId: "d", sessionStart: 100, states: [0, 2])
        let v12 = try await s.sessionMotion(deviceId: "d", sessionStart: 100)
        XCTAssertEqual(v12, [0.1, 0.2])
        let v13 = try await s.sessionSleepState(deviceId: "d", sessionStart: 100)
        XCTAssertEqual(v13, [0, 2])
        let v14 = try await s.sessionMotion(deviceId: "d", sessionStart: 999)
        XCTAssertNil(v14)
    }

    func testPrimaryKeyColumnsReportInOrder() async throws {
        let s = try await store()
        let v15 = try await s.primaryKeyColumns("hrSample")
        XCTAssertEqual(v15, ["deviceId", "ts"])
    }
}
