import XCTest
@testable import StrapProtocol

/// The offload's ack path. A HISTORY_END that does not decode is invisible: the live stream keeps
/// working, the app reports "streaming", and the strap simply never trims — so these assert the two
/// values the ack depends on rather than that a frame merely parsed.
final class HistoryEndTests: XCTestCase {

    /// Inner payload of a HISTORY_END, laid out as the strap sends it:
    ///   [0] type · [1] seq · [2] sub(=2) · [3..7] u32 clock · [7..9] u16 subsec
    ///   [9..13] u32 expected count · [13..17] u32 trim page · [17..21] u32 wrap count
    private func historyEndInner(type: UInt8, clock: UInt32, trim: UInt32,
                                 length: Int = 24) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0] = type
        b[1] = 0x01
        b[2] = 2                                        // HISTORY_END
        if length >= 7  { withUnsafeBytes(of: clock.littleEndian) { b.replaceSubrange(3..<7, with: $0) } }
        if length >= 17 { withUnsafeBytes(of: trim.littleEndian)  { b.replaceSubrange(13..<17, with: $0) } }
        return b
    }

    private func classify(_ inner: [UInt8], profile: BandProfile, family: DeviceFamily) -> HistoricalMeta {
        classifyHistoricalMeta(parseFrame(buildFrame(inner, profile: profile), family: family))
    }

    func testGen4HistoryEndYieldsClockAndTrim() {
        let meta = classify(historyEndInner(type: PacketType.metadata, clock: 1_775_395_266, trim: 65_597),
                            profile: .gen4, family: .whoop4)
        XCTAssertEqual(meta, .end(unix: 1_775_395_266, trim: 65_597))
    }

    /// The regression that matters on WHOOP 5/MG: METADATA arrives as type 56, and unless that byte
    /// is folded onto the strap's vocabulary the frame names itself PUFFIN_METADATA, never reaches
    /// the metadata branch, and the whole backlog stalls with nothing logged.
    func testGen5PuffinMetadataIsFoldedAndStillAcks() {
        let meta = classify(historyEndInner(type: UInt8(PuffinPacketType.puffinMetadata),
                                            clock: 1_775_395_266, trim: 109_654),
                            profile: .gen5, family: .whoop5)
        XCTAssertEqual(meta, .end(unix: 1_775_395_266, trim: 109_654))
    }

    /// 0xFFFFFFFF is the strap's "nothing to trim" sentinel, not a cursor. The decoder must hand it
    /// through untouched — the consumer excludes it deliberately, and filtering it here would look
    /// identical to a frame that failed to decode.
    func testSentinelTrimIsPassedThroughNotFiltered() {
        let meta = classify(historyEndInner(type: PacketType.metadata, clock: 1_775_395_266, trim: 0xFFFF_FFFF),
                            profile: .gen4, family: .whoop4)
        XCTAssertEqual(meta, .end(unix: 1_775_395_266, trim: 0xFFFF_FFFF))
    }

    /// An implausible clock must still ack. A strap with an unset RTC is the case the corrupt-RTC
    /// detector exists to report, and withholding `unix` here would wedge the offload instead.
    func testUnsetRtcClockStillAcks() {
        let meta = classify(historyEndInner(type: PacketType.metadata, clock: 42, trim: 65_597),
                            profile: .gen4, family: .whoop4)
        XCTAssertEqual(meta, .end(unix: 42, trim: 65_597))
    }

    /// Too short to hold the 8-byte token the ack echoes back. Fails closed: acking a cursor the
    /// strap never sent would destroy a backlog against a value we invented.
    func testTruncatedEndIsNotAnEnd() {
        let meta = classify(historyEndInner(type: PacketType.metadata, clock: 1_775_395_266,
                                            trim: 65_597, length: 16),
                            profile: .gen4, family: .whoop4)
        XCTAssertEqual(meta, .other)
    }

    func testStartAndCompleteStillClassify() {
        var start = historyEndInner(type: PacketType.metadata, clock: 0, trim: 0)
        start[2] = 1
        XCTAssertEqual(classify(start, profile: .gen4, family: .whoop4), .start)
        var complete = start
        complete[2] = 3
        XCTAssertEqual(classify(complete, profile: .gen4, family: .whoop4), .complete)
    }
}
