import XCTest
import StrapStore
@testable import whoopmaxx

/// Pure policy predicates ported from forks of the original app (wave 010).
///
/// Both rules under test are extracted as pure statics precisely so they can be pinned here without a
/// strap, a store, a clock or a Task — the fork each came from does the same, and those are the tests
/// that made the ports trustworthy enough to take.
final class ForkPortPolicyTests: XCTestCase {

    // MARK: - BuildPolicy (Brechard/noop)

    /// Only a build compiled WITH the authority flag may consume the strap's destructively-read
    /// history queue; a debug build needs a deliberate opt-in on top; a release build without the
    /// flag (i.e. a config that forgot to set it) is refused rather than assumed safe.
    func testHistoryAuthorityTruthTable() {
        // Release: authority, unconditionally — the debug opt-in is irrelevant (and compiled out).
        XCTAssertTrue(BuildPolicy.grantsAuthority(compiledWithAuthority: true, debugBuild: false,
                                                  debugOverride: false))
        XCTAssertTrue(BuildPolicy.grantsAuthority(compiledWithAuthority: true, debugBuild: true,
                                                  debugOverride: false))

        // Debug, no opt-in: READ-ONLY. This is the case that protects the sideloaded install's backlog.
        XCTAssertFalse(BuildPolicy.grantsAuthority(compiledWithAuthority: false, debugBuild: true,
                                                   debugOverride: false))

        // Debug WITH the deliberate opt-in: allowed, so on-device BLE work is still possible.
        XCTAssertTrue(BuildPolicy.grantsAuthority(compiledWithAuthority: false, debugBuild: true,
                                                  debugOverride: true))

        // Not debug and not compiled with authority: refused. The opt-in must not be a back door —
        // this is what makes the guarantee compile-time rather than a runtime setting.
        XCTAssertFalse(BuildPolicy.grantsAuthority(compiledWithAuthority: false, debugBuild: false,
                                                   debugOverride: true))
    }

    /// The test bundle compiles under Debug with no opt-in set, so the live property must be false.
    /// Pins that the `#if` wiring actually matches the truth table above rather than defaulting open.
    func testLiveAuthorityIsClosedInTheTestBundle() {
        XCTAssertFalse(BuildPolicy.hasHistoryAuthority,
                       "the Debug test bundle must never hold history authority")
    }

    // MARK: - Standard-HR flush policy (Brechard/noop)

    /// Row count alone still trips the flush, exactly as before the time bound was added.
    func testStandardFlushTripsOnRowCount() {
        XCTAssertTrue(Collector.shouldFlushStandard(rows: 30, waited: 0, maxRows: 30, maxInterval: 30))
        XCTAssertTrue(Collector.shouldFlushStandard(rows: 31, waited: nil, maxRows: 30, maxInterval: 30))
        XCTAssertFalse(Collector.shouldFlushStandard(rows: 29, waited: 0, maxRows: 30, maxInterval: 30))
    }

    /// THE fix: a partial batch that has waited out the interval flushes anyway. Before this, a sparse
    /// or backgrounded 0x2A37 stream held those readings in RAM until the app was killed.
    func testStandardFlushTripsOnElapsedTimeWithPartialBatch() {
        XCTAssertTrue(Collector.shouldFlushStandard(rows: 1, waited: 30, maxRows: 30, maxInterval: 30),
                      "one reading that has waited the full interval must still be persisted")
        XCTAssertTrue(Collector.shouldFlushStandard(rows: 29, waited: 45, maxRows: 30, maxInterval: 30))
        XCTAssertFalse(Collector.shouldFlushStandard(rows: 29, waited: 29.9, maxRows: 30, maxInterval: 30),
                       "the deadline is >=, not >; 29.9s has not waited out a 30s interval")
    }

    /// An empty buffer never flushes, however long it has "waited" — otherwise the deadline task would
    /// spin up a pointless store write every interval on a strap that is simply not streaming.
    func testStandardFlushNeverTripsOnEmptyBuffer() {
        XCTAssertFalse(Collector.shouldFlushStandard(rows: 0, waited: 600, maxRows: 30, maxInterval: 30))
        XCTAssertFalse(Collector.shouldFlushStandard(rows: 0, waited: nil, maxRows: 30, maxInterval: 30))
    }

    /// No stamp yet (buffers were empty at the last check) means the time bound simply doesn't apply —
    /// it must not be read as "waited forever" and force a flush of a batch that just started.
    func testStandardFlushIgnoresMissingStampBelowRowCount() {
        XCTAssertFalse(Collector.shouldFlushStandard(rows: 5, waited: nil, maxRows: 30, maxInterval: 30))
    }

    // MARK: - Backup drain barrier (Brechard/noop)

    /// A drain that reports rows still stuck in RAM must ABORT the snapshot — shipping a backup that
    /// silently omits them is the failure mode being fixed, and it only surfaces on restore.
    func testWriteBackupFailsWhenDrainReportsStuckRows() async throws {
        let tmp = try Fixtures.tempDir("fork-port-drain")
        defer { Fixtures.cleanUp(tmp) }
        let dbPath = tmp.appendingPathComponent("store-drain.sqlite").path
        let store = try await StrapStore(path: dbPath)
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-08-05", totalSleepMin: 400, recovery: 50)],
            deviceId: "my-whoop")
        let outFolder = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        let result = await WmBackup.writeBackup(
            databaseAt: dbPath,
            checkpoint: { XCTFail("checkpoint must not run once the drain has failed"); return true },
            drain: { false },
            into: outFolder)
        guard case .failure = result else {
            return XCTFail("expected .failure on a refused drain, got \(result)")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: outFolder.path)
        XCTAssertTrue(written.isEmpty, "no archive may be left behind when the drain refused")
    }

    /// …and a successful drain leaves the existing write path untouched.
    func testWriteBackupSucceedsWhenDrainReportsClean() async throws {
        let tmp = try Fixtures.tempDir("fork-port-drain-ok")
        defer { Fixtures.cleanUp(tmp) }
        let dbPath = tmp.appendingPathComponent("store-drain-ok.sqlite").path
        let store = try await StrapStore(path: dbPath)
        _ = try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(day: "2026-08-05", totalSleepMin: 400, recovery: 50)],
            deviceId: "my-whoop")
        let outFolder = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

        var drained = false
        let result = await WmBackup.writeBackup(
            databaseAt: dbPath,
            checkpoint: { (try? await store.checkpointWAL()) != nil },
            drain: { drained = true; return true },
            into: outFolder)
        guard case .written = result else {
            return XCTFail("expected .written, got \(result)")
        }
        XCTAssertTrue(drained, "the drain must run on every snapshot, not only on the manual path")
    }
}
