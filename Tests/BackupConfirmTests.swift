import XCTest
import StrapStore
import ZIPFoundation
@testable import whoopmaxx

/// The confirm that now stands between picking a backup and losing everything on the device.
///
/// Two seams, both of which have to hold for the confirm to be worth having:
///  1. `RestoreConfirmCopy` — the comparison itself. The consequence line is pinned in BOTH
///     directions, because a line that always shows is as wrong as one that never does: the first
///     trains the user to tap through it, the second is the silent loss the wave exists to close.
///     Every number here is measured; a field that could not be read says so and is never a 0.
///  2. `BackupImportRunner`'s review states — that picking a file no longer restores it, that a
///     refusal has no staged database behind it (so it structurally cannot offer a Replace), and
///     that a cancel deletes the staging instead of stranding a whole extracted store in temp.
///
/// `replace()` is deliberately NEVER called here. It resolves `StorePaths.defaultDatabasePath()`, so
/// exercising it would run a real restore over the test host's own store; the destructive half is
/// covered against a throwaway destination by `BackupImportTests` instead.
final class BackupConfirmTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = try Fixtures.tempDir("backupconfirm-tests")
    }

    override func tearDownWithError() throws {
        Fixtures.cleanUp(tmp)
    }

    // MARK: - Builders

    /// A file summary shaped like a real `.wmbak`'s: 199 days ending 2026-07-21, with a manifest.
    private func fileSummary(dayCount: Int? = 199,
                             earliestDay: String? = "2026-01-04",
                             latestDay: String? = "2026-07-21",
                             sizeBytes: Int? = 536_870_912,
                             createdAtUTC: String? = "2026-07-21T09:30:00Z",
                             formatVersion: Int? = 2,
                             schemaVersion: Int? = 26,
                             appVersion: String? = "1.3.0 (18)") -> BackupImport.Inspection.Summary {
        BackupImport.Inspection.Summary(sizeBytes: sizeBytes, dayCount: dayCount,
                                        earliestDay: earliestDay, latestDay: latestDay,
                                        sleepSessionCount: 191, formatVersion: formatVersion,
                                        schemaVersion: schemaVersion, appVersion: appVersion,
                                        createdAtUTC: createdAtUTC)
    }

    /// Day keys from `from` to `to` inclusive, in the `yyyy-MM-dd` shape `Repository.days` publishes.
    private func dayKeys(from: String, to: String) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let start = f.date(from: from), let end = f.date(from: to), start <= end else { return [] }
        var keys: [String] = []
        var cursor = start
        while cursor <= end {
            keys.append(f.string(from: cursor))
            cursor = cursor.addingTimeInterval(86_400)
        }
        return keys
    }

    // MARK: - The consequence line, both directions

    /// The ordinary case the confirm exists for: a months-old snapshot restored over a live store.
    /// The device holds 17 days the backup's range does not reach, and the copy names exactly that
    /// number — counted off the two ranges, never asserted blindly.
    func testLossLineNamesTheDaysThisBackupPredates() {
        let copy = RestoreConfirmCopy(file: fileSummary(),
                                      deviceDays: dayKeys(from: "2026-01-04", to: "2026-08-07"))

        XCTAssertEqual(copy.daysLost, 17)
        XCTAssertEqual(copy.lossLine, "The 17 days since this backup will be lost.")
    }

    /// The other direction, and it matters just as much: a backup that covers the whole span the
    /// device holds costs nothing, and must say nothing. A warning shown on every import is a warning
    /// the user learns to tap through — which is worse than no warning at all, because it spends the
    /// attention the real case needs.
    func testLossLineIsAbsentWhenTheBackupCoversEverythingOnTheDevice() {
        let copy = RestoreConfirmCopy(file: fileSummary(),
                                      deviceDays: dayKeys(from: "2026-02-01", to: "2026-07-21"))

        XCTAssertEqual(copy.daysLost, 0)
        XCTAssertNil(copy.lossLine)
    }

    /// Days BEFORE the backup's first are lost exactly as surely as days after its last — a backup
    /// from another device, or one taken after a long gap, has both ends. Counting only the newer end
    /// would under-report the loss, which is the dangerous direction to be wrong in.
    func testDaysBeforeTheBackupsRangeCountAsLostToo() {
        let copy = RestoreConfirmCopy(
            file: fileSummary(),
            deviceDays: dayKeys(from: "2026-01-01", to: "2026-01-03")      // 3 before the file's first
                + dayKeys(from: "2026-01-04", to: "2026-07-21")            // fully covered
                + dayKeys(from: "2026-07-22", to: "2026-07-23"))           // 2 after the file's last

        XCTAssertEqual(copy.daysLost, 5)
        XCTAssertEqual(copy.lossLine,
                       "At least 5 days on this device are outside this backup's range and will be lost.")
    }

    /// The device figures come from `Repository.refresh(days: 120)`'s trailing window, which truncates
    /// at its OLD end. Restoring a backup older than that window means days newer than it that the
    /// cache cannot see — so the count is a FLOOR, and it has to say so. A floor printed as a total
    /// under-reports the loss, which is the dangerous direction for this particular sentence.
    func testALossTheCachedWindowCannotBoundIsStatedAsAFloor() {
        let copy = RestoreConfirmCopy(
            file: fileSummary(dayCount: 7, earliestDay: "2026-01-04", latestDay: "2026-01-10"),
            deviceDays: dayKeys(from: "2026-04-09", to: "2026-08-07"))       // the cached window

        XCTAssertEqual(copy.daysLost, 121, "every cached day is newer than this backup")
        XCTAssertEqual(copy.lossLine,
                       "At least 121 days on this device are newer than this backup and will be lost.")
    }

    /// Zero `dailyMetric` rows is a legitimate reading of a real file, not a read failure — and it is
    /// the worst case there is: everything goes, and nothing replaces it. Stated WITHOUT a count,
    /// because "everything" is exact whatever the cached window can see and any number here would be
    /// that window's floor wearing a total's clothes.
    func testAnEmptyBackupSaysEverythingGoesAndDoesNotCountIt() {
        let copy = RestoreConfirmCopy(
            file: fileSummary(dayCount: 0, earliestDay: nil, latestDay: nil),
            deviceDays: dayKeys(from: "2026-08-05", to: "2026-08-07"))

        XCTAssertEqual(
            copy.lossLine,
            "This backup holds no days. Everything on this device will be lost, and nothing replaces it.")
    }

    /// Grammar at n = 1, in both shapes. Small, but this line is the one sentence standing between a
    /// user and their whole history; it does not get to read like a placeholder.
    func testTheConsequenceLineStaysGrammaticalAtOneDay() {
        let after = RestoreConfirmCopy(file: fileSummary(),
                                       deviceDays: dayKeys(from: "2026-01-04", to: "2026-07-22"))
        XCTAssertEqual(after.daysLost, 1)
        XCTAssertEqual(after.lossLine, "The 1 day since this backup will be lost.")

        let before = RestoreConfirmCopy(file: fileSummary(),
                                        deviceDays: dayKeys(from: "2026-01-03", to: "2026-07-21"))
        XCTAssertEqual(before.daysLost, 1)
        XCTAssertEqual(before.lossLine,
                       "At least 1 day on this device is outside this backup's range and will be lost.")
    }

    // MARK: - Never a number the app did not measure

    /// The device cache before its first publish is "not read yet", which is a different answer from
    /// "no days". Printing it as 0 would tell the user they have nothing to lose at the exact moment
    /// they are deciding whether to lose it.
    func testAnUnreadDeviceCacheNeverPrintsANumber() {
        let copy = RestoreConfirmCopy(file: fileSummary(), deviceDays: nil)

        XCTAssertEqual(copy.deviceLine, "not read yet")
        XCTAssertNil(copy.lossLine)
        XCTAssertEqual(copy.daysLost, 0)
    }

    /// An empty store, by contrast, IS a measurement — the repository published, and there is nothing
    /// there. It reads as a real zero, and nothing is at risk.
    func testAnEmptyDeviceReadsAsAMeasuredZero() {
        let copy = RestoreConfirmCopy(file: fileSummary(), deviceDays: [])

        XCTAssertEqual(copy.deviceLine, "0 days")
        XCTAssertNil(copy.lossLine)
    }

    /// A bare `.zip` carries no manifest, so its save date and (on an attribute-read failure) its size
    /// are unknown. Both say so; neither becomes a zero or an invented epoch date.
    func testAManifestlessBackupSaysNotRecordedRatherThanZero() {
        let copy = RestoreConfirmCopy(
            file: fileSummary(dayCount: 2, earliestDay: "2026-07-13", latestDay: "2026-07-14",
                              sizeBytes: nil, createdAtUTC: nil,
                              formatVersion: nil, schemaVersion: nil, appVersion: nil),
            deviceDays: dayKeys(from: "2026-07-13", to: "2026-07-14"))

        XCTAssertEqual(copy.fileLine,
                       "2 days · 2026-07-13 to 2026-07-14 · save date not recorded · size not recorded")
        XCTAssertNil(copy.lossLine)
    }

    /// The manifest's `createdAtUTC` is a UTC instant; the line shows the calendar day the FILE
    /// claims, by truncation. Re-rendering it in the device's zone would print a date the backup does
    /// not carry — a number the app did not measure, one time zone at a time.
    func testTheSaveDateIsTheDayTheFileRecordedNotTheDevicesReadingOfIt() {
        let copy = RestoreConfirmCopy(file: fileSummary(createdAtUTC: "2026-07-21T23:30:00Z"),
                                      deviceDays: nil)

        XCTAssertTrue(copy.fileLine.contains("saved 2026-07-21"), copy.fileLine)
        XCTAssertFalse(copy.fileLine.contains("2026-07-22"), copy.fileLine)
    }

    /// The receipt is the SAME reading the user agreed to, not a second rendering of it — otherwise
    /// "what landed" and "what you confirmed" can drift apart without anything failing.
    func testTheReceiptIsTheLineTheConfirmShowed() {
        let file = fileSummary()
        let copy = RestoreConfirmCopy(file: file, deviceDays: dayKeys(from: "2026-01-04",
                                                                     to: "2026-08-07"))

        XCTAssertEqual(RestoreConfirmCopy.summaryLine(file), copy.fileLine)
        XCTAssertTrue(copy.fileLine.hasPrefix("199 days · 2026-01-04 to 2026-07-21 · saved 2026-07-21 · "),
                      copy.fileLine)
    }

    /// …and the receipt has to be REACHABLE, which is a separate question the content test above cannot
    /// answer.
    ///
    /// The first version of this shipped the receipt inside `DataSection`, gated on the same
    /// `.needsRelaunch` edge that calls `markStoreSwapped()`. That flag replaces the whole window with
    /// `RelaunchWall`, tearing down `AppShell` → `MoreScreen` → `DataSection` and the runner that holds
    /// the summary — so the receipt was unreachable BY CONSTRUCTION while a green test asserted its
    /// text. The summary now travels WITH the flag; this pins that it survives the transition.
    func testTheReceiptLandsOnTheWallThatReplacesTheImportScreen() throws {
        let line = try XCTUnwrap(RelaunchWall.receiptLine(fileSummary()),
                                 "the wall must show what landed")
        XCTAssertEqual(line, RestoreConfirmCopy.summaryLine(fileSummary()),
                       "and it must be the SAME reading the confirm showed, not a second rendering")
    }

    /// First Run's restore route has no summary to hand over, and the wall must still work — it simply
    /// reads as it always has. A receipt that were REQUIRED would break that path.
    func testTheWallWithoutAReceiptReadsAsItAlwaysHas() {
        XCTAssertNil(RelaunchWall.receiptLine(nil))
    }

    // MARK: - The review states

    /// A real GRDB store (so it carries `grdb_migrations`) with two days, checkpointed, zipped — the
    /// container the picker offers and the one Gates 1–4c accept.
    private func makeBackupZip() async throws -> URL {
        let path = tmp.appendingPathComponent("confirm-src.sqlite").path
        let store = try await StrapStore(path: path)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        _ = try await store.upsertDailyMetrics([
            Fixtures.dailyMetric(day: "2026-07-13", totalSleepMin: 400, recovery: 61),
            Fixtures.dailyMetric(day: "2026-07-14", totalSleepMin: 420, recovery: 72),
        ], deviceId: "my-whoop")
        try await store.checkpointWAL()

        let bak = tmp.appendingPathComponent("confirm-\(UUID().uuidString).wmbak")
        let archive = try Archive(url: bak, accessMode: .create)
        try archive.addEntry(with: "backup.sqlite", fileURL: URL(fileURLWithPath: path),
                             compressionMethod: .deflate)
        return bak
    }

    /// `beginReview` runs Gates 1–4c on a detached task; wait for a settled verdict.
    @MainActor
    private func awaitReview(_ runner: BackupImportRunner,
                             file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 {
            switch runner.review {
            case .confirming, .refused: return
            case .inspecting, .none:    try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTFail("the review never settled", file: file, line: line)
    }

    /// THE change this packet makes: picking a file no longer restores it. The runner stages and
    /// verifies and then STOPS — nothing has been imported, and there is no receipt yet either (a
    /// receipt for a restore that has not happened is a lie the user would read as reassurance).
    @MainActor
    func testPickingAFileStagesItAndStopsThere() async throws {
        let bak = try await makeBackupZip()
        let runner = BackupImportRunner()

        runner.beginReview(.success(bak))
        await awaitReview(runner)

        guard case .confirming(let staged) = runner.review else {
            return XCTFail("expected .confirming, got \(String(describing: runner.review))")
        }
        XCTAssertEqual(runner.phase, .idle, "picking a file must not enter the destructive half")
        XCTAssertNil(runner.replaced, "there is no receipt until something has actually landed")
        XCTAssertEqual(staged.summary.dayCount, 2, "the confirm shows what was read off the file")
        runner.cancel()
    }

    /// The cancel path. Without the `discard()` a cancelled confirm strands a whole extracted store
    /// (~675 MB at the documented steady state) in temp, and nothing else ever cleans it up — the
    /// pre-split `defer` that used to is gone precisely because the staging now outlives `inspect`.
    @MainActor
    func testCancelDiscardsTheStagingAndLeavesNothingToReplace() async throws {
        let bak = try await makeBackupZip()
        let runner = BackupImportRunner()

        runner.beginReview(.success(bak))
        await awaitReview(runner)
        guard case .confirming(let staged) = runner.review else {
            return XCTFail("expected .confirming, got \(String(describing: runner.review))")
        }
        let stagedDir = try XCTUnwrap(staged.extractedDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDir.path))

        runner.cancel()

        XCTAssertNil(runner.review, "a cancelled review must leave nothing to replace with")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDir.path),
                       "a cancelled confirm must not strand an extracted store in temp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path),
                      "cancel must never touch the user's own picked file")
    }

    /// A refusal carries no staged database, so there is nothing to replace anything WITH and the
    /// confirm block renders no Replace at all. The reason is the importer's own gate copy, not an
    /// invented one, and the phase never left idle — nothing was attempted.
    @MainActor
    func testARefusedFileOffersNothingToReplaceWith() async throws {
        let garbage = tmp.appendingPathComponent("garbage.wmbak")
        try Data((0..<512).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        let runner = BackupImportRunner()

        runner.beginReview(.success(garbage))
        await awaitReview(runner)

        guard case .refused(let reason) = runner.review else {
            return XCTFail("expected .refused, got \(String(describing: runner.review))")
        }
        XCTAssertTrue(reason.contains("SQLite"), "the gate's own reason must survive: \(reason)")
        XCTAssertEqual(runner.phase, .idle, "a refusal must never enter the destructive half")
        XCTAssertNil(runner.replaced)
        runner.cancel()
    }

    /// One file under review at a time. A second pick while a staging is open would replace the
    /// reference to it and orphan the temp directory — nothing else knows it exists, so it would
    /// survive until the OS reclaimed it.
    @MainActor
    func testASecondPickCannotOrphanTheOpenStaging() async throws {
        let bak = try await makeBackupZip()
        let runner = BackupImportRunner()

        runner.beginReview(.success(bak))
        await awaitReview(runner)
        guard case .confirming(let first) = runner.review else {
            return XCTFail("expected .confirming, got \(String(describing: runner.review))")
        }

        runner.beginReview(.success(bak))
        await awaitReview(runner)

        guard case .confirming(let second) = runner.review else {
            return XCTFail("expected .confirming, got \(String(describing: runner.review))")
        }
        XCTAssertEqual(first.extractedDir, second.extractedDir,
                       "the second pick must be declined, not stage a second copy")
        let stagedDir = try XCTUnwrap(first.extractedDir)
        runner.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDir.path),
                       "the one staging there ever was must be the one cancel deletes")
    }
}
