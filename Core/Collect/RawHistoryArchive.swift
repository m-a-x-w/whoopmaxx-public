// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import StrapProtocol

/// Durable set-aside store for historical record frames this build could not decode.
///
/// The reason it exists is the safe-trim invariant. HISTORICAL_DATA_RESULT is the strap's permission
/// to free everything up to the echoed trim token, and the Backfiller has to send that token even for
/// a chunk that produced zero rows, because withholding it wedges the offload in a re-send loop that
/// never advances. So an undecodable frame gets exactly one chance to become durable, and it is
/// before the ack. Miss it and a future firmware's records are gone from both sides while the sync UI
/// still shows a clean run.
///
/// What the file buys is an honest status: N records set aside, not lost. It is also the corpus a
/// later layout mapping re-ingests, which is what `replay` is for.
///
/// Identity is frame CONTENT, never the strap's record counter. That counter restarts near zero on
/// every strap reboot, so two genuinely different frames from different boots can carry the same
/// value; keying on it lets a dedupe silently discard the second one, in the one store whose entire
/// purpose is to never lose a frame. Appending the raw bytes never has to answer the question.
///
/// The file is newline-delimited JSON, one record per line, fsynced before the call returns:
///   {"capturedAtMs":Double,"trim":Int,"family":"whoop4"|"whoop5","frameHex":String}
/// Frames carry sensor payloads only. No serial or MAC address reaches this file.
struct RawHistoryArchive {
    /// Name under `<AppSupport>/com.whoopmaxx.app/`. Both that directory component and this name are
    /// on-disk identity: rename either and every existing user's archive is orphaned, which for
    /// undecodable records means the only surviving copy of those bytes anywhere.
    static let fileName = "rejected_history.jsonl"

    /// Soft cap, past which the oldest surplus is evicted rather than the write refused.
    ///
    /// Unbounded is not an option: one undecodable record version on a real strap export ran to
    /// hundreds of megabytes inside a fortnight, on the order of gigabytes a year, and this file is
    /// swept into every backup the user takes. Only a batch too large to fit an empty archive is
    /// skipped outright.
    static let maxBytes = 5 * 1024 * 1024

    /// Newest lines of each distinct (family, hist_version) bucket that eviction may never touch.
    ///
    /// A pure oldest-first byte race deletes precisely what the archive was built for. A never-seen
    /// layout arrives as a handful of frames while a well-understood one arrives as thousands, so the
    /// race spends the rare samples to store more copies of something already decoded. Thinning the
    /// small buckets costs real evidence and saves nothing. The exemption can hold at most
    /// `floor x distinctVersions` lines, a bounded and negligible slice of the cap.
    static let perVersionFloor = 64

    /// What the caller must do about the trim ack.
    enum Result {
        /// The frames are on stable storage. Ack; the strap may free them.
        case written(count: Int)
        /// Nothing was written because the batch cannot fit. Ack anyway and count the frames as
        /// unarchived, so no status ever claims they were saved. Refusing the ack here would wedge the
        /// offload, which is strictly worse than losing a chunk of an oversized burst.
        case capReached(count: Int)
        /// A genuine I/O failure. Hold the trim cursor so the strap re-sends. Reserved for that alone:
        /// returning it for a merely full archive turns the offload into an infinite re-send loop.
        case failed
    }

    private let directory: URL
    /// Per-instance overrides of the two policy constants above. They exist so a test can exercise
    /// eviction with a few kilobytes instead of manufacturing five megabytes of frames.
    private let maxBytes: Int
    private let perVersionFloor: Int

    init(directory: URL? = nil,
         maxBytes: Int = RawHistoryArchive.maxBytes,
         perVersionFloor: Int = RawHistoryArchive.perVersionFloor) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("com.whoopmaxx.app", isDirectory: true)
        }
        self.maxBytes = maxBytes
        self.perVersionFloor = perVersionFloor
    }

    /// A path and nothing more. Reading it creates neither the directory nor the file.
    var fileURL: URL { directory.appendingPathComponent(RawHistoryArchive.fileName) }

    /// The hist_version byte that tells one historical layout from another: index 5 on WHOOP 4, index
    /// 9 on WHOOP 5/MG whose envelope is four bytes longer. A frame too short to carry it takes the
    /// -1 sentinel so it forms a bucket of its own rather than folding in with real version 0 frames.
    static func versionByte(_ frame: [UInt8], family: DeviceFamily) -> Int {
        let idx = family == .whoop5 ? 9 : 5
        return frame.count > idx ? Int(frame[idx]) : -1
    }

    /// Retention bucket. Family belongs in the key because a WHOOP 4 v18 and a WHOOP 5 v18 are
    /// unrelated layouts that happen to share a number, and each deserves its own floor.
    private struct VersionKey: Hashable { let family: String; let version: Int }

    private func versionKey(family: DeviceFamily, version: Int) -> VersionKey {
        VersionKey(family: family.rawValue, version: version)
    }

    /// Write `frames` durably as JSONL, tagged with the trim token and family that make them
    /// replayable later. See `Result` for what each outcome obliges the caller to do.
    ///
    /// `count` on the success cases is always `frames.count` and never the surviving line count: the
    /// caller's session counters describe the chunk it just handled, not the state of the file.
    func archive(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Result {
        guard !frames.isEmpty else { return .written(count: 0) }
        let url = fileURL

        // One capture stamp for the whole batch, and it is the receive time rather than a record time
        // because a frame lands here precisely when its own timestamp never decoded. When we got it is
        // the only time we have.
        let capturedAtMs = Date().timeIntervalSince1970 * 1000
        let newLines = frames.map { frame -> String in
            let hex = frame.map { String(format: "%02x", $0) }.joined()
            // Built by hand rather than through JSONEncoder. The only dynamic field is hex in [0-9a-f],
            // so there is nothing an escaper is needed for, while an encoder is free to reorder or
            // re-quote fields that the substring parsers below and every archive already on disk read
            // positionally.
            return "{\"capturedAtMs\":\(capturedAtMs),\"trim\":\(Int(trim)),"
                + "\"family\":\"\(family.rawValue)\",\"frameHex\":\"\(hex)\"}\n"
        }
        let incoming = newLines.reduce(0) { $0 + $1.utf8.count }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? Int } ?? 0

        // No amount of eviction makes room for a batch that overflows an empty archive, and by the time
        // one chunk is that large there is ample sample material on disk already.
        if incoming > maxBytes {
            return .capReached(count: frames.count)
        }

        do {
            if onDisk + incoming <= maxBytes {
                try appendDurably(Data(newLines.joined().utf8), to: url)
            } else {
                // Fold the incoming lines onto the existing ones, which are older and therefore sort
                // first, then apply the retention policy to the whole set and rewrite.
                let existing = (try? String(contentsOf: url, encoding: .utf8))
                    .map { text in
                        text.split(separator: "\n", omittingEmptySubsequences: true)
                            .map { String($0) + "\n" }
                    } ?? []
                let kept = RawHistoryArchive.evictLines(existing + newLines,
                                                        maxBytes: maxBytes,
                                                        floor: perVersionFloor)
                try writeDurably(Data(kept.joined().utf8), to: url)
            }
            return .written(count: frames.count)
        } catch {
            return .failed
        }
    }

    /// Extend the file, then flush. The flush is not optional. Returning `.written` while the bytes sit
    /// in the page cache lets the caller ack a chunk the strap then frees, and a crash in that window
    /// destroys the only copy.
    private func appendDurably(_ data: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try writeDurably(data, to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Replace the whole file, then flush, creating the directory if this is the first archive ever.
    private func writeDurably(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fsync(url)
    }

    /// Push an already-written file's data blocks to stable storage.
    ///
    /// `Data.write(options: .atomic)` renames a temp file into place, which orders the directory entry
    /// but says nothing about the contents reaching the device, so the atomic write on its own still
    /// loses the data on a crash before the ack. Re-opening costs nothing and clobbers nothing:
    /// `FileHandle(forWritingTo:)` opens O_WRONLY without truncation.
    private func fsync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    /// The `family` and `frameHex` fields of one stored line, or `nil` when either is absent, the
    /// family is a raw value this build does not know, or the hex has an odd length.
    ///
    /// Note what is NOT required: `capturedAtMs` and `trim` are forensic only, so a line carrying
    /// neither still parses. Earlier builds and the tests both write such lines.
    private static func fields(_ line: Substring) -> (family: DeviceFamily, hex: Substring)? {
        guard let fr = line.range(of: "\"family\":\""),
              let hr = line.range(of: "\"frameHex\":\"") else { return nil }
        let fam = line[fr.upperBound...].prefix { $0 != "\"" }
        let hex = line[hr.upperBound...].prefix { $0 != "\"" }
        guard let family = DeviceFamily(rawValue: String(fam)), hex.count % 2 == 0 else { return nil }
        return (family, hex)
    }

    /// Decode at most `limit` bytes off the front of a hex field, or `nil` on the first non-hex pair.
    /// Stopping early is what keeps eviction affordable: bucketing needs one byte at a known index,
    /// and decoding whole 124-byte frames instead would cost millions of radix parses per pass over a
    /// full archive.
    private static func hexBytes(_ hex: Substring, limit: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(Swift.min(limit, hex.count / 2))
        var i = hex.startIndex
        while i < hex.endIndex, out.count < limit {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Bucket key for one stored line, or `nil` when the line does not parse.
    ///
    /// `nil` means no floor slot at all, which is deliberate: garbage has to be evictable ahead of
    /// every real line, or a corrupted tail permanently squats on slots a rare layout needs. Only the
    /// prefix through the version index is decoded, and the length guard inside `versionByte` still
    /// yields the -1 sentinel for a frame too short to reach it, so the bucketing is identical to what
    /// a full decode would produce.
    private static func lineVersionKey(_ line: String) -> VersionKey? {
        guard let f = fields(line[...]) else { return nil }
        let idx = f.family == .whoop5 ? 9 : 5
        guard let head = hexBytes(f.hex, limit: idx + 1) else { return nil }
        return VersionKey(family: f.family.rawValue, version: versionByte(head, family: f.family))
    }

    /// Floor-aware retention across the whole newline-terminated line set, oldest first. Pure, so the
    /// policy is testable without a disk. Survivors come back in their original order, byte for byte:
    /// callers compare lines by equality, so nothing here may re-terminate, trim or normalise one.
    ///
    /// Two rules interact. Eviction runs oldest first, and the newest `floor` lines of each bucket are
    /// exempt. When everything left is exempt, eviction stops while still over cap. That is the point
    /// rather than a bug: the obvious "keep dropping until it fits" loop spends exactly the rare
    /// samples the archive exists to hold, and the overshoot it avoids is bounded.
    ///
    /// Eviction aims at a low-water mark under the cap, not at the cap. Trimming to exactly the cap
    /// leaves the file over again on the very next chunk, so from the day the archive first fills,
    /// every append pays a read, an evict, a rewrite and an fsync on the main actor, once per
    /// HISTORY_END chunk. Undershooting restores the plain append path for the next `headroom` worth of
    /// frames. The default is a tenth of the cap capped at 512 KB, because a flat 512 KB would swallow
    /// a small injected cap whole.
    static func evictLines(_ lines: [String], maxBytes: Int, floor: Int,
                           headroom: Int? = nil) -> [String] {
        var total = lines.reduce(0) { $0 + $1.utf8.count }
        // The cap decides WHETHER to evict; the low-water mark below decides HOW FAR.
        guard total > maxBytes else { return lines }

        var exempt = Set<Int>()
        var used: [VersionKey: Int] = [:]
        // Reversed, so the floor protects each bucket's NEWEST lines. Walking forward instead would
        // pin the oldest of every bucket and invert the whole retention policy while still looking
        // right from the "rare layouts survive" angle.
        for i in lines.indices.reversed() {
            guard let key = lineVersionKey(lines[i]) else { continue }
            let taken = used[key, default: 0]
            guard taken < floor else { continue }
            used[key] = taken + 1
            exempt.insert(i)
        }

        let slack = Swift.max(0, headroom ?? Swift.min(512 * 1_024, maxBytes / 10))
        let target = Swift.max(0, maxBytes - slack)
        var evicted = Set<Int>()
        for i in lines.indices {
            if total <= target { break }        // ascending index, so oldest goes first
            if exempt.contains(i) { continue }
            evicted.insert(i)
            total -= lines[i].utf8.count
        }
        guard !evicted.isEmpty else { return lines }
        return lines.indices.filter { !evicted.contains($0) }.map { lines[$0] }
    }

    /// Read the archive back, oldest first, with the hand parser that matches the hand-built writer.
    ///
    /// Absence is reported rather than papered over. A missing or unreadable file yields an empty
    /// array, and any line lacking a field, naming an unknown family or carrying malformed hex is
    /// skipped. Nothing here invents a frame or a family it could not read off the line.
    func readAll() -> [(frame: [UInt8], family: DeviceFamily)] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let f = RawHistoryArchive.fields(line),
                  let bytes = RawHistoryArchive.hexBytes(f.hex, limit: .max) else { return nil }
            return (bytes, f.family)
        }
    }

    /// Re-drive the archive through TODAY's decoder and bank whatever now decodes.
    ///
    /// A frame is here because a BUILD could not read it, which is a statement about the build and not
    /// about the bytes. Nothing else ever comes back to re-read them, so without this pass the archive
    /// quietly turns into a graveyard instead of the recovery store it was created as. The strap freed
    /// these records the moment they were acked, so this file is the only route by which that history
    /// can ever backfill once a new layout mapping lands.
    ///
    /// Three things it does not do. It does not touch the archived bytes: no line is deleted, thinned
    /// or relabelled, so a frame that still fails today stays exactly where it is for the build that
    /// can read it. It does not invent a family or a device: family comes off the line, and the id
    /// comes from the caller, because a replay has no live link to ask and the record version does not
    /// answer that question. And it never lets a failed decode displace a successful one, which is
    /// what the store's own dedupe on (deviceId, ts) guarantees.
    ///
    /// The return is rows ACTUALLY inserted, not rows decoded. Replay runs once per app version, so a
    /// re-run lands entirely on that dedupe, and counting decoded rows would announce a triumphant
    /// recovery on every single update. It throws on insert failure so the caller's replay gate cannot
    /// advance past records whose only copy is this file.
    @discardableResult
    func replay(into store: BackfillStoreWriting, deviceId: String) async throws -> Int {
        let archived = readAll()
        var rows = 0
        for family in Set(archived.map(\.family)) {
            let parsed = archived.filter { $0.family == family }
                .map { parseFrame($0.frame, family: family) }
            // Identity clock refs: type-47 records carry a real unix timestamp of their own, so there is
            // no device-to-wall offset to apply and no live session from which one could be learned.
            var streams = extractHistoricalStreams(parsed, deviceClockRef: 0, wallClockRef: 0)
            // Skip this and a retro-decode becomes the one respiration writer with no plausibility check
            // anywhere in its path, re-banking exactly the mode-register rows every live path refuses,
            // and doing it after StoreMaintenance has already flagged its purge complete so nothing
            // reclaims them. The chunk-local judgement is the right one here: this pass hands it a
            // family's entire archive at once, so the sample either clears the minimum outright or is
            // genuinely too small to judge.
            RespChannelGate.dropIfDegenerate(&streams)
            rows += (try await store.insert(streams, deviceId: deviceId)).gravity
        }
        return rows
    }
}
