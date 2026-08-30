import XCTest
@testable import whoopmaxx

/// The App Group the widget and the app share is the one piece of wiring whose failure is completely
/// silent: `UserDefaults(suiteName:)` hands back a private per-process store when the entitlement is
/// absent, so writes succeed, reads come back empty, and no error is raised anywhere. A sideload build
/// shipped exactly that way — no entitlements blob at all, because `CODE_SIGNING_ALLOWED=NO` skips
/// packaging — and every widget tap was dropped for as long as it was installed.
///
/// `AppGroup` resolves against what the process actually holds instead of what the build asked for.
/// The parsing half of that is pure, so it is pinned here; the container probe is not (it depends on
/// the entitlements of whatever process is running) and is only asserted for internal consistency.
final class AppGroupResolutionTests: XCTestCase {

    // MARK: - Carving the plist out of a provisioning profile

    /// Shape of a real `.mobileprovision`: DER envelope bytes, then the signed XML payload, then the
    /// certificates and signature. The payload's `</plist>` is therefore NOT the last thing in the file.
    private func fakeProfile(groups: [String], trailingGarbage: Data = Data([0x30, 0x82, 0x04, 0x00])) -> Data {
        let entries = groups.map { "<string>\($0)</string>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>\
        <key>Entitlements</key><dict>\
        <key>com.apple.security.application-groups</key><array>\(entries)</array>\
        </dict></dict></plist>
        """
        var blob = Data([0x30, 0x82, 0x0A, 0xBC])      // DER header junk ahead of the payload
        blob.append(Data(xml.utf8))
        blob.append(trailingGarbage)                    // certificates trailing the signed content
        return blob
    }

    func testExtractsPayloadPlistFromEnvelope() throws {
        let blob = fakeProfile(groups: ["group.com.whoopmaxx.app"])
        let plist = try XCTUnwrap(AppGroup.embeddedPlist(in: blob))

        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let entitlements = try XCTUnwrap(root["Entitlements"] as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String],
                       ["group.com.whoopmaxx.app"])
    }

    /// The reason the carve searches FORWARD for `</plist>`: trailing DER can contain almost anything,
    /// and a backwards search that swallowed it would produce a slice that no longer parses.
    func testStopsAtPayloadTerminatorNotAtTrailingBytes() throws {
        let decoy = Data("...cert blob mentioning </plist> in passing...".utf8)
        let blob = fakeProfile(groups: ["group.com.whoopmaxx.app"], trailingGarbage: decoy)
        let plist = try XCTUnwrap(AppGroup.embeddedPlist(in: blob))

        XCTAssertNotNil(try PropertyListSerialization.propertyList(from: plist, format: nil),
                        "carve must end at the payload's terminator, not the last one in the file")
    }

    func testReturnsNilWhenThereIsNoPlist() {
        XCTAssertNil(AppGroup.embeddedPlist(in: Data([0x30, 0x82, 0x0A, 0xBC])))
        XCTAssertNil(AppGroup.embeddedPlist(in: Data()))
    }

    func testReturnsNilWhenTerminatorIsMissing() {
        var truncated = Data([0x30, 0x82])
        truncated.append(Data("<?xml version=\"1.0\"?><plist><dict>".utf8))
        XCTAssertNil(AppGroup.embeddedPlist(in: truncated))
    }

    // MARK: - Resolution

    /// An unsigned or profile-less bundle grants nothing; resolution must still name the declared id so
    /// callers have something to log, rather than crashing or inventing one.
    func testGrantedIsEmptyWithoutAProfile() {
        // The test host carries no embedded.mobileprovision.
        XCTAssertEqual(AppGroup.granted(), [])
        XCTAssertFalse(AppGroup.declared.isEmpty)
        XCTAssertEqual(AppGroup.resolved, AppGroup.declared,
                       "with nothing granted to fall back to, resolution stays on the declared id")
    }

    /// `suiteName` must be the RESOLVED id, not the declared one — that indirection is the whole point.
    func testSnapshotSuiteNameUsesResolvedGroup() {
        XCTAssertEqual(WidgetSnapshot.suiteName, AppGroup.resolved)
    }

    /// `isProvisioned` reports on the id actually in use, so the two can never disagree.
    func testProvisioningReportsOnTheResolvedId() {
        XCTAssertEqual(AppGroup.isProvisioned, AppGroup.reachable(AppGroup.resolved))
        XCTAssertEqual(WidgetSnapshot.isGroupProvisioned, AppGroup.isProvisioned)
    }
}
