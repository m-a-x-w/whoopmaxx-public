import XCTest
@testable import whoopmaxx

/// `isArmedOnStrap` drives the Rest section's `.armedOnStrap` copy, which promises a firm wrist buzz
/// "even if whoopmaxx is closed". Neither an encrypted bond nor a SENT arm earns that promise: a 5/MG
/// reaches `encryptedBond == true` on a plain CLIENT_HELLO ack but BLEManager refuses to arm its firmware
/// alarm unless Experimental is on (the 5/MG wake has never been observed firing), and a WHOOP 4 arm
/// written at the bond edge can be dropped (six days of zero STRAP_DRIVEN_ALARM_SET in the 2026-09-15
/// backup). So `isArmedOnStrap` is true only once the strap has echoed the armed epoch back through
/// `onReadback`; until then the arm is `.confirming` and reads as backup-only.
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

    func testBondedAndArmableReadsAsArmedOnStrap_onlyAfterReadback() {
        let strap = HonestyFakeStrap(); strap.armable = true
        let (coord, settings) = makeCoordinator(strap: strap, bonded: true)
        settings.enabled = true

        coord.apply()
        XCTAssertEqual(coord.backstop, .confirming)
        XCTAssertFalse(coord.isArmedOnStrap, "sent is not armed")
        coord.onReadback(UInt32(settings.scheduledDeadlineEpoch))
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

    /// BLEManager owns the refusal and its own log line, so `apply()` still calls the arm over a bond
    /// regardless of whether it will take (through `armBackstop`, whose default forwards here).
    func testApplyStillCallsArmStrapAlarmEvenWhenNotArmable() {
        let strap = HonestyFakeStrap(); strap.armable = false
        let (coord, settings) = makeCoordinator(strap: strap, bonded: true)
        settings.enabled = true

        coord.apply()

        XCTAssertEqual(strap.armCount, 1,
                       "the fix is UI honesty only — it must not change what is written over BLE")
    }

    /// The protocol defaults keep every pre-existing conformer (and the app's own non-BLE fakes)
    /// behaving exactly as before the members were added.
    func testProtocolDefaultIsArmable() {
        XCTAssertTrue(DefaultingFakeStrap().strapAlarmArmable)
        XCTAssertTrue(DefaultingFakeStrap().backstopVerifiable)
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

/// Deliberately implements only the four original requirements — pins the default extension.
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
