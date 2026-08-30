import XCTest
@testable import StrapProtocol

/// `rejectedHistoricalRecords` decides which offload frames are archived as decode failures. The
/// PPG-waveform layout carries no biometrics by design and must NOT be filed as a failure — but the
/// exemption was gen5-only (v26), so a real WHOOP 4.0 reported its v25 PPG bursts as "undecodable
/// sensor record(s)" on every sync and flooded the reject archive with them.
final class RejectedRecordsTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return UInt8(hex[s..<e], radix: 16)
        }
    }

    /// A real v25 PPG frame captured from the user's WHOOP 4.0 (type 0x2f = 47, version 0x19 = 25).
    private let realV25 = "aa50000c2f19009ee40000c4ba976ad81a1900a6dc00000e015301ea011201edff5ff99af9a2fbedfd8dff9700ae01ea014601aa007eff66fff6ff3e00fd00c3007b014001a501c0350c3ca002000000fb17d246"

    func testGen4V25PpgIsNotFiledAsARejectedRecord() {
        let rejected = rejectedHistoricalRecords([bytes(realV25)], family: .whoop4)
        XCTAssertTrue(rejected.isEmpty, "v25 PPG carries no biometrics by design — exempt, not a failure")
    }

    /// The exemption keys on the version byte, so a corrupt/undecodable NON-PPG frame still archives.
    func testGarbageHistoricalFrameStillArchives() {
        // type 47, version 24 (a normal biometric record), but truncated to nothing decodable.
        let junk = bytes("aa08000c2f18000000")
        XCTAssertEqual(rejectedHistoricalRecords([junk], family: .whoop4).count, 1)
    }

    /// A non-historical frame (e.g. an event) is never a "rejected historical record".
    func testNonHistoricalFrameIsIgnored() {
        let event = bytes("aa08000c30030000dead")
        XCTAssertTrue(rejectedHistoricalRecords([event], family: .whoop4).isEmpty)
    }
}
