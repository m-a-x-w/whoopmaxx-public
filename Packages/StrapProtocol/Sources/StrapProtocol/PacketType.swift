import Foundation

/// Inner-payload packet types. `inner[0]` on every frame.
public enum PacketType {
    public static let command: UInt8            = 0x23
    public static let commandResponse: UInt8    = 0x24
    /// Battery-pack command/response. Named so neither is misread as "unknown".
    public static let puffinCommand: UInt8         = 0x25
    public static let puffinCommandResponse: UInt8 = 0x26
    public static let realtimeData: UInt8       = 0x28
    public static let realtimeRawData: UInt8    = 0x2B
    public static let historicalData: UInt8     = 0x2F
    public static let event: UInt8              = 0x30
    public static let metadata: UInt8           = 0x31
    public static let consoleLogs: UInt8        = 0x32
}

/// Which strap generation produced a record.
public enum DeviceFamily: String, Sendable, CaseIterable {
    case whoop4
    case whoop5
}
