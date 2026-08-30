import Foundation

/// One captured frame, with whatever this decoder could say about it.
///
/// Every interpreted field is optional because the point of a capture is the frames that did
/// NOT decode. A record that stored only what parsed cleanly would discard exactly the evidence
/// the capture exists to collect.
public struct PuffinCaptureRecord: Codable, Equatable, Sendable {
    /// The raw bytes, hex-encoded. Always present — this is the payload of the record.
    public let hex: String
    /// Which GATT characteristic the frame arrived on.
    public let char: String
    /// Host wall clock at arrival, milliseconds. Host time, not strap time: the two disagree,
    /// and the whole reason to capture is usually that the strap's own clock is suspect.
    public let tsMs: Int
    public let hr: Int?
    public let typeName: String?
    public let seq: Int?
    public let crcOK: Bool?
    /// Whether the frame decoded at all.
    public let ok: Bool

    public init(hex: String, char: String, tsMs: Int, hr: Int? = nil, typeName: String? = nil,
                seq: Int? = nil, crcOK: Bool? = nil, ok: Bool) {
        self.hex = hex; self.char = char; self.tsMs = tsMs; self.hr = hr
        self.typeName = typeName; self.seq = seq; self.crcOK = crcOK; self.ok = ok
    }
}

/// An in-memory buffer of captured frames, for reporting a strap that misbehaves.
///
/// Deliberately unbounded and explicitly drained: a capture is started for a specific
/// reproduction, and a ring buffer that quietly dropped the oldest frames would throw away the
/// beginning of the very sequence being investigated. The app layer gates it on a user toggle
/// and flushes it.
public final class PuffinCapture {
    public private(set) var records: [PuffinCaptureRecord] = []

    public init() {}

    public var count: Int { records.count }
    public func reset() { records.removeAll() }

    /// Capture one frame, decoding what can be decoded and recording the rest verbatim.
    @discardableResult
    public func record(frame bytes: [UInt8], char: String, tsMs: Int, hr: Int? = nil,
                       profile: BandProfile = .gen4) -> PuffinCaptureRecord {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let f = parseEnvelope(bytes, profile: profile) else {
            // Not even an envelope. Still captured — an unparseable frame is a finding.
            let r = PuffinCaptureRecord(hex: hex, char: char, tsMs: tsMs, hr: hr, ok: false)
            records.append(r)
            return r
        }
        let p = Interpreter.interpret(f, rawLength: bytes.count)
        let r = PuffinCaptureRecord(hex: hex, char: char, tsMs: tsMs,
                                    hr: hr ?? p.parsed["heart_rate"]?.intValue,
                                    typeName: p.typeName, seq: p.seq,
                                    crcOK: f.payloadCRCOK, ok: p.ok)
        records.append(r)
        return r
    }

    /// The capture as JSON, for attaching to a bug report.
    public func encodedJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(records)
    }

    /// Just the raw hex, in the shape the decoder's own fixtures use, so a captured frame can be
    /// replayed straight into a test.
    public func framesFixtureJSON() throws -> Data {
        struct Frame: Encodable { let hex: String }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(records.map { Frame(hex: $0.hex) })
    }
}
