import Foundation

/// gen5 runtime configuration flags.
///
/// The strap exposes named boolean-ish settings that gate which packet families it emits. They
/// are set one at a time, each in its own framed command; there is no batch form.
public enum Whoop5Config {
    /// `SET_CONFIG` — the 40-byte body form.
    public static let setConfigCmd: UInt8 = 0x78
    /// `SET_DEVICE_CONFIG` — the 33-byte body form.
    public static let setDeviceConfigCmd: UInt8 = 0x77

    /// One named flag and its value.
    ///
    /// The value is an ASCII DIGIT, not a boolean: `0x32` is `'2'` and `0x31` is `'1'`. Sending
    /// 0x00/0x01 sets the flag to the characters NUL/SOH, which is not what the firmware parses.
    public struct Flag: Equatable, Sendable {
        public let name: String
        public let value: UInt8
        public init(_ name: String, _ value: UInt8) { self.name = name; self.value = value }
    }

    /// The flag sequence that turns on the R22 packet families and the signals that ride with them.
    public static let enableR22Sequence: [Flag] = [
        Flag("enable_r22_packets", 0x32),
        Flag("enable_r22_v2_packets", 0x32),
        Flag("enable_r22_v3_packets", 0x32),
        Flag("enable_r22_v4_packets", 0x31),
        Flag("enable_r22_v5_packets", 0x32),
        Flag("enable_r22_v6_packets", 0x32),
        Flag("enable_r22_v8_packets", 0x32),
        Flag("make_hrfm_visible", 0x32),
        Flag("disable_pip_r26_packets", 0x32),
        Flag("wear_detect_bias", 0x32),
        Flag("hr_ch_switching", 0x32),
        Flag("ir_hw_switching", 0x32),
        Flag("enable_passive_strap_fit_gen5", 0x31),
        Flag("enable_sig11_during_sleep", 0x32),
        Flag("dorset_inhibit_wpt", 0x32),
    ]

    /// `SET_CONFIG` body: name as ASCII NUL-padded to 32 bytes, value at offset 32, then 7 zeros.
    public static func payloadBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 40)
        for (i, b) in Array(name.utf8).prefix(32).enumerated() { p[i] = b }
        p[32] = value
        return p
    }

    /// `SET_DEVICE_CONFIG` body: the same 32-byte name and value byte, with no trailing pad.
    public static func deviceConfigBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 33)
        for (i, b) in Array(name.utf8).prefix(32).enumerated() { p[i] = b }
        p[32] = value
        return p
    }

    /// One flag as a complete gen5 frame.
    public static func frame(flag: Flag, seq: UInt8) -> [UInt8] {
        buildCommand(seq: seq, opcode: setConfigCmd,
                     payload: [0x01] + payloadBody(name: flag.name, value: flag.value),
                     profile: .gen5)
    }

    /// The whole enable sequence, one frame per flag, sequence numbers running from `firstSeq`.
    public static func enableSequenceFrames(firstSeq: UInt8 = 1) -> [[UInt8]] {
        enableR22Sequence.enumerated().map { i, flag in
            frame(flag: flag, seq: firstSeq &+ UInt8(truncatingIfNeeded: i))
        }
    }
}
