import XCTest
import SQLite3
import StrapStore
import ZIPFoundation
@testable import whoopmaxx

/// The backup importer: build a `.wmbak` fixture in-test (a real GRDB store zipped with a
/// `settings.json`), restore it over a throwaway destination, and verify rows + settings + the
/// snapshot sidecar. Plus the reject gates (garbage, foreign SQLite).
final class BackupImportTests: XCTestCase {

    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("backupimport-tests")
        suiteName = "backup-import-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        Fixtures.cleanUp(tmp)
    }

    /// Build a tiny real GRDB store (via the vendored StrapStore, so it carries `grdb_migrations`)
    /// with two dailyMetric rows, WAL-checkpointed, at the returned path.
    private func makeFixtureStore(named name: String) async throws -> String {
        let path = tmp.appendingPathComponent(name).path
        let store = try await StrapStore(path: path)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        _ = try await store.upsertDailyMetrics([
            Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 400, recovery: 61),
            Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 420, recovery: 72),
        ], deviceId: "my-whoop")
        try await store.checkpointWAL()
        return path
    }

    /// Zip a fixture backup: `backup.sqlite` first, then an optional `settings.json` —
    /// the exact container the original exporter writes.
    private func makeBackupZip(from sqlitePath: String, settings: [String: Any]?) throws -> URL {
        let bak = tmp.appendingPathComponent("fixture-\(UUID().uuidString).wmbak")
        let archive = try Archive(url: bak, accessMode: .create)
        try archive.addEntry(with: "backup.sqlite",
                             fileURL: URL(fileURLWithPath: sqlitePath), compressionMethod: .deflate)
        if let settings, let json = BackupSettings.encode(settings) {
            let tmpJSON = tmp.appendingPathComponent("settings-\(UUID().uuidString).json")
            try json.write(to: tmpJSON)
            try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON,
                                 compressionMethod: .deflate)
        }
        return bak
    }

    // MARK: - Round trip

    func testZipRestoreRoundTrip() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-src.sqlite")
        let bak = try makeBackupZip(from: fixturePath,
                                  settings: ["units.system": "imperial", "profile.age": 33])

        // Destination: a pre-existing store with one DIFFERENT row, so the test proves both the
        // replacement and the pre-import snapshot sidecar.
        let destDir = tmp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destPath = destDir.appendingPathComponent("whoop.sqlite").path
        do {
            let old = try await StrapStore(path: destPath)
            _ = try await old.upsertDailyMetrics(
                [Fixtures.dailyMetric(day: "2026-01-01", totalSleepMin: 111, recovery: 11)],
                deviceId: "my-whoop")
            try await old.checkpointWAL()
        }

        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .needsRelaunch(let sidecar) = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }

        // The previous store was preserved aside under the whoopmaxx-replaced-<ts> scheme.
        XCTAssertTrue(sidecar.lastPathComponent.hasPrefix("whoopmaxx-replaced-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        // The swapped-in DB opens through the vendored store and carries the fixture rows only.
        let swapped = try await StrapStore(path: destPath)
        let rows = try await swapped.dailyMetrics(deviceId: "my-whoop",
                                                  from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(rows.map(\.day), ["2026-07-13", "2026-07-14"])
        XCTAssertEqual(rows.first?.recovery, 61)

        // settings.json was applied to the injected defaults (whitelist mapping intact).
        XCTAssertEqual(defaults.string(forKey: "units.system"), "imperial")
        XCTAssertEqual(defaults.integer(forKey: "profile.age"), 33)
    }

    /// A settings-less (legacy, DB-only) ZIP restores rows and leaves settings untouched.
    func testLegacyDbOnlyZipRestores() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-legacy.sqlite")
        let bak = try makeBackupZip(from: fixturePath, settings: nil)
        let destPath = tmp.appendingPathComponent("dest-legacy.sqlite").path

        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .needsRelaunch = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }
        let swapped = try await StrapStore(path: destPath)
        let rows = try await swapped.dailyMetrics(deviceId: "my-whoop",
                                                  from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(defaults.string(forKey: "units.system"))
    }

    // MARK: - Reject gates

    /// Non-ZIP, non-SQLite garbage is refused before anything touches the destination.
    func testRejectsGarbageFile() throws {
        let garbage = tmp.appendingPathComponent("garbage.wmbak")
        try Data((0..<512).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        let destPath = tmp.appendingPathComponent("dest-garbage.sqlite").path

        let result = BackupImport.restore(from: garbage, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .failure(let reason) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        XCTAssertTrue(reason.contains("SQLite"), "reason should name the shape problem: \(reason)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destPath),
                       "a refused import must not create a destination DB")
    }

    /// A valid SQLite that holds data tables but no `grdb_migrations` bookkeeping (a Room/Android
    /// or foreign DB) is refused — restoring it would strand the migrator (#222).
    func testRejectsSqliteWithoutGrdbMigrations() throws {
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(foreign.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE device (id TEXT PRIMARY KEY)", nil, nil, nil),
                       SQLITE_OK)
        sqlite3_close(db)

        let destPath = tmp.appendingPathComponent("dest-foreign.sqlite").path
        let result = BackupImport.restore(from: foreign, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .failure(let reason) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        XCTAssertTrue(reason.contains("migration bookkeeping"), "wrong reject reason: \(reason)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destPath))
    }

    /// A ZIP with no `*.sqlite` entry at all is refused.
    func testRejectsZipWithoutDatabaseEntry() throws {
        let zip = tmp.appendingPathComponent("empty-ish.wmbak")
        let archive = try Archive(url: zip, accessMode: .create)
        let tmpJSON = tmp.appendingPathComponent("readme.json")
        try Data("{}".utf8).write(to: tmpJSON)
        try archive.addEntry(with: "readme.json", fileURL: tmpJSON, compressionMethod: .deflate)

        let destPath = tmp.appendingPathComponent("dest-empty.sqlite").path
        let result = BackupImport.restore(from: zip, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .failure(let reason) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        XCTAssertTrue(reason.contains("doesn't contain a database"), "wrong reason: \(reason)")
    }

    // MARK: - Origin classification (pure)

    func testBackupOriginClassification() {
        XCTAssertEqual(BackupImport.backupOrigin(of: ["grdb_migrations", "device"]), .grdb)
        XCTAssertEqual(BackupImport.backupOrigin(of: ["room_master_table", "device"]), .android)
        XCTAssertEqual(BackupImport.backupOrigin(of: ["android_metadata", "sqlite_sequence"]), .android)
        // Degenerate both-present case: our marker wins (less destructive read).
        XCTAssertEqual(BackupImport.backupOrigin(of: ["grdb_migrations", "room_master_table"]), .grdb)
        XCTAssertEqual(BackupImport.backupOrigin(of: []), .unknown)
        XCTAssertEqual(BackupImport.backupOrigin(of: ["something_else"]), .unknown)
    }

    // MARK: - .wmbak restores through the same path

    /// whoopmaxx's own `.wmbak` (store.sqlite + manifest.json + settings.json) restores via the
    /// exact same importer — the container convention exists for this.
    func testWmbakRestoresThroughBackupImport() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-wm.sqlite")
        let folder = tmp.appendingPathComponent("wmout", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let written = await WmBackup.writeBackup(databaseAt: fixturePath, checkpoint: { true },
                                                 into: folder, defaults: defaults)
        guard case .written(let wmbak) = written else {
            return XCTFail("fixture backup failed: \(written)")
        }

        let destPath = tmp.appendingPathComponent("dest-wm.sqlite").path
        let result = BackupImport.restore(from: wmbak, toDatabaseAt: destPath,
                                        settingsDefaults: defaults)
        guard case .needsRelaunch = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }
        let swapped = try await StrapStore(path: destPath)
        let rows = try await swapped.dailyMetrics(deviceId: "my-whoop",
                                                  from: "2026-07-01", to: "2026-07-31")
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Gate 4b + the inspect/restore split

    // `restore` is now `inspect` (Gates 1–4b, which touch nothing outside a temp dir) followed by
    // `restore(staged:)` (Gates 5–9, the destructive half). Two things have to be pinned: that the
    // split changed NOTHING about what lands, and that the new refusal fires strictly BEFORE Gate 5 —
    // a schema gate that runs after the swap is worse than no gate at all.

    /// A `.wmbak`-shaped container whose manifest carries an EXPLICIT `schemaVersion`, the field Gate
    /// 4b reads. Hand-built rather than routed through `WmBackup.writeBackup`, which always stamps the
    /// RUNNING binary's own schema and so can never produce the future-dated file this gate exists for.
    private func makeWmbak(from sqlitePath: String, schemaVersion: Int) throws -> URL {
        let bak = tmp.appendingPathComponent("schema-\(schemaVersion)-\(UUID().uuidString).wmbak")
        let archive = try Archive(url: bak, accessMode: .create)
        try archive.addEntry(with: WmBackup.dbEntryName,
                             fileURL: URL(fileURLWithPath: sqlitePath), compressionMethod: .deflate)
        let manifest: [String: Any] = [
            "formatVersion": WmBackup.formatVersion,
            "schemaVersion": schemaVersion,
            "appVersion": "9.9.9 (999)",
            "createdAtUTC": "2026-08-05T09:30:00Z",
            "settingsVersion": WmBackup.settingsVersion,
        ]
        let json = tmp.appendingPathComponent("manifest-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: json)
        try archive.addEntry(with: WmBackup.manifestEntryName, fileURL: json,
                             compressionMethod: .deflate)
        return bak
    }

    /// A destination store holding one row, checkpointed, in a directory of its OWN — so a
    /// `whoopmaxx-replaced-<ts>` snapshot from one restore can never be mistaken for another's.
    private func makeDestinationStore(named name: String) async throws -> String {
        let dir = tmp.appendingPathComponent("dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        let old = try await StrapStore(path: path)
        _ = try await old.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-01-01", totalSleepMin: 111, recovery: 11)],
            deviceId: "my-whoop")
        try await old.checkpointWAL()
        return path
    }

    /// A backup one schema AHEAD of this binary carries migrations it does not have, so it is refused.
    /// The return value is the least interesting half of that: what this pins is the live database,
    /// byte-identical afterwards and with no Gate-5 snapshot beside it — proof the refusal fired
    /// before anything destructive, which is the only thing that makes it worth having.
    func testFutureSchemaBackupIsRefusedBeforeAnythingIsTouched() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-future.sqlite")
        let bak = try makeWmbak(from: fixturePath, schemaVersion: StrapStoreInfo.schemaVersion + 1)
        let destPath = try await makeDestinationStore(named: "whoop-future.sqlite")
        let destURL = URL(fileURLWithPath: destPath)
        let before = try Data(contentsOf: destURL)

        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath,
                                          settingsDefaults: defaults)

        guard case .failure(let reason) = result else {
            return XCTFail("expected .failure, got \(result)")
        }
        XCTAssertTrue(reason.contains("\(StrapStoreInfo.schemaVersion + 1)"),
                      "the refusal must name the file's schema: \(reason)")
        XCTAssertTrue(reason.contains("\(StrapStoreInfo.schemaVersion)"),
                      "the refusal must name this app's schema: \(reason)")
        let after = try Data(contentsOf: destURL)
        XCTAssertEqual(after, before,
                       "a refused restore must leave the live database byte-identical")
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: destURL.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix("whoopmaxx-replaced-") },
                       "Gate 4b must refuse BEFORE Gate 5 — no snapshot should have been written")
    }

    /// The other direction, and it matters just as much: an OLDER backup is the ordinary case and must
    /// still restore. Migrating an old store forward is exactly what the migrator is for; refusing it
    /// would strand every long-standing archive. Also pins the manifest fields the confirm step reads.
    func testOlderSchemaBackupStillRestores() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-older.sqlite")
        let older = max(1, StrapStoreInfo.schemaVersion - 1)
        let bak = try makeWmbak(from: fixturePath, schemaVersion: older)

        guard case .ready(let staged) = BackupImport.inspect(from: bak) else {
            return XCTFail("expected .ready from inspect")
        }
        XCTAssertEqual(staged.summary.schemaVersion, older)
        XCTAssertEqual(staged.summary.formatVersion, WmBackup.formatVersion)
        XCTAssertEqual(staged.summary.appVersion, "9.9.9 (999)")
        XCTAssertEqual(staged.summary.createdAtUTC, "2026-08-05T09:30:00Z")
        staged.discard()

        let destPath = try await makeDestinationStore(named: "whoop-older.sqlite")
        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath,
                                          settingsDefaults: defaults)
        guard case .needsRelaunch = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }
        let swapped = try await StrapStore(path: destPath)
        let rows = try await swapped.dailyMetrics(deviceId: "my-whoop",
                                                  from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(rows.map(\.day), ["2026-07-13", "2026-07-14"])
    }

    /// A bare `.zip` carries no manifest, so every manifest field reads nil — "not recorded", which
    /// the UI must say rather than printing a fabricated 0 — while the counts are read for real off
    /// the staged file. An empty `sleepSession` table that DID open is 0, not nil: that is a
    /// measurement.
    func testInspectOfManifestlessZipReportsNilManifestAndRealCounts() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-nomanifest.sqlite")
        // A COMPUTED-lane row on a day the raw lane already has. `dailyMetric`'s key is
        // (deviceId, day), so this fixture holds 3 rows across 2 days — the summary must report the
        // days, which is what "days" means everywhere else in the app, not the row count.
        do {
            let store = try await StrapStore(path: fixturePath)
            _ = try await store.upsertDailyMetrics(
                [Fixtures.dailyMetric(day: "2026-07-13", recovery: 55)], deviceId: computedId)
            try await store.checkpointWAL()
        }
        let bak = try makeBackupZip(from: fixturePath, settings: nil)

        guard case .ready(let staged) = BackupImport.inspect(from: bak) else {
            return XCTFail("expected .ready from inspect")
        }
        defer { staged.discard() }

        XCTAssertNil(staged.summary.formatVersion)
        XCTAssertNil(staged.summary.schemaVersion)
        XCTAssertNil(staged.summary.appVersion)
        XCTAssertNil(staged.summary.createdAtUTC)
        XCTAssertEqual(staged.summary.dayCount, 2)
        XCTAssertEqual(staged.summary.earliestDay, "2026-07-13")
        XCTAssertEqual(staged.summary.latestDay, "2026-07-14")
        XCTAssertEqual(staged.summary.sleepSessionCount, 0)
        XCTAssertNotNil(staged.summary.sizeBytes)
        XCTAssertGreaterThan(staged.summary.sizeBytes ?? 0, 0)
    }

    /// The split test — with an honest note on what it does and does not establish.
    ///
    /// It pins that the COMPOSITION holds: calling `inspect` then `restore(staged:)` by hand lands the
    /// same bytes, applies the same settings and re-arms the same flags as the one-shot
    /// `restore(from:)` every existing caller uses. That genuinely catches a composition bug — a
    /// staging discarded before Gate 6 copies out of it, or a Gate 4c refusal that only fires under the
    /// default database path — because the two routes differ in exactly those respects.
    ///
    /// What it CANNOT establish is equivalence to the PRE-SPLIT code, because `restore(from:)` is now
    /// implemented as those same two calls: at that level it compares the new code with itself. No
    /// in-suite test can compare against deleted code without vendoring a copy of it. The evidence for
    /// "Gates 5–9 were moved, not edited" is the diff — 9 removed lines, every one in Gates 1–4 — and
    /// it lives in review, not here. Do not read a green run of this as more than it is.
    func testInspectThenRestoreStagedMatchesTheOneShotRestore() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-equiv.sqlite")
        let bak = try makeBackupZip(from: fixturePath, settings: ["units.system": "imperial"])

        // Path A: the pre-split entry point, unchanged for every caller.
        let destA = try await makeDestinationStore(named: "whoop-a.sqlite")
        let resultA = BackupImport.restore(from: bak, toDatabaseAt: destA, settingsDefaults: defaults)
        guard case .needsRelaunch(let sidecarA) = resultA else {
            return XCTFail("expected .needsRelaunch, got \(resultA)")
        }

        // Path B: the two halves, driven the way a confirm step will drive them. Clear what A left
        // behind first, so every assertion below is about B's own work.
        defaults.removeObject(forKey: "units.system")
        markEverythingHealed()
        let destB = try await makeDestinationStore(named: "whoop-b.sqlite")
        guard case .ready(let staged) = BackupImport.inspect(from: bak) else {
            return XCTFail("expected .ready from inspect")
        }
        let resultB = BackupImport.restore(staged: staged, toDatabaseAt: destB,
                                           settingsDefaults: defaults)
        guard case .needsRelaunch(let sidecarB) = resultB else {
            return XCTFail("expected .needsRelaunch, got \(resultB)")
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destA)),
                       try Data(contentsOf: URL(fileURLWithPath: destB)),
                       "the split must land a byte-identical database")
        XCTAssertTrue(sidecarA.lastPathComponent.hasPrefix("whoopmaxx-replaced-"))
        XCTAssertTrue(sidecarB.lastPathComponent.hasPrefix("whoopmaxx-replaced-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarB.path),
                      "Gate 5 must still snapshot the store it replaced")
        XCTAssertEqual(defaults.string(forKey: "units.system"), "imperial",
                       "Gate 8 must still apply the backup's settings")
        XCTAssertFalse(defaults.bool(forKey: Spo2Heal.doneKey),
                       "Gate 9 must still re-arm the store-scoped one-shots")

        // The staging OUTLIVES `restore(staged:)` — that is the point of the seam (Gate 8 reads
        // settings out of it) and the reason `discard()` is the caller's job.
        let stagedDir = try XCTUnwrap(staged.extractedDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDir.path),
                      "restore(staged:) must not delete a staging its caller still owns")
        staged.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDir.path))
    }

    /// `discard()` is the counterpart to the `defer` the split removed: it deletes OUR staging and
    /// nothing else. Without it a cancelled confirm strands a whole extracted store (~675 MB at the
    /// documented steady state) in temp; with a sloppier one it would delete the user's picked file.
    func testDiscardRemovesTheStagedTempDirAndNothingElse() async throws {
        let fixturePath = try await makeFixtureStore(named: "fixture-discard.sqlite")
        let bak = try makeBackupZip(from: fixturePath, settings: nil)

        guard case .ready(let staged) = BackupImport.inspect(from: bak) else {
            return XCTFail("expected .ready from inspect")
        }
        let dir = try XCTUnwrap(staged.extractedDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.source.path))

        staged.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "a cancelled confirm must not strand an extracted store in temp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path),
                      "discard() must never touch the user's own picked file")
        staged.discard()   // idempotent: a cancel path that fires twice must stay harmless
    }

    // MARK: - Gate 4c: the free-space precheck

    // A restore writes TWICE — Gate 5 snapshots the database it is replacing, Gate 6 lands the staged
    // one over it — so it can run a volume dry inside the destructive half, with the live database
    // already removed. Gate 4c declines up front instead.
    //
    // The volume read behind the verdict is not injectable, and is not the part that can be wrong. What
    // these pin is the ARITHMETIC it is handed, and the property that makes an unmeasurable input safe:
    // the gate declines to ANSWER rather than refusing the user's restore. That the gate does not fire
    // on an ordinary import is pinned by every restore test above — they all traverse it now, so an
    // inverted verdict takes the whole file red.

    /// Needed = the staged file + the database it replaces. Two sizes, both distinct and neither a
    /// multiple of the other, so a requirement that quietly dropped either term still shows up.
    func testRequiredFreeBytesIsTheStagedFilePlusTheDatabaseItReplaces() throws {
        let staged = tmp.appendingPathComponent("staged-arith.sqlite")
        let live = tmp.appendingPathComponent("live-arith.sqlite")
        try Data(repeating: 0x41, count: 4_096).write(to: staged)
        try Data(repeating: 0x42, count: 1_500).write(to: live)

        XCTAssertEqual(BackupImport.requiredFreeBytes(stagedAt: staged, databaseAt: live.path),
                       4_096 + 1_500,
                       "the landed copy AND the Gate-5 snapshot of what it replaces")
    }

    /// Gate 5 snapshots the live `-wal`/`-shm` siblings alongside the main file
    /// (`copyDatabaseWithSidecars`), so a requirement that ignores them under-reports exactly the store
    /// most at risk: a large one whose recent pages still live in an un-checkpointed WAL.
    func testRequiredFreeBytesCountsTheWalAndShmTheSnapshotWillCopy() throws {
        let staged = tmp.appendingPathComponent("staged-wal.sqlite")
        let live = tmp.appendingPathComponent("live-wal.sqlite")
        try Data(repeating: 0x41, count: 4_096).write(to: staged)
        try Data(repeating: 0x42, count: 1_500).write(to: live)
        try Data(repeating: 0x43, count: 900).write(to: URL(fileURLWithPath: live.path + "-wal"))
        try Data(repeating: 0x44, count: 300).write(to: URL(fileURLWithPath: live.path + "-shm"))

        XCTAssertEqual(BackupImport.requiredFreeBytes(stagedAt: staged, databaseAt: live.path),
                       4_096 + 1_500 + 900 + 300,
                       "the snapshot copies main + WAL + SHM, so the precheck has to size all three")
    }

    /// A fresh install has no database to snapshot — Gate 5 says exactly that when it finds none — so
    /// "nothing there" is a measured zero. Answering "unknown" would disarm the gate for the install
    /// with the least margin to spare.
    func testRequiredFreeBytesTreatsAMissingDatabaseAsAMeasuredZero() throws {
        let staged = tmp.appendingPathComponent("staged-fresh.sqlite")
        try Data(repeating: 0x41, count: 2_048).write(to: staged)
        let neverWritten = tmp.appendingPathComponent("fresh-install-whoop.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverWritten))

        XCTAssertEqual(BackupImport.requiredFreeBytes(stagedAt: staged, databaseAt: neverWritten),
                       2_048, "nothing to snapshot is a measurement of zero, not a failure to measure")
    }

    /// The direction that matters most, and the reason the answer is an Optional at all. An unreadable
    /// staged size is OUR failure to measure, not evidence of a full disk — and it must not become a
    /// refusal, because `volumeCanAfford` reads a non-positive requirement as "cannot afford". A gate
    /// that turned a failed stat into "there isn't enough free space" would be inventing a shortfall it
    /// never measured, on the one refusal in the importer a user cannot act on.
    func testRequiredFreeBytesIsNilWhenTheStagedFileCannotBeMeasured() throws {
        let missing = tmp.appendingPathComponent("staged-that-isnt-there.sqlite")
        let live = tmp.appendingPathComponent("live-unmeasurable.sqlite")
        try Data(repeating: 0x42, count: 1_500).write(to: live)

        XCTAssertNil(BackupImport.requiredFreeBytes(stagedAt: missing, databaseAt: live.path),
                     "no measurement means no verdict — the gate skips rather than refuses")
        XCTAssertFalse(StoreMaintenance.volumeCanAfford(bytes: 0, near: tmp.path),
                       "and this is why it cannot be 0: a zero requirement reads as unaffordable")
    }

    /// The capacity read itself, pinned where it can actually be wrong: silently answering "unknown"
    /// forever. `volumeCanAfford` turns nil into false, so a read that stopped working would disarm BOTH
    /// the VACUUM guard and Gate 4c without a single failing assertion anywhere else.
    func testVolumeCapacityReadsARealNumber() throws {
        let free = try XCTUnwrap(StoreMaintenance.volumeAvailableBytes(near: tmp.path),
                                 "an unreadable capacity disarms the space guards silently")
        XCTAssertGreaterThan(free, 0)
        XCTAssertTrue(StoreMaintenance.volumeCanAfford(bytes: 1, near: tmp.path))
    }

    // MARK: - Gate 9: a landed restore re-arms the store-scoped one-shots

    // A restore swaps the DATABASE; the one-shot repair flags live in UserDefaults and describe an
    // INSTALL. Before Gate 9 those two went out of sync and every heal short-circuited on its first
    // line — measured on the user's real 422 MB backup, a restore onto an already-healed install left
    // all 17 fabricated 85.0 % SpO2 rows in place and the Health bridge re-published them as
    // 0.85 oxygenSaturation. These pin the seam from both directions: a LANDED restore re-arms, and
    // nothing that failed to land ever does.

    private let computedId = "my-whoop-computed"

    /// A day key `n` days before today. 200 is deliberately outside every rescore window, so only the
    /// one-shot sweep can reach the row — the case the heal exists for.
    private func dayKey(daysAgo n: Int) -> String {
        DayKey.local(Date().addingTimeInterval(-Double(n) * 86_400))
    }

    /// A pre-fix store: one clamp-pinned 85.0 % SpO2 day plus a stale `solMin`, both on the COMPUTED
    /// lane and both 200 days back, packed into a real `.wmbak` by the production writer.
    private func makePreFixWmbak() async throws -> URL {
        let srcPath = tmp.appendingPathComponent("prefix-src.sqlite").path
        let store = try await StrapStore(path: srcPath)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: dayKey(daysAgo: 200), totalSleepMin: 400,
                                  spo2Pct: 85.0, solMin: 3.5)],
            deviceId: computedId)
        try await store.checkpointWAL()

        let folder = tmp.appendingPathComponent("wmout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let written = await WmBackup.writeBackup(databaseAt: srcPath, checkpoint: { true },
                                                 into: folder, defaults: defaults)
        guard case .written(let bak) = written else {
            throw XCTSkip("fixture backup failed: \(written)")
        }
        return bak
    }

    /// Mark this install as "already healed" — every store-scoped one-shot consumed.
    private func markEverythingHealed() {
        for key in RestoreHealReset.storeScopedOneShots { defaults.set(true, forKey: key) }
    }

    /// THE regression test. Fails on pre-Gate-9 code at the first assertion.
    func testRestoreOntoAlreadyHealedInstallReArmsTheHeals() async throws {
        let bak = try await makePreFixWmbak()
        let destPath = tmp.appendingPathComponent("dest-rearm.sqlite").path
        markEverythingHealed()

        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath, settingsDefaults: defaults)
        guard case .needsRelaunch = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }

        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertFalse(defaults.bool(forKey: key),
                           "a landed restore must re-arm \(key) — the rows it guards just changed")
        }

        // What the next launch's `dataDidChange(.rawHistory)` then does, in its own order.
        let landed = try await StrapStore(path: destPath)
        let clearedSpo2 = await Spo2Heal.runIfNeeded(store: landed, deviceId: "my-whoop",
                                                     defaults: defaults)
        let clearedSol = await SleepHrvHeal.finish(store: landed, deviceId: "my-whoop",
                                                   defaults: defaults)
        XCTAssertEqual(clearedSpo2, 1, "the restored fabricated SpO2 row must be swept")
        XCTAssertEqual(clearedSol, 1, "the restored stale solMin must be swept")

        let rows = try await landed.dailyMetrics(deviceId: computedId,
                                                 from: dayKey(daysAgo: 400), to: dayKey(daysAgo: -1))
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.spo2Pct, "85.0 % was never a measurement — it must not survive a restore")
        XCTAssertNil(row.solMin)
        XCTAssertEqual(row.totalSleepMin, 400, "the rest of the restored row must be untouched")
    }

    /// The re-arm must not become a re-heal LOOP: each sweep consumes its one-shot again on the same
    /// launch, so a second pass is a no-op.
    func testReArmedHealsStillConsumeTheirOneShot() async throws {
        let bak = try await makePreFixWmbak()
        let destPath = tmp.appendingPathComponent("dest-idempotent.sqlite").path
        markEverythingHealed()
        _ = BackupImport.restore(from: bak, toDatabaseAt: destPath, settingsDefaults: defaults)

        let landed = try await StrapStore(path: destPath)
        _ = await Spo2Heal.runIfNeeded(store: landed, deviceId: "my-whoop", defaults: defaults)
        _ = await SleepHrvHeal.finish(store: landed, deviceId: "my-whoop", defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: Spo2Heal.doneKey), "a clean pass must consume the one-shot")
        XCTAssertTrue(defaults.bool(forKey: SleepHrvHeal.doneKey))

        let againSpo2 = await Spo2Heal.runIfNeeded(store: landed, deviceId: "my-whoop",
                                                   defaults: defaults)
        let againSol = await SleepHrvHeal.finish(store: landed, deviceId: "my-whoop",
                                                 defaults: defaults)
        XCTAssertEqual(againSpo2, 0)
        XCTAssertEqual(againSol, 0)
    }

    /// The re-arm makes `Spo2Heal` run once per RESTORE rather than once per lifetime, so its predicate
    /// has to be provably non-destructive. It is bounded by the estimator's reject floor: a value ABOVE
    /// `bandLo` is one the current estimator could legitimately have written, and a day 200 back has no
    /// raw left to re-derive it from — nulling it would be permanent data loss, not a repair.
    func testReArmedSweepSparesALegitimateComputedSpo2() async throws {
        let (store, dir) = try await Fixtures.tempStore("rearm-legit-spo2")
        defer { Fixtures.cleanUp(dir) }
        try await store.upsertDailyMetrics([
            Fixtures.dailyMetric(day: dayKey(daysAgo: 200), spo2Pct: 85.0),   // clamp artefact
            Fixtures.dailyMetric(day: dayKey(daysAgo: 201), spo2Pct: 96.5),   // a real estimate
        ], deviceId: computedId)

        let cleared = await Spo2Heal.runIfNeeded(store: store, deviceId: "my-whoop", defaults: defaults)

        XCTAssertEqual(cleared, 1, "only the at-or-below-reject-floor row is fabricated")
        let rows = try await store.dailyMetrics(deviceId: computedId,
                                                from: dayKey(daysAgo: 400), to: dayKey(daysAgo: -1))
        XCTAssertNil(rows.first(where: { $0.day == dayKey(daysAgo: 200) })?.spo2Pct)
        XCTAssertEqual(rows.first(where: { $0.day == dayKey(daysAgo: 201) })?.spo2Pct, 96.5,
                       "a value the fixed estimator could have written must survive every re-arm")
    }

    /// Scenario E: the bare-zip route (no manifest, no `wm-settings.json`) is NOT covered by anything
    /// else — it lands on the same seam behind the same flag, so Gate 9 has to reach it too.
    func testBareZipRestoreReArmsTheHealsToo() async throws {
        let srcPath = tmp.appendingPathComponent("prefix-computedbak-src.sqlite").path
        let store = try await StrapStore(path: srcPath)
        try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: dayKey(daysAgo: 200), spo2Pct: 85.0)], deviceId: computedId)
        try await store.checkpointWAL()
        let bak = try makeBackupZip(from: srcPath, settings: ["profile.age": 19])

        let destPath = tmp.appendingPathComponent("dest-computedbak-rearm.sqlite").path
        markEverythingHealed()
        let result = BackupImport.restore(from: bak, toDatabaseAt: destPath, settingsDefaults: defaults)
        guard case .needsRelaunch = result else {
            return XCTFail("expected .needsRelaunch, got \(result)")
        }
        XCTAssertFalse(defaults.bool(forKey: Spo2Heal.doneKey))

        let landed = try await StrapStore(path: destPath)
        let cleared = await Spo2Heal.runIfNeeded(store: landed, deviceId: "my-whoop",
                                                 defaults: defaults)
        XCTAssertEqual(cleared, 1)
    }

    /// A REFUSED restore never swapped the database, so the flags still describe it correctly and must
    /// be left alone — re-arming there would force a pointless multi-second rescore on the next launch.
    func testRefusedRestoreLeavesTheHealFlagsAlone() throws {
        let garbage = tmp.appendingPathComponent("garbage-rearm.wmbak")
        try Data((0..<512).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        markEverythingHealed()

        let result = BackupImport.restore(from: garbage,
                                        toDatabaseAt: tmp.appendingPathComponent("dest-x.sqlite").path,
                                        settingsDefaults: defaults)
        guard case .failure = result else { return XCTFail("expected .failure, got \(result)") }
        for key in RestoreHealReset.storeScopedOneShots {
            XCTAssertTrue(defaults.bool(forKey: key),
                          "\(key) must survive a restore that never landed")
        }
    }

    /// Same, one gate later: a ZIP with no `*.sqlite` entry is refused after extraction but still before
    /// any swap.
    func testZipWithoutDatabaseLeavesTheHealFlagsAlone() throws {
        let zip = tmp.appendingPathComponent("no-db-rearm.wmbak")
        let archive = try Archive(url: zip, accessMode: .create)
        let readme = tmp.appendingPathComponent("readme-rearm.json")
        try Data("{}".utf8).write(to: readme)
        try archive.addEntry(with: "readme.json", fileURL: readme, compressionMethod: .deflate)
        markEverythingHealed()

        let result = BackupImport.restore(from: zip,
                                        toDatabaseAt: tmp.appendingPathComponent("dest-y.sqlite").path,
                                        settingsDefaults: defaults)
        guard case .failure = result else { return XCTFail("expected .failure, got \(result)") }
        XCTAssertTrue(defaults.bool(forKey: Spo2Heal.doneKey))
    }

    /// The registry's MEMBERSHIP is the load-bearing part, so pin it. The HealthKit purge flags are
    /// excluded on purpose: both are unpredicated `deleteObjects` over ALL time while the re-export
    /// reaches only 14 days, so re-arming them would make every restore destroy the user's Health
    /// history from 15 days back. See the decision recorded at their declaration in `HealthExport`.
    func testRegistryHoldsTheStoreScopedFlagsAndNotTheHealthKitOnes() {
        XCTAssertEqual(Set(RestoreHealReset.storeScopedOneShots),
                       ["wm.heal.spo2ClampPinned.v1",
                        "wm.heal.sleepHrvSpliceAndDeep.v1",
                        "wm.maintenance.respSamplePurge.v2",
                        // Added with the SleepStagingV2-by-default flip: a restored store's hypnograms were
                        // staged by whatever build wrote it, so the widened re-score has to run again.
                        // Safe to re-arm — the pass only re-derives from raw samples still present.
                        "wm.heal.round4StagingAndSpread.v2",
                        // Added with 009's weed confounder: a restored store's nights were evaluated
                        // before weed joined `IllnessSignalEngine.Context`, so their banked
                        // `strain_level` never saw it. Re-arms on the same argument as round-4.
                        "wm.heal.weedConfounder.v1"])
        for hkKey in ["wm.health.spo2PurgeV1", "wm.health.hrvSplicePurgeV1"] {
            XCTAssertFalse(RestoreHealReset.storeScopedOneShots.contains(hkKey),
                           "\(hkKey) deletes Health samples we can never rewrite — it must stay out")
        }
    }
}
