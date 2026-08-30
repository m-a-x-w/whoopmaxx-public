import Foundation

extension ParsedValue {
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .bool(let v): return v ? 1 : 0
        case .string, .intArray: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .bool, .string, .intArray: return nil
        }
    }
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public var intArrayValue: [Int]? {
        if case .intArray(let v) = self { return v }
        return nil
    }
}

/// A decoded field, kept alongside its position so a frame can be rendered byte-by-byte in a
/// diagnostic view rather than only as a bag of values.
public struct FieldSpec: Codable, Equatable, Sendable {
    public let off: Int
    public let len: Int
    public let name: String
    /// Coarse grouping — `frame`, `time`, `hr`, `rr`, `optical`, `motion`, `event`.
    public let cat: String
    public let value: ParsedValue?
    public let note: String?

    public init(off: Int, len: Int, name: String, cat: String,
                value: ParsedValue? = nil, note: String? = nil) {
        self.off = off; self.len = len; self.name = name
        self.cat = cat; self.value = value; self.note = note
    }
}

/// A frame rendered as named values — the inspection view the collector, router and diagnostic
/// screens read.
///
/// `ok` and `crcOK` are separate on purpose. `crcOK` says the bytes survived the link; `ok` says
/// this decoder could also make sense of them. A frame that is intact but unrecognised is
/// `crcOK && !ok`, and that combination has to stay reachable: it is the signal to archive the
/// raw bytes for re-decode rather than discard them.
public struct ParsedFrame: Equatable, Sendable {
    public let ok: Bool
    public let crcOK: Bool
    public let lenBytes: Int
    public let seq: Int
    public let typeName: String
    /// Present on command and command-response frames only.
    public let cmdName: String?
    public let fields: [FieldSpec]
    /// Named values, keyed by field name.
    public let parsed: [String: ParsedValue]

    public init(ok: Bool, crcOK: Bool, lenBytes: Int, seq: Int, typeName: String,
                cmdName: String? = nil, fields: [FieldSpec] = [], parsed: [String: ParsedValue] = [:]) {
        self.ok = ok; self.crcOK = crcOK; self.lenBytes = lenBytes; self.seq = seq
        self.typeName = typeName; self.cmdName = cmdName; self.fields = fields; self.parsed = parsed
    }
}

/// Turns validated frames into named values.
public enum Interpreter {

    /// Interpret one frame envelope.
    public static func interpret(_ frame: StrapFrame, rawLength: Int? = nil) -> ParsedFrame {
        let inner = frame.inner
        // Fold the battery-pack sub-types onto the strap's vocabulary BEFORE anything reads the
        // type — both the name below and the dispatch switch. A WHOOP 5/MG METADATA frame carries
        // type 56, so without this it names itself PUFFIN_METADATA and falls to the switch's
        // default (`ok = false`); `Backfiller` routes exactly those frames here expecting the alias
        // ("56 PUFFIN_METADATA which the WHOOP 5/MG envelope aliases onto the same name"), and the
        // offload stalls on gen5 with no decode error to show for it.
        let type = canonicalPacketType(frame.packetType)
        let typeName = Schema.packetTypeName(type)
        let seq = frame.sequence
        let len = rawLength ?? inner.count

        // An intact frame whose revision this decoder cannot map must not be interpreted with
        // the field offsets of a revision it is not — that is how a body byte becomes an opcode.
        guard frame.decodable else {
            return ParsedFrame(ok: false, crcOK: frame.payloadCRCOK, lenBytes: len,
                               seq: seq, typeName: typeName)
        }

        var parsed: [String: ParsedValue] = [:]
        var fields: [FieldSpec] = [
            FieldSpec(off: 0, len: 1, name: "packet_type", cat: "frame", value: .string(typeName)),
            FieldSpec(off: 1, len: 1, name: "seq", cat: "frame", value: .int(seq)),
        ]
        var cmdName: String?
        var ok = true

        switch UInt8(truncatingIfNeeded: type) {
        case PacketType.historicalData, PacketType.realtimeData:
            if let r = parseR24(inner) {
                parsed["hist_version"] = .int(r.histVersion)
                parsed["unix"] = .int(Int(r.tsEpoch))
                parsed["subseconds"] = .int(Int(r.tsSubsec))
                parsed["counter"] = .int(Int(r.counter))
                if r.hr > 0 { parsed["heart_rate"] = .int(r.hr) }
                if !r.rrIntervalsMs.isEmpty {
                    parsed["rr_intervals"] = .intArray(r.rrIntervalsMs)
                }
                if r.accelG.count == 3 {
                    parsed["gravity_x"] = .double(r.accelG[0])
                    parsed["gravity_y"] = .double(r.accelG[1])
                    parsed["gravity_z"] = .double(r.accelG[2])
                }
                // 0 is the ADC-absent sentinel throughout this stack — publish only real reads,
                // so a consumer's `> 0` gate and a missing key mean the same thing.
                if r.spo2RedRaw > 0 { parsed["spo2_red"] = .int(r.spo2RedRaw) }
                if r.spo2IrRaw > 0 { parsed["spo2_ir"] = .int(r.spo2IrRaw) }
                if r.skinTempRaw > 0 { parsed["skin_temp_raw"] = .int(r.skinTempRaw) }
                if r.respRateRaw > 0 { parsed["resp_rate_raw"] = .int(r.respRateRaw) }
                if r.ambientRaw > 0 { parsed["ambient_raw"] = .int(r.ambientRaw) }
                if r.histVersion == 25 { parsed["ppg_waveform"] = .bool(true) }
                fields.append(FieldSpec(off: 7, len: 4, name: "unix", cat: "time", value: parsed["unix"]))
                fields.append(FieldSpec(off: 17, len: 1, name: "heart_rate", cat: "hr", value: parsed["heart_rate"]))
            } else if let rt = parseRealtimeHr(inner) {
                parsed["unix"] = .int(Int(rt.tsEpoch))
                parsed["heart_rate"] = .int(rt.bpm)
                parsed["wearing"] = .bool(rt.wearing)
                if !rt.rrIntervalsMs.isEmpty {
                    parsed["rr_intervals"] = .intArray(rt.rrIntervalsMs)
                }
            } else {
                ok = false
            }

        case PacketType.realtimeRawData:
            // The R10/R11 raw flood (type 43) — the stream SEND_R10_R11_REALTIME turns on, and the
            // only lane a WHOOP 4.0 actually delivers live heart rate on. Header: cmd at inner[2],
            // record header u32 at [3], DEVICE-epoch timestamp u32 at [7], subseconds u16 at [11];
            // the sensor payload begins at inner[17]. Two variants, told apart by size: IMU
            // (inner 1920) opens hr u8 / rr-count u8 / four u16 R-R slots, optical (inner 1924)
            // carries PPG and no heart rate. Omitting this case routes every frame to
            // `default: ok = false`, and FrameRouter's first guard then drops the entire live
            // stream while historical offload (type 47) still decodes — a Live screen that says
            // "No live signal" against a strap that is demonstrably syncing.
            guard inner.count >= 13 else { ok = false; break }
            parsed["timestamp"] = .int(Int(u32(inner, 7)))
            parsed["subseconds"] = .int(Int(u16(inner, 11)))
            fields.append(FieldSpec(off: 11, len: 4, name: "timestamp", cat: "time",
                                    value: parsed["timestamp"]))
            if inner.count == Schema.rawImuInnerLength {
                // 0 is the strap's "no reading this frame", not a decode failure — emit nothing
                // and stay ok, matching every other lane's zero rule.
                let hr = Int(inner[17])
                if hr >= 1, hr <= 250 { parsed["heart_rate"] = .int(hr) }
                fields.append(FieldSpec(off: 17, len: 1, name: "heart_rate", cat: "hr",
                                        value: parsed["heart_rate"]))
                // A count above the four slots the layout holds means these are not the bytes this
                // map claims; emit no intervals rather than reading sensor samples as beats.
                let declared = Int(inner[18])
                if declared > 0, declared <= 4 {
                    var rr: [Int] = []
                    for i in 0..<declared {
                        let v = Int(u16(inner, 19 + 2 * i))
                        if v >= minRRIntervalMs, v <= maxRRIntervalMs { rr.append(v) }
                    }
                    if !rr.isEmpty { parsed["rr_intervals"] = .intArray(rr) }
                }
            }

        case PacketType.event:
            // The event number rides in the opcode slot; its timestamp follows at inner[4].
            let id = frame.opcode
            parsed["event"] = .string(Schema.eventName(id))
            parsed["event_id"] = .int(id)
            let ts = Int(u32(inner, 4))
            if ts > 0 { parsed["event_timestamp"] = .int(ts) }
            fields.append(FieldSpec(off: 2, len: 1, name: "event", cat: "event", value: parsed["event"]))
            fields.append(FieldSpec(off: 4, len: 4, name: "event_timestamp", cat: "time",
                                    value: parsed["event_timestamp"]))

            // BATTERY_LEVEL carries the pack state in the event BODY. The event envelope is
            // [type][seq][u16 event id][u32 unix][u16 subsec][u16 body len][body…], so the body
            // starts at inner[12]: revision at body[0], state-of-charge u16 at body[1], millivolts
            // u16 at body[5], charger flag at body[9].
            //
            // The charge is DECI-percent — a different convention from GET_BATTERY_LEVEL's command
            // response, which is direct percent. Reading this one as whole percent reports a full
            // strap as 1000%. The charger flag is body[9] and not body[10]: [10] is always zero, so
            // reading it there leaves `charging` permanently false.
            if id == Schema.batteryLevelEvent, inner.count >= 24 {
                let deci = Int(u16(inner, 13))
                let pct = (Double(deci) / 10 * 10).rounded() / 10
                // Out of range means these are not the bytes this map claims; a fabricated charge
                // reading drives the low-battery alert and the runtime estimate.
                if pct >= 0, pct <= 100 { parsed["battery_pct"] = .double(pct) }
                parsed["battery_mv"] = .int(Int(u16(inner, 17)))
                parsed["battery_charging"] = .int(inner[21] != 0 ? 1 : 0)
            }

        case PacketType.commandResponse, PacketType.command:
            cmdName = Schema.commandName(frame.opcode)
            parsed["command"] = .string(cmdName!)
            parsed["resp_cmd"] = parsed["command"]
            fields.append(FieldSpec(off: 2, len: 1, name: "command", cat: "frame", value: parsed["command"]))

            // GET_CLOCK's reply carries the strap's own RTC, and that is the reference the offload
            // corrects records against. Reply body starts at inner[3] — echoed request seq at [3],
            // status at [4] — so the u32 seconds sit at inner[5] with u32 subseconds behind them.
            // (Corroborated against a real GET_DATA_RANGE reply from this repo's own strap log,
            // where inner[3]/inner[4]/inner[5] read as echoed-seq / status / revision=1.)
            //
            // Read the field; never scan for a value that "looks like an epoch". The bytes at
            // inner[4] straddle status and the first three clock bytes, and that straddle is in
            // range for any current wall clock — so a scan finds it first and is essentially never
            // the strap's real clock.
            //
            // The window here is deliberately NOT the record plausibility gate. That one rejects
            // anything past wallNow + a day, which is right for a measurement and exactly wrong for
            // an RTC: a strap sitting years in the future is the case this reference exists to
            // correct. Gating it there withholds the reference when it is most needed, leaves the
            // offset at zero, and silently drops every record as implausible.
            if frame.opcode == Schema.getClockOpcode, inner.count >= 9 {
                let secs = Int(u32(inner, 5))
                if secs >= MIN_PLAUSIBLE_UNIX && secs <= MAX_PLAUSIBLE_UNIX {
                    parsed["clock"] = .int(secs)
                    fields.append(FieldSpec(off: 5, len: 4, name: "clock", cat: "time",
                                            value: parsed["clock"]))
                }
            }

            // GET_BATTERY_LEVEL's reply is DECI-percent in the u16 at inner[5] (reply body starts
            // at inner[3]: echoed seq, status, then the value). FrameRouter reads `battery_pct`
            // off every COMMAND_RESPONSE, so without this decode `refreshBattery()` round-trips a
            // reply nothing can read and the live battery figure waits on the strap's own
            // eight-minute BATTERY_LEVEL event instead.
            if frame.opcode == Schema.getBatteryLevelOpcode, inner.count >= 7 {
                let pct = Double(u16(inner, 5)) / 10
                if pct >= 0, pct <= 100 { parsed["battery_pct"] = .double(pct) }
            }

            // REPORT_VERSION_INFO (WHOOP 4.0): three status bytes then eight LE u32s — the first
            // four are the harvard (strap) firmware a.b.c.d, the next four boylston. BLEManager
            // sends this on every gen4 connect and FrameRouter shows `fw_harvard`; with no decode
            // the firmware row simply never fills.
            if frame.opcode == Schema.reportVersionInfoOpcode, inner.count >= 34 {
                func quad(_ at: Int) -> String {
                    // The final u32 can be truncated off a short reply; render what arrived.
                    let parts = (0..<4).map { i -> String in
                        at + 4 * i + 4 <= inner.count ? String(u32(inner, at + 4 * i)) : "0"
                    }
                    return parts.joined(separator: ".")
                }
                parsed["fw_harvard"] = .string(quad(6))
                parsed["fw_boylston"] = .string(quad(22))
            }

            // GET_HELLO (WHOOP 5/MG): firmware version rides at reply offset 93 (inner[96]),
            // guarded by the generation byte reading 50 ("5.x") so a different layout fails
            // closed instead of publishing garbage.
            if frame.opcode == Schema.getHelloOpcode, inner.count >= 100, inner[96] == 50 {
                parsed["fw_version"] = .string("\(inner[96]).\(inner[97]).\(inner[98]).\(inner[99])")
            }

        case PacketType.metadata:
            let sub = frame.opcode
            let metaName = Schema.metadataName(sub)
            parsed["meta_type"] = .string(metaName)
            parsed["metadata"] = parsed["meta_type"]

            // HISTORY_END additionally carries the strap's own clock and the 8-byte trim token
            // (`[u32 trim_page][u32 wrap_count]`) that the ACK echoes back verbatim. Without these
            // two values `classifyHistoricalMeta` can never answer `.end`, the offload never acks,
            // and the strap never advances its cursor — the whole backlog stalls while the live
            // stream keeps working, because the live stream does not come through here.
            //
            // The offsets are inner-relative and identical on gen4 and gen5, which the envelope
            // difference hides: `Backfiller.endData` slices the same token out of the RAW frame at
            // frame[17] on gen4 and frame[21] on gen5, and both are inner[13] once the 4-byte and
            // 8-byte headers come off. Requiring the full 21 bytes matches that slice — an END too
            // short to hold the token cannot be acked anyway, since the echo would be truncated and
            // the strap would refuse it.
            //
            // The clock is emitted RAW on purpose. Its only consumer is the corrupt-RTC detector,
            // which needs the bad value in order to report it and which excludes the 0xFFFFFFFF
            // sentinel itself. Gating it on plausibility here would withhold `unix`, and the
            // classifier demands `unix` AND `trim_cursor` together — so a strap with an unset RTC
            // would never ack and would wedge exactly where the detector is designed to let it
            // through ("the ack still proceeds ... refusing to ack would only wedge the offload").
            if metaName == "HISTORY_END", inner.count >= 21 {
                parsed["unix"] = .int(Int(u32(inner, 3)))
                parsed["trim_cursor"] = .int(Int(u32(inner, 13)))
            }

        case PacketType.consoleLogs:
            // Log text, deliberately not decoded into fields — it is free-form and any field map
            // laid over it would be inventing structure.
            parsed["console"] = .bool(true)

        default:
            ok = false
        }

        return ParsedFrame(ok: ok, crcOK: frame.payloadCRCOK, lenBytes: len, seq: seq,
                           typeName: typeName, cmdName: cmdName, fields: fields, parsed: parsed)
    }

    /// Interpret every frame carved out of a raw byte stream.
    public static func interpret(stream bytes: [UInt8], profile: BandProfile = .gen4) -> [ParsedFrame] {
        FrameReassembler(profile: profile).feed(bytes).map { interpret($0) }
    }
}


// MARK: - Device-family convenience
//
// The app layer carries a DeviceFamily rather than a BandProfile and wants one call that both
// validates and interprets. A frame that fails to parse comes back as `ok: false` rather than
// nil: "these bytes are not a frame" is a result the caller has to record, not an absence.

extension BandProfile {
    public init(family: DeviceFamily) { self = family == .whoop5 ? .gen5 : .gen4 }
}

/// Parse and interpret one complete frame in a single call.
public func parseFrame(_ raw: [UInt8], family: DeviceFamily = .whoop4) -> ParsedFrame {
    let profile = BandProfile(family: family)
    guard let f = parseEnvelope(raw, profile: profile) else {
        return ParsedFrame(ok: false, crcOK: false, lenBytes: raw.count, seq: -1,
                           typeName: "UNPARSEABLE")
    }
    return Interpreter.interpret(f, rawLength: raw.count)
}
