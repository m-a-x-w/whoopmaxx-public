import XCTest
@testable import whoopmaxx

/// The guard that stops a REINSTALL from wiping the user's Apple Health history.
///
/// `purgeStaleHrvIfNeeded` / `purgeFabricatedSpo2IfNeeded` are one-shot corrections of samples this app
/// wrote badly. Each is gated on a `UserDefaults` flag, and each deletes with
/// `predicateForObjects(from: HKSource.default())` — no date bound, so ALL TIME.
///
/// Deleting the app clears `UserDefaults` but NOT the Health store. So on a plain reinstall both flags
/// reset while the samples remain: the purges re-arm, delete every HRV and SpO2 sample whoopmaxx ever
/// wrote, and `exportRecent` rewrites only the trailing 14 days. Every reinstall therefore truncated the
/// user's Apple Health history to two weeks — permanently, since `SampleRetention` has aged out the raw
/// behind the older days at 28 days.
///
/// The fix requires evidence that THIS install has actually exported. A fresh install has no per-(type,
/// day) fingerprints, so it has written nothing of its own to correct and must not delete anything.
final class HealthExportPurgeGuardTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "health-purge-guard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// THE REGRESSION. A fresh install — the state after deleting and reinstalling the app — has no
    /// fingerprints, so the purges must not be allowed to delete.
    func testFreshInstallHasNoExportHistory() {
        XCTAssertFalse(HealthExport.hasEverExportedVitals(defaults: defaults),
                       "a fresh install has written nothing to Health and must never purge")
    }

    /// An install that HAS exported keeps the original one-shot correction — including the restore case
    /// the purges were deliberately left un-whitelisted for, since a restore replays exports.
    func testInstallThatHasExportedStillPurges() {
        defaults.set("fp-abc", forKey: "wm.health.vitalsFp.2026-07-30.HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        XCTAssertTrue(HealthExport.hasEverExportedVitals(defaults: defaults))
    }

    /// Only vitals fingerprints count. A sleep-stage fingerprint alone does not mean we ever wrote the
    /// quantity types these purges delete.
    func testSleepFingerprintAloneDoesNotCountAsVitalsHistory() {
        defaults.set("fp-xyz", forKey: "wm.health.sleepFp.1785302834")
        XCTAssertFalse(HealthExport.hasEverExportedVitals(defaults: defaults))
    }

    /// Unrelated keys must not be mistaken for export history.
    func testUnrelatedKeysAreIgnored() {
        defaults.set(true, forKey: "wm.health.exportEnabled")
        defaults.set(42, forKey: "wm.alarm.earliestMin")
        XCTAssertFalse(HealthExport.hasEverExportedVitals(defaults: defaults))
    }
}
