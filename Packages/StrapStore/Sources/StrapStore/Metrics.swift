import Foundation
import GRDB

// Day-keyed reads and writes: the computed metrics, the generic series lane, and the staged
// nights. All three are upserts rather than insert-or-ignore, because these ARE recomputed —
// re-scoring a day is expected to replace the previous answer.

extension StrapStore {

    // MARK: - Daily metrics

    private static let dailyColumns = [
        "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
        "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
        "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "solMin",
        "remLatencyMin", "wasoMin",
    ]

    public func dailyMetrics(deviceId: String, from: String, to: String) async throws -> [DailyMetric] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM dailyMetric WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY day
                """, arguments: [deviceId, from, to]).map { r in
                DailyMetric(day: r["day"], totalSleepMin: r["totalSleepMin"], efficiency: r["efficiency"],
                            deepMin: r["deepMin"], remMin: r["remMin"], lightMin: r["lightMin"],
                            disturbances: r["disturbances"], restingHr: r["restingHr"], avgHrv: r["avgHrv"],
                            recovery: r["recovery"], strain: r["strain"], exerciseCount: r["exerciseCount"],
                            spo2Pct: r["spo2Pct"], skinTempDevC: r["skinTempDevC"], respRateBpm: r["respRateBpm"],
                            steps: r["steps"], activeKcalEst: r["activeKcalEst"], solMin: r["solMin"],
                            remLatencyMin: r["remLatencyMin"], wasoMin: r["wasoMin"])
            }
        }
    }

    /// Write day rows, REPLACING every column.
    ///
    /// A nil clears the stored value. That is load-bearing rather than incidental: the heal sweeps
    /// clear a fabricated reading by writing the row back with that one field nil, and a merging
    /// upsert would silently preserve exactly the value they exist to remove. The cost is that a
    /// caller holding a partial row must read-modify-write, and every caller does.
    @discardableResult
    public func upsertDailyMetrics(_ days: [DailyMetric], deviceId: String) async throws -> Int {
        guard !days.isEmpty else { return 0 }
        let cols = Self.dailyColumns
        let assignments = cols.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        let sql = """
            INSERT INTO dailyMetric (deviceId, day, \(cols.joined(separator: ", ")))
            VALUES (?, ?, \(cols.map { _ in "?" }.joined(separator: ", ")))
            ON CONFLICT(deviceId, day) DO UPDATE SET \(assignments)
            """
        return try await dbQueue.write { db in
            for d in days {
                let values: [DatabaseValueConvertible?] = [
                    d.totalSleepMin, d.efficiency, d.deepMin, d.remMin, d.lightMin, d.disturbances,
                    d.restingHr, d.avgHrv, d.recovery, d.strain, d.exerciseCount, d.spo2Pct,
                    d.skinTempDevC, d.respRateBpm, d.steps, d.activeKcalEst, d.solMin,
                    d.remLatencyMin, d.wasoMin,
                ]
                try db.execute(sql: sql, arguments: StatementArguments([deviceId, d.day] + values))
            }
            return days.count
        }
    }

    @discardableResult
    public func deleteDailyMetrics(deviceId: String, from: String, to: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dailyMetric WHERE deviceId = ? AND day BETWEEN ? AND ?",
                           arguments: [deviceId, from, to])
            return db.changesCount
        }
    }

    // MARK: - Metric series

    public func metricSeries(deviceId: String, key: String, from: String, to: String) async throws -> [MetricPoint] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day BETWEEN ? AND ? ORDER BY day
                """, arguments: [deviceId, key, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// All series for a day range, keyed by series name. One query rather than one per key: the
    /// metric wall asks for dozens at once.
    public func allMetricSeries(deviceId: String, from: String, to: String) async throws -> [String: [MetricPoint]] {
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY key, day
                """, arguments: [deviceId, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
        return Dictionary(grouping: rows, by: \.key)
    }

    @discardableResult
    public func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for p in rows {
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?,?,?,?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                    """, arguments: [deviceId, p.day, p.key, p.value])
            }
            return rows.count
        }
    }

    // MARK: - Sleep sessions

    public func sleepSessions(deviceId: String, from: Int, to: Int, limit: Int = 10_000) async throws -> [CachedSleepSession] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM sleepSession WHERE deviceId = ? AND startTs BETWEEN ? AND ?
                ORDER BY startTs LIMIT ?
                """, arguments: [deviceId, from, to, limit]).map { r in
                CachedSleepSession(startTs: r["startTs"], endTs: r["endTs"], efficiency: r["efficiency"],
                                   restingHr: r["restingHr"], avgHrv: r["avgHrv"], stagesJSON: r["stagesJSON"],
                                   userEdited: r["userEdited"] ?? false,
                                   startTsAdjusted: r["startTsAdjusted"],
                                   lowConfidence: r["lowConfidence"] ?? false)
            }
        }
    }

    /// Write staged nights.
    ///
    /// A row the user has EDITED is never overwritten by a re-detection: `userEdited` and
    /// `startTsAdjusted` are preserved on conflict unless the incoming row is itself an edit.
    /// Re-staging runs on a schedule, so without this a user's correction would silently revert
    /// the next time the engine ran.
    @discardableResult
    public func upsertSleepSessions(_ sessions: [CachedSleepSession], deviceId: String) async throws -> Int {
        guard !sessions.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for s in sessions {
                try db.execute(sql: """
                    INSERT INTO sleepSession
                        (deviceId, startTs, endTs, efficiency, restingHr, avgHrv, stagesJSON,
                         userEdited, startTsAdjusted, lowConfidence)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, startTs) DO UPDATE SET
                        endTs = excluded.endTs,
                        efficiency = excluded.efficiency,
                        restingHr = excluded.restingHr,
                        avgHrv = excluded.avgHrv,
                        stagesJSON = COALESCE(excluded.stagesJSON, sleepSession.stagesJSON),
                        lowConfidence = excluded.lowConfidence,
                        userEdited = sleepSession.userEdited OR excluded.userEdited,
                        startTsAdjusted = COALESCE(excluded.startTsAdjusted, sleepSession.startTsAdjusted)
                    """, arguments: [deviceId, s.startTs, s.endTs, s.efficiency, s.restingHr,
                                     s.avgHrv, s.stagesJSON, s.userEdited, s.startTsAdjusted,
                                     s.lowConfidence])
            }
            return sessions.count
        }
    }

    @discardableResult
    public func deleteSleepSession(deviceId: String, startTs: Int) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                           arguments: [deviceId, startTs])
            return db.changesCount
        }
    }

    /// Record a user's manual correction to a night's boundaries.
    ///
    /// The DETECTED start stays in `startTs`; the correction lands in `startTsAdjusted`. Keeping
    /// both means the edit is reversible and a later re-detection still has its own anchor to
    /// compare against instead of drifting from an already-moved one.
    @discardableResult
    public func applySleepEdit(deviceId: String, detectedStartTs: Int,
                               newStartTs: Int, newEndTs: Int) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sleepSession SET startTsAdjusted = ?, endTs = ?, userEdited = 1
                WHERE deviceId = ? AND startTs = ?
                """, arguments: [newStartTs, newEndTs, deviceId, detectedStartTs])
            return db.changesCount
        }
    }
}
