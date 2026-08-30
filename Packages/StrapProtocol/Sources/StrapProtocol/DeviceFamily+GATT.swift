import Foundation

/// Which checksum guards a generation's frame header. The payload CRC32 is the same on both.
public enum HeaderCRCKind: String, Sendable, CaseIterable {
    case crc8
    case crc16Modbus
}

/// Battery-pack ("puffin") packet sub-types. These carry their own numbers and must be mapped
/// onto the strap's vocabulary before anything reads them by name.
public enum PuffinPacketType {
    public static let puffinCommandResponse: Int = 38
    public static let puffinMetadata: Int = 56
}

/// Fold a raw type byte onto the strap's own vocabulary, mapping the battery-pack sub-types onto
/// their equivalents. Without this a puffin frame reads as an unknown type and is dropped — and on
/// WHOOP 5/MG that silently costs the whole history offload, because METADATA arrives as 56 and
/// `classifyHistoricalMeta` only answers for a frame whose type resolved to METADATA.
///
/// Numeric rather than by-name so the interpreter's dispatch and the name lookup below cannot
/// disagree about what a byte means; the two drifting apart is what made this fold look optional.
public func canonicalPacketType(_ t: Int) -> Int {
    switch t {
    case PuffinPacketType.puffinCommandResponse: return Int(PacketType.commandResponse)
    case PuffinPacketType.puffinMetadata: return Int(PacketType.metadata)
    default: return t
    }
}

/// Map a raw type byte to the strap's own vocabulary, folding the battery-pack sub-types onto
/// their equivalents. Without this a puffin frame reads as an unknown type and is dropped.
public func canonicalTypeName(_ t: Int) -> String {
    Schema.packetTypeName(canonicalPacketType(t))
}

public extension DeviceFamily {
    var headerCRCKind: HeaderCRCKind { self == .whoop5 ? .crc16Modbus : .crc8 }
    var profile: BandProfile { BandProfile(family: self) }
    var gatt: GattProfile { profile.gatt }

    var serviceUUIDString: String { gatt.service }
    var commandCharacteristicUUIDString: String { gatt.commandTo }

    var characteristicUUIDStrings: [String] {
        switch self {
        case .whoop4:
            return [gatt.commandTo, gatt.commandFrom, gatt.events, gatt.data]
        case .whoop5:
            // gen5 adds the memfault channel; subscribing to it is how a crashing strap reports
            // itself instead of just going quiet.
            return [gatt.commandTo, gatt.commandFrom, gatt.events, gatt.data, gatt.memfault]
        }
    }

    /// The opening frame a gen5 link must send before the strap will talk. gen4 needs none.
    var clientHello: [UInt8]? { self == .whoop5 ? DeviceFamily.whoop5ClientHello : nil }

    /// gen5 HELLO. Built rather than transcribed so the header CRC is computed, not asserted —
    /// a hand-copied checksum is a byte that silently stops matching if the body ever moves.
    static var whoop5ClientHello: [UInt8] {
        buildCommand(seq: 0x01, opcode: 0x91, payload: [0x01], profile: .gen5)
    }
}

/// Reassembles complete frames from a notification stream, returning the RAW bytes of each.
///
/// The BLE layer wants the bytes — it archives them, re-decodes them later, and hands them to
/// the interpreter separately — so this is deliberately not the parsed form.
public final class Reassembler {
    private let inner: FrameReassembler
    public var resyncs: Int { inner.resyncs }

    public init(family: DeviceFamily = .whoop4) {
        inner = FrameReassembler(profile: BandProfile(family: family))
    }

    public func reset() { inner.reset() }

    public func feed(_ fragment: [UInt8]) -> [[UInt8]] {
        inner.feed(fragment).map { frame in
            // Rebuild the wire form from the validated envelope: callers store and replay these.
            buildFrame(frame.inner, profile: inner.profile)
        }
    }
}
