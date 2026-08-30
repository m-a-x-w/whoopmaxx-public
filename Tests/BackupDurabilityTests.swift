import XCTest
import StrapStore
@testable import whoopmaxx

/// Two ways a `.wmbak` could be silently unreliable, both fixed in 011:
///  1. an interrupted write left a truncated archive under a CANONICAL name, which prune then treated as
///     a real backup — it always survived (newest) and evicted a good one, burning a keep-slot per crash;
///  2. `checkpointWAL()` reported success on a checkpoint SQLite had actually refused, so the archive
///     shipped without the frames still in the WAL.
final class BackupDurabilityTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("backup-durability")
    }

    override func tearDown() {
        if let tmp { Fixtures.cleanUp(tmp) }
    }

    // MARK: - Staging names

    /// The whole point of the staging name: a corpse under it can never be counted as a snapshot, so it
    /// cannot occupy a keep-slot nor be chosen for deletion.
    func testStagingNameIsNotASnapshot() {
        let staging = WmBackup.stagingPrefix + UUID().uuidString + WmBackup.stagingSuffix
        XCTAssertTrue(WmBackup.isStagingName(staging))
        XCTAssertFalse(WmBackup.isSnapshot(staging),
                       "a partially-written archive must never parse as a backup")
        XCTAssertNil(WmBackup.snapshotTimeMs(staging))
    }

    /// Prune must ignore staging residue entirely — it neither counts toward `keep` nor gets deleted by it.
    func testPruneIgnoresStagingResidue() {
        let snaps = (1...12).map { WmBackup.snapshotName(1_700_000_000_000 + $0 * 86_400_000) }
        let residue = (1...3).map { _ in WmBackup.stagingPrefix + UUID().uuidString + WmBackup.stagingSuffix }

        let toPrune = WmBackup.snapshotsToPrune(snaps + residue, keep: 10)

        XCTAssertEqual(toPrune.count, 2, "12 real snapshots, keep 10 — residue must not inflate the count")
        for name in toPrune {
            XCTAssertTrue(WmBackup.isSnapshot(name))
            XCTAssertFalse(WmBackup.isStagingName(name))
        }
    }

    /// The sweep is the price of the staging name (prune only touches canonical names, so residue would
    /// otherwise accumulate forever). It must be incapable of touching a real backup.
    func testSweepRemovesOnlyStaleStagingFilesAndNeverSnapshots() throws {
        let fm = FileManager.default
        let now = Date()
        let snapshot = tmp.appendingPathComponent(WmBackup.snapshotName(1_700_000_000_000))
        let freshStaging = tmp.appendingPathComponent(WmBackup.stagingPrefix + "fresh" + WmBackup.stagingSuffix)
        let staleStaging = tmp.appendingPathComponent(WmBackup.stagingPrefix + "stale" + WmBackup.stagingSuffix)
        let unrelated = tmp.appendingPathComponent("something-the-user-put-here.zip")
        for url in [snapshot, freshStaging, staleStaging, unrelated] {
            try Data("x".utf8).write(to: url)
        }
        // Age the stale one well past the 24 h threshold.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-48 * 3_600)],
                             ofItemAtPath: staleStaging.path)

        WmBackup.sweepStaleStaging(in: tmp, now: now)

        XCTAssertTrue(fm.fileExists(atPath: snapshot.path), "a real .wmbak must never be swept")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "unrelated files must never be swept")
        XCTAssertTrue(fm.fileExists(atPath: freshStaging.path), "an in-flight write must never be swept")
        XCTAssertFalse(fm.fileExists(atPath: staleStaging.path))
    }

    // MARK: - Atomic publish

    /// A successful write still lands under the canonical name, and leaves no `.part` behind.
    func testSuccessfulBackupPublishesCanonicallyAndLeavesNoResidue() async throws {
        let (store, storeDir) = try await Fixtures.tempStore()
        defer { Fixtures.cleanUp(storeDir) }
        let dbPath = storeDir.appendingPathComponent("store.sqlite").path
        try await store.checkpointWAL()

        let result = await WmBackup.writeBackup(databaseAt: dbPath,
                                                checkpoint: { (try? await store.checkpointWAL()) != nil },
                                                into: tmp)

        guard case .written(let url) = result else { return XCTFail("expected .written, got \(result)") }
        XCTAssertTrue(WmBackup.isSnapshot(url.lastPathComponent))
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(left.filter(WmBackup.isStagingName), [], "staging file must be renamed away, not left")
    }

    /// A refused checkpoint must abort BEFORE anything is created — no canonical name, no `.part`.
    func testRefusedCheckpointCreatesNothing() async throws {
        let (store, storeDir) = try await Fixtures.tempStore()
        defer { Fixtures.cleanUp(storeDir) }
        let dbPath = storeDir.appendingPathComponent("store.sqlite").path

        let result = await WmBackup.writeBackup(databaseAt: dbPath, checkpoint: { false }, into: tmp)

        guard case .failure = result else { return XCTFail("expected .failure, got \(result)") }
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(left, [], "a refused backup must leave the folder untouched")
    }

    // MARK: - Checkpoint completeness

    /// `checkpointWALComplete()` is the predicate the backup now gates on. On an uncontended store it must
    /// report complete — otherwise the fix trades a silently-short backup for a silently-absent one.
    func testCheckpointCompleteSucceedsOnAnUncontendedStore() async throws {
        let (store, storeDir) = try await Fixtures.tempStore()
        defer { Fixtures.cleanUp(storeDir) }

        let complete = try await store.checkpointWALComplete()

        XCTAssertTrue(complete, "an idle store's WAL is fully backfilled; refusing here would block all backups")
    }

    /// It must stay true across real writes — the retry in `AppRoot.checkpointForBackup` exists for
    /// transient reader contention, not for a predicate that is false by construction.
    func testCheckpointCompleteSucceedsAfterWrites() async throws {
        let (store, storeDir) = try await Fixtures.tempStore()
        defer { Fixtures.cleanUp(storeDir) }
        _ = try await store.upsertDailyMetrics([Fixtures.dailyMetric(day: "2026-08-01", restingHr: 52)],
                                               deviceId: "my-whoop")

        let complete = try await store.checkpointWALComplete()
        XCTAssertTrue(complete)
    }
}
