// Derived from ParthJadhav/noop, PolyForm Noncommercial License 1.0.0, Copyright 2026 NoopApp.
// Required Notice: Copyright 2026 NoopApp (https://github.com/ParthJadhav/noop)
// Terms: https://polyformproject.org/licenses/noncommercial/1.0.0 — see ../../LICENSE.

import Foundation
import StrapProtocol
import StrapAnalytics

/// Decodes one already-reassembled frame and folds it into `LiveState`. No CoreBluetooth here, so
/// every routing decision is reachable from a unit test with a byte array.
@MainActor
public final class FrameRouter {
    private let state: LiveState

    /// Fired for every EVENT the strap pushes. BLEManager wires it to a rate-limited
    /// `requestSync(.strap)`; left nil in tests, where a sync would have nothing to talk to.
    var onSyncTrigger: (() -> Void)?

    /// Envelope dialect to decode with, set per connection once the model is known. The default is
    /// load-bearing: frames can arrive before BLEManager assigns it, and every offset in this file
    /// (including the type-byte pre-check below) keys off it, so a different default silently
    /// mis-reads the first frames of a connection rather than failing loudly.
    var family: DeviceFamily = .whoop4

    public init(state: LiveState) {
        self.state = state
    }

    /// Route one complete frame (0xAA SOF through the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK else { return }

        // Plain (unpublished) liveness counter, so the raw flood costs nothing here.
        state.noteFrameRouted()

        // Publish only on a genuine change. Each `@Published` write fires objectWillChange and
        // re-evaluates the whole live console body, and these frames arrive as separate BLE
        // notifications that SwiftUI cannot coalesce. Under the type-43 raw flood — same type,
        // hundreds of frames — an unconditional write turns a steady stream into a re-render per
        // notification and the UI feels hung on device. Nothing tests this; it is only visible
        // with a real strap attached.
        if state.lastFrameType != parsed.typeName {
            if TestCentre.active(.connection) {
                state.append(log: "frameTiming type=\(parsed.typeName) t=\(Int(Date().timeIntervalSince1970))s",
                             domain: .connection)
            }
            state.lastFrameType = parsed.typeName
        }

        switch parsed.typeName {
        case "REALTIME_DATA", "REALTIME_RAW_DATA":
            // Live streams are ephemeral: they drive the console only, never persistence. Out-of-band
            // values are the stream's own dropouts (0 on an unworn strap), not real bradycardia.
            // Same change-guard reasoning as lastFrameType — the raw stream repeats one HR byte
            // across many frames.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220 {
                state.noteHRSeen()   // before the change guard — a steady rate must still read alive
            }
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220, state.heartRate != hr {
                state.heartRate = hr
                if TestCentre.active(.sleep) {
                    state.recordSleepLiveHr(ts: Int(Date().timeIntervalSince1970), bpm: hr)
                }
            }
            // Most realtime frames report rr_count=0. Forwarding an empty array would clear R-R
            // that the standard 0x2A37 heart-rate profile supplied, leaving HRV blank on a link
            // where it was actually available.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.setRRIntervals(rr)
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            // WHOOP 4.0 answers REPORT_VERSION_INFO with `fw_harvard`; 5/MG answers GET_HELLO with
            // `fw_version`. Take whichever this decode produced. It is fixed for the connection, so
            // only republish when it actually changes.
            if let fw = parsed.parsed["fw_version"]?.stringValue ?? parsed.parsed["fw_harvard"]?.stringValue,
               state.strapFirmware != fw {
                state.strapFirmware = fw
            }
            // The schema has no field decode for the name/rename/alarm replies, so these read the
            // frame bytes directly.
            //
            // Match cmdName BY PREFIX. The decoder renders it as "NAME(rawValue)" — e.g.
            // "GET_ALARM_TIME(67)" — so `==` compiles, never matches, and fails silently: the
            // rename and name readouts simply stay blank on device while the test suite stays green,
            // because nothing here covers COMMAND_RESPONSE dispatch.
            if family == .whoop4, let cmd = parsed.cmdName {
                if cmd.hasPrefix("GET_ADVERTISING_NAME_HARVARD") {
                    // An empty decode means the field was all NULs; keeping the previous good name
                    // beats blanking the Devices row on one bad read.
                    if let name = Self.advertisingName(in: frame), !name.isEmpty {
                        state.advertisingName = name
                    }
                } else if cmd.hasPrefix("SET_ADVERTISING_NAME_HARVARD") {
                    state.renameStatus = Self.renameAck(for: Self.commandResultByte(in: frame))
                } else if cmd.hasPrefix("GET_ALARM_TIME") {
                    // Readback after arming, so a support log records what the STRAP believes is
                    // armed rather than only what we sent. LOG-ONLY and it must stay that way: the
                    // 4.0 reply layout is undocumented, so an unrecognised payload is logged as raw
                    // hex instead of being allowed to cancel or re-arm anything. The wording says
                    // "strap reports", never "verified", so one firmware's answer format cannot
                    // mislead a triage.
                    if let epoch = Self.armedAlarmEpoch(in: frame) {
                        state.append(log: "Alarm: strap reports armed for \(Self.alarmLocalTime(epoch: epoch)) (epoch \(epoch))")
                    } else {
                        state.append(log: "Alarm: strap answered the alarm readback with an unrecognised payload (raw \(Self.commandResponsePayloadHex(in: frame) ?? "empty")) - layout undocumented, log-only")
                    }
                }
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                // BLE_REALTIME_HR_ON/OFF is our own live-stream toggle echoed back. It fires on
                // every connect and would otherwise be the only thing the "Last Event" row ever
                // shows.
                if !ev.hasPrefix("BLE_REALTIME_HR") {
                    state.lastEvent = ev
                }
                // Any pushed event means the strap may be holding new records. Fired for the
                // suppressed toggle too: what it says matters less than that it arrived.
                onSyncTrigger?()
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // The charging flag only. Battery percentage keeps its family-specific source, and
                // this path never sees replayed history (backfill frames bypass handle(frame:)), so
                // it needs no freshness gate of its own.
                if ev.hasPrefix("BATTERY_LEVEL"),
                   let ch = parsed.parsed["battery_charging"]?.intValue {
                    state.charging = (ch != 0)
                }
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                } else if ev.hasPrefix("STRAP_DRIVEN_ALARM_EXECUTED") {
                    // Log the fire, so a "did it actually buzz?" report is answerable from the strap
                    // log alone rather than from the user's memory. The re-arm writes its own armed
                    // line right after, and the pair is meant to read as one sequence.
                    state.append(log: "Alarm: strap-driven wake fired (event 57), re-arming the next day's instant")
                    // The firmware alarm is a single absolute instant with no recurrence, so a fire
                    // consumes it. Re-arm tomorrow's; the daily/foreground re-arm covers the times
                    // this event is not observed.
                    state.onSmartAlarmFired?()
                }
            }

        default:
            break
        }
    }

    // MARK: - WHOOP 4.0 COMMAND_RESPONSE byte walks

    /// Where the inner `[type][seq][cmd][origin_seq][result][payload…]` starts: SOF(1) + length(2)
    /// + crc8(1).
    private nonisolated static let whoop4InnerOffset = 4

    /// Payload bytes of a WHOOP 4.0 COMMAND_RESPONSE: everything after the five inner header bytes,
    /// stopping at `length`, which is where the crc32 trailer begins. nil when the frame is too
    /// short to carry one. Every other decode below walks the envelope through this, so the bounds
    /// arithmetic exists once.
    nonisolated static func commandResponsePayload(in frame: [UInt8]) -> [UInt8]? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)
        let start = whoop4InnerOffset + 5
        guard length <= frame.count, start < length else { return nil }
        return Array(frame[start..<length])
    }

    /// Advertising name from a GET_ADVERTISING_NAME reply.
    ///
    /// The name is a NUL-TERMINATED string inside a buffer the strap never clears, not a run of
    /// printable bytes. Renaming to something shorter leaves the old name's tail sitting past the
    /// terminator, so filtering the whole field for printable ASCII concatenates it: "WHOOP" reads
    /// back as "WHOOPx" or "WHOOP;", the stray character being whatever the previous name ended
    /// with. Stopping at the first terminator is what removes it.
    ///
    /// Leading NULs are dropped rather than treated as a terminator because the reply carries a
    /// header of unpinned width; truncating there would return empty on every read. The known cost
    /// is that a field that is empty but holds residue decodes as the residue — pinned by the tests
    /// as a limitation, not a bug to "fix" without a capture that pins the header width.
    ///
    /// Returns "" (not nil) for an all-NUL field; the caller's non-empty guard is what suppresses it.
    static func advertisingName(in frame: [UInt8]) -> String? {
        guard let field = commandResponsePayload(in: frame) else { return nil }
        let name = field.drop { $0 == 0x00 }.prefix { $0 != 0x00 }
        return String(decoding: name.filter { $0 >= 32 && $0 < 127 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The result byte of a COMMAND_RESPONSE: the fifth inner byte, after type/seq/cmd/origin_seq.
    static func commandResultByte(in frame: [UInt8]) -> Int? {
        let idx = whoop4InnerOffset + 4
        return idx < frame.count ? Int(frame[idx]) : nil
    }

    /// Lowercase space-separated hex of the payload, for the diagnostic fallback when a readback
    /// does not decode. nil when there is no payload to print.
    nonisolated static func commandResponsePayloadHex(in frame: [UInt8]) -> String? {
        guard let payload = commandResponsePayload(in: frame), !payload.isEmpty else { return nil }
        return payload.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Alarm readback (GET_ALARM_TIME)

    /// An armed alarm is always near now, so anything outside 2017...2100 is garbage, a zeroed
    /// field, or a strap with nothing armed. Rejecting it makes the caller log raw hex instead of a
    /// confidently wrong date. Bounds inclusive.
    nonisolated static func isPlausibleAlarmEpoch(_ epoch: UInt32) -> Bool {
        (1_500_000_000...4_102_444_800).contains(epoch)
    }

    /// Armed epoch from a GET_ALARM_TIME reply, decoded defensively because the 4.0 layout is
    /// undocumented: first the SET_ALARM_TIME mirror (`[0x01][u32 LE epoch]…`, the shape we arm
    /// with), then a bare leading u32 LE.
    ///
    /// That order is not cosmetic. Trying the bare u32 first reads a 0x01-prefixed payload one byte
    /// short, and whenever that shifted value happens to land inside the plausible range it is
    /// accepted and logged as a real armed time.
    nonisolated static func armedAlarmEpoch(in frame: [UInt8]) -> UInt32? {
        guard let payload = commandResponsePayload(in: frame) else { return nil }
        func u32le(at i: Int) -> UInt32? {
            guard payload.count >= i + 4 else { return nil }
            return UInt32(payload[i])
                | (UInt32(payload[i + 1]) << 8)
                | (UInt32(payload[i + 2]) << 16)
                | (UInt32(payload[i + 3]) << 24)
        }
        if payload.first == 0x01, let e = u32le(at: 1), isPlausibleAlarmEpoch(e) { return e }
        if let e = u32le(at: 0), isPlausibleAlarmEpoch(e) { return e }
        return nil
    }

    /// Device-local render for the readback log line, in the same format the arming line uses so
    /// the two read as one sequence.
    nonisolated static func alarmLocalTime(epoch: UInt32) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm zzz"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - Rename acknowledgement

    /// User-facing ack for a SET_ADVERTISING_NAME result byte (0 failure, 1 success, 2 pending,
    /// 3 unsupported). An absent byte is reported as sent-but-unconfirmed rather than as success.
    static func renameAck(for result: Int?) -> String {
        switch result {
        case 1:  return "Renamed, your strap reboots to apply the new name."
        case 0:  return "The strap rejected the rename (failure)."
        case 2:  return "Rename pending…"
        case 3:  return "This strap firmware doesn't support renaming."
        default: return "Rename sent - re-scan to confirm the new name."
        }
    }

    // MARK: - Live gestures during an offload

    /// How fresh a gesture's own timestamp must be to fire its live handler.
    static let liveGestureWindowSeconds = 45

    /// Fire ONLY the physical-gesture handlers (double-tap, wrist on/off) for a frame that arrives
    /// while `handle(frame:)` is bypassed — during a backfill offload, which on 5/MG runs for
    /// minutes and would otherwise swallow every tap the wearer makes.
    ///
    /// `now` must be in the STRAP's clock domain, the same domain as event_timestamp (BLEManager
    /// passes its strapClockNow). Comparing against wall time instead would reject every gesture on
    /// a strap whose RTC has drifted. The window is symmetric because a strap RTC running ahead
    /// stamps events in the future, and a one-sided age check never looks at that side — a
    /// future-dated replay would sail straight through and fire a wrist handler for a gesture made
    /// hours ago.
    ///
    /// Deliberately touches nothing else: no lastEvent, no sync trigger, no bonded/charging, no
    /// frame-type stamp. Excluding those side effects during an offload is the whole point.
    func dispatchLiveGestureIfFresh(frame: [UInt8], now: Int = Int(Date().timeIntervalSince1970)) {
        // One-byte type check BEFORE parseFrame. An offload is almost entirely type-47 historical
        // records; parsing every one of them just to discover it is not an event burns CPU for the
        // whole multi-minute drain. Type byte sits at frame[4] on WHOOP 4.0, frame[8] on 5/MG.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex, frame[typeIndex] == 48 else { return }

        let parsed = parseFrame(frame, family: family)
        guard parsed.ok, parsed.crcOK else { return }
        guard parsed.typeName == "EVENT", let ev = parsed.parsed["event"]?.stringValue else { return }
        // Fail closed: a missing or zero timestamp is not evidence of a live gesture.
        guard let ts = parsed.parsed["event_timestamp"]?.intValue, ts > 0 else { return }
        guard abs(now - ts) <= FrameRouter.liveGestureWindowSeconds else { return }

        if ev.hasPrefix("DOUBLE_TAP") {
            state.onDoubleTap?()
        } else if ev.hasPrefix("WRIST_ON") {
            if !state.worn { state.worn = true; state.onWristChange?(true) }
        } else if ev.hasPrefix("WRIST_OFF") {
            if state.worn { state.worn = false; state.onWristChange?(false) }
        }
    }
}
