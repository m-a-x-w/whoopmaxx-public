import XCTest
@testable import StrapProtocol

/// GET_CLOCK's reply. This is the reference the offload corrects record timestamps against, so a
/// reply that does not decode does not fail loudly — it leaves the correction offset at zero and
/// every record from a mis-set strap is then dropped as implausible, while the sync itself reports
/// success.
final class ClockResponseTests: XCTestCase {

    /// Reply inner: [type][seq][opcode][echoed seq][status][u32 seconds][u32 subseconds]
    private func clockReply(opcode: Int = Schema.getClockOpcode, seconds: UInt32,
                            status: UInt8 = 1, length: Int = 13) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0] = PacketType.commandResponse
        b[1] = 0x07
        b[2] = UInt8(opcode)
        b[3] = 0x0B                                     // echoed request seq
        if length > 4 { b[4] = status }
        if length >= 9 {
            withUnsafeBytes(of: seconds.littleEndian) { b.replaceSubrange(5..<9, with: $0) }
        }
        return b
    }

    private func parsed(_ inner: [UInt8]) -> ParsedFrame {
        parseFrame(buildFrame(inner, profile: .gen4), family: .whoop4)
    }

    func testClockIsReadFromTheFieldNotScannedFor() {
        let p = parsed(clockReply(seconds: 1_775_395_266))
        XCTAssertEqual(p.parsed["clock"]?.intValue, 1_775_395_266)
    }

    /// The case this whole path exists for. A strap whose RTC is years fast still has to yield a
    /// reference — that wrongness is the offset the offload needs. Judging it by the RECORD gate
    /// (wallNow + a day) would reject it and silently strand the entire backlog.
    func testFutureDatedStrapClockIsStillCaptured() {
        let year2029: UInt32 = 1_885_000_000
        XCTAssertGreaterThan(Int(year2029), Int(Date().timeIntervalSince1970) + FUTURE_MARGIN,
                             "fixture must actually be beyond the record gate, or this proves nothing")
        XCTAssertEqual(parsed(clockReply(seconds: year2029)).parsed["clock"]?.intValue, Int(year2029))
    }

    /// Not a clock at all — emit nothing rather than a guess, since this value becomes the reference
    /// every corrected timestamp is derived from.
    func testImplausibleValuesAreNotEmitted() {
        XCTAssertNil(parsed(clockReply(seconds: 0)).parsed["clock"])
        XCTAssertNil(parsed(clockReply(seconds: 1)).parsed["clock"])
        XCTAssertNil(parsed(clockReply(seconds: 4_200_000_000)).parsed["clock"])
    }

    func testOtherCommandRepliesCarryNoClock() {
        // GET_BATTERY_LEVEL (26) with bytes that would read as a fine epoch at the clock offset.
        XCTAssertNil(parsed(clockReply(opcode: 26, seconds: 1_775_395_266)).parsed["clock"])
    }

    func testTruncatedReplyIsNotAClock() {
        XCTAssertNil(parsed(clockReply(seconds: 1_775_395_266, length: 8)).parsed["clock"])
    }

    func testTheReplyStillNamesItsCommand() {
        XCTAssertEqual(parsed(clockReply(seconds: 1_775_395_266)).parsed["command"]?.stringValue,
                       "GET_CLOCK")
    }
}
