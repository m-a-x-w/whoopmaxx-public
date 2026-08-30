import XCTest
@testable import whoopmaxx

/// Pins for `BatteryNotifier.evaluate` — the two-tier (15 % warning / 5 % critical) dedupe state
/// machine. Drives it against a throwaway defaults suite so nothing here touches the real app
/// domain or UNUserNotificationCenter.
final class BatteryNotifierTests: XCTestCase {

    private func makeNotifier() -> (BatteryNotifier, UserDefaults) {
        let name = "wm.test.battery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (BatteryNotifier(defaults: defaults), defaults)
    }

    func testWarningFiresOncePerCycle() {
        let (n, _) = makeNotifier()
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)
        XCTAssertNil(n.evaluate(pct: 14, charging: false))
        XCTAssertNil(n.evaluate(pct: 12, charging: false))
    }

    func testCriticalFiresAfterWarningInSameCycle() {
        let (n, _) = makeNotifier()
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)
        XCTAssertEqual(n.evaluate(pct: 5, charging: false), .critical)
        XCTAssertNil(n.evaluate(pct: 4, charging: false))
    }

    /// A first reading already below the critical bar says "now" once — and never backfills the
    /// milder warning afterwards.
    func testStraightToCriticalSpendsTheWarningTier() {
        let (n, _) = makeNotifier()
        XCTAssertEqual(n.evaluate(pct: 3, charging: false), .critical)
        XCTAssertNil(n.evaluate(pct: 4, charging: false))
    }

    func testChargingRearmsBothTiers() {
        let (n, _) = makeNotifier()
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)
        XCTAssertEqual(n.evaluate(pct: 4, charging: false), .critical)
        XCTAssertNil(n.evaluate(pct: 40, charging: true))
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)
        XCTAssertEqual(n.evaluate(pct: 4, charging: false), .critical)
    }

    /// The unwatched partial charge: a ≥5 pt rise above the pct we last notified at ends the cycle
    /// even though it never crosses the 30 % re-arm bar.
    func testPartialChargeRiseRearms() {
        let (n, _) = makeNotifier()
        XCTAssertEqual(n.evaluate(pct: 4, charging: false), .critical)
        XCTAssertNil(n.evaluate(pct: 8, charging: false))     // +4: not enough
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)  // +10: re-armed
    }

    func testUnknownChargingStateNeverNotifies() {
        let (n, _) = makeNotifier()
        XCTAssertNil(n.evaluate(pct: 4, charging: nil))
        XCTAssertNil(n.evaluate(pct: 14, charging: nil))
        // Silent means SPENT NOTHING — the next known-discharging read still gets both tiers.
        XCTAssertEqual(n.evaluate(pct: 14, charging: false), .warning)
        XCTAssertEqual(n.evaluate(pct: 4, charging: false), .critical)
    }

    func testPreferenceOffSilencesBothTiers() {
        let (n, defaults) = makeNotifier()
        defaults.set(false, forKey: StrapAlerts.lowBatteryKey)
        XCTAssertNil(n.evaluate(pct: 14, charging: false))
        XCTAssertNil(n.evaluate(pct: 2, charging: false))
    }
}
