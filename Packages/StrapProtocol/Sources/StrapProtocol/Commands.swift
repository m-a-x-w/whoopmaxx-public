import Foundation

/// Command opcodes. `inner[2]` on a command frame.
public enum Cmd {
    public static let setAlarmTime: UInt8      = 0x42
    public static let getAlarmTime: UInt8      = 0x43
    /// Fire the alarm haptics immediately — a test/preview, not a schedule.
    public static let runAlarm: UInt8          = 0x44
    public static let disableAlarm: UInt8      = 0x45
    public static let runHapticsPattern: UInt8 = 0x4F
}

/// Wrap a command payload in a full frame. `inner = [0x23][seq][opcode] + payload`.
public func buildCommand(seq: UInt8, opcode: UInt8, payload: [UInt8] = [0x00],
                         profile: BandProfile = .gen4) -> [UInt8] {
    buildFrame([PacketType.command, seq, opcode] + payload, profile: profile)
}

/// The strap's stock alarm buzz: two waveform effects with no per-effect loop, the whole
/// waveform looped 7×, capped at 30 s.
///
/// Layout — 12 bytes:
///   `[8 × u8 waveform effect (0 = idle slot)][u16 LE per-effect loop][u8 overall loop][u8 seconds]`
public let defaultAlarmHaptics: [UInt8] = [
    47, 152, 0, 0, 0, 0, 0, 0,
    0, 0,
    7,
    30,
]

/// On-device haptic alarm payloads (`SET_ALARM_TIME` 0x42 and friends).
///
/// The strap runs the alarm on its own wall clock, so it fires with no phone connected. Only
/// the payload bodies live here — an app layer running its own sequence counter frames them —
/// so the byte layout has exactly one home.
public enum AlarmPayload {

    /// Sub-second units are 1/32768 s (a 32768 Hz RTC crystal), the same as `SET_CLOCK`.
    public static let subsecondsPerSecond = 32768

    /// Split a wall-clock instant in milliseconds into the strap's (u32 seconds, u16 sub-seconds).
    public static func seconds(fromEpochMs ms: Int64) -> UInt32 { UInt32(ms / 1000) }

    public static func subseconds(fromEpochMs ms: Int64) -> UInt16 {
        UInt16((ms % 1000) * Int64(subsecondsPerSecond) / 1000)   // 0..32767
    }

    /// The RICH (revision-4) arm form.
    ///
    /// ```
    ///   [0x04]                    form marker
    ///   [u8 slot]                 alarm slot
    ///   [u32 LE epoch seconds]
    ///   [u16 LE sub-seconds]
    ///   [12-byte haptic pattern]  see defaultAlarmHaptics
    /// ```
    ///
    /// Whether this form EXECUTES on a gen4 is firmware-dependent: on some firmware it latches
    /// and confirms exactly like a live arm — the strap emits its alarm-set event either way —
    /// yet the scheduler never fires it. Only the fired events prove execution. The confirmation
    /// also arrives on the next history sync rather than live, so a latched alarm and a working
    /// alarm look identical until morning.
    public static func setAlarmRev4(wakeEpochMs: Int64, alarmId: UInt8 = 1,
                                    hapticPattern: [UInt8] = defaultAlarmHaptics) -> [UInt8] {
        precondition(hapticPattern.count == 12, "haptic pattern must be 12 bytes")
        let s = seconds(fromEpochMs: wakeEpochMs)
        let ss = subseconds(fromEpochMs: wakeEpochMs)
        return [0x04, alarmId,
                UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8((s >> 24) & 0xFF),
                UInt8(ss & 0xFF), UInt8((ss >> 8) & 0xFF)] + hapticPattern
    }

    /// Cancel every armed alarm (`DISABLE_ALARM` 0x45). Revision byte first, then the slot —
    /// 0xFF meaning "all".
    public static func disableRev2() -> [UInt8] { [0x02, 0xFF] }

    /// Cancel one slot.
    public static func disableRev2(alarmId: UInt8) -> [UInt8] { [0x02, alarmId] }

    /// Fire the alarm haptics now (`RUN_ALARM` 0x44) — a preview, it does not schedule anything.
    public static func runAlarmRev2(alarmId: UInt8 = 1) -> [UInt8] { [0x02, alarmId] }
}

/// Notification haptics on gen5 hardware.
public enum MaverickHaptics {
    /// A short notification buzz, repeated `loops` times.
    ///
    /// Payload is the waveform-effect id followed by four zero bytes — the same shape as the
    /// alarm's effect slots, with no per-effect loop control.
    public static func notificationBuzz(loops: Int) -> [UInt8] {
        [hapticShortPulse, UInt8(clamping: loops), 0, 0, 0]
    }

    /// The short-pulse waveform effect id.
    public static let hapticShortPulse: UInt8 = 2
}
