import XCTest
@testable import whoopmaxx

/// A dead Bluetooth radio must not read as a missing strap.
///
/// `centralManagerDidUpdateState` guards on `state == .poweredOn` and returns, and `scanForWhoops`
/// silently no-ops off the same condition — so with Bluetooth off, permission denied, or BLE
/// unsupported, the pair sheet sat on "Searching for nearby straps · Keep the strap close to your
/// iPhone", blaming the strap for a radio problem the app already knew about. `.unauthorized` is the
/// bad one: it never self-heals, so the first-ever screen spun forever with no way out.
final class RadioStateTests: XCTestCase {

    /// A healthy radio says nothing — the strap really is the subject of the searching copy.
    func testAHealthyRadioHasNoProblemCopy() {
        XCTAssertNil(LiveState.RadioState.poweredOn.problem)
        XCTAssertNil(LiveState.RadioState.unknown.problem,
                     "unknown/resetting is transient — staying quiet is right, not a missing case")
    }

    /// Each broken state names itself and what to do about it.
    func testEveryBrokenStateIsActionable() {
        for state in [LiveState.RadioState.poweredOff, .unauthorized, .unsupported] {
            let copy = state.problem
            XCTAssertNotNil(copy, "\(state) must explain itself")
            XCTAssertFalse(copy!.isEmpty)
        }
    }

    /// The permission case must point at Settings — it is the only one the user cannot fix by toggling
    /// Control Centre, and the only one that never resolves on its own.
    func testUnauthorizedPointsAtSettings() {
        let copy = LiveState.RadioState.unauthorized.problem ?? ""
        XCTAssertTrue(copy.contains("Settings"), "the non-self-healing case needs a recovery route")
    }

    /// The copy must never blame the strap for a radio fault.
    func testRadioCopyDoesNotBlameTheStrap() {
        for state in [LiveState.RadioState.poweredOff, .unauthorized, .unsupported] {
            let copy = (state.problem ?? "").lowercased()
            XCTAssertFalse(copy.contains("charged"), "\(state) must not tell the user to charge the strap")
            XCTAssertFalse(copy.contains("nearby"), "\(state) must not tell the user to move the strap closer")
        }
    }

    /// Default is `.unknown`, so a LiveState that has never heard from CoreBluetooth shows the ordinary
    /// searching copy rather than a spurious error.
    @MainActor
    func testDefaultIsQuiet() {
        let live = LiveState()
        XCTAssertEqual(live.radio, .unknown)
        XCTAssertNil(live.radio.problem)
    }
}
