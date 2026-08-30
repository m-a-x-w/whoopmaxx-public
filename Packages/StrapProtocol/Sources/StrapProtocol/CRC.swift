import Foundation

/// The three checksums the WHOOP envelope uses. All three are standard, published
/// algorithms — the only WHOOP-specific facts here are *which* one guards *which* span:
///
/// - `crc8` (poly 0x07) covers the gen4 header's two length bytes and nothing else.
/// - `crc16Modbus` covers the gen5 header's first six bytes.
/// - `crc32` (zlib/IEEE) covers the padded inner payload on **both** generations.
///
/// The narrowness of the header check is load-bearing downstream: eight bits over two
/// bytes means roughly 1 in 254 corrupt length fields still passes, which is why
/// `FrameReassembler` re-syncs on a payload-CRC failure instead of trusting the length
/// it just read. See the comment there.
public enum CRC {

    /// CRC-8, polynomial 0x07, zero init, no final XOR. Applied ONLY to the gen4 length pair.
    public static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes { crc = crc8Table[Int(crc ^ b)] }
        return crc
    }

    /// zlib CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) over the padded inner payload.
    /// Byte-for-byte equivalent to Python's `zlib.crc32`.
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = crc32Table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// CRC-16/MODBUS (init 0xFFFF, reflected poly 0xA001, no final XOR) over the gen5
    /// header bytes [0..<6].
    public static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    // Both tables are generated once at first use rather than written out as literals:
    // a transcribed 256-entry table is a place for a silent typo to live, and the
    // generator IS the specification.
    private static let crc8Table: [UInt8] = (0..<256).map { n in
        var c = UInt8(n)
        for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }

    private static let crc32Table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

// Free-function spellings. The envelope's checksums are referred to by their algorithm names
// throughout the BLE layer, where the surrounding code is all byte-level and a namespace
// qualifier reads as noise.

public func crc8(_ bytes: [UInt8]) -> UInt8 { CRC.crc8(bytes) }
public func crc32(_ bytes: [UInt8]) -> UInt32 { CRC.crc32(bytes) }
public func crc16Modbus(_ bytes: [UInt8]) -> UInt16 { CRC.crc16Modbus(bytes) }
