import XCTest
@testable import StrapProtocol

/// The live lane's timestamp gate. `extractStreams` converts a device stamp to wall time by
/// arithmetic; if the stamp is not on the basis that arithmetic assumes, the result is an arbitrary
/// date. Unchecked, those rows persist — invisible in a chart, but they become MAX(ts), which is
/// what the UI calls the newest reading.
final class LiveStreamGateTests: XCTestCase {

    private func realtimeFrame(deviceTs: UInt32, bpm: UInt8) -> ParsedFrame {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = PacketType.realtimeData
        withUnsafeBytes(of: deviceTs.littleEndian) { b.replaceSubrange(2..<6, with: $0) }
        b[8] = bpm
        return parseFrame(buildFrame(b, profile: .gen4), family: .whoop4)
    }

    func testAMatchedReferenceKeepsTheReading() {
        let now = Int(Date().timeIntervalSince1970)
        let out = extractStreams([realtimeFrame(deviceTs: UInt32(now), bpm: 55)],
                                 deviceClockRef: now, wallClockRef: now)
        XCTAssertEqual(out.hr.count, 1)
        XCTAssertEqual(out.hr.first?.bpm, 55)
    }

    /// A reference on a different basis sends the converted stamp decades out. Observed for real:
    /// a 39-second burst of genuine beats written to 2082.
    func testAStampConvertedIntoTheFarFutureIsDropped() {
        let now = Int(Date().timeIntervalSince1970)
        let out = extractStreams([realtimeFrame(deviceTs: UInt32(now), bpm: 55)],
                                 deviceClockRef: 100_000_000, wallClockRef: now)
        XCTAssertTrue(out.hr.isEmpty, "a reading dated ~2080 must not be persisted")
    }

    func testAStampConvertedBeforeTheEpochFloorIsDropped() {
        let now = Int(Date().timeIntervalSince1970)
        let out = extractStreams([realtimeFrame(deviceTs: 1_000, bpm: 55)],
                                 deviceClockRef: now, wallClockRef: now)
        XCTAssertTrue(out.hr.isEmpty)
    }
}
