// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import StrapProtocol

/// Every opcode this app is able to write to a strap, and the frame builder that wraps one.
///
/// Raw values are on-wire bytes, so none of them may change. What matters more than the bytes
/// present is the bytes absent: reboot, power-cycle, force-trim, ship mode, fuel-gauge reset,
/// firmware load and BLE DFU have no case here. `BLEManager.send(_:payload:writeType:)` accepts
/// this enum and not a `UInt8`, so those opcodes are not merely discouraged — no expression in
/// app code can name one, and no reviewer has to notice a bad constant to keep a strap from
/// being wiped or bricked.
///
/// That is a design choice with a live alternative. The MIT engine this was ported from keeps a
/// complete opcode table and refuses the destructive members at the single lowest-level write,
/// with one named, audited carve-out for the persistent config write. A runtime block list buys
/// the carve-out; absence-by-construction buys a compile-time guarantee and costs the ability to
/// grant an exception without editing this file. We took the compile-time guarantee, which is
/// why this list is curated by hand. Generating it from the protocol tables would restore every
/// destructive opcode to the app's vocabulary in one commit and remove the property silently.
public enum WhoopCommand: UInt8, CaseIterable {

    // MARK: Identity and handshake

    /// Firmware/hardware version report. Read-only, part of the connect handshake.
    case reportVersionInfo = 7
    /// Hello on WHOOP 4.0 (the "Harvard" generation). Read-only.
    case getHelloHarvard = 35
    /// Hello on WHOOP 5/MG, which moved the handshake to its own opcode; a 4.0 answers
    /// "unsupported", so this is only written once the generation is known. The reply carries the
    /// device name and firmware version shown on the Devices card.
    case getHello = 145
    /// Read back the BLE advertising name programmed into a 4.0. Read-only, and the handshake
    /// re-reads it after a rename because a rename only takes effect once the strap reboots.
    case getAdvertisingNameHarvard = 76
    /// Program a 4.0's BLE advertising name; body from `advertisingNamePayload(_:)`. The strap
    /// stores the name and applies it on reboot, so the new name shows up on the next connect.
    /// 4.0 only: 5/MG has its own advertising-name pair behind puffin framing. Reversible.
    case setAdvertisingNameHarvard = 77

    // MARK: Clock

    /// Set the strap's RTC from phone time. The firmware alarm counts against that RTC and not
    /// against ours, so this has to land before `setAlarmTime` or the alarm arms in the wrong
    /// time frame.
    case setClock = 10
    /// Read the RTC back so drift against phone time can be measured. Read-only.
    case getClock = 11

    // MARK: Battery

    case getBatteryLevel = 26
    /// Extended fuel-gauge report. Nothing in the app calls it today; it stays because this enum
    /// is public API and dropping a case breaks compilation for anyone naming it and changes
    /// `allCases`.
    case getExtendedBatteryInfo = 98

    // MARK: History offload

    /// Ask the strap to stream stored records; the offload driver decides the pacing.
    case sendHistoricalData = 22
    /// Acknowledge a received batch so the strap may trim it. Skipping this is precisely what
    /// makes a strap hand back the same records on every connect, forever.
    case historicalDataResult = 23
    /// Report first and last stored record timestamps, which bounds a backfill.
    case getDataRange = 34

    // MARK: Live streams

    /// Live heart-rate notifications on/off.
    case toggleRealtimeHR = 3
    /// The real control for the type-43 "R10/R11" raw realtime stream. Despite the name,
    /// `stopRawData` (82) does not silence that stream; only this opcode does. Connect sends
    /// `[0x00]` here to stop roughly two frames a second of raw traffic that otherwise consumes
    /// BLE airtime and fills strap flash, crowding out the dense biometric history a backfill
    /// needs. The setting survives reconnects, so this is also how it comes back on.
    case sendR10R11Realtime = 63
    case startRawData = 81
    case stopRawData = 82
    case toggleIMUMode = 106
    /// Optical (PPG) stream toggle. No caller today; kept for the same reason as
    /// `getExtendedBatteryInfo`. Note that on 5/MG this opcode is the save-to-history toggle
    /// rather than a live one, so a future caller cannot treat it as generation-neutral.
    case enableOpticalData = 107
    /// Enter high-frequency sync. This app never sends it: high-freq drains the battery, and
    /// builds that entered it left straps parked there. Kept as public API and as the named
    /// counterpart to the exit we do send.
    case enterHighFreqSync = 96
    /// Leave high-frequency sync. Sent on every connect without checking first, because a parked
    /// strap has no way out on its own and the user has no other lever. Body `[0x00]`.
    case exitHighFreqSync = 97

    // MARK: Config writes (persistent, opt-in gated)

    /// SET_CONFIG / SET_FF_VALUE: write one persistent feature flag by name. This is the 5/MG
    /// "R22" sequence that unlocks deep biometric streams the strap otherwise withholds. Body is
    /// `[0x01]` plus a NUL-padded ASCII flag name and an ASCII value byte. The write outlives a
    /// reboot, which is why it sits behind an explicit opt-in that ships with a restore path.
    /// One flag per write, spaced out; a burst gets dropped.
    case setConfig = 120
    /// SET_DEVICE_CONFIG addresses a different table from `setConfig` — device settings, not
    /// feature flags — so the two are not substitutes and each needs its own opcode. Carries the
    /// broadcast-HR setting that makes the strap advertise as a standard 0x180D sensor. Also
    /// persistent, also behind its own opt-in.
    case setDeviceConfig = 119

    // MARK: Haptics

    /// Play one of the strap's preset haptic patterns. Body `[patternId, loops, 0, 0, 0]`.
    case runHapticsPattern = 79
    /// Interrupt a pattern already playing. Body `[0x00]`.
    case stopHaptics = 122

    // MARK: Firmware alarm

    /// Arm the strap's own alarm for an instant. The firmware owns the timer, so the strap buzzes
    /// with the app backgrounded or killed. Body from `setAlarmPayload(epochSec:)` on 4.0; the
    /// 5/MG body is richer and is built in StrapProtocol.
    case setAlarmTime = 66
    /// Read the armed alarm back. Read-only, and the only way to distinguish an accepted arm from
    /// one the firmware quietly dropped.
    case getAlarmTime = 67
    /// Buzz now, so the user can prove the strap fires before trusting it with a wake alarm.
    case runAlarm = 68
    /// Clear the armed alarm. Body `[0x01]` on 4.0; an earlier `[0x00]` body was acknowledged and
    /// left the alarm armed.
    case disableAlarm = 69

    /// Human-readable name for logs. These strings are the vocabulary in the connect and write
    /// lines users paste into bug reports, and they are how a report gets searched, so every case
    /// answers with something non-empty and recognisable.
    public var label: String {
        switch self {
        case .toggleRealtimeHR:      return "Toggle Realtime HR"
        case .reportVersionInfo:     return "Report Version Info"
        case .setClock:              return "Set Clock"
        case .getClock:              return "Get Clock"
        case .sendHistoricalData:    return "Send Historical Data"
        case .historicalDataResult:  return "Historical Data Result"
        case .getBatteryLevel:       return "Get Battery Level"
        case .getDataRange:          return "Get Data Range"
        case .getHelloHarvard:       return "Get Hello (Harvard)"
        case .getHello:              return "Get Hello (5/MG)"
        case .getAdvertisingNameHarvard: return "Get Advertising Name (Harvard)"
        case .setAdvertisingNameHarvard: return "Set Advertising Name (Harvard)"
        case .startRawData:          return "Start Raw Data"
        case .stopRawData:           return "Stop Raw Data"
        case .enterHighFreqSync:     return "Enter High-Freq Sync"
        case .exitHighFreqSync:      return "Exit High-Freq Sync"
        case .getExtendedBatteryInfo:return "Get Extended Battery Info"
        case .toggleIMUMode:         return "Toggle IMU Mode"
        case .enableOpticalData:     return "Enable Optical Data"
        case .setConfig:             return "Set Config (R22 feature flag)"
        case .setDeviceConfig:       return "Set Device Config (broadcast HR)"
        case .runHapticsPattern:     return "Run Haptics Pattern"
        case .stopHaptics:           return "Stop Haptics"
        case .sendR10R11Realtime:    return "R10/R11 Realtime (raw stream)"
        case .setAlarmTime:          return "Set Alarm Time"
        case .getAlarmTime:          return "Get Alarm Time"
        case .runAlarm:              return "Run Alarm"
        case .disableAlarm:          return "Disable Alarm"
        }
    }

    // MARK: Payload builders

    /// Revision-1 SET_ALARM_TIME body for a 4.0. Nine bytes:
    /// `[0x01][u32 epoch seconds LE][u16 sub-seconds LE][u16 haptic mode LE]`.
    ///
    /// Both trailing pairs are zero here. Sub-seconds count 1/32768 s ticks of the RTC crystal
    /// and this signature only carries whole seconds; haptic mode 0 is the stock wake buzz, the
    /// only value any capture of a real client shows. There is no fourth field to add: a body the
    /// firmware does not recognise is acknowledged and then never fires, which the user sees as a
    /// broken alarm with nothing logged anywhere.
    ///
    /// The haptic-mode pair is not trailing padding that can be dropped for tidiness. A 7-byte
    /// body — this layout minus that `u16`, a shape the reference implementation documents as
    /// reference-only — is accepted, reads back as armed, and never buzzes on some firmware. No
    /// test in this repo would notice.
    ///
    /// `epochSec` must already be expressed in the STRAP's clock frame, with `setClock` landed
    /// first. Armed against an RTC that never took a clock write, the alarm fires whenever that
    /// RTC reaches the value, which for a factory-epoch clock and a present-day timestamp is
    /// decades away — that is, never, while a manual test buzz still works perfectly.
    public static func setAlarmPayload(epochSec: UInt32) -> [UInt8] {
        [0x01,
         UInt8(epochSec & 0xFF),
         UInt8((epochSec >> 8) & 0xFF),
         UInt8((epochSec >> 16) & 0xFF),
         UInt8((epochSec >> 24) & 0xFF),
         0x00, 0x00,   // sub-seconds: whole-second arming only
         0x00, 0x00]   // haptic mode 0: the strap's stock wake buzz
    }

    /// Longest advertising name we will program, counted in UTF-8 bytes. A BLE advertising record
    /// is 31 bytes total and the strap still has to fit its flags and service UUID beside the
    /// name. Past this the strap either truncates the name or stops advertising a usable record,
    /// and a strap that no longer advertises cannot be found in order to be renamed back.
    public static let maxAdvertisingNameBytes = 24

    /// SET_ADVERTISING_NAME_HARVARD body: `[0x00, 0x00] + UTF-8 name + [0x00]`.
    ///
    /// The two leading NULs and the terminator are the shape 4.0 firmware takes, and our own
    /// decoder skips exactly that header and stops at that terminator, so neither end can be
    /// trimmed on one side alone. The MIT engine writes a different body for the same idea
    /// (`[0x01][len][ascii][u32 0]`, capped at 20 ASCII characters); adopting it would compile
    /// and would pass our decode tests, which build their own fixtures, and would still break
    /// renaming against real firmware. Only the existence of a cap carries over.
    ///
    /// Clamping drops whole `Character`s rather than bytes or scalars. Cutting mid-scalar hands
    /// the strap a truncated UTF-8 sequence, which it stores verbatim and advertises back as
    /// mojibake with nothing in the app able to tell malformed from merely wrong.
    public static func advertisingNamePayload(_ name: String) -> [UInt8] {
        var clamped = name
        while clamped.utf8.count > maxAdvertisingNameBytes {
            clamped.removeLast()
        }
        return [0x00, 0x00] + Array(clamped.utf8) + [0x00]
    }

    /// First byte of a command frame's inner block. Read from `PacketType` instead of spelled as
    /// a literal so this builder and the package's own framing cannot drift apart unnoticed.
    static let commandType: UInt8 = PacketType.command

    /// Assemble the bytes to write to the command characteristic:
    /// `[0xAA][length u16 LE][crc8 of those two length bytes][inner…][crc32 of inner, LE]`,
    /// where `inner = [type][seq][opcode] + payload` and `length = inner.count + 4`.
    ///
    /// The `[0x00]` default is load-bearing. Several commands are sent with no arguments and the
    /// firmware expects a single zero byte, not an empty body; removing the default, or changing
    /// it to `[]`, changes the wire form of every one of those sends.
    ///
    /// The inner block is deliberately not zero-padded to a 4-byte boundary, and this deliberately
    /// does not call StrapProtocol's `buildCommand`/`buildFrame`, which pad and then count the
    /// padding in the declared length. Routing through those changes both the declared length and
    /// the CRC32 of every frame whose inner length is not a multiple of four — today the
    /// empty-payload GET_CLOCK and battery keep-alive, and the odd-length rename write, which are
    /// exactly the frames a 4.0 is known to answer. Nothing in Tests/ fails; the symptom is a
    /// strap that stops replying to GET_CLOCK, and the drift correlation alarm arming depends on
    /// disappears with it.
    public func frame(seq: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
        let inner: [UInt8] = [Self.commandType, seq, rawValue] + payload
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        let checksum = crc32(inner)
        return [0xAA] + lenBytes + [crc8(lenBytes)] + inner + [
            UInt8(checksum & 0xFF),
            UInt8((checksum >> 8) & 0xFF),
            UInt8((checksum >> 16) & 0xFF),
            UInt8((checksum >> 24) & 0xFF),
        ]
    }
}
