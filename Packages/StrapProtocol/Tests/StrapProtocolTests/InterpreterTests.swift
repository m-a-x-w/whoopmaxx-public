import XCTest
@testable import StrapProtocol

final class RealtimeTests: XCTestCase {

    private func packet(hr: UInt8, rrCount: UInt8 = 0, rr: [UInt16] = [],
                        wearing: UInt8? = nil, length: Int = 20) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0] = PacketType.realtimeData
        b[2] = 0x10                                   // ts
        if length > 8 { b[8] = hr }
        if length > 9 { b[9] = rrCount }
        for (i, v) in rr.enumerated() where 10 + 2 * i + 1 < length {
            b[10 + 2 * i] = UInt8(v & 0xFF); b[11 + 2 * i] = UInt8(v >> 8)
        }
        if let w = wearing, length > 18 { b[18] = w }
        return b
    }

    func testDecodesHrAndIntervals() throws {
        let p = packet(hr: 62, rrCount: 2, rr: [900, 910], wearing: 1)
        let r = try XCTUnwrap(parseRealtimeHr(p))
        XCTAssertEqual(r.bpm, 62)
        XCTAssertEqual(r.rrIntervalsMs, [900, 910])
        XCTAssertTrue(r.wearing)
    }

    func testReadsAllFourSlotsNotJustTheFirstTwo() throws {
        let r = try XCTUnwrap(parseRealtimeHr(packet(hr: 60, rrCount: 4, rr: [800, 810, 820, 830])))
        XCTAssertEqual(r.rrIntervalsMs.count, 4, "dropping beats 3 and 4 changes RMSSD")
    }

    func testRejectsHrOutsideALivingRange() {
        XCTAssertNil(parseRealtimeHr(packet(hr: 0)))
        XCTAssertNil(parseRealtimeHr(packet(hr: 251)))
    }

    func testShortPacketHasNoIntervalsButStillDecodes() throws {
        // 9 bytes carry timestamp and HR and nothing more. That is not a failed decode.
        let r = try XCTUnwrap(parseRealtimeHr(packet(hr: 58, length: 9)))
        XCTAssertEqual(r.bpm, 58)
        XCTAssertEqual(r.rrIntervalsMs, [])
        XCTAssertTrue(r.wearing, "a truncated packet is not evidence the strap came off")
    }

    func testCountBeyondTheFourSlotsYieldsNoIntervals() throws {
        // A count that cannot fit the layout means these are not the bytes we think they are —
        // reading on would take the wear byte as a heartbeat.
        let r = try XCTUnwrap(parseRealtimeHr(packet(hr: 60, rrCount: 9, rr: [800, 810])))
        XCTAssertEqual(r.rrIntervalsMs, [])
    }
}

final class InterpreterTests: XCTestCase {

    func testCommandFrameNamesItsOpcode() {
        let raw = buildCommand(seq: 5, opcode: Cmd.setAlarmTime, payload: [0x01])
        let p = Interpreter.interpret(parseEnvelope(raw)!)
        XCTAssertTrue(p.ok)
        XCTAssertTrue(p.crcOK)
        XCTAssertEqual(p.typeName, "COMMAND")
        XCTAssertEqual(p.seq, 5)
        XCTAssertEqual(p.cmdName, "SET_ALARM_TIME")
        XCTAssertEqual(p.parsed["command"]?.stringValue, "SET_ALARM_TIME")
    }

    func testUnknownOpcodeNamesTheNumberItCouldNotResolve() {
        let raw = buildCommand(seq: 1, opcode: 0xEE)
        let p = Interpreter.interpret(parseEnvelope(raw)!)
        XCTAssertEqual(p.cmdName, "UNKNOWN(238)", "an unmapped opcode must not render blank")
    }

    func testHistoricalRecordFillsTheKeysTheCollectorReads() throws {
        var inner = [UInt8](repeating: 0, count: 89)
        inner[0] = PacketType.historicalData
        inner[1] = 24
        inner[7] = 0x40                                    // unix
        inner[17] = 61                                     // hr
        inner[18] = 1; inner[19] = 0x2C; inner[20] = 0x01  // one 300 ms beat
        inner[44] = 0x00; inner[45] = 0x00; inner[46] = 0x80; inner[47] = 0x3F   // accel z = 1 g
        inner[68] = 0x10                                   // skin_temp_raw
        let p = Interpreter.interpret(parseEnvelope(buildFrame(inner))!)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 24)
        XCTAssertEqual(p.parsed["unix"]?.intValue, 0x40)
        XCTAssertEqual(p.parsed["heart_rate"]?.intValue, 61)
        XCTAssertEqual(p.parsed["rr_intervals"]?.intArrayValue, [300])
        XCTAssertEqual(p.parsed["gravity_x"]?.doubleValue, 0)
        XCTAssertEqual(p.parsed["skin_temp_raw"]?.intValue, 0x10)
    }

    func testAbsentAdcReadsAreOmittedRatherThanPublishedAsZero() {
        // 0 is the ADC-absent sentinel. A missing key and a `> 0` gate must agree.
        var inner = [UInt8](repeating: 0, count: 89)
        inner[0] = PacketType.historicalData
        inner[1] = 24
        inner[17] = 60
        inner[46] = 0x80; inner[47] = 0x3F
        let p = Interpreter.interpret(parseEnvelope(buildFrame(inner))!)
        XCTAssertNil(p.parsed["spo2_red"])
        XCTAssertNil(p.parsed["skin_temp_raw"])
    }

    func testEventFrameNamesTheEventAndItsTimestamp() {
        // The event number rides in the opcode slot at inner[2]; the timestamp follows at [4].
        var inner: [UInt8] = [PacketType.event, 1, 60, 0, 0, 0, 0, 0]
        inner[4] = 0x00; inner[5] = 0x94; inner[6] = 0x35; inner[7] = 0x77   // a plausible epoch
        let p = Interpreter.interpret(parseEnvelope(buildFrame(inner))!)
        XCTAssertEqual(p.typeName, "EVENT")
        XCTAssertNotNil(p.parsed["event"]?.stringValue)
        XCTAssertEqual(p.parsed["event_id"]?.intValue, 60)
        XCTAssertEqual(p.parsed["event_timestamp"]?.intValue, 0x77359400)
    }

    func testZeroEventTimestampIsOmittedSoConsumersFailClosed() {
        let inner: [UInt8] = [PacketType.event, 1, 60, 0, 0, 0, 0, 0]
        let p = Interpreter.interpret(parseEnvelope(buildFrame(inner))!)
        XCTAssertNil(p.parsed["event_timestamp"], "a zero epoch is absent, not 1970")
    }

    func testUnparseableBytesReportRatherThanVanish() {
        let p = parseFrame([0x11, 0x22], family: .whoop4)
        XCTAssertFalse(p.ok)
        XCTAssertEqual(p.typeName, "UNPARSEABLE", "not a frame is a result the caller must record")
    }

    func testFamilySelectsTheHeaderShape() {
        let raw = buildCommand(seq: 4, opcode: Cmd.runAlarm, profile: .gen5)
        XCTAssertTrue(parseFrame(raw, family: .whoop5).ok)
        XCTAssertFalse(parseFrame(raw, family: .whoop4).ok, "a gen5 frame read as gen4 must not decode")
    }

    func testIntactButUndecodableFrameIsReportedNotDiscarded() throws {
        // crcOK && !ok is the archive-for-re-decode signal. It has to stay reachable.
        var raw = buildFrame([PacketType.historicalData, 24, 0, 0], profile: .gen5)
        raw[1] = 0x02                                       // an unmappable revision
        let c = CRC.crc16Modbus(Array(raw[0..<6]))
        raw[6] = UInt8(c & 0xFF); raw[7] = UInt8((c >> 8) & 0xFF)
        let f = try XCTUnwrap(parseEnvelope(raw, profile: .gen5))
        let p = Interpreter.interpret(f)
        XCTAssertTrue(p.crcOK, "the bytes survived the link")
        XCTAssertFalse(p.ok, "but this decoder cannot map them")
    }

    func testStreamInterpretationCarvesAndNamesEveryFrame() {
        let a = buildCommand(seq: 1, opcode: Cmd.runAlarm)
        let b = buildCommand(seq: 2, opcode: Cmd.disableAlarm)
        let out = Interpreter.interpret(stream: a + b)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.cmdName), ["RUN_ALARM", "DISABLE_ALARM"])
    }

    func testSchemaNamesAreDistinct() {
        // A duplicated name would make two different opcodes indistinguishable in a log.
        let names = Array(Schema.commandNames.values)
        XCTAssertEqual(names.count, Set(names).count)
    }
}
