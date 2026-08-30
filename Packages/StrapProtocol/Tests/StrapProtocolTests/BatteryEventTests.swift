import XCTest
@testable import StrapProtocol

/// BATTERY_LEVEL, the strap's only live state-of-charge source. It re-emits roughly every eight
/// minutes, so a decode failure here shows up as a battery reading that is simply never there.
final class BatteryEventTests: XCTestCase {

    /// Event envelope: [type][seq][u16 id][u32 unix][u16 subsec][u16 body len][body…]
    /// Body: [0] revision, [1] u16 deci-percent, [5] u16 millivolts, [9] charger flag.
    private func batteryEvent(deciPercent: UInt16, mv: UInt16, charging: UInt8,
                              eventId: UInt8 = UInt8(Schema.batteryLevelEvent),
                              length: Int = 26) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: length)
        b[0] = PacketType.event
        b[1] = 0x04
        b[2] = eventId
        withUnsafeBytes(of: UInt32(1_775_395_266).littleEndian) { b.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: UInt16(12).littleEndian) { b.replaceSubrange(10..<12, with: $0) }
        if length > 12 { b[12] = 2 }                                     // revision
        if length >= 15 { withUnsafeBytes(of: deciPercent.littleEndian) { b.replaceSubrange(13..<15, with: $0) } }
        if length >= 19 { withUnsafeBytes(of: mv.littleEndian) { b.replaceSubrange(17..<19, with: $0) } }
        if length >= 22 { b[21] = charging }
        return b
    }

    private func parsed(_ inner: [UInt8]) -> [String: ParsedValue] {
        parseFrame(buildFrame(inner, profile: .gen4), family: .whoop4).parsed
    }

    /// Deci-percent, not percent. Reading this field as whole percent reports a full strap as 1000%.
    func testChargeIsDeciPercent() {
        let p = parsed(batteryEvent(deciPercent: 505, mv: 3_712, charging: 0))
        XCTAssertEqual(p["battery_pct"]?.doubleValue, 50.5)
        XCTAssertEqual(p["battery_mv"]?.intValue, 3_712)
    }

    /// The real reading from a nearly-flat strap in this project's own backup.
    func testLowChargeMatchesARealReading() {
        XCTAssertEqual(parsed(batteryEvent(deciPercent: 101, mv: 3_709, charging: 0))["battery_pct"]?.doubleValue,
                       10.1)
    }

    /// body[9], not body[10] — [10] is always zero, so reading it there is permanently false.
    func testChargingFlagIsReadFromTheRightByte() {
        XCTAssertEqual(parsed(batteryEvent(deciPercent: 505, mv: 3_712, charging: 1))["battery_charging"]?.intValue, 1)
        XCTAssertEqual(parsed(batteryEvent(deciPercent: 505, mv: 3_712, charging: 0))["battery_charging"]?.intValue, 0)
    }

    /// Out of range means this is not the field the map claims. A fabricated charge drives the
    /// low-battery alert and the runtime estimate, so emit nothing instead.
    func testImpossibleChargeIsNotEmitted() {
        XCTAssertNil(parsed(batteryEvent(deciPercent: 1_010, mv: 3_712, charging: 0))["battery_pct"])
    }

    func testOtherEventsCarryNoBattery() {
        XCTAssertNil(parsed(batteryEvent(deciPercent: 505, mv: 3_712, charging: 0, eventId: 7))["battery_pct"])
    }

    func testTruncatedEventIsNotDecoded() {
        XCTAssertNil(parsed(batteryEvent(deciPercent: 505, mv: 3_712, charging: 0, length: 20))["battery_pct"])
    }
}
