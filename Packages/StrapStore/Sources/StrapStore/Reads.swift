import Foundation
import GRDB

// Aggregate and diagnostic reads: downsampling, series discovery, the per-session caches, and the
// shape checks the restore path uses before it trusts a recovered file.

extension StrapStore {

    /// Mean heart rate per fixed bucket.
    ///
    /// Averaged rather than sampled: a chart that picks one sample per bucket shows whichever
    /// beat happened to land on the boundary, so the same data redraws differently at a different
    /// zoom. The mean is stable under rebucketing.
    public func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket] {
        guard bucketSeconds > 0 else { return [] }
        return try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, AVG(bpm) AS mean
                FROM hrSample WHERE deviceId = ? AND ts BETWEEN ? AND ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [bucketSeconds, bucketSeconds, deviceId, from, to])
                .map { HRBucket(ts: $0["bucket"], bpm: $0["mean"]) }
        }
    }

    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    /// A cheap identity for a range of heart-rate data: how many rows and the newest timestamp.
    ///
    /// Used to decide whether anything actually changed before re-running an expensive score. Both
    /// halves are needed — a count alone misses a backfill that replaced rows without adding any.
    public func hrFingerprint(deviceId: String, from: Int, to: Int) async throws -> (count: Int, maxTs: Int) {
        try await dbQueue.read { db in
            let r = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                WHERE deviceId = ? AND ts BETWEEN ? AND ?
                """, arguments: [deviceId, from, to])
            return (count: r?["c"] ?? 0, maxTs: r?["m"] ?? 0)
        }
    }

    /// Every series key this device has data for.
    public func metricKeys(deviceId: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT key FROM metricSeries WHERE deviceId = ? ORDER BY key",
                                arguments: [deviceId])
        }
    }

    /// The span one series covers, or nil when it has no points at all.
    public func metricDays(deviceId: String, key: String) async throws -> (earliest: String, latest: String)? {
        try await dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT MIN(day) AS lo, MAX(day) AS hi FROM metricSeries WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key]),
                let lo: String = r["lo"], let hi: String = r["hi"] else { return nil }
            return (earliest: lo, latest: hi)
        }
    }

    // MARK: - Per-session caches
    //
    // Motion and the strap's own sleep state are cached ON the session rather than recomputed from
    // samples, because the stager needs them at a resolution the sample tables no longer hold once
    // older raw data is pruned.

    @discardableResult
    public func persistSessionMotion(deviceId: String, sessionStart: Int, motionEpochs: [Double]) async throws -> Int {
        let json = String(data: try JSONEncoder().encode(motionEpochs), encoding: .utf8)
        return try await dbQueue.write { db in
            try db.execute(sql: "UPDATE sleepSession SET motionJSON = ? WHERE deviceId = ? AND startTs = ?",
                           arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    public func sessionMotion(deviceId: String, sessionStart: Int) async throws -> [Double]? {
        try await dbQueue.read { db in
            guard let json: String = try Row.fetchOne(db, sql: "SELECT motionJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                                                      arguments: [deviceId, sessionStart])?["motionJSON"] else { return nil }
            return try? JSONDecoder().decode([Double].self, from: Data(json.utf8))
        }
    }

    @discardableResult
    public func persistSessionSleepState(deviceId: String, sessionStart: Int, states: [Int]) async throws -> Int {
        let json = String(data: try JSONEncoder().encode(states), encoding: .utf8)
        return try await dbQueue.write { db in
            try db.execute(sql: "UPDATE sleepSession SET sleepStateJSON = ? WHERE deviceId = ? AND startTs = ?",
                           arguments: [json, deviceId, sessionStart])
            return db.changesCount
        }
    }

    public func sessionSleepState(deviceId: String, sessionStart: Int) async throws -> [Int]? {
        try await dbQueue.read { db in
            guard let json: String = try Row.fetchOne(db, sql: "SELECT sleepStateJSON FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                                                      arguments: [deviceId, sessionStart])?["sleepStateJSON"] else { return nil }
            return try? JSONDecoder().decode([Int].self, from: Data(json.utf8))
        }
    }

    /// Insert a night the user entered by hand, marked edited from the start so no re-detection
    /// will move it.
    @discardableResult
    public func insertManualSleepSession(deviceId: String, startTs: Int, endTs: Int) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES (?,?,?,1)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET endTs = excluded.endTs, userEdited = 1
                """, arguments: [deviceId, startTs, endTs])
            return db.changesCount
        }
    }

    // MARK: - Shape checks

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .filter { ($0["pk"] as Int? ?? 0) > 0 }
                .sorted { ($0["pk"] as Int? ?? 0) < ($1["pk"] as Int? ?? 0) }
                .map { $0["name"] }
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try await dbQueue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))").map { $0["name"] as String })
        }
    }

    public func storageStats_rowCountsForTest() async throws -> [String: Int] {
        let tables = ["hrSample", "rrInterval", "gravitySample", "spo2Sample", "skinTempSample",
                      "respSample", "stepSample", "sleepStateSample", "ppgHrSample", "battery",
                      "event", "dailyMetric", "metricSeries", "sleepSession", "rawBatch"]
        return try await dbQueue.read { db in
            var out: [String: Int] = [:]
            for t in tables { out[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0 }
            return out
        }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try await dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try await dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    public func stepCountForTest() async throws -> Int {
        try await dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try await dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id])
            else { return nil }
            return (mac: r["mac"], name: r["name"])
        }
    }
}
