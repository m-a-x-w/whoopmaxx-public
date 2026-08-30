import Foundation
import CoreBluetooth
import StrapProtocol

/// Records frames the strap sent, so an unknown format can be worked out offline.
///
/// Read-only with respect to the band: it stores what already arrived and never writes to the
/// device, which is why it is safe to leave on. That is the whole difference between this and the
/// protocol probes — capturing is passive, probing guesses.
///
/// Each frame is stamped with wall-clock time and the live heart rate, so a decoded field can be
/// checked against a value that was independently true at that instant.
///
/// `@MainActor` because it reads live state and publishes a count; the callbacks that feed it are
/// already on the main queue.
@MainActor
final class PuffinFrameRecorder {
    /// Mirrored by the Settings toggle. `nonisolated` so the backup's settings list can name it.
    nonisolated static let enabledKey = "wmPuffinCapture"

    /// Frames between durable writes. A crash or a yanked cable loses at most this many.
    private static let flushEvery = 25

    /// Ceiling on the capture directory.
    ///
    /// One file per launch, never trimmed, is unbounded growth: left on, this reached gigabytes.
    /// After each flush the oldest files are evicted until the total is back under the cap.
    private static let directorySoftCapBytes = 50 * 1024 * 1024

    private weak var state: LiveState?

    /// Only the frames not yet written. It resets on every flush, so memory stays bounded by
    /// `flushEvery` rather than growing for the session — and a flush costs the new frames, not a
    /// re-encode of everything captured so far.
    private let buffer = PuffinCapture()

    /// Frames this session, which is what the UI shows. Counted separately because the buffer above
    /// is only the unwritten tail.
    private var totalCaptured = 0
    private var fileURL: URL?

    init(state: LiveState) { self.state = state }

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private static func captureDirectory() throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("puffin-captures", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func capture(frame: [UInt8], char: CBUUID) {
        guard isEnabled else { return }
        buffer.record(frame: frame, char: char.uuidString.lowercased(),
                      tsMs: Int(Date().timeIntervalSince1970 * 1000), hr: state?.heartRate)
        totalCaptured += 1
        state?.puffinCaptureCount = totalCaptured
        if buffer.count >= Self.flushEvery { flush() }
    }

    /// Append what is buffered, then drop it from memory.
    ///
    /// Best effort: a failed write leaves the frames buffered for the next attempt, so nothing is
    /// lost to a transient error — the reset happens only after the bytes are on disk.
    func flush() {
        let pending = buffer.records
        guard !pending.isEmpty else { return }
        do {
            let url = try sessionFileURL()
            try Self.appendDurably(Self.encodeJSONL(pending), to: url)
            buffer.reset()
            state?.puffinCaptureURL = url
            Self.evictOldCaptures(keeping: url)
        } catch {
            // Left buffered on purpose — the next flush retries.
        }
    }

    /// One compact object per line. Not pretty-printed: a record has to be a single line for the
    /// file to stay valid under append.
    private static func encodeJSONL(_ records: [PuffinCaptureRecord]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for rec in records {
            out.append(try enc.encode(rec))
            out.append(0x0A)
        }
        return out
    }

    /// Append, creating the file on the first write — so the file grows without ever being re-read.
    private static func appendDurably(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return try data.write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Delete oldest captures until the directory is back under the cap.
    ///
    /// Filenames are timestamped, so name order is time order. The file this session is still
    /// writing is never a candidate.
    private static func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let dir = try? captureDirectory(),
              let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let files = entries
            .filter { $0.pathExtension == "jsonl" || $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > directorySoftCapBytes else { break }
            guard file.url != keep else { continue }
            if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    /// One file per recorder lifetime, named on first use; every flush appends to it.
    private func sessionFileURL() throws -> URL {
        if let fileURL { return fileURL }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = try Self.captureDirectory().appendingPathComponent("puffin-\(stamp).jsonl")
        fileURL = url
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
