import XCTest
@testable import whoopmaxx

/// Two restore guards that were open:
///  1. Gate 3's foreign-SQLite predicate only checked `device`/`hrSample`, so another app's database
///     could replace the live store — emptying it, or wedging the migrator permanently on a colliding
///     generic table name with no in-app way back.
///  2. Gate 9 re-armed the heal one-shots, but the still-running pre-restore process could spend them
///     against the old (unlinked) database before the relaunch, leaving the restored rows unhealed.
final class RestoreGuardTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "wm.test.restore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName { UserDefaults.standard.removeSuite(named: suiteName) }
    }

    // MARK: - Gate 3 origin predicate

    /// A genuine whoopmaxx backup always carries `grdb_migrations` (the migrator runs in
    /// `StrapStore.init`, before anything can export it), so it classifies `.grdb` and the data
    /// predicate is never consulted.
    func testGenuineBackupClassifiesAsGrdb() {
        XCTAssertEqual(BackupImport.backupOrigin(of: ["grdb_migrations", "device", "hrSample"]), .grdb)
        XCTAssertEqual(BackupImport.backupOrigin(of: ["grdb_migrations"]), .grdb)
    }

    func testAndroidBackupIsStillDetected() {
        XCTAssertEqual(BackupImport.backupOrigin(of: ["room_master_table", "device"]), .android)
        XCTAssertEqual(BackupImport.backupOrigin(of: ["android_metadata", "sqlite_sequence"]), .android)
    }

    /// The regression: a foreign SQLite carrying a table the migrator creates with a bare
    /// `CREATE TABLE` must be caught. `workout`, `journal` and `event` are the realistic collisions —
    /// generic names another fitness app would plausibly use.
    func testForeignDatabaseWithACollidingTableIsRejected() {
        for table in ["workout", "journal", "event", "habit", "battery", "cursors"] {
            XCTAssertTrue(BackupImport.migratorOwnedTables.contains(table),
                          "\(table) is created with a bare CREATE TABLE and must be in the predicate")
        }
        // …and the old two-name predicate would have missed every one of them.
        for table in ["workout", "journal", "event"] {
            XCTAssertNotEqual(table, "device")
            XCTAssertNotEqual(table, "hrSample")
        }
    }

    /// An unrelated SQLite that collides with nothing is still allowed through Gate 3 — the gate exists
    /// to catch collisions, not to be a whitelist.
    func testUnrelatedTablesDoNotCollide() {
        let foreign: Set<String> = ["notes", "photos", "recipes", "sqlite_sequence"]
        XCTAssertTrue(foreign.isDisjoint(with: BackupImport.migratorOwnedTables))
    }

    /// The legacy carve-out: an unreadable probe yields an EMPTY table set, which must stay disjoint so
    /// that path behaves exactly as before.
    func testEmptyTableSetIsDisjoint() {
        XCTAssertTrue(Set<String>().isDisjoint(with: BackupImport.migratorOwnedTables))
        XCTAssertEqual(BackupImport.backupOrigin(of: []), .unknown)
    }

    // MARK: - Gate 9 re-arm survival

    func testRearmClearsOneShotsAndRaisesThePendingMarker() {
        for key in RestoreHealReset.storeScopedOneShots { defaults.set(true, forKey: key) }

        RestoreHealReset.rearm(in: defaults)

        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must return to its never-run state")
        }
        XCTAssertTrue(defaults.bool(forKey: RestoreHealReset.rearmPendingKey))
    }

    /// The regression: the live pre-restore process burns the flags again before the user quits. The
    /// next launch must re-arm them, or the restored rows keep exactly the corruption Gate 9 clears.
    func testPendingRearmSurvivesThePreRelaunchProcessBurningTheFlags() {
        RestoreHealReset.rearm(in: defaults)
        // Simulate the still-running process: an .idleTick / finished sync runs the heals against the
        // OLD store and sets every flag straight back to done.
        for key in RestoreHealReset.storeScopedOneShots { defaults.set(true, forKey: key) }

        RestoreHealReset.applyPendingRearm(in: defaults)

        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must be re-armed on the launch after a restore")
        }
        XCTAssertFalse(defaults.bool(forKey: RestoreHealReset.rearmPendingKey), "the marker is consumed")
    }

    /// It must be a no-op on an ordinary launch — otherwise every launch re-runs the widened rescore
    /// and both 400-day sweeps.
    func testApplyPendingRearmIsANoOpWithoutAMarker() {
        for key in RestoreHealReset.storeScopedOneShots { defaults.set(true, forKey: key) }

        RestoreHealReset.applyPendingRearm(in: defaults)

        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertTrue(defaults.bool(forKey: key), "\(key) must not be disturbed on a normal launch")
        }
    }

    /// Consuming it once is enough: a second launch does nothing.
    func testPendingRearmIsConsumedExactlyOnce() {
        RestoreHealReset.rearm(in: defaults)
        RestoreHealReset.applyPendingRearm(in: defaults)
        for key in RestoreHealReset.storeScopedOneShots { defaults.set(true, forKey: key) }

        RestoreHealReset.applyPendingRearm(in: defaults)

        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertTrue(defaults.bool(forKey: key), "the marker was already spent")
        }
    }

    /// The Apple Health purge flags must STAY out of the registry — re-arming them would delete Health
    /// history the 14-day re-export cannot rewrite.
    func testHealthPurgeFlagsAreNotReArmed() {
        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertFalse(key.hasPrefix("wm.health."), "\(key) must not be in the restore re-arm registry")
        }
    }
}
