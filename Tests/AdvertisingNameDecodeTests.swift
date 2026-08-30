import XCTest
@testable import whoopmaxx

/// Pins for `FrameRouter.advertisingName(in:)` — the WHOOP 4.0 GET_ADVERTISING_NAME reply decode.
///
/// The regression these exist for: the strap's name field is a NUL-terminated string in a buffer it
/// does NOT clear between writes, so renaming to a SHORTER name leaves the old name's tail after the
/// terminator. The original decode filtered printable bytes across the whole field and therefore
/// concatenated that residue — "WHOOP" reading back as "WHOOPx" / "WHOOP;" / "WHOOPG", the stray
/// character being the previous name's last byte. Reported from the field.
///
/// There is no wire capture of the GET reply's exact header width, so these fixtures build the frame
/// with the SAME envelope `WhoopCommand.frame` writes and assert the decode is robust to a leading
/// NUL header being present or absent. What is pinned is the INVARIANT: nothing after the first
/// terminator is ever part of the name.
///
/// `@MainActor` because `FrameRouter` is main-actor-isolated and its statics inherit that isolation;
/// the decode itself is pure, so the hop is incidental and every case below stays synchronous.
@MainActor
final class AdvertisingNameDecodeTests: XCTestCase {

    /// A COMMAND_RESPONSE frame carrying `payload` where the name field would sit.
    ///
    /// Envelope mirrors `WhoopCommand.frame`: `[0xAA][len u16 LE][crc8][type][seq][cmd][origin][result]
    /// [payload…][crc32]`, with `len = inner.count + 4`. The decode only reads `frame[1...2]` for the
    /// length and slices from inner+5, so the crc bytes here are arbitrary — they exist to prove the
    /// decode stops at `length` and never reads into the trailer.
    private func responseFrame(payload: [UInt8]) -> [UInt8] {
        let inner: [UInt8] = [35, 0x01, 76, 0x01, 0x00] + payload   // type, seq, cmd, origin_seq, result
        let length = inner.count + 4
        // Deliberately PRINTABLE trailer bytes: if the decode ever ran past `length` these would show
        // up in the name, which is exactly the class of bug being pinned.
        let trailer: [UInt8] = Array("ZZZZ".utf8)
        return [0xAA, UInt8(length & 0xFF), UInt8(length >> 8), 0x00] + inner + trailer
    }

    // MARK: - The reported regression

    func testResidueAfterTerminatorIsNotAppended() {
        // "WHOOP" written over a longer previous name "WHOOPMAXX": the terminator lands after "WHOOP"
        // and "AXX" is the uncleared tail. Pre-fix this decoded as "WHOOPAXX".
        let field: [UInt8] = [0x00, 0x00] + Array("WHOOP".utf8) + [0x00] + Array("AXX".utf8)
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "WHOOP")
    }

    func testSingleCharacterResidueIsNotAppended() {
        // The exact shape reported: one stray printable byte after the terminator.
        for junk in Array("x;G".utf8) {
            let field: [UInt8] = [0x00, 0x00] + Array("WHOOP".utf8) + [0x00, junk]
            XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "WHOOP",
                           "residue byte \(junk) leaked into the name")
        }
    }

    func testNonPrintableResidueWasAlreadyHarmlessAndStaysSo() {
        let field: [UInt8] = [0x00, 0x00] + Array("WHOOP".utf8) + [0x00, 0x01, 0x02, 0xFF]
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "WHOOP")
    }

    // MARK: - Layout robustness (the GET header width is not pinned by a capture)

    func testDecodesWithLeadingNulHeader() {
        let field: [UInt8] = [0x00, 0x00] + Array("Bandit".utf8) + [0x00]
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "Bandit")
    }

    func testDecodesWithoutLeadingNulHeader() {
        let field: [UInt8] = Array("Bandit".utf8) + [0x00]
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "Bandit")
    }

    func testDecodesWhenFieldIsNotTerminatedAtAll() {
        // A field that fills to the crc32 boundary with no terminator must still decode, not truncate.
        let field: [UInt8] = [0x00, 0x00] + Array("Bandit".utf8)
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "Bandit")
    }

    func testCrc32TrailerIsNeverReadIntoTheName() {
        // The trailer is "ZZZZ" — printable on purpose. It sits at/after `length`.
        let field: [UInt8] = [0x00, 0x00] + Array("Bandit".utf8) + [0x00]
        let name = FrameRouter.advertisingName(in: responseFrame(payload: field))
        XCTAssertEqual(name, "Bandit")
        XCTAssertFalse(name?.contains("Z") ?? false, "crc32 trailer leaked into the name")
    }

    // MARK: - Preserved behaviour

    func testInteriorSpacesSurviveAndEdgesAreTrimmed() {
        let field: [UInt8] = [0x00, 0x00] + Array("  My Strap  ".utf8) + [0x00] + Array("old".utf8)
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "My Strap")
    }

    func testAllNulFieldDecodesEmptySoTheCallerCanIgnoreIt() {
        // FrameRouter's caller guards on `!name.isEmpty`, so an empty strap name stays unpublished.
        let field: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "")
    }

    /// KNOWN LIMITATION, pinned deliberately so it is a decision and not a surprise.
    ///
    /// Skipping leading NULs is what makes the decode tolerant of a header whose width no capture
    /// pins. The cost is that an EMPTY name followed by uncleared residue is indistinguishable from
    /// a name sitting behind a wider header — both look like "NULs, then bytes". This case cannot
    /// arise from our own rename (`renameStrap` rejects an empty name, and `advertisingNamePayload`
    /// always writes a 2-byte header), so the tolerance is worth more than the edge case.
    ///
    /// If a wire capture ever pins the GET reply's header width, replace the `drop` with a fixed
    /// offset and this test flips to expecting "".
    func testEmptyNameWithResidueDecodesAsResidue() {
        let field: [UInt8] = [0x00, 0x00, 0x00] + Array("stale".utf8)
        XCTAssertEqual(FrameRouter.advertisingName(in: responseFrame(payload: field)), "stale")
    }

    func testShortFrameReturnsNil() {
        XCTAssertNil(FrameRouter.advertisingName(in: []))
        XCTAssertNil(FrameRouter.advertisingName(in: [0xAA, 0x05]))
        // length <= start: no payload room at all.
        XCTAssertNil(FrameRouter.advertisingName(in: [0xAA, 0x08, 0x00, 0x00, 35, 0x01, 76, 0x01, 0x00]))
    }
}
