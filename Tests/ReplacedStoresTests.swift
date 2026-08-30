import XCTest
import StrapStore
import ZIPFoundation
@testable import whoopmaxx

/// The databases previous imports replaced — the list that makes Gate 5's snapshots visible, and the
/// only destructive control 013 adds.
///
/// Three things have to hold, and all three have already failed somewhere in this app's history:
///  1. The reader must find what the WRITER writes. `BackupImport`'s Gate 5 names its snapshot
///     `whoopmaxx-replaced-<ts>.sqlite` and nothing read it back until now, so nothing would have
///     noticed a drift. `testTheReaderFindsWhatGate5ActuallyWrote` runs a REAL restore and reads its
///     sidecar back through this type.
///  2. The size must count the `-wal`/`-shm` siblings Gate 5 copied, and the delete must remove them.
///     A size that ignores them under-reports the very thing this list exists to expose; a delete that
///     ignores them leaves orphans no surface can ever show again.
///  3. It must never touch anything that is not a snapshot — the LIVE database sits in the same
///     directory — and it must never claim a number, a date or a role it did not measure.
final class ReplacedStoresTests: XCTestCase {

    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("replacedstores-tests")
        suiteName = "replaced-stores-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        Fixtures.cleanUp(tmp)
    }

    // MARK: - Builders

    /// A file of `bytes` zero bytes at `name` inside a directory. These are never opened — everything
    /// this type does is name-and-attribute work — so the contents are irrelevant and the SIZES are the
    /// measurement under test.
    @discardableResult
    private func write(_ name: String, bytes: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// A directory shaped like a real Application Support after two imports: two snapshots (the newer
    /// one still carrying a `-wal` sibling), the LIVE database beside them, and one file that wears the
    /// snapshot prefix without being one.
    private func makeDirectory() throws -> URL {
        let dir = tmp.appendingPathComponent("appsupport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("whoopmaxx-replaced-2026-08-05-093000.sqlite", bytes: 4_096, in: dir)
        try write("whoopmaxx-replaced-2026-08-05-093000.sqlite-wal", bytes: 1_024, in: dir)
        try write("whoopmaxx-replaced-2026-07-30-171500.sqlite", bytes: 2_048, in: dir)
        try write("whoop.sqlite", bytes: 8_192, in: dir)                     // the live database
        try write("whoopmaxx-replaced-2026-08-04-101500", bytes: 512, in: dir)  // no .sqlite: not a store
        return dir
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - The list

    /// The whole enumeration contract in one directory: only the snapshots, newest first, each sized
    /// with the siblings Gate 5 copied beside it, and nothing else in the directory so much as read.
    ///
    /// The live `whoop.sqlite` assertion is the one that matters most: it sits in this directory, it is
    /// the user's actual history, and the only control this list offers is a delete.
    func testTheListIsTheSnapshotsAndNothingElseNewestFirst() throws {
        let dir = try makeDirectory()

        let entries = ReplacedStores.entries(in: dir)

        XCTAssertEqual(entries.map(\.name), ["whoopmaxx-replaced-2026-08-05-093000.sqlite",
                                             "whoopmaxx-replaced-2026-07-30-171500.sqlite"],
                       "only the .sqlite snapshots, newest first")
        XCTAssertEqual(entries.first?.sizeBytes, 5_120, "the -wal sibling counts into its parent's size")
        XCTAssertEqual(entries.last?.sizeBytes, 2_048)
        XCTAssertEqual(ReplacedStores.totalBytes(entries), 7_168)
        // Enumeration is a read. Everything that was there is still there.
        XCTAssertTrue(exists("whoop.sqlite", in: dir), "the live database is untouched")
        XCTAssertTrue(exists("whoopmaxx-replaced-2026-08-04-101500", in: dir))
        XCTAssertTrue(exists("whoopmaxx-replaced-2026-08-05-093000.sqlite-wal", in: dir))
    }

    /// A name that carries no readable timestamp is still a whole database, so it is LISTED — with its
    /// raw name and no date — rather than hidden. Hiding it would recreate exactly the defect this type
    /// exists to end: bytes on disk that no surface admits are there.
    ///
    /// It sorts last, because an entry that cannot be placed in time must never take the top slot: that
    /// slot is the one the UI names as the rollback.
    func testAnUnparseableNameIsListedRawRatherThanHidden() throws {
        let dir = tmp.appendingPathComponent("odd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("whoopmaxx-replaced-2026-07-30-171500.sqlite", bytes: 2_048, in: dir)
        try write("whoopmaxx-replaced-restore-of-old-phone.sqlite", bytes: 1_024, in: dir)

        let entries = ReplacedStores.entries(in: dir)

        XCTAssertEqual(entries.count, 2)
        XCTAssertNotNil(entries.first?.created, "the dated snapshot keeps the top slot")
        XCTAssertNil(entries.last?.created)
        XCTAssertEqual(entries.last?.name, "whoopmaxx-replaced-restore-of-old-phone.sqlite",
                       "an undatable snapshot is named by its file name, not dropped")
        XCTAssertEqual(entries.last?.sizeBytes, 1_024, "and it is still sized")
    }

    /// The rollback claim is withheld from a set that cannot be ordered. With an entry whose date will
    /// not read, the top of the list is no longer provably the newest — and "rollback for the most
    /// recent import", printed on an older copy inside a DELETE confirmation, is the worst possible
    /// place for a claim the app did not measure.
    func testAnUndatableNameWithholdsTheRollbackClaim() throws {
        let dir = try makeDirectory()
        let ordered = ReplacedStores.entries(in: dir)
        XCTAssertEqual(ReplacedStores.rollback(of: ordered)?.name,
                       "whoopmaxx-replaced-2026-08-05-093000.sqlite",
                       "a fully dated list names its newest as the rollback")

        try write("whoopmaxx-replaced-restore-of-old-phone.sqlite", bytes: 1_024, in: dir)

        XCTAssertNil(ReplacedStores.rollback(of: ReplacedStores.entries(in: dir)),
                     "one unplaceable entry and no row may be called the newest")
    }

    /// The timestamp is read strictly. `DateFormatter.date(from:)` parses a matching PREFIX and ignores
    /// the rest, so without the round-trip check a hand-copied `…-093000-copy.sqlite` would present
    /// itself as a genuine 09:30 snapshot and sort as one.
    func testTheTimestampIsParsedStrictly() throws {
        let real = try XCTUnwrap(ReplacedStores.created(
            fromName: "whoopmaxx-replaced-2026-08-05-093000.sqlite"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: real)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 8, 5, 9, 30, 0])

        XCTAssertNil(ReplacedStores.created(fromName: "whoopmaxx-replaced-2026-08-05-093000-copy.sqlite"),
                     "a stamp with anything after it is not a stamp this app wrote")
        XCTAssertNil(ReplacedStores.created(fromName: "whoopmaxx-replaced-.sqlite"))
        XCTAssertNil(ReplacedStores.created(fromName: "whoop.sqlite"))
    }

    /// A total assembled from the entries that happened to stat would under-report — and it would be a
    /// number the app did not measure, printed on the row that justifies deleting something.
    func testTotalBytesRefusesToSumAroundASizeItCouldNotRead() {
        let known = ReplacedStores.Entry(url: URL(fileURLWithPath: "/x/whoopmaxx-replaced-a.sqlite"),
                                         created: nil, sizeBytes: 100)
        let unknown = ReplacedStores.Entry(url: URL(fileURLWithPath: "/x/whoopmaxx-replaced-b.sqlite"),
                                           created: nil, sizeBytes: nil)

        XCTAssertEqual(ReplacedStores.totalBytes([known, known]), 200)
        XCTAssertNil(ReplacedStores.totalBytes([known, unknown]))
        XCTAssertEqual(ReplacedStores.totalBytes([]), 0, "an empty list costs a measured nothing")
    }

    // MARK: - The delete

    /// Delete takes the whole set Gate 5 wrote — main file plus `-wal`/`-shm` — and touches nothing
    /// else. A delete that dropped only the main file would leave siblings that no list can ever show
    /// again, which is the invisible-stranded-copy defect wearing a different hat.
    func testDeletingOneTakesItsSiblingsAndLeavesEverythingElseAlone() throws {
        let dir = try makeDirectory()
        try write("whoopmaxx-replaced-2026-08-05-093000.sqlite-shm", bytes: 32, in: dir)
        let entries = ReplacedStores.entries(in: dir)
        let newest = try XCTUnwrap(entries.first)

        XCTAssertTrue(ReplacedStores.delete(newest))

        XCTAssertFalse(exists("whoopmaxx-replaced-2026-08-05-093000.sqlite", in: dir))
        XCTAssertFalse(exists("whoopmaxx-replaced-2026-08-05-093000.sqlite-wal", in: dir),
                       "the -wal Gate 5 copied goes with it")
        XCTAssertFalse(exists("whoopmaxx-replaced-2026-08-05-093000.sqlite-shm", in: dir))
        XCTAssertTrue(exists("whoopmaxx-replaced-2026-07-30-171500.sqlite", in: dir),
                      "the other snapshot is the user's other copy and is not ours to remove")
        XCTAssertTrue(exists("whoop.sqlite", in: dir), "the live database is untouched")
        XCTAssertEqual(ReplacedStores.entries(in: dir).map(\.name),
                       ["whoopmaxx-replaced-2026-07-30-171500.sqlite"])
    }

    /// THE guard (013 decision 6 — this wave adds no new way to lose data). The live database sits in
    /// the same directory as the snapshots, so `delete` re-checks the NAME rather than trusting the URL
    /// it was handed. Nothing a caller can construct talks it into another path.
    func testDeleteRefusesAnythingThatIsNotASnapshot() throws {
        let dir = try makeDirectory()
        let live = ReplacedStores.Entry(url: dir.appendingPathComponent("whoop.sqlite"),
                                        created: nil, sizeBytes: 8_192)
        let notEvenAFile = ReplacedStores.Entry(
            url: dir.appendingPathComponent("whoopmaxx-replaced-2026-01-01-000000.sqlite"),
            created: nil, sizeBytes: nil)

        XCTAssertFalse(ReplacedStores.delete(live))
        XCTAssertFalse(ReplacedStores.delete(notEvenAFile), "nothing there to remove")

        XCTAssertTrue(exists("whoop.sqlite", in: dir), "the live database survives being handed in")
        XCTAssertEqual(ReplacedStores.entries(in: dir).count, 2, "and the real snapshots are still there")
    }

    // MARK: - The writer/reader contract

    /// The one that would catch a drift: run a REAL restore over a throwaway database and read its
    /// snapshot back through this type.
    ///
    /// `BackupImport`'s Gate 5 names the file (`whoopmaxx-replaced-\(timestamp()).sqlite`) and this type
    /// re-derives the same name and format independently — `timestamp()` is private, so there is no
    /// shared constant to bind them. If either side moves, every snapshot on disk stays there and the
    /// list silently reads EMPTY, which is precisely the invisible state 013 P3 exists to end. This
    /// asserts the two agree on a file the importer actually wrote.
    func testTheReaderFindsWhatGate5ActuallyWrote() async throws {
        let fixturePath = tmp.appendingPathComponent("fixture-src.sqlite").path
        do {
            let store = try await StrapStore(path: fixturePath)
            try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
            _ = try await store.upsertDailyMetrics(
                [Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 420, recovery: 72)],
                deviceId: "my-whoop")
            try await store.checkpointWAL()
        }
        let bak = tmp.appendingPathComponent("fixture.wmbak")
        let archive = try Archive(url: bak, accessMode: .create)
        try archive.addEntry(with: "backup.sqlite", fileURL: URL(fileURLWithPath: fixturePath),
                             compressionMethod: .deflate)

        // A destination that HAS data, so Gate 5 has something to preserve.
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

        let entries = ReplacedStores.entries(in: destDir)

        XCTAssertEqual(entries.map(\.url.lastPathComponent), [sidecar.lastPathComponent],
                       "the snapshot Gate 5 just wrote is exactly what this reader lists")
        let created = try XCTUnwrap(entries.first?.created,
                                    "Gate 5's timestamp format must still parse here")
        XCTAssertLessThan(abs(created.timeIntervalSinceNow), 300,
                          "the parsed stamp is the moment the restore ran")
        XCTAssertGreaterThan(entries.first?.sizeBytes ?? 0, 0, "and it is sized off the real file")
    }
}
