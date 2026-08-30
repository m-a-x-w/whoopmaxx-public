import XCTest
@testable import whoopmaxx

/// Regression pins for `LiveState.redactPii` — the shareable-log PII scrub. It must mask BLE MACs, the
/// WHOOP serial in the device name, and the per-install CoreBluetooth peripheral UUID, while PRESERVING
/// the public standard-BLE base UUID (e.g. 0x2A37) and the WHOOP vendor service base (the
/// negative-lookahead carve-out). A leak here is a security regression.
final class RedactPiiTests: XCTestCase {

    /// A BLE MAC is masked to its first + last byte.
    func testMacMasked() {
        XCTAssertEqual(LiveState.redactPii("AA:BB:CC:DD:EE:FF"), "AA:••:••:••:••:FF")
    }

    /// The WHOOP serial carried in the device name is removed.
    func testSerialRemoved() {
        XCTAssertEqual(LiveState.redactPii("WHOOP 4C1594026"), "WHOOP <serial>")
    }

    /// A random CoreBluetooth peripheral UUID is masked to <device>.
    func testPeripheralUuidMasked() {
        XCTAssertEqual(LiveState.redactPii("12345678-1234-1234-1234-1234567890ab"), "<device>")
    }

    /// The standard-BLE base UUID (here the 0x2A37 HR characteristic) is PUBLIC and left untouched.
    func testStandardBaseUuidPreserved() {
        let uuid = "00002a37-0000-1000-8000-00805f9b34fb"
        XCTAssertEqual(LiveState.redactPii(uuid), uuid)
    }

    /// The WHOOP vendor service base UUID is identical on every strap and left untouched.
    func testWhoopVendorBaseUuidPreserved() {
        let uuid = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        XCTAssertEqual(LiveState.redactPii(uuid), uuid)
    }
}
