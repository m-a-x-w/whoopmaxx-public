import XCTest
@testable import StrapProtocol

/// Record decode checked against OpenStrap's published parity corpus — 550 real v24 records,
/// each with the field values an independent implementation produced from the same bytes.
///
/// This is the acceptance spec for the record layer. It is deliberately an EXTERNAL oracle:
/// a decoder tested only against its own output will happily agree with itself while
/// disagreeing with the strap.
final class RecordParityTests: XCTestCase {

    private struct Case: Decodable {
        let kind: String
        let hex: String
        let out: Out
        struct Out: Decodable {
            let ts_epoch: UInt32
            let ts_subsec: UInt16
            let counter: UInt32
            let hr: Int
            let rr_count: Int
            let rr_intervals_ms: [Int]
            let ppg_green: Int
            let ppg_red_ir: Int
            let accel_g: [Double]
            let skin_contact: Int
            let spo2_red_raw: Int
            let spo2_ir_raw: Int
            let skin_temp_raw: Int
            let ambient_raw: Int
            let raw_tail: String
        }
    }

    private func loadCases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "r24_parity", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return UInt8(hex[s..<e], radix: 16)
        }
    }

    func testEveryParityCaseDecodesIdentically() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 550, "fixture went missing or was truncated")

        var decoded = 0
        for (i, c) in cases.enumerated() {
            guard let r = parseR24(bytes(c.hex)) else {
                XCTFail("case \(i): decoder returned nil for a known-good record")
                continue
            }
            decoded += 1
            let o = c.out
            XCTAssertEqual(r.tsEpoch, o.ts_epoch, "case \(i) ts_epoch")
            XCTAssertEqual(r.tsSubsec, o.ts_subsec, "case \(i) ts_subsec")
            XCTAssertEqual(r.counter, o.counter, "case \(i) counter")
            XCTAssertEqual(r.hr, o.hr, "case \(i) hr")
            XCTAssertEqual(r.rrCount, o.rr_count, "case \(i) rr_count")
            XCTAssertEqual(r.rrIntervalsMs, o.rr_intervals_ms, "case \(i) rr_intervals_ms")
            XCTAssertEqual(r.ppgGreen, o.ppg_green, "case \(i) ppg_green")
            XCTAssertEqual(r.ppgRedIr, o.ppg_red_ir, "case \(i) ppg_red_ir")
            XCTAssertEqual(r.skinContact, o.skin_contact, "case \(i) skin_contact")
            XCTAssertEqual(r.spo2RedRaw, o.spo2_red_raw, "case \(i) spo2_red_raw")
            XCTAssertEqual(r.spo2IrRaw, o.spo2_ir_raw, "case \(i) spo2_ir_raw")
            XCTAssertEqual(r.skinTempRaw, o.skin_temp_raw, "case \(i) skin_temp_raw")
            XCTAssertEqual(r.ambientRaw, o.ambient_raw, "case \(i) ambient_raw")
            XCTAssertEqual(r.accelG.count, o.accel_g.count, "case \(i) accel_g arity")
            for (a, b) in zip(r.accelG, o.accel_g) {
                XCTAssertEqual(a, b, accuracy: 1e-9, "case \(i) accel_g")
            }
            let tail = r.rawTail.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(tail, o.raw_tail, "case \(i) raw_tail")
        }
        XCTAssertEqual(decoded, cases.count)
    }
}

/// Guards on the decode paths the parity corpus cannot reach — it is all well-formed v24.
final class RecordGuardTests: XCTestCase {

    /// A v24 record with everything zeroed except the bits each test needs.
    private func record(version: UInt8, packetType: UInt8 = PacketType.historicalData,
                        length: Int = 89, mutate: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0] = packetType
        b[1] = version
        b[17] = 60                                   // HR, inside the plausible range
        // accel = (0, 0, 1) g — magnitude 1, so the plausibility gate passes
        b[44] = 0x00; b[45] = 0x00; b[46] = 0x80; b[47] = 0x3F
        mutate(&b)
        return b
    }

    func testRejectsNonRecordPacketTypes() {
        // The bug this guards: dispatching on inner[1] alone reads a control frame's SEQUENCE
        // byte, so 2 in 256 control frames decode as records with an HR read out of log text.
        for t: UInt8 in [PacketType.command, PacketType.commandResponse, PacketType.consoleLogs,
                         PacketType.event, PacketType.metadata] {
            XCTAssertNil(parseR24(record(version: 24, packetType: t)), "packet type 0x\(String(t, radix: 16))")
        }
        XCTAssertNotNil(parseR24(record(version: 24, packetType: PacketType.historicalData)))
        XCTAssertNotNil(parseR24(record(version: 24, packetType: PacketType.realtimeData)))
    }

    func testRejectsTruncatedRecords() {
        XCTAssertNil(parseR24([]))
        XCTAssertNil(parseR24([PacketType.historicalData]))
        XCTAssertNil(parseR24(record(version: 24, length: 88)), "one byte under the validated floor")
        XCTAssertNotNil(parseR24(record(version: 24, length: 89)))
    }

    func testShortFrameFloorIsOptInOnly() {
        // Real firmware sends well-formed 88-byte v12 records. They decode only when the caller
        // explicitly asks for the shorter floor — the validated 89-byte default never moves.
        let short = record(version: 12, length: 80)
        XCTAssertNil(parseR24(short))
        XCTAssertNotNil(parseR24(short, minLength: shortFrameMinLength))
    }

    func testRejectsNonFiniteAccel() {
        // NaN in the accel block means [36..<48] is not the float32 vector the map claims.
        let r = record(version: 24) { b in
            b[36] = 0xFF; b[37] = 0xFF; b[38] = 0xC0; b[39] = 0x7F   // NaN
        }
        XCTAssertNil(parseR24(r), "a NaN component must reject the record, not decode as 0.0")
    }

    func testImplausibleDeclaredRRCountYieldsNoBeats() {
        // 255 declared intervals would address int16s straight through the accel and optical
        // blocks, handing HRV fabricated beats.
        let r = record(version: 24) { b in b[18] = 255 }
        let d = parseR24(r)
        XCTAssertEqual(d?.rrCount, 0)
        XCTAssertEqual(d?.rrIntervalsMs, [])
    }

    func testOutOfRangeRRIntervalsAreDropped() {
        let r = record(version: 24) { b in
            b[18] = 2
            b[19] = 0x64; b[20] = 0x00                                 // 100 ms — under the floor
            b[21] = 0x2C; b[22] = 0x01                                 // 300 ms — kept
        }
        let d = parseR24(r)
        XCTAssertEqual(d?.rrIntervalsMs, [300])
        XCTAssertEqual(d?.rrCount, 1, "rrCount reports what was accepted, not what was declared")
    }

    func testUntrustedVersionsOmitTheRRAndOpticalBlocks() throws {
        // v18 has a confirmed HR offset (14) and nothing else. Reading v24's R-R and optical
        // offsets on it would be applying a map known not to apply.
        let r = record(version: 18) { b in
            b[14] = 60                                   // HR at v18's offset
            b[18] = 2; b[19] = 0x2C; b[20] = 0x01        // would-be beats at v24's offsets
            b[29] = 0xFF; b[64] = 0xFF; b[70] = 0xFF     // would-be optical at v24's offsets
        }
        let d = try XCTUnwrap(parseR24(r))
        XCTAssertEqual(d.hr, 60, "HR is read at v18's own offset")
        XCTAssertEqual(d.rrIntervalsMs, [], "no beats invented from an unconfirmed layout")
        XCTAssertEqual(d.ppgGreen, 0)
        XCTAssertEqual(d.spo2RedRaw, 0)
        XCTAssertEqual(d.ambientRaw, 0)
    }

    func testUnknownVersionIsGatedOnPlausibility() {
        let implausible = record(version: 99) { b in b[17] = 240 }     // HR above the human range
        XCTAssertNil(parseR24(implausible))
        XCTAssertNotNil(parseR24(record(version: 99)), "plausible unknown versions still decode")
    }

    func testV25CarriesTimestampAndCounterOnly() throws {
        var b = [UInt8](repeating: 0, count: 76)
        b[0] = PacketType.historicalData
        b[1] = 25
        b[3] = 0x2A; b[7] = 0x10                        // counter, epoch
        let d = try XCTUnwrap(parseR24(b))
        XCTAssertEqual(d.histVersion, 25)
        XCTAssertEqual(d.counter, 0x2A)
        XCTAssertEqual(d.tsEpoch, 0x10)
        XCTAssertEqual(d.hr, 0)
        XCTAssertEqual(d.accelG, [], "empty means absent, not a still wrist")
        XCTAssertNil(parseR24(Array(b.prefix(74))), "a truncated v25 burst is not a record")
    }

    func testKnownVersionsAreTheOnesWeRoute() {
        XCTAssertEqual(knownRecordVersions, [7, 9, 12, 18, 24, 25])
    }
}
