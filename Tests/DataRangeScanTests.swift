import XCTest
import StrapProtocol
@testable import whoopmaxx

/// GET_DATA_RANGE epoch extraction — pinned against a REAL frame captured from the user's own strap
/// on 2026-09-02, on which the port's rewrite returned a newest of 2029 (a u32 straddling the payload
/// tail into the CRC) and missed every genuine banked-record epoch (they are not word-aligned).
@MainActor
final class DataRangeScanTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return UInt8(hex[s..<e], radix: 16)
        }
    }

    /// The captured frame. Real span is 2026-08-19 → 2026-09-02 15:32:40 (== the wall clock at capture).
    private let realFrame = "aa4c00a724a6220a010180e7010032d5010062e701002dd50100090000000000020061b00000ee4913002794856a282900001398976a384300004398976a904b00009841986ad8390000000017c06f07"
    private let capturedWall = 1_788_363_160     // 2026-09-02 15:32:40 UTC

    func testNewestIsNowNotTheCrcStraddle() {
        let newest = BLEManager.dataRangeNewestUnix(from: bytes(realFrame), wallNowUnix: capturedWall)
        XCTAssertEqual(newest, capturedWall, "the real newest is the just-banked record, not 2029")
    }

    func testOldestIsTheStartOfBankedHistory() {
        let oldest = BLEManager.dataRangeOldestUnix(from: bytes(realFrame), wallNowUnix: capturedWall)
        XCTAssertEqual(oldest, 1_787_139_111, "2026-08-19 — the oldest record the strap still holds")
    }

    /// The exact failure: a future-dated newest nulls strapNewestTs and disables auto-continue.
    func testNewestIsNotFutureDated() {
        let newest = BLEManager.dataRangeNewestUnix(from: bytes(realFrame), wallNowUnix: capturedWall)
        XCTAssertFalse(BackfillContinuation.isFutureDatedNewest(newest, wallNowUnix: capturedWall))
    }

    /// A 4-aligned in-range word must NOT out-vote the real epochs — the stride-4 scan's core defect.
    func testWordAlignedJunkDoesNotBecomeNewest() {
        // header(7) + one real epoch at an odd offset + a 4-aligned far-future-but-<cap word + CRC(4).
        var f: [UInt8] = [0xAA, 0x4C, 0x00, 0xA7, 0x24, 0x00, 0x00]   // 7-byte header
        f.append(0x00)                                                // pad so the real epoch lands unaligned
        withUnsafeBytes(of: UInt32(1_788_000_000).littleEndian) { f += Array($0) }   // real, offset 8
        withUnsafeBytes(of: UInt32(capturedWall + 5 * 86_400).littleEndian) { f += Array($0) } // 5 days ahead, 4-aligned
        f += [0xDE, 0xAD, 0xBE, 0xEF]                                 // CRC
        let newest = BLEManager.dataRangeNewestUnix(from: f, wallNowUnix: capturedWall)
        XCTAssertEqual(newest, 1_788_000_000, "the 5-days-ahead word is past the wallNow+margin cap and excluded")
    }

    func testTooShortFrameYieldsNil() {
        XCTAssertNil(BLEManager.dataRangeNewestUnix(from: [0xAA, 0x4C, 0x00], wallNowUnix: capturedWall))
    }
}
