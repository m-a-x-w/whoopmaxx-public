import Foundation
import GRDB

// Timestamped intake: meals, caffeine, alcohol, water, and weed sessions.
//
// Both tables carry `tsExact`. A back-dated entry has a day but no real moment, and the surfaces
// that draw measured signal around a logged event must be able to tell the two apart — drawing a
// tape around a placeholder minute would present an invented time as a recorded one.

extension StrapStore {

    /// The source id the app's own weed logging writes under, so a user's taps stay
    /// distinguishable from imported or demo rows.
    public static let weedSourceId = "wm-weed"

    // MARK: - Intake events

    public func ingestionEvents(deviceId: String, from: String, to: String) async throws -> [IngestionEventRow] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM ingestionEvent WHERE deviceId = ? AND day BETWEEN ? AND ?
                ORDER BY ts
                """, arguments: [deviceId, from, to]).map(Self.ingestionRow)
        }
    }

    public func latestIngestionEvent(deviceId: String) async throws -> IngestionEventRow? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM ingestionEvent WHERE deviceId = ? ORDER BY ts DESC LIMIT 1",
                             arguments: [deviceId]).map(Self.ingestionRow)
        }
    }

    private static func ingestionRow(_ r: Row) -> IngestionEventRow {
        IngestionEventRow(id: r["id"], deviceId: r["deviceId"], day: r["day"], ts: r["ts"],
                          tsExact: r["tsExact"] ?? true, kind: r["kind"], countValue: r["countValue"],
                          sizeOrdinal: r["sizeOrdinal"], variant: r["variant"], amountMg: r["amountMg"],
                          source: r["source"], createdAt: r["createdAt"])
    }

    @discardableResult
    public func upsertIngestionEvents(_ rows: [IngestionEventRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for e in rows {
                try db.execute(sql: """
                    INSERT INTO ingestionEvent (id, deviceId, day, ts, tsExact, kind, countValue,
                                                sizeOrdinal, source, createdAt, variant, amountMg)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                        day = excluded.day, ts = excluded.ts, tsExact = excluded.tsExact,
                        kind = excluded.kind, countValue = excluded.countValue,
                        sizeOrdinal = excluded.sizeOrdinal, variant = excluded.variant,
                        amountMg = excluded.amountMg
                    """, arguments: [e.id, e.deviceId, e.day, e.ts, e.tsExact, e.kind, e.countValue,
                                     e.sizeOrdinal, e.source, e.createdAt, e.variant, e.amountMg])
            }
            return rows.count
        }
    }

    @discardableResult
    public func deleteIngestionEvent(deviceId: String, id: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ingestionEvent WHERE deviceId = ? AND id = ?",
                           arguments: [deviceId, id])
            return db.changesCount
        }
    }

    /// Drop every event from one source — how a demo seed or a re-import is undone without
    /// touching what the user logged by hand.
    @discardableResult
    public func deleteIngestionEvents(deviceId: String, source: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ingestionEvent WHERE deviceId = ? AND source = ?",
                           arguments: [deviceId, source])
            return db.changesCount
        }
    }

    // MARK: - Weed sessions

    public func weedSessions(deviceId: String, from: String, to: String) async throws -> [WeedSessionRow] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM weedSession WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY ts
                """, arguments: [deviceId, from, to]).map(Self.weedRow)
        }
    }

    public func latestWeedSession(deviceId: String) async throws -> WeedSessionRow? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM weedSession WHERE deviceId = ? ORDER BY ts DESC LIMIT 1",
                             arguments: [deviceId]).map(Self.weedRow)
        }
    }

    /// Distinct days with at least one session. Used for run-length counts, so it is a DISTINCT
    /// over days rather than a session count — two sessions in one evening are one logged day.
    public func weedSessionDays(deviceId: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT day FROM weedSession WHERE deviceId = ? ORDER BY day",
                                arguments: [deviceId])
        }
    }

    private static func weedRow(_ r: Row) -> WeedSessionRow {
        WeedSessionRow(id: r["id"], deviceId: r["deviceId"], day: r["day"], ts: r["ts"],
                       tsExact: r["tsExact"] ?? true, method: r["method"], potency: r["potency"],
                       source: r["source"], createdAt: r["createdAt"])
    }

    @discardableResult
    public func upsertWeedSessions(_ rows: [WeedSessionRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for w in rows {
                try db.execute(sql: """
                    INSERT INTO weedSession (id, deviceId, day, ts, tsExact, method, potency, source, createdAt)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                        day = excluded.day, ts = excluded.ts, tsExact = excluded.tsExact,
                        method = excluded.method, potency = excluded.potency
                    """, arguments: [w.id, w.deviceId, w.day, w.ts, w.tsExact, w.method,
                                     w.potency, w.source, w.createdAt])
            }
            return rows.count
        }
    }

    @discardableResult
    public func deleteWeedSession(deviceId: String, id: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM weedSession WHERE deviceId = ? AND id = ?", arguments: [deviceId, id])
            return db.changesCount
        }
    }

    @discardableResult
    public func deleteWeedSessions(deviceId: String, day: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM weedSession WHERE deviceId = ? AND day = ?", arguments: [deviceId, day])
            return db.changesCount
        }
    }

    @discardableResult
    public func deleteWeedSessions(deviceId: String, source: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM weedSession WHERE deviceId = ? AND source = ?", arguments: [deviceId, source])
            return db.changesCount
        }
    }
}
