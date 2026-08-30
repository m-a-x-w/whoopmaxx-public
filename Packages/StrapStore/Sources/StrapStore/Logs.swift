import Foundation
import GRDB

// The user-authored lanes: journal answers, workouts, Apple Health's daily roll-up, guided live
// sessions, habits, lab markers, intake events and weed sessions.
//
// Everything here is upserted on its natural key, because these are edits — a user changing an
// answer is meant to replace the old one, not accumulate a second row beside it.

extension StrapStore {

    // MARK: - Journal

    public func journalEntries(deviceId: String, from: String, to: String) async throws -> [JournalEntry] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, question, answeredYes, notes, numericValue FROM journal
                WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY day, question
                """, arguments: [deviceId, from, to]).map {
                JournalEntry(day: $0["day"], question: $0["question"],
                             answeredYes: $0["answeredYes"], notes: $0["notes"],
                             numericValue: $0["numericValue"])
            }
        }
    }

    @discardableResult
    public func upsertJournal(_ rows: [JournalEntry], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO journal (deviceId, day, question, answeredYes, notes, numericValue)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        answeredYes = excluded.answeredYes,
                        notes = excluded.notes,
                        numericValue = excluded.numericValue
                    """, arguments: [deviceId, r.day, r.question, r.answeredYes, r.notes, r.numericValue])
            }
            return rows.count
        }
    }

    @discardableResult
    public func deleteJournal(deviceId: String, day: String, question: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM journal WHERE deviceId = ? AND day = ? AND question = ?",
                           arguments: [deviceId, day, question])
            return db.changesCount
        }
    }

    // MARK: - Workouts

    public func workouts(deviceId: String, from: Int, to: Int, limit: Int = 10_000) async throws -> [WorkoutRow] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM workout WHERE deviceId = ? AND startTs BETWEEN ? AND ?
                ORDER BY startTs LIMIT ?
                """, arguments: [deviceId, from, to, limit]).map { r in
                WorkoutRow(startTs: r["startTs"], endTs: r["endTs"], sport: r["sport"],
                           source: r["source"], durationS: r["durationS"], energyKcal: r["energyKcal"],
                           avgHr: r["avgHr"], maxHr: r["maxHr"], strain: r["strain"],
                           distanceM: r["distanceM"], zonesJSON: r["zonesJSON"], notes: r["notes"])
            }
        }
    }

    /// Write workouts.
    ///
    /// The key is (device, start, SPORT) — the same start time under a different sport is a
    /// distinct workout, not an overwrite. Two activities can genuinely share a boundary.
    ///
    /// `notes` is preserved when an incoming row has none. A re-detection re-emits the workout
    /// from signal alone and knows nothing about what the user typed on it; overwriting would
    /// throw the note away on the next scheduled pass.
    @discardableResult
    public func upsertWorkouts(_ rows: [WorkoutRow], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for w in rows {
                try db.execute(sql: """
                    INSERT INTO workout (deviceId, startTs, endTs, sport, source, durationS,
                                         energyKcal, avgHr, maxHr, strain, distanceM, zonesJSON, notes)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs, source = excluded.source,
                        durationS = excluded.durationS, energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr, maxHr = excluded.maxHr, strain = excluded.strain,
                        distanceM = excluded.distanceM, zonesJSON = excluded.zonesJSON,
                        notes = COALESCE(excluded.notes, workout.notes)
                    """, arguments: [deviceId, w.startTs, w.endTs, w.sport, w.source, w.durationS,
                                     w.energyKcal, w.avgHr, w.maxHr, w.strain, w.distanceM,
                                     w.zonesJSON, w.notes])
            }
            return rows.count
        }
    }

    @discardableResult
    public func deleteWorkouts(deviceId: String, sport: String, from: Int, to: Int) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND sport = ? AND startTs BETWEEN ? AND ?",
                           arguments: [deviceId, sport, from, to])
            return db.changesCount
        }
    }

    // MARK: - Apple Health daily

    public func appleDaily(deviceId: String, from: String, to: String) async throws -> [AppleDaily] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM appleDaily WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY day
                """, arguments: [deviceId, from, to]).map { r in
                AppleDaily(day: r["day"], steps: r["steps"], activeKcal: r["activeKcal"],
                           basalKcal: r["basalKcal"], vo2max: r["vo2max"], avgHr: r["avgHr"],
                           maxHr: r["maxHr"], walkingHr: r["walkingHr"], weightKg: r["weightKg"])
            }
        }
    }

    @discardableResult
    public func upsertAppleDaily(_ rows: [AppleDaily], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let cols = ["steps", "activeKcal", "basalKcal", "vo2max", "avgHr", "maxHr", "walkingHr", "weightKg"]
        let sets = cols.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        return try await dbQueue.write { db in
            for a in rows {
                try db.execute(sql: """
                    INSERT INTO appleDaily (deviceId, day, \(cols.joined(separator: ", ")))
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET \(sets)
                    """, arguments: [deviceId, a.day, a.steps, a.activeKcal, a.basalKcal, a.vo2max,
                                     a.avgHr, a.maxHr, a.walkingHr, a.weightKg])
            }
            return rows.count
        }
    }

    // MARK: - Live sessions

    public func recentLiveSessions(deviceId: String, limit: Int = 50) async throws -> [LiveSessionRow] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liveSession WHERE deviceId = ? ORDER BY startTs DESC LIMIT ?
                """, arguments: [deviceId, limit]).map { r in
                LiveSessionRow(startTs: r["startTs"], endTs: r["endTs"], chargeAtStart: r["chargeAtStart"],
                               floorBpm: r["floorBpm"], ceilingBpm: r["ceilingBpm"],
                               inBandSec: r["inBandSec"], belowSec: r["belowSec"], aboveSec: r["aboveSec"],
                               pushCount: r["pushCount"], easeCount: r["easeCount"], hrSource: r["hrSource"])
            }
        }
    }

    @discardableResult
    public func upsertLiveSession(_ r: LiveSessionRow, deviceId: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO liveSession (deviceId, startTs, endTs, chargeAtStart, floorBpm, ceilingBpm,
                                         inBandSec, belowSec, aboveSec, pushCount, easeCount, hrSource)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(deviceId, startTs) DO UPDATE SET
                    endTs = excluded.endTs, chargeAtStart = excluded.chargeAtStart,
                    floorBpm = excluded.floorBpm, ceilingBpm = excluded.ceilingBpm,
                    inBandSec = excluded.inBandSec, belowSec = excluded.belowSec,
                    aboveSec = excluded.aboveSec, pushCount = excluded.pushCount,
                    easeCount = excluded.easeCount, hrSource = excluded.hrSource
                """, arguments: [deviceId, r.startTs, r.endTs, r.chargeAtStart, r.floorBpm,
                                 r.ceilingBpm, r.inBandSec, r.belowSec, r.aboveSec,
                                 r.pushCount, r.easeCount, r.hrSource])
            return db.changesCount
        }
    }

    // MARK: - Habits

    /// Habit definitions, unarchived first and in the user's own order.
    public func habits(deviceId: String) async throws -> [HabitDef] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM habit WHERE deviceId = ? ORDER BY archived, sortOrder, createdAt
                """, arguments: [deviceId]).map { r in
                HabitDef(id: r["id"], name: r["name"], kind: r["kind"], cadence: r["cadence"],
                         cadenceN: r["cadenceN"], weekdaysMask: r["weekdaysMask"],
                         targetMinutes: r["targetMinutes"], buzzEnabled: r["buzzEnabled"] ?? false,
                         buzzWindowStart: r["buzzWindowStart"], buzzWindowEnd: r["buzzWindowEnd"],
                         pinned: r["pinned"] ?? true, sortOrder: r["sortOrder"] ?? 0,
                         archived: r["archived"] ?? false, createdAt: r["createdAt"])
            }
        }
    }

    @discardableResult
    public func upsertHabits(_ rows: [HabitDef], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for h in rows {
                try db.execute(sql: """
                    INSERT INTO habit (deviceId, id, name, kind, cadence, cadenceN, weekdaysMask,
                                       targetMinutes, buzzEnabled, buzzWindowStart, buzzWindowEnd,
                                       pinned, sortOrder, archived, createdAt)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, id) DO UPDATE SET
                        name = excluded.name, kind = excluded.kind, cadence = excluded.cadence,
                        cadenceN = excluded.cadenceN, weekdaysMask = excluded.weekdaysMask,
                        targetMinutes = excluded.targetMinutes, buzzEnabled = excluded.buzzEnabled,
                        buzzWindowStart = excluded.buzzWindowStart, buzzWindowEnd = excluded.buzzWindowEnd,
                        pinned = excluded.pinned, sortOrder = excluded.sortOrder,
                        archived = excluded.archived
                    """, arguments: [deviceId, h.id, h.name, h.kind, h.cadence, h.cadenceN,
                                     h.weekdaysMask, h.targetMinutes, h.buzzEnabled,
                                     h.buzzWindowStart, h.buzzWindowEnd, h.pinned, h.sortOrder,
                                     h.archived, h.createdAt])
            }
            return rows.count
        }
    }

    /// Delete a habit and every log it owns.
    ///
    /// The logs go with it deliberately: orphaned rows keyed to a habit that no longer exists
    /// would still be counted by any query that groups by day rather than by habit.
    @discardableResult
    public func deleteHabit(deviceId: String, id: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM habitLog WHERE deviceId = ? AND habitId = ?", arguments: [deviceId, id])
            try db.execute(sql: "DELETE FROM habit WHERE deviceId = ? AND id = ?", arguments: [deviceId, id])
            return db.changesCount
        }
    }

    public func habitLogs(deviceId: String, from: String, to: String) async throws -> [HabitLog] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT habitId, day, done, source, value, stampedAt FROM habitLog
                WHERE deviceId = ? AND day BETWEEN ? AND ? ORDER BY day
                """, arguments: [deviceId, from, to]).map {
                HabitLog(habitId: $0["habitId"], day: $0["day"], done: $0["done"],
                         source: $0["source"], value: $0["value"], stampedAt: $0["stampedAt"])
            }
        }
    }

    @discardableResult
    public func upsertHabitLogs(_ rows: [HabitLog], deviceId: String) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for l in rows {
                try db.execute(sql: """
                    INSERT INTO habitLog (deviceId, habitId, day, done, source, value, stampedAt)
                    VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, habitId, day) DO UPDATE SET
                        done = excluded.done, source = excluded.source,
                        value = excluded.value, stampedAt = excluded.stampedAt
                    """, arguments: [deviceId, l.habitId, l.day, l.done, l.source, l.value, l.stampedAt])
            }
            return rows.count
        }
    }

    @discardableResult
    public func deleteHabitLog(deviceId: String, habitId: String, day: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM habitLog WHERE deviceId = ? AND habitId = ? AND day = ?",
                           arguments: [deviceId, habitId, day])
            return db.changesCount
        }
    }

    // MARK: - Lab markers

    public func labMarkers(deviceId: String, category: String) async throws -> [LabMarkerRow] {
        try await labMarkers(deviceId: deviceId, column: "category", value: category)
    }

    public func labMarkers(deviceId: String, markerKey: String) async throws -> [LabMarkerRow] {
        try await labMarkers(deviceId: deviceId, column: "markerKey", value: markerKey)
    }

    private func labMarkers(deviceId: String, column: String, value: String) async throws -> [LabMarkerRow] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM labMarker WHERE deviceId = ? AND \(column) = ? ORDER BY takenAt DESC
                """, arguments: [deviceId, value]).map { r in
                LabMarkerRow(id: r["id"], deviceId: r["deviceId"], markerKey: r["markerKey"],
                             category: r["category"], day: r["day"], takenAt: r["takenAt"],
                             value: r["value"], valueText: r["valueText"], unit: r["unit"],
                             source: r["source"], note: r["note"], referenceText: r["referenceText"])
            }
        }
    }

    /// Which markers this device has any result for. Drives the picker, so an empty category never
    /// gets offered.
    public func markerKeysPresent(deviceId: String) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT markerKey FROM labMarker WHERE deviceId = ? ORDER BY markerKey",
                                arguments: [deviceId])
        }
    }

    /// Write lab results.
    ///
    /// Conflicts resolve on the NATURAL key — device, marker, time taken and source — not on the
    /// row id. Re-importing the same panel generates fresh ids, and keying on those would file a
    /// duplicate of every result each time.
    @discardableResult
    public func upsertLabMarkers(_ rows: [LabMarkerRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try await dbQueue.write { db in
            for m in rows {
                try db.execute(sql: """
                    INSERT INTO labMarker (id, deviceId, markerKey, category, day, takenAt, value,
                                           valueText, unit, source, note, referenceText)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(deviceId, markerKey, takenAt, source) DO UPDATE SET
                        category = excluded.category, day = excluded.day, value = excluded.value,
                        valueText = excluded.valueText, unit = excluded.unit,
                        note = COALESCE(excluded.note, labMarker.note),
                        referenceText = excluded.referenceText
                    """, arguments: [m.id, m.deviceId, m.markerKey, m.category, m.day, m.takenAt,
                                     m.value, m.valueText, m.unit, m.source, m.note, m.referenceText])
            }
            return rows.count
        }
    }

    public func deleteLabMarker(id: String) async throws -> Bool {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM labMarker WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
