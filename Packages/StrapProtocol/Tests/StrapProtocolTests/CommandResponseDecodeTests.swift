import XCTest
@testable import StrapProtocol

/// The command replies FrameRouter and the collectors actually consume. Each of these was a
/// decoded field in the original protocol layer and a silent blank after the port: the request
/// went out, the reply came back, and no branch read it.
final class CommandResponseDecodeTests: XCTestCase {

    private func response(opcode: UInt8, body: [UInt8]) -> ParsedFrame {
        // Reply envelope: [type][seq][opcode][echoed seq][status][value…]
        var inner: [UInt8] = [PacketType.commandResponse, 0x04, opcode, 0x01, 0x00]
        inner += body
        return parseFrame(buildFrame(inner, profile: .gen4), family: .whoop4)
    }

    /// Deci-percent, same convention as the BATTERY_LEVEL event: 505 → 50.5%.
    func testBatteryLevelReplyDecodesDeciPercent() {
        let p = response(opcode: 26, body: [0xF9, 0x01])            // 505 LE
        XCTAssertEqual(p.parsed["battery_pct"]?.doubleValue, 50.5)
    }

    /// Out of range means these are not the bytes the map claims — publish nothing.
    func testImpossibleBatteryReplyIsNotEmitted() {
        XCTAssertNil(response(opcode: 26, body: [0xF2, 0x03]).parsed["battery_pct"]) // 1010
    }

    /// Three status bytes then eight LE u32s: harvard quad first, boylston quad second.
    func testReportVersionInfoDecodesBothQuads() {
        var body: [UInt8] = [0x00]                                   // third status byte
        for v in [50, 38, 1, 0, 2, 7, 9, 4] as [UInt32] {
            withUnsafeBytes(of: v.littleEndian) { body += Array($0) }
        }
        let p = response(opcode: 7, body: body)
        XCTAssertEqual(p.parsed["fw_harvard"]?.stringValue, "50.38.1.0")
        XCTAssertEqual(p.parsed["fw_boylston"]?.stringValue, "2.7.9.4")
    }

    /// GET_HELLO's version sits at reply offset 93, guarded by the generation byte reading 50.
    func testGetHelloDecodesVersionBehindGenerationGuard() {
        var body = [UInt8](repeating: 0, count: 95)
        body[91] = 50; body[92] = 40; body[93] = 2; body[94] = 1     // inner[96...] = 50.40.2.1
        XCTAssertEqual(response(opcode: 145, body: body).parsed["fw_version"]?.stringValue, "50.40.2.1")
        body[91] = 49                                                // wrong generation byte
        XCTAssertNil(response(opcode: 145, body: body).parsed["fw_version"])
    }
}
