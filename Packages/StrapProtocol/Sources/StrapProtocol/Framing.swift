import Foundation

/// A parsed, integrity-checked frame envelope.
///
/// Frame layout, both generations:
///   `[header][inner payload, zero-padded to 4 bytes][u32 LE CRC32 of the padded inner]`
/// where `declared` (read from the header) counts the padded inner **plus** that trailing CRC32.
public struct StrapFrame: Sendable, Equatable {
    /// The padded inner payload: packet type, sequence, opcode, then body.
    public let inner: [UInt8]
    /// Header integrity: crc8 over the length pair on gen4, crc16-modbus over [0..<6] on gen5.
    public let headerCRCOK: Bool
    /// Payload integrity: crc32 over the padded inner.
    public let payloadCRCOK: Bool
    /// Whether the header advertises the frame revision these field offsets were written for.
    ///
    /// The `inner[0]/[1]/[2]` reads below assume rev-1. A rev-2 frame can pass both CRCs and
    /// still shift those fields, which would make `opcode` quietly return a body byte. gen5
    /// carries an explicit revision byte; gen4's 4-byte header has none and is always rev-1.
    public let frameRevisionOK: Bool

    public init(inner: [UInt8], headerCRCOK: Bool, payloadCRCOK: Bool, frameRevisionOK: Bool = true) {
        self.inner = inner
        self.headerCRCOK = headerCRCOK
        self.payloadCRCOK = payloadCRCOK
        self.frameRevisionOK = frameRevisionOK
    }

    /// Both checksums passed. Says nothing about whether the field map is readable.
    public var valid: Bool { headerCRCOK && payloadCRCOK }

    /// Safe to read `packetType` / `sequence` / `opcode`: the bytes are intact AND the revision
    /// is one this decoder understands.
    ///
    /// `valid && !decodable` means the bytes are INTACT and only the field map is unknown —
    /// archive those, never drop them. Dropping is how a firmware revision bump becomes a silent
    /// zero-record sync while the strap goes on trimming records that could have been re-decoded later.
    public var decodable: Bool { valid && frameRevisionOK }

    public var packetType: Int { inner.count > 0 ? Int(inner[0]) : -1 }
    public var sequence: Int { inner.count > 1 ? Int(inner[1]) : -1 }
    public var opcode: Int { inner.count > 2 ? Int(inner[2]) : -1 }
    public var body: [UInt8] { inner.count > 3 ? Array(inner[3...]) : [] }
}

/// Zero-pad to a 4-byte boundary. The CRC32 is computed over the padded form.
public func padTo4(_ data: [UInt8]) -> [UInt8] {
    let remainder = data.count % 4
    return remainder == 0 ? data : data + [UInt8](repeating: 0, count: 4 - remainder)
}

/// Wrap inner content in a frame envelope.
public func buildFrame(_ inner: [UInt8], profile: BandProfile = .gen4) -> [UInt8] {
    let padded = padTo4(inner)
    let declared = padded.count + 4          // +4 for the trailing CRC32
    let c32 = CRC.crc32(padded)
    var out = profile.buildHeader(declared: declared)
    out += padded
    out += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF),
            UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]
    return out
}

/// Parse one complete frame. Returns nil when the buffer is too short or the SOF is wrong —
/// both mean "this is not a frame", which is distinct from "this is a frame that failed its CRC".
public func parseEnvelope(_ raw: [UInt8], profile: BandProfile = .gen4) -> StrapFrame? {
    let headerLength = profile.headerLength
    guard raw.count >= headerLength + 4, raw[0] == strapSOF else { return nil }
    let declared = profile.declaredLength(raw)
    // Must cover at least the trailing CRC32, or the inner slice below runs negative.
    guard declared >= 4 else { return nil }
    let total = headerLength + declared
    guard raw.count >= total else { return nil }

    let innerEnd = headerLength + declared - 4
    let inner = Array(raw[headerLength..<innerEnd])
    let stored = UInt32(raw[innerEnd])
        | (UInt32(raw[innerEnd + 1]) << 8)
        | (UInt32(raw[innerEnd + 2]) << 16)
        | (UInt32(raw[innerEnd + 3]) << 24)
    let revisionOK = !profile.isGen5 || raw[1] == strapFrameRevision1
    return StrapFrame(inner: inner,
                      headerCRCOK: profile.headerCRCValid(raw),
                      payloadCRCOK: stored == CRC.crc32(inner),
                      frameRevisionOK: revisionOK)
}

/// Length-based frame reassembler over a BLE notification stream.
///
/// It MUST be length-driven rather than "restart at every 0xAA": sensor payloads contain 0xAA,
/// and notification boundaries land on them. Construct one per session — a session speaks one
/// generation.
public final class FrameReassembler {
    private var buffer: [UInt8] = []
    private(set) public var resyncs: Int = 0
    public let profile: BandProfile

    public init(profile: BandProfile = .gen4) { self.profile = profile }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        resyncs = 0
    }

    /// Feed a chunk; get back every complete frame that can be carved out of the running buffer.
    public func feed(_ chunk: [UInt8]) -> [StrapFrame] {
        var out: [StrapFrame] = []
        buffer += chunk

        // Drop to the next plausible SOF. False ⇒ nothing left to work with this round.
        func resync() -> Bool {
            resyncs += 1
            if let next = buffer.dropFirst().firstIndex(of: strapSOF) {
                buffer.removeFirst(next)
                return true
            }
            buffer.removeAll(keepingCapacity: true)
            return false
        }

        let headerLength = profile.headerLength
        while buffer.count >= headerLength + 4 {
            guard buffer[0] == strapSOF else {
                if resync() { continue } else { break }
            }
            let declared = profile.declaredLength(buffer)
            let total = headerLength + declared
            guard declared >= 4, total <= 4096 else {          // implausible ⇒ spurious SOF
                if resync() { continue } else { break }
            }
            // The header check guards the length field and nothing else, so it has to pass
            // before `declared` is acted on. Skipping it can consume kilobytes of good stream
            // on one corrupted length byte — records the strap is about to trim from flash and
            // will never send again.
            guard profile.headerCRCValid(buffer) else {
                if resync() { continue } else { break }
            }
            guard buffer.count >= total else { break }         // wait for the rest of this frame

            let frame = parseEnvelope(Array(buffer[0..<total]), profile: profile)
            if let frame { out.append(frame) }

            // A payload-CRC failure means `declared` itself is untrustworthy: the header check is
            // only 8 bits wide on gen4, so ~1 in 254 bad length pairs still passes it. Consuming
            // `total` on that basis swallows every frame packed in behind this one. Resync instead.
            // The frame is still emitted above so corruption accounting sees it, and `valid` is
            // false so nothing ingests it as records.
            if let frame, !frame.payloadCRCOK {
                if resync() { continue } else { break }
            }

            buffer.removeFirst(total)
            // Inter-record null padding is not part of any frame.
            if let firstNonZero = buffer.firstIndex(where: { $0 != 0x00 }) {
                if firstNonZero > 0 { buffer.removeFirst(firstNonZero) }
            } else if !buffer.isEmpty {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if buffer.count > 8192 { buffer.removeAll(keepingCapacity: true) }  // never grow unbounded
        return out
    }
}
