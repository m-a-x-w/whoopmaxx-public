import XCTest
@testable import whoopmaxx

/// `isArmedOnStrap` drives the Rest section's `.armedOnStrap` copy, which promises a firm wrist buzz
/// "even if whoopmaxx is closed". An encrypted bond alone does not earn that promise: a 5/MG reaches
/// `encryptedBond == true` on a plain CLIENT_HELLO ack, but BLEManager additionally refuses to arm its
/// firmware alarm unless Experimental is on (the 5/MG wake has never been observed firing). Before this,
/// such a user was shown "Armed on the strap" for a backstop that was silently never armed — and set no
/// phone alarm because of it.
@MainActor
final class StrapAlarmHonestyTests: XCTestCase {

    private func makeCoordinator(strap: HonestyFakeStrap,
                                 bonded: Bool) -> (SmartAlarmCoordinator, SmartAlarmSettings) {
        let defaults = UserDefaults(suiteName: "wm.test.alarm.honesty.\(UUID().uuidString)")!
        let settings = SmartAlarmSettings(defaults: defaults)
        let live = LiveState()
        live.encryptedBond = bonded
        live.connected = bonded
        let coord = SmartAlarmCoordinator(ble: strap, live: live, settings: settings,
                                          notifier: HonestyFakeNotifier())
        return (coord, settings)
    }

    func testBondedAndArmableReadsAsArmedOnStrap() {
        let strap = HonestyFakeStrap(); strap.armable = true
        let (coord, settings) = makeCoordinator(strap: strap, bonded: true)
        settings.enabled = true

        XCTAssertTrue(coord.isArmedOnStrap)
    }

    /// The regression: bonded, enabled — but the family gate will refuse. Must NOT claim the strap backstop.
    func testBondedButRefusedFamilyReadsAsBackupOnly() {
        let strap = HonestyFakeStrap(); strap.armable = false
        let (coord, settings) = makeCoordinator(strap: strap, bonded: true)
        settings.enabled = true

        XCTAssertFalse(coord.isArmedOnStrap,
                       "a refused firmware arm must render .backupOnly, not .armedOnStrap")
    }

    func testUnbondedIsNeverArmedOnStrap() {
        let strap = HonestyFakeStrap(); strap.armable = true
        let (coord, settings) = makeCoordinator(strap: strap, bonded: false)
        settings.enabled = true

        XCTAssertFalse(coord.isArmedOnStrap)
    }

    func testDisabledIsNeverArmedOnStrap() {
        let strap = HonestyFakeStrap(); strap.armable = true
        let (coord, _) = makeCoordinator(strap: strap, bonded: true)

        XCTAssertFalse(coord.isArmedOnStrap)
    }

    /// The wire behaviour must be UNCHANGED — BLEManager owns the refusal and its own log line, so
    /// `apply()` still calls `armStrapAlarm` over a bond regardless of whether it will take.
    func testApplyStillCallsArmStrapAlarmEvenWhenNotArmable() {
        let strap = HonestyFakeStrap(); strap.armable = false
        let (coord, settings) = makeCoordinator(strap: strap, bonded: true)
        settings.enabled = true

        coord.apply()

        XCTAssertEqual(strap.armCount, 1,
                       "the fix is UI honesty only — it must not change what is written over BLE")
    }

    /// The protocol default keeps every pre-existing conformer (and the app's own non-BLE fakes)
    /// behaving exactly as before the member was added.
    func testProtocolDefaultIsArmable() {
        XCTAssertTrue(DefaultingFakeStrap().strapAlarmArmable)
    }
}

@MainActor
private final class HonestyFakeStrap: AlarmStrap {
    var armable = true
    var armCount = 0
    var strapAlarmArmable: Bool { armable }
    func armStrapAlarm(at date: Date) { armCount += 1 }
    func disableStrapAlarm() {}
    func buzzStrapOnce() {}
    func buzzStrap(loops: Int) {}
}

/// Deliberately does NOT implement `strapAlarmArmable` — pins the default extension.
@MainActor
private final class DefaultingFakeStrap: AlarmStrap {
    func armStrapAlarm(at date: Date) {}
    func disableStrapAlarm() {}
    func buzzStrapOnce() {}
    func buzzStrap(loops: Int) {}
}

private final class HonestyFakeNotifier: WakeNotifier {
    var log: ((String) -> Void)?
    func scheduleBackup(atMinute minute: Int) {}
    func cancelBackup() {}
    func postWakeNow() {}
}
