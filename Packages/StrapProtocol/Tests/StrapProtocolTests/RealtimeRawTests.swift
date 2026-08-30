import XCTest
@testable import StrapProtocol

/// REALTIME_RAW_DATA (type 43), the R10/R11 stream a WHOOP 4.0 delivers live heart rate on.
/// Offsets are pinned against a real captured frame: declared 1924 (inner 1920), hr 0x46 = 70 bpm
/// at inner[17], one R-R of 857 ms — the same frame historical_golden decoded in the original
/// project. Without this decode every live frame parses `ok: false` and the Live screen reads
/// "No live signal" while sync works.
final class RealtimeRawTests: XCTestCase {

    private func rawFrame(hr: UInt8, rrCount: UInt8? = nil, rr: [UInt16] = [],
                          ts: UInt32 = 1_756_700_000, innerLength: Int = 1920) -> ParsedFrame {
        var b = [UInt8](repeating: 0, count: innerLength)
        b[0] = PacketType.realtimeRawData
        b[1] = 0x05
        withUnsafeBytes(of: ts.littleEndian) { b.replaceSubrange(7..<11, with: $0) }
        if innerLength > 17 { b[17] = hr }
        if innerLength > 18 { b[18] = rrCount ?? UInt8(rr.count) }
        for (i, v) in rr.enumerated() where 21 + 2 * i <= innerLength {
            withUnsafeBytes(of: v.littleEndian) { b.replaceSubrange(19 + 2 * i..<21 + 2 * i, with: $0) }
        }
        return parseFrame(buildFrame(b, profile: .gen4), family: .whoop4)
    }

    /// The real frame's shape: hr 70, one R-R of 857 ms, device-epoch stamp in the header.
    func testImuVariantDecodesHeartRateAndRR() {
        let p = rawFrame(hr: 70, rr: [857], ts: 31_538_447)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.typeName, "REALTIME_RAW_DATA")
        XCTAssertEqual(p.parsed["heart_rate"]?.intValue, 70)
        XCTAssertEqual(p.parsed["rr_intervals"]?.intArrayValue, [857])
        XCTAssertEqual(p.parsed["timestamp"]?.intValue, 31_538_447)
    }

    /// The optical variant (inner 1924) carries PPG where the IMU variant carries hr — reading
    /// its bytes as a heart rate would chart sensor noise as beats.
    func testOpticalVariantCarriesNoHeartRate() {
        let p = rawFrame(hr: 70, rr: [857], innerLength: 1924)
        XCTAssertTrue(p.ok)
        XCTAssertNil(p.parsed["heart_rate"])
        XCTAssertNil(p.parsed["rr_intervals"])
        XCTAssertNotNil(p.parsed["timestamp"])
    }

    /// 0 is the strap's "no reading this frame", not a measurement of a stopped heart.
    func testZeroHeartRateIsNotEmitted() {
        XCTAssertNil(rawFrame(hr: 0).parsed["heart_rate"])
    }

    /// Out-of-band intervals are dropped; the in-band one survives.
    func testRRIntervalsAreBoundsChecked() {
        XCTAssertEqual(rawFrame(hr: 70, rr: [100, 857]).parsed["rr_intervals"]?.intArrayValue, [857])
    }

    /// A count above the four slots the layout holds means these are not the bytes the map
    /// claims — no intervals, rather than sensor samples read as beats.
    func testImplausibleRRCountEmitsNothing() {
        XCTAssertNil(rawFrame(hr: 70, rrCount: 9, rr: [857]).parsed["rr_intervals"])
    }

    /// Truncated below its own header, the frame is not interpreted.
    func testShortFrameIsNotOK() {
        XCTAssertFalse(rawFrame(hr: 70, innerLength: 12).ok)
    }
}
