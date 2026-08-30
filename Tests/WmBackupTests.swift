import XCTest
import StrapStore
import ZIPFoundation
@testable import whoopmaxx

/// The `.wmbak` autobackup container: round-trip a throwaway store through
/// `WmBackup.writeBackup` and verify every entry, plus the pure filename/prune logic.
final class WmBackupTests: XCTestCase {

    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("wmbackup-tests")
        suiteName = "wm-backup-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        Fixtures.cleanUp(tmp)
    }

    // MARK: - Round trip

    func testWriteBackupRoundTrip() async throws {
        // Seed a throwaway store with a couple of rows.
        let dbPath = tmp.appendingPathComponent("store-src.sqlite").path
        let store = try await StrapStore(path: dbPath)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        _ = try await store.upsertDailyMetrics([
            Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 400, recovery: 61),
            Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 420, recovery: 72),
        ], deviceId: "my-whoop")

        defaults.set("imperial", forKey: "units.system")

        let outFolder = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        let result = await WmBackup.writeBackup(
            databaseAt: dbPath,
            checkpoint: { (try? await store.checkpointWAL()) != nil },
            into: outFolder,
            defaults: defaults)
        guard case .written(let url) = result else {
            return XCTFail("expected .written, got \(result)")
        }
        XCTAssertNotNil(WmBackup.snapshotTimeMs(url.lastPathComponent),
                        "backup must use the canonical UTC snapshot name, got \(url.lastPathComponent)")

        // Unzip: DB entry first (importer convention), manifest + settings present.
        let unzipped = tmp.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
        let archive = try Archive(url: url, accessMode: .read)
        var entryNames: [String] = []
        for entry in archive where entry.type == .file {
            entryNames.append(entry.path)
            _ = try archive.extract(entry, to: unzipped.appendingPathComponent(
                (entry.path as NSString).lastPathComponent))
        }
        XCTAssertEqual(entryNames.first, WmBackup.dbEntryName,
                       "the SQLite entry must be FIRST so bare-zip importers find it")
        XCTAssertTrue(entryNames.contains(WmBackup.manifestEntryName))
        XCTAssertTrue(entryNames.contains(BackupSettings.entryName))

        // Manifest is sane.
        let manifestData = try Data(contentsOf: unzipped.appendingPathComponent(WmBackup.manifestEntryName))
        let manifest = try JSONDecoder().decode(WmBackup.Manifest.self, from: manifestData)
        XCTAssertEqual(manifest.formatVersion, WmBackup.formatVersion)
        XCTAssertEqual(manifest.schemaVersion, StrapStoreInfo.schemaVersion)
        XCTAssertFalse(manifest.appVersion.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: manifest.createdAtUTC),
                        "createdAtUTC must be ISO-8601, got \(manifest.createdAtUTC)")

        // Settings entry carries the whitelisted value.
        let settingsData = try Data(contentsOf: unzipped.appendingPathComponent(BackupSettings.entryName))
        XCTAssertEqual(BackupSettings.decode(settingsData)["units.system"] as? String, "imperial")

        // The SQLite entry opens through the vendored store and carries the rows. (Open the store
        // FIRST: the raw extracted file has a WAL-mode header with no -wal/-shm siblings, which a
        // READ-ONLY connection can't open — the importer normalizes that on its own staged copy;
        // here the read-write pool recreates the sidecars, after which quick_check runs read-only.)
        let sqliteURL = unzipped.appendingPathComponent(WmBackup.dbEntryName)
        let reopened = try await StrapStore(path: sqliteURL.path)
        let rows = try await reopened.dailyMetrics(deviceId: "my-whoop",
                                                   from: "2026-07-01", to: "2026-07-31")
        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: sqliteURL.path))
        XCTAssertEqual(rows.map(\.day), ["2026-07-13", "2026-07-14"])
        XCTAssertEqual(rows.last?.recovery, 72)
    }

    /// whoopmaxx's OWN keys ride in `wm-settings.json` (the frozen vendored whitelist structurally
    /// can't carry them) and survive a full export → import round trip into a DIFFERENT defaults
    /// domain — the phone-wipe restore that used to silently lose the smart-alarm window.
    func testWmSettingsSurviveExportImportRoundTrip() async throws {
        let dbPath = tmp.appendingPathComponent("store-wmsettings.sqlite").path
        let store = try await StrapStore(path: dbPath)
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 50)],
            deviceId: "my-whoop")

        defaults.set(true, forKey: SmartAlarmSettings.Key.enabled)
        defaults.set(395, forKey: SmartAlarmSettings.Key.earliestMin)

        let outFolder = tmp.appendingPathComponent("out-wmsettings", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let result = await WmBackup.writeBackup(
            databaseAt: dbPath,
            checkpoint: { (try? await store.checkpointWAL()) != nil },
            into: outFolder,
            defaults: defaults)
        guard case .written(let url) = result else {
            return XCTFail("expected .written, got \(result)")
        }
        let names = try Archive(url: url, accessMode: .read).filter { $0.type == .file }.map(\.path)
        XCTAssertTrue(names.contains(WmBackup.wmSettingsEntryName))

        // Restore into a FRESH defaults domain, so a surviving value can only have come from the ZIP.
        let targetSuite = "wm-backup-tests-target-\(UUID().uuidString)"
        let target = UserDefaults(suiteName: targetSuite)!
        defer { target.removePersistentDomain(forName: targetSuite) }
        let restored = BackupImport.restore(
            from: url,
            toDatabaseAt: tmp.appendingPathComponent("store-restored.sqlite").path,
            settingsDefaults: target)
        guard case .needsRelaunch = restored else {
            return XCTFail("expected .needsRelaunch, got \(restored)")
        }
        XCTAssertEqual(target.object(forKey: SmartAlarmSettings.Key.earliestMin) as? Int, 395,
                       "wm.alarm.earliestMin must survive the export → import round trip")
        XCTAssertEqual(target.object(forKey: SmartAlarmSettings.Key.enabled) as? Bool, true)
    }

    /// Nothing whitelisted set → the settings entry is omitted (DB + manifest only), like the original
    /// legacy degrade.
    func testWriteBackupOmitsSettingsEntryWhenNothingSet() async throws {
        let dbPath = tmp.appendingPathComponent("store-nosettings.sqlite").path
        let store = try await StrapStore(path: dbPath)
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 50)],
            deviceId: "my-whoop")
        let outFolder = tmp.appendingPathComponent("out2", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        let result = await WmBackup.writeBackup(
            databaseAt: dbPath,
            checkpoint: { (try? await store.checkpointWAL()) != nil },
            into: outFolder,
            defaults: defaults)
        guard case .written(let url) = result else {
            return XCTFail("expected .written, got \(result)")
        }
        let archive = try Archive(url: url, accessMode: .read)
        let names = archive.filter { $0.type == .file }.map(\.path)
        XCTAssertEqual(Set(names), [WmBackup.dbEntryName, WmBackup.manifestEntryName])
    }

    /// A failed checkpoint must refuse to write (a single-file ZIP has no WAL sidecar fallback).
    func testWriteBackupFailsWhenCheckpointFails() async throws {
        let dbPath = tmp.appendingPathComponent("store-ckpt.sqlite").path
        let store = try await StrapStore(path: dbPath)
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 400, recovery: 50)],
            deviceId: "my-whoop")
        let outFolder = tmp.appendingPathComponent("out3", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        let result = await WmBackup.writeBackup(databaseAt: dbPath, checkpoint: { false },
                                                into: outFolder, defaults: defaults)
        guard case .failure = result else {
            return XCTFail("expected .failure on refused checkpoint, got \(result)")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: outFolder.path)
        XCTAssertTrue(written.isEmpty, "no partial archive may be left behind")
    }

    // MARK: - Pure filename / prune logic

    func testSnapshotNameRoundTrip() {
        let ms = 1_776_543_210_000   // arbitrary instant
        let name = WmBackup.snapshotName(ms)
        XCTAssertTrue(name.hasPrefix("whoopmaxx-backup-"))
        XCTAssertTrue(name.hasSuffix(".wmbak"))
        // Second resolution: the round-tripped instant equals ms truncated to whole seconds.
        XCTAssertEqual(WmBackup.snapshotTimeMs(name), (ms / 1000) * 1000)
        XCTAssertTrue(WmBackup.isSnapshot(name))
        XCTAssertFalse(WmBackup.isSnapshot("whoopmaxx-backup-notadate.wmbak"))
        XCTAssertFalse(WmBackup.isSnapshot("other-backup-20260714-101010.wmbak"))
    }

    func testPruneKeepsNewestTen() {
        let names = (0..<13).map { WmBackup.snapshotName(1_700_000_000_000 + $0 * 60_000) }
            + ["keep-me.wmbak", "unrelated.txt"]
        let doomed = WmBackup.snapshotsToPrune(names.shuffled(), keep: WmFolderBackup.keepCount)
        // 13 canonical snapshots − keep 10 = the 3 OLDEST go; hand-named files are never pruned.
        XCTAssertEqual(Set(doomed), Set(names.prefix(3)))
        XCTAssertFalse(doomed.contains("keep-me.wmbak"))
    }
}
