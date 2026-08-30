import XCTest
@testable import StrapProtocol

final class PuffinCaptureTests: XCTestCase {

    func testCapturesADecodableFrameWithItsInterpretation() throws {
        let c = PuffinCapture()
        let raw = buildCommand(seq: 9, opcode: Cmd.runAlarm)
        let r = c.record(frame: raw, char: "cmdFrom", tsMs: 1_700_000_000_000)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.crcOK, true)
        XCTAssertEqual(r.seq, 9)
        XCTAssertEqual(r.typeName, "COMMAND")
        XCTAssertEqual(r.hex, raw.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(c.count, 1)
    }

    func testCapturesGarbageToo() {
        // The frames that do NOT decode are the reason a capture exists.
        let c = PuffinCapture()
        let r = c.record(frame: [0x11, 0x22, 0x33], char: "data", tsMs: 1)
        XCTAssertFalse(r.ok)
        XCTAssertNil(r.crcOK, "no envelope means no CRC verdict, not a false one")
        XCTAssertEqual(r.hex, "112233", "the bytes survive regardless")
        XCTAssertEqual(c.count, 1)
    }

    func testCapturesAFrameThatFailsItsCRC() throws {
        let c = PuffinCapture()
        var raw = buildCommand(seq: 1, opcode: Cmd.runAlarm)
        raw[6] ^= 0xFF
        let r = c.record(frame: raw, char: "data", tsMs: 1)
        XCTAssertEqual(r.crcOK, false)
    }

    func testResetDrainsTheBuffer() {
        let c = PuffinCapture()
        c.record(frame: buildCommand(seq: 1, opcode: Cmd.runAlarm), char: "a", tsMs: 1)
        XCTAssertEqual(c.count, 1)
        c.reset()
        XCTAssertEqual(c.count, 0)
    }

    func testEncodesBothReportShapes() throws {
        let c = PuffinCapture()
        c.record(frame: buildCommand(seq: 2, opcode: Cmd.disableAlarm), char: "cmdFrom", tsMs: 5)
        let report = try JSONSerialization.jsonObject(with: c.encodedJSON()) as? [[String: Any]]
        XCTAssertEqual(report?.count, 1)
        XCTAssertNotNil(report?.first?["hex"])
        XCTAssertNotNil(report?.first?["char"])

        let fixture = try JSONSerialization.jsonObject(with: c.framesFixtureJSON()) as? [[String: Any]]
        XCTAssertEqual(fixture?.count, 1)
        XCTAssertEqual(fixture?.first.map { Array($0.keys) }, ["hex"], "fixtures carry hex and nothing else")
    }

    func testExplicitHrOverridesTheDecodedOne() {
        let c = PuffinCapture()
        var inner = [UInt8](repeating: 0, count: 89)
        inner[0] = PacketType.historicalData; inner[1] = 24; inner[17] = 61
        inner[46] = 0x80; inner[47] = 0x3F
        let r = c.record(frame: buildFrame(inner), char: "data", tsMs: 1, hr: 99)
        XCTAssertEqual(r.hr, 99, "a caller-supplied HR wins over the decoded one")
    }
}
