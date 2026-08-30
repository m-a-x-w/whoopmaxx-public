import Foundation

/// Start-of-frame marker. Present on both generations.
public let strapSOF: UInt8 = 0xAA

/// The frame revision this decoder's field offsets were written against.
public let strapFrameRevision1: UInt8 = 0x01

/// Which physical WHOOP generation a link is speaking.
///
/// These are not two protocols. gen5 is gen4 in a different envelope: the header grows
/// from 4 bytes to 8 and its integrity check changes from crc8 to crc16-modbus, while the
/// padded inner payload and its trailing crc32 are identical on both. Everything that
/// actually differs lives in `BandProfile`, so framing and record decode stay band-neutral.
public enum DeviceGeneration: Sendable {
    case gen4
    case gen5
}

/// GATT service and characteristic UUIDs for one generation.
///
/// The low nibble is the same on both (0001 service, 0002 write, 0003 command responses,
/// 0004 events, 0005 data, 0007 memfault); only the 32-bit prefix and the 96-bit base
/// suffix change.
public struct GattProfile: Sendable, Equatable {
    public let service: String
    public let commandTo: String
    public let commandFrom: String
    public let events: String
    public let data: String
    public let memfault: String

    public static let gen4 = GattProfile(
        service:     "61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
        commandTo:   "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
        commandFrom: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
        events:      "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
        data:        "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
        memfault:    "61080007-8d6d-82b8-614a-1c8cb0f8dcc6")

    public static let gen5 = GattProfile(
        service:     "fd4b0001-cce1-4033-93ce-002d5875f58a",
        commandTo:   "fd4b0002-cce1-4033-93ce-002d5875f58a",
        commandFrom: "fd4b0003-cce1-4033-93ce-002d5875f58a",
        events:      "fd4b0004-cce1-4033-93ce-002d5875f58a",
        data:        "fd4b0005-cce1-4033-93ce-002d5875f58a",
        memfault:    "fd4b0007-cce1-4033-93ce-002d5875f58a")

    /// The 32-bit prefix used to tell the generations apart from a scan result.
    public var servicePrefix: String { String(service.prefix(8)) }
}

/// Per-generation wire-format profile. Carry one of the two singletons; there is no
/// reason to build another.
public struct BandProfile: Sendable, Equatable {
    public let generation: DeviceGeneration
    /// Bytes before the inner payload: 4 on gen4, 8 on gen5.
    public let headerLength: Int
    /// Offset of the u16-LE declared-length field within the header. `declared` counts
    /// the padded inner payload PLUS the trailing 4-byte CRC32.
    public let sizeFieldOffset: Int

    /// gen5 header bytes [4..<6] on a host → strap COMMAND frame.
    ///
    /// This pair is a direction marker, not a magic constant: host → strap commands carry
    /// `[0x00, 0x01]`, and strap → host frames of every other packet type carry
    /// `[0x01, 0x00]`. The crc16 covers whichever bytes are actually present, so treating
    /// it as a fixed value was never a validity bug — but nothing here may gate *inbound*
    /// frames on it, or nearly every frame a live session receives would be rejected.
    public let outboundDirectionMarker: [UInt8]?
    /// The inbound counterpart. Carried as data so a future generation's convention lives
    /// in the profile rather than as a literal buried in the framing code. Nothing gates on it.
    public let inboundDirectionMarker: [UInt8]?

    public static let gen4 = BandProfile(
        generation: .gen4, headerLength: 4, sizeFieldOffset: 1,
        outboundDirectionMarker: nil, inboundDirectionMarker: nil)

    public static let gen5 = BandProfile(
        generation: .gen5, headerLength: 8, sizeFieldOffset: 2,
        outboundDirectionMarker: [0x00, 0x01], inboundDirectionMarker: [0x01, 0x00])

    public static func of(_ g: DeviceGeneration) -> BandProfile { g == .gen5 ? .gen5 : .gen4 }

    public var isGen5: Bool { generation == .gen5 }
    public var gatt: GattProfile { isGen5 ? .gen5 : .gen4 }

    /// Read the declared length from a header. Caller guarantees `frame.count >= sizeFieldOffset + 2`.
    public func declaredLength(_ frame: [UInt8]) -> Int {
        Int(frame[sizeFieldOffset]) | (Int(frame[sizeFieldOffset + 1]) << 8)
    }

    public func totalLength(declared: Int) -> Int { headerLength + declared }

    /// Validate the header's own integrity field — the length bytes only, never the payload.
    public func headerCRCValid(_ frame: [UInt8]) -> Bool {
        if !isGen5 {
            guard frame.count >= 4 else { return false }
            return frame[3] == CRC.crc8([frame[1], frame[2]])
        }
        guard frame.count >= 8 else { return false }
        let want = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
        return CRC.crc16Modbus(Array(frame[0..<6])) == want
    }

    /// Build the header for a given declared length.
    ///
    ///   gen4: `[0xAA][u16 declared LE][crc8]`
    ///   gen5: `[0xAA][0x01][u16 declared LE][outbound marker][crc16-modbus LE]`
    ///
    /// This always stamps the OUTBOUND marker — every builder here constructs a host → strap
    /// command. Never use it to synthesise a frame standing in for something the strap sent.
    public func buildHeader(declared: Int) -> [UInt8] {
        if !isGen5 {
            var h: [UInt8] = [strapSOF, UInt8(declared & 0xFF), UInt8((declared >> 8) & 0xFF), 0]
            h[3] = CRC.crc8([h[1], h[2]])
            return h
        }
        var h: [UInt8] = [
            strapSOF, strapFrameRevision1,
            UInt8(declared & 0xFF), UInt8((declared >> 8) & 0xFF),
            outboundDirectionMarker?[0] ?? 0x00, outboundDirectionMarker?[1] ?? 0x01,
            0, 0,
        ]
        let c = CRC.crc16Modbus(Array(h[0..<6]))
        h[6] = UInt8(c & 0xFF)
        h[7] = UInt8((c >> 8) & 0xFF)
        return h
    }
}
