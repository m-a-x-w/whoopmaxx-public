import XCTest
@testable import StrapProtocol

/// Framing + checksum tests.
///
/// The CRC cases are pinned to PUBLISHED check values, not to whatever this implementation
/// happens to produce — a self-consistent checksum that disagrees with the strap is the exact
/// failure these are here to catch. "123456789" is the standard check string for all three.
final class CRCTests: XCTestCase {

    func testCRC8MatchesPublishedCheckValue() {
        // CRC-8/SMBUS, poly 0x07, init 0x00, no final XOR. Published check = 0xF4.
        XCTAssertEqual(CRC.crc8(Array("123456789".utf8)), 0xF4)
    }

    func testCRC32MatchesZlibCheckValue() {
        // zlib / IEEE 802.3. Published check = 0xCBF43926.
        XCTAssertEqual(CRC.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testCRC16ModbusMatchesPublishedCheckValue() {
        // CRC-16/MODBUS. Published check = 0x4B37.
        XCTAssertEqual(CRC.crc16Modbus(Array("123456789".utf8)), 0x4B37)
    }

    func testCRC16ModbusMatchesRealGen5HelloHeader() {
        // The one WHOOP-specific vector in this file: the gen5 client HELLO frame's first six
        // header bytes. Byte-verified against a real strap exchange.
        XCTAssertEqual(CRC.crc16Modbus([0xAA, 0x01, 0x08, 0x00, 0x00, 0x01]), 0x71E6)
    }

    func testCRC8OverEmptyInputIsZero() {
        XCTAssertEqual(CRC.crc8([]), 0)
    }
}

final class FramingTests: XCTestCase {

    private let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]

    func testPadTo4RoundsUpAndLeavesAlignedInputAlone() {
        XCTAssertEqual(padTo4([1, 2, 3]).count, 4)
        XCTAssertEqual(padTo4([1, 2, 3, 4]).count, 4)
        XCTAssertEqual(padTo4([1, 2, 3, 4, 5]).count, 8)
        XCTAssertEqual(padTo4([]).count, 0)
        XCTAssertEqual(padTo4([1, 2, 3, 4]), [1, 2, 3, 4])   // no spurious padding
    }

    func testGen4RoundTrip() throws {
        let raw = buildFrame(payload, profile: .gen4)
        XCTAssertEqual(raw[0], strapSOF)
        let f = try XCTUnwrap(parseEnvelope(raw, profile: .gen4))
        XCTAssertTrue(f.headerCRCOK)
        XCTAssertTrue(f.payloadCRCOK)
        XCTAssertTrue(f.valid)
        XCTAssertTrue(f.decodable)
        XCTAssertEqual(Array(f.inner.prefix(5)), payload)
        XCTAssertEqual(f.packetType, 0x01)
        XCTAssertEqual(f.sequence, 0x02)
        XCTAssertEqual(f.opcode, 0x03)
    }

    func testGen5RoundTripAndHeaderShape() throws {
        let raw = buildFrame(payload, profile: .gen5)
        XCTAssertEqual(raw[0], strapSOF)
        XCTAssertEqual(raw[1], strapFrameRevision1)
        // Outbound direction marker — a host → strap command, not a fixed magic constant.
        XCTAssertEqual([raw[4], raw[5]], [0x00, 0x01])
        let f = try XCTUnwrap(parseEnvelope(raw, profile: .gen5))
        XCTAssertTrue(f.valid)
        XCTAssertTrue(f.decodable)
        XCTAssertEqual(Array(f.inner.prefix(5)), payload)
    }

    func testDeclaredLengthCountsPaddedInnerPlusCRC32() {
        let raw = buildFrame(payload, profile: .gen4)          // 5 bytes → padded to 8
        XCTAssertEqual(BandProfile.gen4.declaredLength(raw), 8 + 4)
        XCTAssertEqual(raw.count, 4 + 8 + 4)
    }

    func testCorruptPayloadFailsOnlyThePayloadCRC() throws {
        var raw = buildFrame(payload, profile: .gen4)
        raw[5] ^= 0xFF                                          // flip a byte inside the payload
        let f = try XCTUnwrap(parseEnvelope(raw, profile: .gen4))
        XCTAssertTrue(f.headerCRCOK, "the header check covers the length bytes only")
        XCTAssertFalse(f.payloadCRCOK)
        XCTAssertFalse(f.valid)
    }

    func testGen5NonRev1FrameIsIntactButNotDecodable() throws {
        var raw = buildFrame(payload, profile: .gen5)
        raw[1] = 0x02                                           // a revision this decoder cannot map
        // Re-stamp the header CRC so the frame really is intact — the point is that a frame can
        // pass both checksums and still not be safe to read fields out of.
        let c = CRC.crc16Modbus(Array(raw[0..<6]))
        raw[6] = UInt8(c & 0xFF); raw[7] = UInt8((c >> 8) & 0xFF)
        let f = try XCTUnwrap(parseEnvelope(raw, profile: .gen5))
        XCTAssertTrue(f.valid, "bytes are intact")
        XCTAssertFalse(f.frameRevisionOK)
        XCTAssertFalse(f.decodable, "intact but unreadable — archive, never drop")
    }

    func testRejectsShortBufferAndWrongSOF() {
        XCTAssertNil(parseEnvelope([0xAA, 0x00], profile: .gen4))
        var raw = buildFrame(payload, profile: .gen4)
        raw[0] = 0xAB
        XCTAssertNil(parseEnvelope(raw, profile: .gen4))
    }
}

final class ReassemblerTests: XCTestCase {

    func testCarvesTwoFramesOutOfOneChunk() {
        let a = buildFrame([0x01, 0x02, 0x03, 0xAA])
        let b = buildFrame([0x04, 0x05, 0x06])
        let r = FrameReassembler(profile: .gen4)
        let frames = r.feed(a + b)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy(\.valid))
        XCTAssertEqual(r.resyncs, 0)
    }

    func testReassemblesAcrossArbitraryChunkBoundaries() {
        let whole = buildFrame([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        for split in 1..<whole.count {
            let r = FrameReassembler(profile: .gen4)
            var got = r.feed(Array(whole[0..<split]))
            got += r.feed(Array(whole[split...]))
            XCTAssertEqual(got.count, 1, "split at \(split)")
            XCTAssertTrue(got[0].valid, "split at \(split)")
        }
    }

    func testPayloadContaining0xAAIsNotTreatedAsAFrameStart() {
        // The whole reason the reassembler is length-driven: 0xAA occurs inside real sensor data.
        let f = buildFrame([0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA])
        let r = FrameReassembler(profile: .gen4)
        let frames = r.feed(f)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].valid)
        XCTAssertEqual(r.resyncs, 0)
    }

    func testResyncsRatherThanConsumingAFrameWhosePayloadCRCFailed() {
        var bad = buildFrame([0x01, 0x02, 0x03, 0x04])
        bad[6] ^= 0xFF                                          // corrupt the payload
        let good = buildFrame([0x09, 0x08, 0x07, 0x06])
        let r = FrameReassembler(profile: .gen4)
        let frames = r.feed(bad + good)
        // The corrupt frame is surfaced so accounting sees it, but marked invalid...
        XCTAssertTrue(frames.contains { !$0.valid })
        // ...and the good frame packed in behind it is still recovered rather than swallowed.
        XCTAssertTrue(frames.contains { $0.valid && $0.inner.prefix(4) == [0x09, 0x08, 0x07, 0x06] })
        XCTAssertGreaterThan(r.resyncs, 0)
    }

    func testSkipsInterRecordNullPadding() {
        let a = buildFrame([0x01, 0x02, 0x03, 0x04])
        let b = buildFrame([0x05, 0x06, 0x07, 0x08])
        let r = FrameReassembler(profile: .gen4)
        let frames = r.feed(a + [0x00, 0x00, 0x00] + b)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy(\.valid))
    }

    func testLeadingGarbageResyncsToTheRealFrame() {
        let f = buildFrame([0x01, 0x02, 0x03, 0x04])
        let r = FrameReassembler(profile: .gen4)
        let frames = r.feed([0x11, 0x22, 0x33] + f)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].valid)
        XCTAssertGreaterThan(r.resyncs, 0)
    }

    func testResetClearsBufferAndCounters() {
        let f = buildFrame([0x01, 0x02, 0x03, 0x04])
        let r = FrameReassembler(profile: .gen4)
        _ = r.feed(Array(f.prefix(6)))                          // leave a partial frame buffered
        r.reset()
        XCTAssertEqual(r.resyncs, 0)
        XCTAssertEqual(r.feed(f).count, 1, "the stale partial must not corrupt the next frame")
    }

    func testGen5StreamReassembles() {
        let a = buildFrame([0x01, 0x02, 0x03], profile: .gen5)
        let b = buildFrame([0x04, 0x05, 0x06], profile: .gen5)
        let r = FrameReassembler(profile: .gen5)
        let frames = r.feed(a + b)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy(\.valid))
    }
}
