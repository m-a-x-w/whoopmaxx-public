import Foundation
import GRDB
import StrapProtocol

// MARK: - Backup settings

/// The settings that travel inside a backup, and the rules for what is allowed to.
///
/// The whitelist is the whole point. A backup archive is opened by a build that may be older or
/// newer than the one that wrote it, so an unrestricted settings blob would let an unknown key
/// land in defaults and change behaviour nobody asked for. Only these keys move, and only at these
/// types.
public enum BackupSettings {
    public static let entryName = "settings.json"

    public enum Kind: Sendable { case int, double, string }

    /// Canonical, platform-neutral key names.
    public static let whitelist: [String: Kind] = [
        "profile.age": .int,
        "profile.sex": .string,
        "profile.weightKg": .double,
        "profile.heightCm": .double,
        "profile.waistCm": .double,
        "profile.hrMax": .int,
        "units.system": .string,
        "units.temperature": .string,
        "effort.scale": .string,
    ]

    /// Canonical key to this platform's defaults key. Identity apart from `profile.hrMax`, which
    /// is stored as an OVERRIDE — the stored value means "the user set this", distinct from a
    /// derived default, and writing it to the plain key would erase that distinction.
    public static let appleDefaultsKey: [String: String] = {
        var m = Dictionary(uniqueKeysWithValues: whitelist.keys.map { ($0, $0) })
        m["profile.hrMax"] = "profile.hrMaxOverride"
        return m
    }()

    /// Read the whitelisted settings out of defaults. Absent keys are OMITTED rather than written
    /// as zero — restoring a zero age is worse than restoring nothing.
    public static func snapshot(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, kind) in whitelist {
            let dk = appleDefaultsKey[key] ?? key
            guard defaults.object(forKey: dk) != nil else { continue }
            switch kind {
            case .int: out[key] = defaults.integer(forKey: dk)
            case .double: out[key] = defaults.double(forKey: dk)
            case .string: if let s = defaults.string(forKey: dk) { out[key] = s }
            }
        }
        return out
    }

    /// Apply a restored settings map, ignoring anything not whitelisted or of the wrong type.
    public static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (key, kind) in whitelist {
            guard let v = values[key] else { continue }
            let dk = appleDefaultsKey[key] ?? key
            switch kind {
            case .int: if let n = v as? NSNumber { defaults.set(n.intValue, forKey: dk) }
            case .double: if let n = v as? NSNumber { defaults.set(n.doubleValue, forKey: dk) }
            case .string: if let s = v as? String { defaults.set(s, forKey: dk) }
            }
        }
    }

    /// Encode the whitelisted settings, or nil when there are none.
    ///
    /// Nil rather than an empty object on purpose: the caller writes a settings entry only when
    /// this returns something, so an untouched install produces an archive with no settings file
    /// at all. An empty `{}` would be indistinguishable, on restore, from settings that were
    /// deliberately cleared.
    public static func encode(_ values: [String: Any]) -> Data? {
        let filtered = values.filter { whitelist[$0.key] != nil }
        guard !filtered.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decode, keeping only whitelisted keys. A malformed or foreign file decodes to empty rather
    /// than throwing — a restore that loses its settings is recoverable, one that refuses to
    /// finish is not.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.filter { whitelist[$0.key] != nil }
    }
}

// MARK: - Integrity

/// Checks run against a database file before it is trusted enough to swap in.
public enum DatabaseIntegrity {

    /// Run SQLite's own quick check. Returns nil when the file is sound, or the first complaint.
    public static func quickCheckFailure(atPath path: String) -> String? {
        do {
            let q = try DatabaseQueue(path: path)
            let rows = try q.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
            return verdict(fromRows: rows)
        } catch {
            return "unreadable: \(error.localizedDescription)"
        }
    }

    /// SQLite reports a healthy database as the single row "ok". Anything else — including NO rows,
    /// which is not success — is a failure, and the first line is the useful part.
    public static func verdict(fromRows rows: [String]) -> String? {
        guard let first = rows.first else { return "quick_check returned no rows" }
        if rows.count == 1 && first.caseInsensitiveCompare("ok") == .orderedSame { return nil }
        return first
    }
}

// MARK: - Sleep session reconciliation

/// Drop nights that are really the same night detected twice.
public enum SleepSessionDedup {
    /// Half an hour of shared clock is enough on its own.
    public static let minOverlapSeconds = 30 * 60
    /// Or half of the shorter session, which catches two short naps detected over one another.
    public static let minOverlapFractionOfShorter = 0.5

    static func overlapSeconds(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Int {
        max(0, min(a.endTs, b.endTs) - max(a.effectiveStartTs, b.effectiveStartTs))
    }

    public static func isDuplicate(_ a: CachedSleepSession, _ b: CachedSleepSession) -> Bool {
        let overlap = overlapSeconds(a, b)
        guard overlap > 0 else { return false }
        if overlap >= minOverlapSeconds { return true }
        let shorter = min(max(a.endTs - a.effectiveStartTs, 0), max(b.endTs - b.effectiveStartTs, 0))
        return shorter > 0 && Double(overlap) >= minOverlapFractionOfShorter * Double(shorter)
    }

    /// Keep one session per real night.
    ///
    /// Ranking decides which survives, in order: a night the USER edited always wins, then one
    /// detected in this pass, then the longer span, then the later end. A user's correction losing
    /// to a fresh detection is the failure this ordering exists to prevent — and `userEdited`
    /// sessions are never dropped even when they do overlap something kept.
    public static func dedupe(_ sessions: [CachedSleepSession], freshStarts: Set<Int> = [])
        -> (kept: [CachedSleepSession], dropped: [CachedSleepSession]) {
        guard sessions.count > 1 else { return (sessions, []) }
        func rank(_ s: CachedSleepSession) -> (Int, Int, Int, Int, Int) {
            (s.userEdited ? 1 : 0,
             freshStarts.contains(s.startTs) ? 1 : 0,
             s.endTs - s.effectiveStartTs,
             s.endTs,
             s.startTs)
        }
        let ordered = sessions.sorted { rank($0) > rank($1) }
        var kept: [CachedSleepSession] = []
        var dropped: [CachedSleepSession] = []
        for s in ordered {
            if !s.userEdited, kept.contains(where: { isDuplicate($0, s) }) { dropped.append(s) }
            else { kept.append(s) }
        }
        return (kept.sorted { $0.startTs < $1.startTs }, dropped.sorted { $0.startTs < $1.startTs })
    }
}

/// Combine imported nights with locally computed ones.
public enum SleepMerge {
    /// Imported wins for any day it covers.
    ///
    /// Whole DAYS are claimed, not overlapping spans: an import is a complete record of the nights
    /// it contains, and letting a locally computed session slot in beside one would show the same
    /// night twice with two different sets of numbers.
    public static func merge(imported: [CachedSleepSession],
                             computed: [CachedSleepSession],
                             endDay: (CachedSleepSession) -> String) -> [CachedSleepSession] {
        var importedDays = Set<String>()
        var out: [CachedSleepSession] = []
        out.reserveCapacity(imported.count + computed.count)
        for s in imported { importedDays.insert(endDay(s)); out.append(s) }
        for s in computed where !importedDays.contains(endDay(s)) { out.append(s) }
        return out.sorted { $0.startTs < $1.startTs }
    }
}

/// Turn a standard Bluetooth heart-rate reading into store lanes.
public enum StandardHRMapping {
    /// A generic HRS device gives a heart rate and, optionally, R-R intervals. R-R values arrive in
    /// 1/1024 s units on that profile and are converted to milliseconds here, once, so nothing
    /// downstream has to know which radio a beat came from.
    public static func samples(fromHR hr: Int, rr: [Int], at ts: Int) -> Streams {
        Streams(hr: hr > 0 ? [HRSample(ts: ts, bpm: hr)] : [],
                rr: rr.compactMap { raw in
                    let ms = Int((Double(raw) * 1000.0 / 1024.0).rounded())
                    guard ms >= minRRIntervalMs, ms <= maxRRIntervalMs else { return nil }
                    return RRInterval(ts: ts, rrMs: ms)
                })
    }
}

// MARK: - Store odds and ends

extension StrapStore {
    /// The source id the app's own intake logging writes under.
    public static let intakeSourceId = "wm-intake"

    /// A day key in the LOCAL calendar. Every day-keyed table uses this, so a night that ends
    /// after midnight is filed by the local date the user would call it.
    public static func localDayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    @discardableResult
    public func updateSleepStages(deviceId: String, detectedStartTs: Int, stagesJSON: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE sleepSession SET stagesJSON = ? WHERE deviceId = ? AND startTs = ?",
                           arguments: [stagesJSON, deviceId, detectedStartTs])
            return db.changesCount
        }
    }

    public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try await dbQueue.read { db in
            let decodedTables = ["hrSample", "rrInterval", "gravitySample", "spo2Sample",
                                 "skinTempSample", "respSample", "stepSample", "sleepStateSample",
                                 "ppgHrSample", "battery", "event"]
            var rows = 0
            for t in decodedTables { rows += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? 0 }
            let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
            return (decodedRows: rows, rawBatches: batches, rawBytes: bytes)
        }
    }

    public func tableNames() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
    }

    public func schemaVersion() async throws -> Int {
        try await appliedMigrationCountForTest()
    }

    /// An in-memory store, for tests and for validating a candidate file before it is swapped in.
    public static func inMemory() async throws -> StrapStore {
        let q = try DatabaseQueue()
        try StoreSchema.migrator().migrate(q)
        return StrapStore(dbQueue: q)
    }
}

/// Facts about the store itself, for anything that has to describe it — a backup manifest, an
/// install report.
public enum StrapStoreInfo {
    /// The schema version, DERIVED from the migration list rather than maintained by hand.
    ///
    /// This was previously a hand-bumped literal whose convention nothing enforced, and it sat
    /// seven migrations behind the store it described. Every backup manifest written in that
    /// period understates its own schema, and the one field designed to let a restore refuse a
    /// backup it cannot safely open was reporting a version that had not been true for months.
    /// Deriving it removes the possibility.
    public static var schemaVersion: Int { StoreSchema.identifiers.count }
}
