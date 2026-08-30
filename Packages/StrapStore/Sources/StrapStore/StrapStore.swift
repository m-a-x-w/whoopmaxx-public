import Foundation
import GRDB
import StrapProtocol

/// The on-device store.
///
/// An actor because the BLE collector, the backfiller and the UI all write concurrently, and SQLite
/// under WAL still serialises writers — funnelling them through one actor turns lock contention
/// into a queue instead of a thrown error under load.
public actor StrapStore {
    public nonisolated let dbQueue: any DatabaseWriter
    public let path: String

    /// Open (creating if needed) and migrate to the current schema.
    public init(path: String) async throws {
        self.path = path
        var config = Configuration()
        // WAL: a reader must not block the collector mid-sync. `busyMode` gives writers a real
        // wait instead of an immediate SQLITE_BUSY when a long read overlaps a flush.
        config.busyMode = .timeout(5)
        let queue = try DatabasePool(path: path, configuration: config)
        try StoreSchema.migrator().migrate(queue)
        self.dbQueue = queue
    }

    /// Adopt an already-open database. The restore path uses this — it has its own connection and
    /// must not have a second one opened against the same file underneath it.
    public init(dbQueue: any DatabaseWriter, path: String = "") {
        self.dbQueue = dbQueue
        self.path = path
    }

    // MARK: - Ingest

    /// Persist a decoded chunk, reporting how many rows each lane actually GAINED.
    ///
    /// Every lane is INSERT OR IGNORE against its natural key, so a re-synced or replayed chunk is
    /// idempotent — the strap re-sends overlapping ranges routinely, and an upsert here would let a
    /// partial re-decode rewrite rows that decoded cleanly.
    ///
    /// The counts are rows INSERTED, not rows offered. That difference is the whole diagnostic
    /// value: "the strap sent 900 samples and 900 were already banked" and "the strap sent 900 new
    /// samples" are the same number of frames and completely different situations, and only the
    /// first means a sync made no progress.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        guard !streams.isEmpty else { return (0, 0, 0, 0, 0, 0, 0, 0) }
        return try await dbQueue.write { db in
            var n = (hr: 0, rr: 0, events: 0, battery: 0, spo2: 0, skinTemp: 0, resp: 0, gravity: 0)
            for s in streams.hr {
                try db.execute(sql: "INSERT OR IGNORE INTO hrSample (deviceId, ts, bpm) VALUES (?,?,?)",
                               arguments: [deviceId, s.ts, s.bpm])
                n.hr += db.changesCount
            }
            for s in streams.rr {
                try db.execute(sql: "INSERT OR IGNORE INTO rrInterval (deviceId, ts, rrMs) VALUES (?,?,?)",
                               arguments: [deviceId, s.ts, s.rrMs])
                n.rr += db.changesCount
            }
            for s in streams.spo2 {
                try db.execute(sql: "INSERT OR IGNORE INTO spo2Sample (deviceId, ts, red, ir) VALUES (?,?,?,?)",
                               arguments: [deviceId, s.ts, s.red, s.ir])
                n.spo2 += db.changesCount
            }
            for s in streams.skinTemp {
                try db.execute(sql: "INSERT OR IGNORE INTO skinTempSample (deviceId, ts, raw) VALUES (?,?,?)",
                               arguments: [deviceId, s.ts, s.raw])
                n.skinTemp += db.changesCount
            }
            for s in streams.resp {
                try db.execute(sql: "INSERT OR IGNORE INTO respSample (deviceId, ts, raw) VALUES (?,?,?)",
                               arguments: [deviceId, s.ts, s.raw])
                n.resp += db.changesCount
            }
            for s in streams.gravity {
                try db.execute(sql: "INSERT OR IGNORE INTO gravitySample (deviceId, ts, x, y, z) VALUES (?,?,?,?,?)",
                               arguments: [deviceId, s.ts, s.x, s.y, s.z])
                n.gravity += db.changesCount
            }
            for s in streams.steps {
                try db.execute(sql: "INSERT OR IGNORE INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?,?,?,?)",
                               arguments: [deviceId, s.ts, s.counter, s.activityClass])
            }
            for s in streams.sleepState {
                try db.execute(sql: "INSERT OR IGNORE INTO sleepStateSample (deviceId, ts, state) VALUES (?,?,?)",
                               arguments: [deviceId, s.ts, s.state])
            }
            for s in streams.ppgHr {
                try db.execute(sql: "INSERT OR IGNORE INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?,?,?,?)",
                               arguments: [deviceId, s.ts, s.bpm, s.conf])
            }
            for s in streams.battery {
                try db.execute(sql: "INSERT OR IGNORE INTO battery (deviceId, ts, soc, mv, charging) VALUES (?,?,?,?,?)",
                               arguments: [deviceId, s.ts, s.soc, s.mv, s.charging])
                n.battery += db.changesCount
            }
            for e in streams.events {
                let payload = (try? JSONEncoder().encode(e.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                try db.execute(sql: "INSERT OR IGNORE INTO event (deviceId, ts, kind, payloadJSON) VALUES (?,?,?,?)",
                               arguments: [deviceId, e.ts, e.kind, payload])
                n.events += db.changesCount
            }
            return n
        }
    }

    // MARK: - Sample reads
    //
    // All of these are half-open on `to` being inclusive and ordered by ts, because every consumer
    // walks them as a timeline. `limit` is a guard against a pathological range, not a page size.

    private func samples<T>(_ sql: String, _ args: StatementArguments,
                            _ make: @escaping (Row) -> T) async throws -> [T] {
        try await dbQueue.read { db in try Row.fetchAll(db, sql: sql, arguments: args).map(make) }
    }

    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [HRSample] {
        try await samples("SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
    }

    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [RRInterval] {
        try await samples("SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
    }

    public func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [GravitySample] {
        try await samples("SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
    }

    public func spo2Samples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [SpO2Sample] {
        try await samples("SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
    }

    public func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [SkinTempSample] {
        try await samples("SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { SkinTempSample(ts: $0["ts"], raw: $0["raw"]) }
    }

    public func respSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [RespSample] {
        try await samples("SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { RespSample(ts: $0["ts"], raw: $0["raw"]) }
    }

    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [SleepStateSample] {
        try await samples("SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { SleepStateSample(ts: $0["ts"], state: $0["state"]) }
    }

    public func ppgHrSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [PpgHrSample] {
        try await samples("SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { PpgHrSample(ts: $0["ts"], bpm: $0["bpm"], conf: $0["conf"] ?? 1.0) }
    }

    public func stepSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [StepSample] {
        try await samples("SELECT ts, counter, activityClass FROM stepSample WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws -> [BatterySample] {
        try await samples("SELECT ts, soc, mv, charging FROM battery WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"], charging: $0["charging"]) }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int = 50_000) async throws -> [WhoopEvent] {
        try await samples("SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts BETWEEN ? AND ? ORDER BY ts LIMIT ?",
                          [deviceId, from, to, limit]) { row in
            let json: String = row["payloadJSON"] ?? "{}"
            let payload = (try? JSONDecoder().decode([String: ParsedValue].self,
                                                     from: Data(json.utf8))) ?? [:]
            return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
        }
    }

    /// The oldest heart-rate sample banked for a device. The backfiller uses it to decide how far
    /// back it still has to reach.
    public func earliestHRSampleTs(deviceId: String) async throws -> Int? {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT MIN(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    // MARK: - Cursors
    //
    // Named integers marking how far a stream has been written or read. Kept in the database
    // rather than in defaults so a restore carries them with the data — a cursor ahead of its rows
    // silently skips a re-sync of exactly the range that was lost.

    public func cursor(_ name: String) async throws -> Int? {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [name])
        }
    }

    public func setCursor(_ name: String, _ value: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO cursors (name, value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value = excluded.value",
                           arguments: [name, value])
        }
    }

    public func highwater(_ stream: String) async throws -> Int? { try await cursor("highwater:" + stream) }
    public func setHighwater(_ stream: String, _ value: Int) async throws { try await setCursor("highwater:" + stream, value) }
    public func readHighwater(_ stream: String) async throws -> Int? { try await cursor("read:" + stream) }
    public func setReadHighwater(_ stream: String, _ value: Int) async throws { try await setCursor("read:" + stream, value) }

    // MARK: - Devices

    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen) VALUES (?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = COALESCE(excluded.mac, device.mac),
                    name = COALESCE(excluded.name, device.name),
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    // MARK: - Maintenance

    /// Fold the WAL back into the main file. Called before a backup: a backup taken without this
    /// copies a database whose most recent writes live only in a sidecar file that is not in the archive.
    public func checkpointWAL() async throws {
        _ = try await checkpointWALComplete()
    }

    /// Checkpoint, reporting whether it fully drained. Returns false when a reader held it open —
    /// which means a backup taken now would be short of those pages.
    @discardableResult
    public func checkpointWALComplete() async throws -> Bool {
        try await dbQueue.writeWithoutTransaction { db in
            do {
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                return true
            } catch {
                return false
            }
        }
    }

    public func databaseFileSizeBytes() async -> Int64? {
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// Erase everything belonging to one device.
    ///
    /// Cursors are cleared alongside the rows. A highwater left pointing past data that no longer
    /// exists is how a wipe turns into a permanent hole: the next sync starts after the gap.
    public func deleteAllData(deviceId: String) async throws {
        let tables = ["hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample",
                      "gravitySample", "stepSample", "sleepStateSample", "ppgHrSample", "battery",
                      "event", "dailyMetric", "metricSeries", "sleepSession", "workout",
                      "appleDaily", "journal", "habitLog", "habit", "labMarker", "liveSession",
                      "ingestionEvent", "weedSession", "rawBatch"]
        try await dbQueue.write { db in
            for t in tables {
                try db.execute(sql: "DELETE FROM \(t) WHERE deviceId = ?", arguments: [deviceId])
            }
            try db.execute(sql: "DELETE FROM cursors")
        }
    }

    // MARK: - Test hooks

    public func appliedMigrationCountForTest() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] }
        }
    }
}
