import XCTest
import GRDB
import StrapProtocol
@testable import StrapStore

private func tempStore() async throws -> StrapStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try await StrapStore(path: dir.appendingPathComponent("s.sqlite").path)
}

final class IngestTests: XCTestCase {

    func testInsertRoundTripsEveryLane() async throws {
        let s = try await tempStore()
        let streams = Streams(
            hr: [HRSample(ts: 100, bpm: 60)],
            rr: [RRInterval(ts: 100, rrMs: 900)],
            spo2: [SpO2Sample(ts: 100, red: 10, ir: 20)],
            skinTemp: [SkinTempSample(ts: 100, raw: 830)],
            resp: [RespSample(ts: 100, raw: 44)],
            gravity: [GravitySample(ts: 100, x: 0, y: 0, z: 1)],
            steps: [StepSample(ts: 100, counter: 5, activityClass: 2)],
            sleepState: [SleepStateSample(ts: 100, state: 2)],
            ppgHr: [PpgHrSample(ts: 100, bpm: 61, conf: 0.9)],
            events: [WhoopEvent(ts: 100, kind: "TEST", payload: ["a": .int(1)])],
            battery: [BatterySample(ts: 100, soc: 55, mv: 3800, charging: true)])
        try await s.insert(streams, deviceId: "d")

        let w = (0, 1000)
        let v1 = try await s.hrSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v1, streams.hr)
        let v2 = try await s.rrIntervals(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v2, streams.rr)
        let v3 = try await s.spo2Samples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v3, streams.spo2)
        let v4 = try await s.skinTempSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v4, streams.skinTemp)
        let v5 = try await s.respSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v5, streams.resp)
        let v6 = try await s.gravitySamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v6, streams.gravity)
        let v7 = try await s.stepSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v7, streams.steps)
        let v8 = try await s.sleepStateSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v8, streams.sleepState)
        let v9 = try await s.ppgHrSamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v9, streams.ppgHr)
        let v10 = try await s.batterySamples(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(v10, streams.battery)
        let ev = try await s.events(deviceId: "d", from: w.0, to: w.1)
        XCTAssertEqual(ev.first?.kind, "TEST")
        XCTAssertEqual(ev.first?.payload["a"]?.intValue, 1)
    }

    func testReinsertingTheSameChunkIsIdempotent() async throws {
        // The strap re-sends overlapping ranges routinely. An upsert here would let a partial
        // re-decode overwrite rows that decoded cleanly the first time.
        let s = try await tempStore()
        let streams = Streams(hr: [HRSample(ts: 1, bpm: 60), HRSample(ts: 2, bpm: 61)])
        try await s.insert(streams, deviceId: "d")
        try await s.insert(Streams(hr: [HRSample(ts: 1, bpm: 99)]), deviceId: "d")
        let hr = try await s.hrSamples(deviceId: "d", from: 0, to: 10)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr.first?.bpm, 60, "the first decode wins")
    }

    func testDevicesAreIsolated() async throws {
        let s = try await tempStore()
        try await s.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "a")
        try await s.insert(Streams(hr: [HRSample(ts: 1, bpm: 70)]), deviceId: "b")
        let v11 = try await s.hrSamples(deviceId: "a", from: 0, to: 10).first?.bpm
        XCTAssertEqual(v11, 60)
        let v12 = try await s.hrSamples(deviceId: "b", from: 0, to: 10).first?.bpm
        XCTAssertEqual(v12, 70)
    }

    func testEmptyStreamsIsANoOp() async throws {
        let s = try await tempStore()
        try await s.insert(Streams(), deviceId: "d")
        let v13 = try await s.hrSamples(deviceId: "d", from: 0, to: 10).isEmpty
        XCTAssertTrue(v13)
    }

    func testRangeReadsAreInclusiveAndOrdered() async throws {
        let s = try await tempStore()
        try await s.insert(Streams(hr: (1...5).map { HRSample(ts: $0, bpm: 60 + $0) }), deviceId: "d")
        let hr = try await s.hrSamples(deviceId: "d", from: 2, to: 4)
        XCTAssertEqual(hr.map(\.ts), [2, 3, 4])
    }

    func testEarliestHRSampleTs() async throws {
        let s = try await tempStore()
        let v14 = try await s.earliestHRSampleTs(deviceId: "d")
        XCTAssertNil(v14)
        try await s.insert(Streams(hr: [HRSample(ts: 500, bpm: 60), HRSample(ts: 100, bpm: 60)]), deviceId: "d")
        let v15 = try await s.earliestHRSampleTs(deviceId: "d")
        XCTAssertEqual(v15, 100)
    }
}

final class DailyMetricTests: XCTestCase {

    func testUpsertReplacesTheWholeRowSoNilClears() async throws {
        // Load-bearing: the heal sweeps remove a fabricated reading by writing the row back with
        // that one field nil. A merging upsert would preserve exactly the value they exist to
        // clear. The cost is that a caller holding a partial row must read-modify-write, and
        // every caller does.
        let s = try await tempStore()
        try await s.upsertDailyMetrics([DailyMetric(day: "2026-01-01", restingHr: 50, spo2Pct: 85)], deviceId: "d")
        try await s.upsertDailyMetrics([DailyMetric(day: "2026-01-01", restingHr: 50)], deviceId: "d")
        let got = try await s.dailyMetrics(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(got.count, 1)
        XCTAssertNil(got[0].spo2Pct, "a nil field clears the stored value")
        XCTAssertEqual(got[0].restingHr, 50)
    }

    func testUpsertOverwritesAValueThatIsActuallyPresent() async throws {
        let s = try await tempStore()
        try await s.upsertDailyMetrics([DailyMetric(day: "2026-01-01", restingHr: 50)], deviceId: "d")
        try await s.upsertDailyMetrics([DailyMetric(day: "2026-01-01", restingHr: 55)], deviceId: "d")
        let got = try await s.dailyMetrics(deviceId: "d", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(got[0].restingHr, 55)
    }

    func testEveryColumnRoundTrips() async throws {
        let s = try await tempStore()
        let d = DailyMetric(day: "2026-02-02", totalSleepMin: 400, efficiency: 0.9, deepMin: 80,
                            remMin: 90, lightMin: 230, disturbances: 4, restingHr: 48, avgHrv: 70,
                            recovery: 77, strain: 12.5, exerciseCount: 2, spo2Pct: 96,
                            skinTempDevC: -0.4, respRateBpm: 14.2, steps: 8000,
                            activeKcalEst: 500, solMin: 12, remLatencyMin: 70, wasoMin: 25)
        try await s.upsertDailyMetrics([d], deviceId: "d")
        let v16 = try await s.dailyMetrics(deviceId: "d", from: "2026-02-02", to: "2026-02-02")
        XCTAssertEqual(v16, [d])
    }

    func testDayRangeIsInclusiveAndOrdered() async throws {
        let s = try await tempStore()
        try await s.upsertDailyMetrics((1...5).map { DailyMetric(day: String(format: "2026-03-%02d", $0)) }, deviceId: "d")
        let got = try await s.dailyMetrics(deviceId: "d", from: "2026-03-02", to: "2026-03-04")
        XCTAssertEqual(got.map(\.day), ["2026-03-02", "2026-03-03", "2026-03-04"])
    }

    func testDelete() async throws {
        let s = try await tempStore()
        try await s.upsertDailyMetrics((1...3).map { DailyMetric(day: String(format: "2026-04-%02d", $0)) }, deviceId: "d")
        let n = try await s.deleteDailyMetrics(deviceId: "d", from: "2026-04-01", to: "2026-04-02")
        XCTAssertEqual(n, 2)
        let v17 = try await s.dailyMetrics(deviceId: "d", from: "2026-04-01", to: "2026-04-30").count
        XCTAssertEqual(v17, 1)
    }
}

final class MetricSeriesTests: XCTestCase {

    func testUpsertAndReadByKey() async throws {
        let s = try await tempStore()
        try await s.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "rhr", value: 50),
                                        MetricPoint(day: "2026-01-02", key: "rhr", value: 51),
                                        MetricPoint(day: "2026-01-01", key: "hrv", value: 70)], deviceId: "d")
        let rhr = try await s.metricSeries(deviceId: "d", key: "rhr", from: "2026-01-01", to: "2026-01-31")
        XCTAssertEqual(rhr.map(\.value), [50, 51])
    }

    func testUpsertReplacesAValue() async throws {
        let s = try await tempStore()
        try await s.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "rhr", value: 50)], deviceId: "d")
        try await s.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "rhr", value: 52)], deviceId: "d")
        let rhr = try await s.metricSeries(deviceId: "d", key: "rhr", from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(rhr.map(\.value), [52], "a recomputed series replaces, it does not accumulate")
    }

    func testAllSeriesGroupsByKey() async throws {
        let s = try await tempStore()
        try await s.upsertMetricSeries([MetricPoint(day: "2026-01-01", key: "rhr", value: 50),
                                        MetricPoint(day: "2026-01-01", key: "hrv", value: 70)], deviceId: "d")
        let all = try await s.allMetricSeries(deviceId: "d", from: "2026-01-01", to: "2026-01-31")
        XCTAssertEqual(Set(all.keys), ["rhr", "hrv"])
    }
}

final class SleepSessionTests: XCTestCase {

    func testUpsertAndRead() async throws {
        let s = try await tempStore()
        let night = CachedSleepSession(startTs: 1000, endTs: 2000, efficiency: 0.9, restingHr: 48)
        try await s.upsertSleepSessions([night], deviceId: "d")
        let v18 = try await s.sleepSessions(deviceId: "d", from: 0, to: 9999)
        XCTAssertEqual(v18, [night])
    }

    func testRestagingDoesNotRevertAUserEdit() async throws {
        // Re-staging runs on a schedule. Without this the user's correction would silently revert
        // the next time the engine ran, and nothing would report it.
        let s = try await tempStore()
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1000, endTs: 2000)], deviceId: "d")
        _ = try await s.applySleepEdit(deviceId: "d", detectedStartTs: 1000, newStartTs: 1100, newEndTs: 1900)
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1000, endTs: 2000)], deviceId: "d")
        let got = try await s.sleepSessions(deviceId: "d", from: 0, to: 9999)
        XCTAssertTrue(got[0].userEdited)
        XCTAssertEqual(got[0].startTsAdjusted, 1100)
        XCTAssertEqual(got[0].effectiveStartTs, 1100)
        XCTAssertEqual(got[0].startTs, 1000, "the detected boundary is kept so the edit is reversible")
    }

    func testLowConfidenceSurvivesTheRoundTrip() async throws {
        let s = try await tempStore()
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1, endTs: 2, lowConfidence: true)], deviceId: "d")
        let v19 = try await s.sleepSessions(deviceId: "d", from: 0, to: 9).first!.lowConfidence
        XCTAssertTrue(v19)
    }

    func testStagesAreNotClearedByALaterWriteThatHasNone() async throws {
        let s = try await tempStore()
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1, endTs: 2, stagesJSON: "[]")], deviceId: "d")
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1, endTs: 2)], deviceId: "d")
        let v20 = try await s.sleepSessions(deviceId: "d", from: 0, to: 9).first?.stagesJSON
        XCTAssertEqual(v20, "[]")
    }

    func testDelete() async throws {
        let s = try await tempStore()
        try await s.upsertSleepSessions([CachedSleepSession(startTs: 1, endTs: 2)], deviceId: "d")
        let v21 = try await s.deleteSleepSession(deviceId: "d", startTs: 1)
        XCTAssertEqual(v21, 1)
        let v22 = try await s.sleepSessions(deviceId: "d", from: 0, to: 9).isEmpty
        XCTAssertTrue(v22)
    }
}

final class CursorAndMaintenanceTests: XCTestCase {

    func testCursorsRoundTrip() async throws {
        let s = try await tempStore()
        let v23 = try await s.cursor("x")
        XCTAssertNil(v23)
        try await s.setCursor("x", 42)
        let v24 = try await s.cursor("x")
        XCTAssertEqual(v24, 42)
        try await s.setCursor("x", 43)
        let v25 = try await s.cursor("x")
        XCTAssertEqual(v25, 43)
    }

    func testHighwatersAreNamespacedApart() async throws {
        // A write highwater and a read highwater for the same stream are different facts.
        let s = try await tempStore()
        try await s.setHighwater("hr", 10)
        try await s.setReadHighwater("hr", 20)
        let v26 = try await s.highwater("hr")
        XCTAssertEqual(v26, 10)
        let v27 = try await s.readHighwater("hr")
        XCTAssertEqual(v27, 20)
    }

    func testDeleteAllDataClearsCursorsToo() async throws {
        // A highwater left past data that no longer exists makes the next sync start after the
        // gap — the wipe becomes a permanent hole.
        let s = try await tempStore()
        try await s.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "d")
        try await s.setHighwater("hr", 100)
        try await s.deleteAllData(deviceId: "d")
        let v28 = try await s.hrSamples(deviceId: "d", from: 0, to: 10).isEmpty
        XCTAssertTrue(v28)
        let v29 = try await s.highwater("hr")
        XCTAssertNil(v29)
    }

    func testUpsertDeviceKeepsKnownFieldsWhenALaterWriteOmitsThem() async throws {
        let s = try await tempStore()
        try await s.upsertDevice(id: "d", mac: "AA", name: "Strap")
        try await s.upsertDevice(id: "d", mac: nil, name: nil)
        let row = try await s.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT mac, name FROM device WHERE id = ?", arguments: ["d"])
        }
        XCTAssertEqual(row?["mac"], "AA")
        XCTAssertEqual(row?["name"], "Strap")
    }

    func testMigrationsAreRecorded() async throws {
        let s = try await tempStore()
        let v30 = try await s.appliedMigrationCountForTest()
        XCTAssertEqual(v30, 28)
    }

    func testCheckpointSucceedsOnAQuietStore() async throws {
        let s = try await tempStore()
        try await s.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "d")
        let v31 = try await s.checkpointWALComplete()
        XCTAssertTrue(v31)
    }
}
