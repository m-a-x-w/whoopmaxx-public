import Foundation
import GRDB

/// The paired-device registry and the day-ownership table.
///
/// Synchronous and separate from the store actor on purpose: this is read during BLE callbacks and
/// view construction, where an await would mean the answer arrives a frame late — long enough for
/// the UI to render "no strap" and then correct itself.
public struct DeviceRegistryStore {
    let dbQueue: any DatabaseWriter
    public init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    private static func row(_ r: Row) -> PairedDevice {
        let caps = (r["capabilities"] as String? ?? "")
            .split(separator: ",").compactMap { Metric(rawValue: String($0)) }
        return PairedDevice(id: r["id"], brand: r["brand"], model: r["model"],
                            nickname: r["nickname"], peripheralId: r["peripheralId"],
                            sourceKind: SourceKind(rawValue: r["sourceKind"] ?? "") ?? .liveBLE,
                            capabilities: Set(caps),
                            status: DeviceStatus(rawValue: r["status"] ?? "") ?? .paired,
                            addedAt: r["addedAt"], lastSeenAt: r["lastSeenAt"])
    }

    public func all() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pairedDevice ORDER BY addedAt").map(Self.row)
        }
    }

    /// The device whose data the app is currently showing, or nil when nothing is adopted.
    public func activeDeviceId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = ? LIMIT 1",
                                arguments: [DeviceStatus.active.rawValue])
        }
    }

    public func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pairedDevice WHERE peripheralId = ?",
                             arguments: [peripheralId]).map(Self.row)
        }
    }

    public func add(_ d: PairedDevice) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities,
                                          status, addedAt, lastSeenAt, peripheralId)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    brand = excluded.brand, model = excluded.model,
                    sourceKind = excluded.sourceKind, capabilities = excluded.capabilities,
                    status = excluded.status, lastSeenAt = excluded.lastSeenAt,
                    nickname = COALESCE(excluded.nickname, pairedDevice.nickname),
                    peripheralId = COALESCE(excluded.peripheralId, pairedDevice.peripheralId)
                """, arguments: [d.id, d.brand, d.model, d.nickname, d.sourceKind.rawValue,
                                 d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                                 d.status.rawValue, d.addedAt, d.lastSeenAt, d.peripheralId])
        }
    }

    /// Make one device active, demoting whichever was.
    ///
    /// Both writes happen in ONE transaction. Two active devices would make `activeDeviceId`
    /// return whichever the query happened to reach first, and the app would appear to switch
    /// straps at random between launches.
    public func setActive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = ? WHERE status = ?",
                           arguments: [DeviceStatus.paired.rawValue, DeviceStatus.active.rawValue])
            try db.execute(sql: "UPDATE pairedDevice SET status = ? WHERE id = ?",
                           arguments: [DeviceStatus.active.rawValue, id])
        }
    }

    public func archive(_ id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = ? WHERE id = ?",
                           arguments: [DeviceStatus.archived.rawValue, id])
        }
    }

    public func rename(_ id: String, nickname: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    public func setPeripheralId(_ id: String, peripheralId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = ?",
                           arguments: [peripheralId, id])
        }
    }

    // MARK: - Day ownership

    public func dayOwner(_ day: String) throws -> DayOwner? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?",
                             arguments: [day]).map { DayOwner(deviceId: $0["deviceId"], locked: $0["locked"] ?? false) }
        }
    }

    /// Assign a day's owner.
    ///
    /// A LOCKED day is not overwritten by an unlocked write. Locked means someone decided — an
    /// import-overlap resolution or the user picking — and the resolver runs on a schedule, so
    /// without this the next automatic pass would quietly undo that decision.
    public func setDayOwner(day: String, deviceId: String, locked: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?,?,?)
                ON CONFLICT(day) DO UPDATE SET
                    deviceId = CASE WHEN dayOwnership.locked = 1 AND excluded.locked = 0
                                    THEN dayOwnership.deviceId ELSE excluded.deviceId END,
                    locked = CASE WHEN dayOwnership.locked = 1 AND excluded.locked = 0
                                  THEN 1 ELSE excluded.locked END
                """, arguments: [day, deviceId, locked])
        }
    }
}

extension StrapStore {
    /// The underlying writer, reachable WITHOUT entering the actor.
    ///
    /// The registry is read on the BLE callback thread and during view construction, where an
    /// `await` would deliver the answer a frame late — long enough to render "no strap" and then
    /// correct itself. GRDB's pool is itself thread-safe, so handing out the connection is sound;
    /// what must not leak out this way is any actor-isolated STATE.
    public nonisolated var registryWriter: any DatabaseWriter { dbQueue }

    /// A registry backed by this store's connection.
    public nonisolated var deviceRegistry: DeviceRegistryStore { DeviceRegistryStore(dbQueue: dbQueue) }
}
