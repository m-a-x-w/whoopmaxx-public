import XCTest
@testable import StrapProtocol

/// `parseR24` has decoded `respRateRaw` since the port, but the Interpreter never published it
/// into `parsed` — so `extractHistoricalStreams`' read of `resp_rate_raw` starved and the
/// respSample lane went silent at the port switchover while every sibling lane kept filling.
final class RespPublishTests: XCTestCase {

    func testInterpreterPublishesRespRateRawForEveryParityRecord() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "r24_parity", withExtension: "json"))
        struct Case: Decodable { let hex: String }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        var published = 0
        for c in cases {
            let inner = stride(from: 0, to: c.hex.count, by: 2).compactMap { i -> UInt8? in
                let s = c.hex.index(c.hex.startIndex, offsetBy: i)
                let e = c.hex.index(s, offsetBy: 2, limitedBy: c.hex.endIndex) ?? c.hex.endIndex
                return UInt8(c.hex[s..<e], radix: 16)
            }
            let reference = parseR24(inner)
            let p = parseFrame(buildFrame(inner, profile: .gen4), family: .whoop4)
            if let r = reference, r.respRateRaw > 0 {
                XCTAssertEqual(p.parsed["resp_rate_raw"]?.intValue, r.respRateRaw)
                published += 1
            } else {
                XCTAssertNil(p.parsed["resp_rate_raw"])
            }
        }
        XCTAssertGreaterThan(published, 0, "corpus should contain optical records with a resp read")
    }
}
