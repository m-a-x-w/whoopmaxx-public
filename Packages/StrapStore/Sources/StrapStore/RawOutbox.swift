import Foundation
import GRDB
import Compression

// The raw-frame archive: the bytes as they came off the radio, kept so a record this build cannot
// decode can be decoded by a later one. Everything here is an ON-DISK FORMAT, so the packing and
// the compression header are fixed — a database written by an older build must still open.

extension StrapStore {

    /// Frames packed end to end: `[u32 LE frame count]` then, per frame, `[u32 LE length][bytes]`.
    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames { appendU32(f.count); buf.append(contentsOf: f) }
        return buf
    }

    /// Unpack, stopping at the first truncation rather than throwing.
    ///
    /// A short blob still yields the frames that ARE intact. This archive exists for records that
    /// could not be decoded once already; refusing the whole batch over a damaged tail would throw
    /// away the part that survived.
    static func unpackFrames(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= bytes.count else { return nil }
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                  | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        guard let count = readU32() else { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let len = readU32(), off + len <= bytes.count else { break }
            out.append(Array(bytes[off..<(off + len)]))
            off += len
        }
        return out
    }

    /// zlib, prefixed with the uncompressed length as u32 LE.
    ///
    /// The length prefix is what makes decompression allocatable in one shot — the framework API
    /// needs a destination size up front and gives no way to ask the stream for it.
    static func zlibCompressWithLength(_ input: Data) throws -> Data {
        let sourceSize = input.count
        let capacity = max(64, sourceSize * 2 + 64)
        var dst = [UInt8](repeating: 0, count: capacity)
        let written: Int = input.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return 0 }
            return compression_encode_buffer(&dst, capacity, base, sourceSize, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        let u = UInt32(sourceSize)
        var blob = Data(capacity: 4 + written)
        blob.append(UInt8(u & 0xFF)); blob.append(UInt8((u >> 8) & 0xFF))
        blob.append(UInt8((u >> 16) & 0xFF)); blob.append(UInt8((u >> 24) & 0xFF))
        blob.append(contentsOf: dst[0..<written])
        return blob
    }

    static func zlibDecompressWithLength(_ blob: Data) throws -> Data {
        let bytes = [UInt8](blob)
        guard bytes.count > 4 else { return Data() }
        let size = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        guard size > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let body = Array(bytes[4...])
        let written: Int = body.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(&dst, size, base, body.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return Data(dst[0..<written])
    }

    /// Archive one batch. Existing batch ids are left ALONE — a replay of the same offload must not
    /// overwrite an archive that a later decoder may already have read.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        let blob = try Self.zlibCompressWithLength(Self.packFrames(frames))
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO rawBatch (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                                      startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?,?,?,?,?,?,?,?,?,?,NULL)
                ON CONFLICT(batchId) DO NOTHING
                """, arguments: [meta.batchId, meta.deviceId, meta.capturedAt,
                                 meta.clockRef.device, meta.clockRef.wall, meta.startTs, meta.endTs,
                                 meta.frameCount, meta.byteSize, blob])
        }
    }

    public func rawFrames(batchId: String) async throws -> [[UInt8]] {
        let blob: Data? = try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT framesBlob FROM rawBatch WHERE batchId = ?",
                             arguments: [batchId])?["framesBlob"]
        }
        guard let blob else { return [] }
        return Self.unpackFrames(try Self.zlibDecompressWithLength(blob))
    }

    private static func metaFromRow(_ r: Row) -> RawBatchMeta {
        RawBatchMeta(batchId: r["batchId"], deviceId: r["deviceId"],
                     clockRef: ClockRef(device: r["deviceClockRef"], wall: r["wallClockRef"]),
                     capturedAt: r["capturedAt"], startTs: r["startTs"], endTs: r["endTs"],
                     frameCount: r["frameCount"], byteSize: r["byteSize"])
    }

    public func pendingRawBatches(limit: Int = 100) async throws -> [RawBatchMeta] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM rawBatch WHERE syncedAt IS NULL ORDER BY capturedAt LIMIT ?",
                             arguments: [limit]).map(Self.metaFromRow)
        }
    }

    public func markRawBatchSynced(batchId: String, at: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE rawBatch SET syncedAt = ? WHERE batchId = ?", arguments: [at, batchId])
        }
    }

    public func allBatchIdsForTest() async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt")
        }
    }

    /// Evict archived frames.
    ///
    /// Two rules, and the ORDER matters: anything past the keep window goes regardless of state,
    /// then unsynced batches are trimmed oldest-first only while they exceed the byte budget.
    /// Reversing that would let a large recent unsynced batch evict the older ones still inside
    /// the window — the archive would silently lose its oldest evidence first, which is the part
    /// most likely to be irreplaceable.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) async throws -> Int {
        try await dbQueue.write { db in
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: "DELETE FROM rawBatch WHERE capturedAt < ?", arguments: [cutoff])
            var removed = db.changesCount

            let rows = try Row.fetchAll(db, sql: """
                SELECT batchId, byteSize FROM rawBatch WHERE syncedAt IS NULL ORDER BY capturedAt DESC
                """)
            var running = 0
            var doomed: [String] = []
            for r in rows {
                running += (r["byteSize"] as Int? ?? 0)
                if running > maxUnsyncedBytes { doomed.append(r["batchId"]) }
            }
            for id in doomed {
                try db.execute(sql: "DELETE FROM rawBatch WHERE batchId = ?", arguments: [id])
                removed += db.changesCount
            }
            return removed
        }
    }
}
