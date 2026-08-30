import Foundation
import SQLite3
import StrapStore
import ZIPFoundation

/// Backup importer: the hardened restore core ported from the original
/// `DataBackup.restore(from:toDatabaseAt:settingsDefaults:)`, iOS-only and UI-free (the file picker
/// and the relaunch prompt live in MoreScreen; this is pure plumbing).
///
/// Accepts a picked `.wmbak` / `.zip` / plain `.sqlite` — and, because the container shape is the
/// same (a ZIP whose first `*.sqlite` entry is a WAL-checkpointed GRDB store plus an optional
/// `settings.json`), whoopmaxx's own `.wmbak` restores through this exact path too (its extra
/// `manifest.json` entry is read at Gate 4b and for the inspection summary — it used to be extracted
/// and ignored; its `wm-settings.json` is applied at Gate 8).
///
/// Safety order (kept verbatim from the original — each gate exists because of a real field incident):
///  1. ZIP magic → extract to temp, locate the first `*.sqlite` entry.
///  2. SQLite magic ("SQLite format 3\0").
///  3. GRDB-origin gate: `grdb_migrations` must be present; a Room/Android or unknown-but-data-bearing
///     SQLite is refused (#222 — a foreign DB strands the migrator forever).
///  4. `PRAGMA quick_check` on the STAGED file (#1014 — magic + sqlite_master live in the first
///     pages, so a truncated/torn backup passes them and "restores" into silent emptiness).
///  4b. `manifest.json`'s `schemaVersion` against `StrapStoreInfo.schemaVersion`: a backup written by
///     a FUTURE build carries migrations this binary does not have, and is refused rather than
///     attempted. An OLDER backup is the normal case and still restores — that is what the migrator
///     is for.
///  4c. Free space, measured against what Gates 5–6 are about to write: the snapshot of the CURRENT
///     database plus the landed copy of the staged one. Refused up front, because the alternative is
///     discovering a full volume somewhere inside Gates 5–7 with the live database already removed.
///  5. Snapshot the current DB aside (`whoopmaxx-replaced-<ts>.sqlite`) before touching it.
///  6. Swap; rollback to the snapshot if the copy fails.
///  7. Post-swap `quick_check` on the LANDED file; automatic rollback on failure.
///  8. Only after a landed, verified swap: apply `settings.json` via the vendored `BackupSettings`,
///     then `wm-settings.json` via `WmBackup` (whoopmaxx's own keys; absent from a bare-zip backup,
///     where the read is a silent no-op).
///  9. Also only after a landed, verified swap: RE-ARM the store-scoped one-shot repairs
///     (`RestoreHealReset`). The database just changed underneath flags that describe "these rows have
///     been healed" — see that type's doc for the measurement.
///
/// THE SPLIT (013). Gates 1–4c are `inspect(from:)`, which writes nothing outside our own temp
/// directory; Gates 5–9 are `restore(staged:toDatabaseAt:settingsDefaults:)`, the only destructive
/// half. `restore(from:toDatabaseAt:settingsDefaults:)` is exactly those two in sequence and behaves
/// as it always did, so every existing caller is unchanged. This is a SPLIT, not a rewrite: the gates
/// below are in the same order, with the same comments, because the order IS the fix. The seam exists
/// so a confirm step can show the user what is in the file — against what is on the device — from ONE
/// staging, rather than extracting a ~675 MB store twice to say it.
///
/// RELAUNCH MODEL (documented decision): whoopmaxx follows the original copy-in-place-then-relaunch model
/// (option b) rather than a live handle swap. `Repository` and `BLEManager` each hold a live
/// `StrapStore` (a GRDB `DatabasePool` with open reader connections); swapping the file under an
/// open pool is undefined behaviour, and tearing down + reopening every handle mid-flight would need
/// a coordination seam BLEManager (copied verbatim by decision) doesn't offer. So a successful
/// import returns `.needsRelaunch` and the UI tells the user to quit and reopen the app — the
/// proven, boring path.
enum BackupImport {

    // MARK: - Result

    /// Typed outcome of an import attempt.
    enum ImportResult: Equatable {
        /// Reserved for a future in-process store swap (tear down + reopen the live handles). The
        /// current importer NEVER returns it — see the relaunch-model note in the type doc.
        case imported
        /// The backup landed at the live DB path and verified; it takes effect on the next launch.
        /// `sidecar` is where the previous database was preserved (equals the DB URL itself on a
        /// fresh install with nothing to preserve).
        case needsRelaunch(sidecar: URL)
        /// Nothing was changed (or a failed swap was rolled back); `reason` is user-facing.
        case failure(String)
    }

    // MARK: - Inspection

    /// What `inspect` found in a picked file: either a refusal, or a STAGED, verified database plus a
    /// summary of what is in it — read WITHOUT touching the live database.
    enum Inspection: Equatable {
        /// Gates 1–4c refused the file. `reason` is user-facing, nothing outside our temp directory
        /// was ever written, and any staging this attempt created has already been deleted.
        case refused(String)
        /// The file passed Gates 1–4c and is staged on disk. The caller now OWNS that staging: it must
        /// either hand it to `restore(staged:toDatabaseAt:settingsDefaults:)` or call `discard()`.
        case ready(Staged)

        /// A staged, verified database waiting for Gates 5–9.
        struct Staged: Equatable {
            /// The verified SQLite file a restore would copy over the live database. For a ZIP — or a
            /// bare plain-SQLite, which is copied for the same reason — this is inside `extractedDir`;
            /// for a legacy plain-SQLite still travelling with its `-wal`/`-shm` siblings it is the
            /// USER'S OWN file, left exactly where it was.
            let source: URL
            /// Our private temp directory, or nil when `source` is the user's own file.
            let extractedDir: URL?
            /// What is in `source`, for the confirm step's copy.
            let summary: Summary

            /// Delete the staging this inspection created, and nothing else.
            ///
            /// EXPLICIT, never a `deinit`: the whole point of the split is that the staging OUTLIVES
            /// `inspect`, so there is no scope whose end means "done with it". The pre-split `restore`
            /// removed its temp dir with an unconditional `defer`; the callers now do it —
            /// `restore(from:toDatabaseAt:settingsDefaults:)` defers this call, and the confirm UI
            /// calls it when the user cancels (without which a cancelled ~675 MB import leaks a temp
            /// dir until the OS reclaims it).
            ///
            /// Guarded on `extractedDir`, which is the whole safety of the method: nil is precisely the
            /// case where `source` is the user's own picked file, and deleting there would destroy the
            /// original. Safe to call twice.
            func discard() {
                guard let extractedDir else { return }
                try? FileManager.default.removeItem(at: extractedDir)
            }
        }

        /// What a staged file contains. Every field is OPTIONAL on purpose: a bare `.zip` or plain
        /// `.sqlite` carries no `manifest.json` at all, and "couldn't read it" is not the same answer
        /// as "it is zero". nil means not recorded / unreadable and the UI says so; 0 means measured,
        /// and it is zero. The app never prints a number it did not measure.
        struct Summary: Equatable {
            /// Bytes of the staged database file itself (not its `-wal`/`-shm` siblings, which a
            /// checkpointed backup does not have).
            let sizeBytes: Int?
            /// DISTINCT `dailyMetric.day` values across BOTH lanes (`my-whoop` and
            /// `my-whoop-computed`), which is what "days" means everywhere else in the app.
            let dayCount: Int?
            let earliestDay: String?
            let latestDay: String?
            let sleepSessionCount: Int?
            /// `manifest.json` fields — all nil when the container carries no manifest.
            let formatVersion: Int?
            let schemaVersion: Int?
            let appVersion: String?
            let createdAtUTC: String?
        }
    }

    // MARK: - Entry points

    /// Restore `pickedSource` over the app's live database path. The caller owns any
    /// security-scoped access around this call; run it OFF the main actor (whole-file copy +
    /// quick_check can take tens of seconds on a big library).
    static func restore(from pickedSource: URL) -> ImportResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the whoopmaxx database. \(error.localizedDescription)") }
        return restore(from: pickedSource, toDatabaseAt: dbPath)
    }

    /// The hardened restore core, destination path + settings domain injected so it is unit-testable
    /// against a throwaway DB and a suite-scoped UserDefaults (never the runner's real domain).
    ///
    /// Now the two halves it was always made of, in sequence: `inspect` (Gates 1–4c, which write
    /// nothing outside our temp directory) then `restore(staged:)` (Gates 5–9, the destructive half).
    /// The `defer` below IS the pre-split `defer { try? fm.removeItem(at: extractedDir) }`, moved out
    /// one level and identical in effect — every caller of this entry point still leaves no staging
    /// behind on any path, success or failure. A caller that wants to show the user what is in the
    /// file before anything is replaced calls the two halves itself and owns `discard()`.
    ///
    /// `dbPath` is handed to `inspect` as well as to the swap: Gate 4c measures the space this exact
    /// destination needs, so a test restoring onto a throwaway DB is checked against THAT file rather
    /// than against the app's real one.
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard) -> ImportResult {
        switch inspect(from: pickedSource, toDatabaseAt: dbPath) {
        case .refused(let reason):
            return .failure(reason)
        case .ready(let staged):
            defer { staged.discard() }
            return restore(staged: staged, toDatabaseAt: dbPath, settingsDefaults: settingsDefaults)
        }
    }

    // MARK: - Gates 1–4c: stage, verify, summarise (the live database is never touched)

    /// Stage `pickedSource`, verify it, and read what is in it — WITHOUT touching the live database.
    /// Nothing below writes anywhere but our own temp directory, so a refusal here costs the user
    /// nothing at all.
    ///
    /// A `.ready` result owns a staged file on disk; the caller must pass it to `restore(staged:)` or
    /// call `Staged.discard()`. Run it OFF the main actor: extracting a ~675 MB store and
    /// quick_checking it takes seconds.
    ///
    /// `dbPath` is the database a restore would REPLACE — read only to size Gate 4c's space check, and
    /// never opened, written or removed here. It defaults to the app's own store, so the space refusal
    /// is armed for every caller that has no reason to name a path (the confirm UI); an injected path
    /// is what the tests and `restore(from:toDatabaseAt:)` use.
    static func inspect(from pickedSource: URL, toDatabaseAt dbPath: String? = nil) -> Inspection {
        // If the picked file is a ZIP container, extract it to a temp dir and use its first
        // `*.sqlite` entry. Plain-SQLite files fall straight through.
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("wm-import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .refused("Couldn't open the backup archive: \(error.localizedDescription)")
            }
            guard let sqliteEntry = (try? fm.contentsOfDirectory(
                at: tmpExtract, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "sqlite" }) else {
                try? fm.removeItem(at: tmpExtract)
                return .refused("The backup archive doesn't contain a database file.")
            }
            // A ZIP-extracted GRDB store carries a WAL-mode header but no -wal/-shm siblings. A
            // READ-ONLY SQLite connection refuses to open that shape (it may not create the shm it
            // needs), so the origin probe and the staged quick_check below would fail SPURIOUSLY
            // ("unable to open database file"). The extracted file is OUR private temp copy, so
            // flip it to journal_mode=DELETE first — byte-safe (the WAL was checkpointed at
            // export; there are no frames to lose) and it leaves the copy readonly-verifiable.
            // The store reopens in WAL on the next real open (DatabasePool sets it).
            normalizeJournalMode(at: sqliteEntry)
            source = sqliteEntry
            extractedDir = tmpExtract
        } else if fm.fileExists(atPath: pickedSource.path + "-wal")
                    || fm.fileExists(atPath: pickedSource.path + "-shm") {
            // Legacy plain-SQLite still travelling with its -wal/-shm siblings: leave it in place (the
            // Gate-4 carve-out + post-swap verify + sidecar restore handle this shape), never mutating the
            // user's original.
            source = pickedSource
            extractedDir = nil
        } else {
            // Bare plain-SQLite with NO siblings. Any store this app writes carries a WAL-mode header even
            // after checkpoint, and a READ-ONLY open of that shape fails ("unable to open database file") —
            // so the origin probe silently empties AND Gate 4 wrongly rejects a HEALTHY backup as "damaged".
            // Mirror the ZIP branch: copy into OUR own temp dir, normalize journal_mode=DELETE on the copy
            // (byte-safe — a checkpointed WAL has no frames to lose), then verify/land that copy. The user's
            // original is never touched.
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("wm-import-\(UUID().uuidString)", isDirectory: true)
            let copy = tmpExtract.appendingPathComponent("store.sqlite")
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try fm.copyItem(at: pickedSource, to: copy)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .refused("Couldn't stage the backup file: \(error.localizedDescription)")
            }
            normalizeJournalMode(at: copy)
            source = copy
            extractedDir = tmpExtract   // discard() cleans it up; the settings.json lookup harmlessly finds none
        }
        // Every refusal from here down deletes the staging it just created. This replaces the
        // pre-split `defer { if let d = extractedDir { try? fm.removeItem(at: d) } }`, which cannot
        // stand any more because a SUCCESSFUL inspection deliberately OUTLIVES this call — one staging
        // serves both the summary and the restore, and re-extracting a ~675 MB store to show a confirm
        // is not acceptable. `Staged.discard()` is the success-path counterpart, and the refusal paths
        // above (which return before `extractedDir` exists) already clean up inline.
        func refuse(_ reason: String) -> Inspection {
            if let extractedDir { try? fm.removeItem(at: extractedDir) }
            return .refused(reason)
        }

        // Gate 2: must be a real SQLite database (magic header).
        guard isSQLiteFile(at: source) else {
            return refuse("That file isn't a whoopmaxx backup. It doesn't look like a SQLite database.")
        }

        // Gate 3: GRDB origin. The magic check passes for ANY SQLite file, so an Android (Room)
        // backup — or any other SQLite that happens to carry our table names without our
        // `grdb_migrations` bookkeeping — would otherwise replace the live DB and leave the migrator
        // re-running v1 forever (`table "device" already exists`, #222).
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        // The predicate must cover EVERY table the migrator creates, not just two of them. It used to be
        // `device || hrSample`, so any foreign SQLite avoiding those two names sailed through — and the
        // picker offers plain `.zip`, so another app's export is a realistic input. Two outcomes, both
        // terrible: the migrator builds our tables alongside theirs and the user lands in an empty app
        // with their real store surviving only as a side file nothing reads; or, if the foreign DB
        // carries a generic name we also create (`workout`, `journal`, `event` are the likely ones), the
        // migrator throws `table "workout" already exists` on EVERY open, `ensureStore` returns nil
        // forever, and `quarantineIncompatibleDatabase` can't rescue it because its own predicate is the
        // same too-narrow pair. That is a reinstall — which also destroys the snapshot holding the real
        // data. This is exactly the #222 failure the gate exists for, reached through a hole in it.
        let holdsData = !backupTables.isDisjoint(with: BackupImport.migratorOwnedTables)
        if origin == .android || (origin == .unknown && holdsData) {
            return refuse("This isn't a whoopmaxx backup from the Apple app. It's missing the migration bookkeeping a whoopmaxx backup carries (it looks like an Android backup or another app's database), and restoring it would strand your store. Export a fresh backup from whoopmaxx on this platform and import that instead.")
        }

        // Gate 4 (#1014): quick_check the STAGED file before anything touches the live DB.
        // Carve-out kept from the original: a legacy plain-SQLite file still travelling with -wal/-shm
        // siblings can't be read-only verified (shm rebuild needs write access); it is still
        // verified by the post-swap check below, which rolls back automatically.
        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return refuse("This backup file is damaged and can't be restored (SQLite reports: \(complaint)). Your current data was left untouched. Try an earlier backup file.")
        }

        // Gate 4b: the refusal the format was designed for and nobody read. Every `.wmbak` manifest
        // records the store's migration count at export (`StrapStoreInfo.schemaVersion`), which
        // StrapStore's own doc calls "the one field designed to let a restore refuse a backup it
        // cannot safely open". Until now `manifest.json` was extracted and ignored, so a backup from a
        // FUTURE build — holding tables and columns this binary's migrator has never heard of — landed
        // silently and the app then met a schema from its own future.
        //
        // STRICTLY GREATER, and only that. An OLDER backup is the ordinary case and MUST keep
        // restoring: migrating an old store forward is exactly what the migrator is for, and refusing
        // it would strand every long-standing user's archive. A missing manifest (bare `.zip`, plain
        // `.sqlite`, legacy in-place import) reads as nil and is not a refusal either — there is
        // nothing to compare, and this gate must never invent a comparison.
        let manifest = manifestFields(in: extractedDir)
        if let fileSchema = manifest.schemaVersion, fileSchema > StrapStoreInfo.schemaVersion {
            return refuse("This backup was written by a newer version of whoopmaxx. It carries store schema \(fileSchema); this app reads schema \(StrapStoreInfo.schemaVersion), so it doesn't have the migrations the file needs. Update whoopmaxx, then import it again. Your current data was left untouched.")
        }

        // Gate 4c: space, and the same shape of argument as every gate above — decline up front rather
        // than fail halfway. A restore does not write ONE file, it writes two: Gate 5 copies the current
        // database aside, then Gate 6 copies the staged one over the live path. Run the volume dry
        // between those and the failure lands inside the destructive half, with the live database
        // already removed and only the rollback path standing between the user and their history.
        //
        // ADVISORY ABOUT A REAL MEASUREMENT, never an estimate dressed as a guarantee (decision 5), and
        // that cuts BOTH ways: `requiredFreeBytes` is nil when a size could not be READ, and
        // `volumeAvailableBytes` is nil when the volume could not be, and in either case this gate does
        // NOT fire. An unreadable number is our failure to measure, not evidence of a full disk, and
        // refusing a good backup over one would be a worse defect than the one this exists for — it is
        // also the only refusal in this file the user cannot act on. The verdict itself is
        // `StoreMaintenance.volumeCanAfford`, the app's one definition of affordable; the second read is
        // for the copy, which must name the free space it is talking about rather than assert a
        // shortfall (decision 9).
        //
        // Placed AFTER 4b so a file this binary cannot open is refused for that reason, which is the
        // more useful thing to be told, and BEFORE the summary so no work is done for a file that is
        // going to be refused anyway. `refuse` deletes the staging — the largest thing this gate is
        // complaining about is the copy it just made.
        if let target = dbPath ?? (try? StorePaths.defaultDatabasePath()) {
            // Probe the DIRECTORY, not the database file: on a fresh install there is no file there yet
            // to read resource values from, and it is the volume we are asking about either way.
            let volumeProbe = URL(fileURLWithPath: target).deletingLastPathComponent().path
            if let needed = requiredFreeBytes(stagedAt: source, databaseAt: target),
               let free = StoreMaintenance.volumeAvailableBytes(near: volumeProbe),
               !StoreMaintenance.volumeCanAfford(bytes: needed, near: volumeProbe) {
                return refuse("There isn't enough free space to restore this backup. It needs \(byteText(needed)) — a restore writes the backup in and keeps a snapshot of your current database beside it — and this device has \(byteText(Int(free))) available. Free up space, then import it again. Your current data was left untouched.")
            }
        }

        // Summarise the staged file for the confirm step. Read-only, and after every gate — so this
        // only ever describes a file that already passed them.
        let counts = storeCounts(at: source)
        let summary = Inspection.Summary(sizeBytes: fileSize(at: source),
                                         dayCount: counts?.dayCount,
                                         earliestDay: counts?.earliestDay,
                                         latestDay: counts?.latestDay,
                                         sleepSessionCount: counts?.sleepSessionCount,
                                         formatVersion: manifest.formatVersion,
                                         schemaVersion: manifest.schemaVersion,
                                         appVersion: manifest.appVersion,
                                         createdAtUTC: manifest.createdAtUTC)
        return .ready(Inspection.Staged(source: source, extractedDir: extractedDir, summary: summary))
    }

    // MARK: - Gates 5–9: the destructive half

    /// Replace the database at `dbPath` with a file `inspect` already staged and verified.
    ///
    /// SPLIT, NOT REWRITTEN. Everything below is the pre-split `restore`'s second half — same gates,
    /// same order, same comments. Each one is a shipped incident fix (#222, #1000, #1014) and the
    /// ORDER is the fix; do not reorder, merge or tidy them. The only change is that `source` and
    /// `extractedDir` now arrive in `staged` instead of being computed a few lines above.
    ///
    /// Does NOT discard the staging: Gate 8 reads `settings.json` / `wm-settings.json` out of it, and
    /// the caller owns its lifetime either way (`Staged.discard()`).
    ///
    /// The caller owns any security-scoped access; run it OFF the main actor (a whole-file copy +
    /// quick_check can take tens of seconds on a big library), and only once the user has agreed to
    /// the replacement.
    static func restore(staged: Inspection.Staged, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard) -> ImportResult {
        let fm = FileManager.default
        let source = staged.source
        let extractedDir = staged.extractedDir
        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Gate 5: snapshot the current DB to a timestamped side file so the user can roll back.
            // C3: copy the live `-wal`/`-shm` siblings ALONGSIDE the main file. Repository + BLEManager
            // hold open WAL-mode connections, so recently-committed pages can still live only in the
            // un-checkpointed `-wal`; snapshotting the bare main file (then deleting the live WAL at Gate 6)
            // would make a rollback restore an INCOMPLETE database. Copying main + WAL + SHM keeps the
            // snapshot a consistent point-in-time DB (SQLite folds the WAL in on the next open).
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoopmaxx-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                try copyDatabaseWithSidecars(from: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); report a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Gate 6: remove the live DB and its WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            do {
                try fm.copyItem(at: source, to: dbURL)
            } catch {
                // The live DB was just removed and the replacement didn't land — roll back to the
                // snapshot so a failed import leaves the user's data exactly as it was (C3: main + WAL/SHM).
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    restoreDatabaseWithSidecars(from: sidecar, to: dbURL)
                }
                return .failure("Import failed. Your existing data was kept. \(error.localizedDescription)")
            }

            // Gate 7 (#1014 post-swap): re-verify the file that actually LANDED — the copy
            // itself can tear (disk-full mid-copy, dying filesystem). Runs BEFORE any legacy
            // sidecars are laid down (a bare main file is always read-only verifiable; WAL frames
            // carry their own checksums). Automatic rollback on failure; the snapshot is kept
            // either way.
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    restoreDatabaseWithSidecars(from: sidecar, to: dbURL)   // C3: main + WAL/SHM
                    return .failure("Import failed its post-restore integrity check (SQLite reports: \(complaint)). Your previous data was rolled back automatically and is unchanged.")
                }
                removeIfPresent(dbURL)
                return .failure("Import failed its post-restore integrity check (SQLite reports: \(complaint)). The damaged file was removed; there was no previous data to roll back.")
            }

            // Restore sidecars only for legacy plain-SQLite backups whose WAL wasn't checkpointed at
            // export. ZIP imports are always checkpointed; no sidecars expected. Deliberately AFTER
            // the post-swap check — best-effort, can't throw, rollback semantics unchanged.
            if extractedDir == nil {
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-wal")
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-shm")
            }

            // Gate 8 (#1000): re-apply the backup's whitelisted profile/display settings — only
            // NOW, after the swap landed and verified. A failed or rolled-back restore returns above
            // and never touches settings. Backups without a `settings.json` restore rows-only; a
            // malformed entry degrades to "fewer keys applied" inside BackupSettings.decode.
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                if let data = try? Data(contentsOf: settingsURL) {
                    BackupSettings.apply(BackupSettings.decode(data), to: settingsDefaults)
                }
                // Then whoopmaxx's OWN settings (`wm-settings.json`) — the app-specific keys the
                // frozen 9-key cross-platform whitelist above structurally cannot carry (smart-alarm
                // window, quiet hours, appearance, every experiment toggle). Read UNCONDITIONALLY: no
                // format detection is needed because a bare-zip backup (and a pre-v2 `.wmbak`) simply has
                // no such entry, so the read fails and this is a silent no-op.
                let wmSettingsURL = extractedDir.appendingPathComponent(WmBackup.wmSettingsEntryName)
                if let data = try? Data(contentsOf: wmSettingsURL) {
                    WmBackup.apply(WmBackup.decode(data), to: settingsDefaults)
                }
            }

            // Gate 9: the database that just landed is a DIFFERENT store from the one this install
            // already healed, and every one-shot repair flag lives in UserDefaults — which a restore
            // does not touch (neither whitelist carries one, so Gate 8 structurally cannot). Re-arm
            // them, or the restored rows keep exactly the corruption the heals exist to clear and the
            // next `dataDidChange(.rawHistory)` short-circuits on its first line. See
            // `RestoreHealReset` for the measurement and for why this is a blanket reset.
            //
            // Placed beside Gate 8 for the same reason: this is the ONLY point that knows a swap both
            // LANDED and VERIFIED, so a refused, failed or rolled-back restore (every path above
            // returns) can never reach it. Deliberately OUTSIDE the `if let extractedDir` block —
            // a legacy plain-SQLite backup travelling with its own `-wal`/`-shm` siblings has no
            // extracted dir and still swapped the store.
            RestoreHealReset.rearm(in: settingsDefaults)
            return .needsRelaunch(sidecar: sidecar)
        } catch {
            return .failure("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Origin classification

    /// Which app produced a backup, judged by its migrator's bookkeeping table.
    enum BackupOrigin: Equatable { case grdb, android, unknown }

    /// Pure classification over a backup's `sqlite_master` table names: GRDB (Apple /
    /// whoopmaxx) writes `grdb_migrations`; Room (Android) writes `room_master_table`.
    /// `.unknown` (neither — an empty or pre-migration file) falls through to the normal import
    /// path unless it holds data tables, where the open-time migrator decides.
    /// Every table StrapStore's migrator creates with a BARE `CREATE TABLE` — which, as of this writing,
    /// is all of them: `grep -c ifNotExists Packages/StrapStore/Sources/StrapStore/*.swift` is zero. A
    /// foreign SQLite carrying ANY of these makes the migration throw on every open, so the store never
    /// bootstraps and there is no in-app way back.
    ///
    /// KEEP IN SYNC with `Packages/StrapStore/Sources/StrapStore/Database.swift`. A future migration that
    /// adds a bare `db.create(table:)` and forgets to add the name here reopens the hole for that table.
    /// Derive the list with:
    ///   grep -o 'create(table: "[^"]*"' Packages/StrapStore/Sources/StrapStore/Database.swift
    static let migratorOwnedTables: Set<String> = [
        "appleDaily", "battery", "cursors", "dailyMetric", "device", "event", "gravitySample",
        "habit", "habitLog", "hrSample", "journal", "labMarker", "liveSession", "metricSeries",
        "ppgHrSample", "rawBatch", "respSample", "rrInterval", "skinTempSample", "sleepSession",
        "sleepStateSample", "spo2Sample", "stepSample", "workout",
    ]

    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        // Our marker wins the (degenerate) both-present case: restoring here is the less
        // destructive read.
        if tableNames.contains("grdb_migrations") { return .grdb }
        if tableNames.contains("room_master_table") { return .android }
        // Older Room layouts didn't carry `room_master_table`; treat the Room/AndroidX duo of
        // `android_metadata` + an internal `sqlite_sequence` as Android too.
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    /// Every table name in a SQLite file, opened READ-ONLY through the system SQLite so the probed
    /// file is never mutated. Empty set on any failure — treated as `.unknown` upstream.
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    // MARK: - Reading a staged file (all READ-ONLY)

    /// What the staged store holds, read through a READ-ONLY connection — the same seam
    /// `sqliteTableNames` uses, and for the same reason twice over: a READ-WRITE open would lay
    /// `-wal`/`-shm` siblings down beside the staged file, changing the very bytes Gate 4 just
    /// verified and Gate 6 is about to copy over the user's database.
    ///
    /// nil when the file could not be opened or `dailyMetric` could not be read. A legacy plain-SQLite
    /// still travelling with its own siblings is exactly that case (a read-only open of a WAL-mode
    /// file with no `-shm` fails — the reason Gate 4 has its carve-out), so the summary honestly says
    /// "not recorded" rather than claiming the backup holds no days. Zero rows in a table that DID
    /// open is a real measurement and comes back as 0.
    private static func storeCounts(at url: URL)
        -> (dayCount: Int, earliestDay: String?, latestDay: String?, sleepSessionCount: Int?)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        // DISTINCT day, not COUNT(*): `dailyMetric`'s key is (deviceId, day) and computed scores live
        // on their own `my-whoop-computed` lane, so a plain row count would report most days twice.
        let sql = "SELECT COUNT(DISTINCT day), MIN(day), MAX(day) FROM dailyMetric"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        // MIN/MAX are NULL on an empty table — which is honest: zero days, and no range to name.
        var earliest: String?
        var latest: String?
        if let c = sqlite3_column_text(stmt, 1) { earliest = String(cString: c) }
        if let c = sqlite3_column_text(stmt, 2) { latest = String(cString: c) }
        return (Int(sqlite3_column_int64(stmt, 0)), earliest, latest,
                rowCount(db, table: "sleepSession"))
    }

    /// `COUNT(*)` over `table` on an already-open READ-ONLY connection; nil when the table is absent
    /// (an older or partial store) or the query fails, never 0. `table` is only ever a literal from
    /// this file — there is no caller-supplied name to interpolate.
    private static func rowCount(_ db: OpaquePointer?, table: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Bytes of the file at `url`, or nil when the attribute read fails (reported as "not recorded",
    /// never as 0).
    private static func fileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.intValue
    }

    /// The `manifest.json` beside a staged store, read FIELD BY FIELD rather than through a
    /// `JSONDecoder` pass over `WmBackup.Manifest`.
    ///
    /// Deliberate, and the safety of Gate 4b depends on it: `Manifest.settingsVersion` is
    /// non-optional and arrived with `formatVersion` 2, so a strict decode THROWS on every pre-v2
    /// `.wmbak` and takes `schemaVersion` down with it — silently disarming the refusal on exactly the
    /// oldest files, which is the dangerous direction to fail in. Reading the fields individually
    /// degrades to "fewer fields" instead, the rule `BackupSettings.decode` and `WmBackup.decode`
    /// already follow for their own payloads.
    ///
    /// All-nil when there is no manifest to read: a bare `.zip`, a plain `.sqlite`, or a legacy
    /// in-place import with no extracted directory to look in.
    private static func manifestFields(in extractedDir: URL?)
        -> (formatVersion: Int?, schemaVersion: Int?, appVersion: String?, createdAtUTC: String?) {
        guard let extractedDir,
              let data = try? Data(contentsOf:
                extractedDir.appendingPathComponent(WmBackup.manifestEntryName)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        return ((obj["formatVersion"] as? NSNumber)?.intValue,
                (obj["schemaVersion"] as? NSNumber)?.intValue,
                obj["appVersion"] as? String,
                obj["createdAtUTC"] as? String)
    }

    // MARK: - The space arithmetic (Gate 4c)

    /// Free bytes a restore of the file staged at `source`, over the database at `dbPath`, still has to
    /// find on the volume.
    ///
    /// TWO writes are still to come, and both are unavoidable:
    ///  - Gate 5 copies the CURRENT database aside — main file plus its `-wal`/`-shm` siblings, exactly
    ///    what `copyDatabaseWithSidecars` copies. Counting only the main file under-reports a store
    ///    whose recent pages still live in an un-checkpointed WAL.
    ///  - Gate 6 copies the staged file over the live path, so its whole size again.
    ///
    /// The staging itself is NOT counted: it was extracted a few lines above, so it is already on disk
    /// and already subtracted from the free space this is compared against. Counting it would inflate
    /// the requirement by up to ~675 MB and refuse restores that fit.
    ///
    /// The SUM is deliberately a headroom, not the exact peak. Gate 6 removes the live database between
    /// the two writes, so the true peak is `max(current, staged)`; asking for both means a restore is
    /// declined with roughly one store's slack still on the volume. That margin is the point — the live
    /// store keeps taking writes from the BLE stack while this runs, and "available for important usage"
    /// is itself a soft number the system may not honour to the last byte. Being wrong here in the
    /// permissive direction is a half-finished swap.
    ///
    /// nil means "not measured", and the caller's contract is to skip the gate entirely rather than
    /// refuse — including a staged size that reads as 0, because `volumeCanAfford` reads a non-positive
    /// requirement as "cannot afford" and that would turn a failed stat into an unanswerable refusal
    /// (nothing the user deletes can make a size read). A file
    /// that simply ISN'T THERE, on the other hand, is a measurement of zero: a fresh install has no
    /// database to snapshot, which is precisely what Gate 5 says when it finds none.
    static func requiredFreeBytes(stagedAt source: URL, databaseAt dbPath: String) -> Int? {
        guard let staged = fileSize(at: source), staged > 0 else { return nil }
        let fm = FileManager.default
        var current = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = dbPath + suffix
            guard fm.fileExists(atPath: path) else { continue }
            guard let bytes = fileSize(at: URL(fileURLWithPath: path)) else { return nil }
            current += bytes
        }
        return staged + current
    }

    /// Bytes as the user reads them ("512 MB"), for the one refusal that quotes a size. Only ever
    /// called with a number this file has just measured.
    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - File-shape probes

    /// Read the first 4 bytes and check for the ZIP PK magic (`PK\x03\x04`).
    static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// Read the first 16 bytes and check for the SQLite magic header ("SQLite format 3\0").
    static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    // MARK: - Helpers

    /// Extract every file entry of the backup ZIP at `zipURL` into `destDir`, each under its own
    /// last-path-component (the SQLite lands as `<destDir>/<name>.sqlite` for the caller to locate).
    private static func extractBackupZip(at zipURL: URL, into destDir: URL) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            let out = destDir.appendingPathComponent(name)
            _ = try archive.extract(entry, to: out)
        }
    }

    /// Best-effort: open the staged copy read-write and set `journal_mode=DELETE` so the read-only
    /// probes (sqlite_master scan, quick_check) can open it. Only ever called on OUR extracted temp
    /// copy — a user's own plain `.sqlite` file is never mutated.
    private static func normalizeJournalMode(at url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// C3: copy a SQLite database (`src`) plus any live `-wal`/`-shm` siblings to `dst` (+ matching
    /// siblings) so the snapshot is a CONSISTENT database even when committed pages still live only in an
    /// un-checkpointed WAL under an open connection. Throws only if the main-file copy fails (the caller's
    /// existing gate); the sidecars are best-effort — a fully-checkpointed DB simply has none.
    private static func copyDatabaseWithSidecars(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        for suffix in ["-wal", "-shm"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            let d = URL(fileURLWithPath: dst.path + suffix)
            removeIfPresent(d)
            if fm.fileExists(atPath: s.path) { try? fm.copyItem(at: s, to: d) }
        }
    }

    /// C3 rollback twin: restore a snapshot (main + `-wal`/`-shm` siblings) back over the live DB path,
    /// clearing any partial landed file + stale siblings first. Best-effort; used only on a failed or
    /// rolled-back import, so it swallows copy errors (there is nothing better to do than surface the
    /// failure the caller already reports).
    private static func restoreDatabaseWithSidecars(from snapshot: URL, to dst: URL) {
        let fm = FileManager.default
        removeIfPresent(dst)
        removeIfPresent(URL(fileURLWithPath: dst.path + "-wal"))
        removeIfPresent(URL(fileURLWithPath: dst.path + "-shm"))
        try? fm.copyItem(at: snapshot, to: dst)
        for suffix in ["-wal", "-shm"] {
            let s = URL(fileURLWithPath: snapshot.path + suffix)
            let d = URL(fileURLWithPath: dst.path + suffix)
            if fm.fileExists(atPath: s.path) { try? fm.copyItem(at: s, to: d) }
        }
    }

    /// Copy a legacy backup's `<source><suffix>` sidecar next to the live DB if it exists, so an
    /// old plain-SQLite backup whose WAL wasn't checkpointed at export restores its committed pages
    /// (SQLite folds them in on open). Not called for ZIP imports (always checkpointed).
    private static func restoreSidecar(from source: URL, toMainPath dbPath: String, suffix: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: source.path + suffix)
        guard fm.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: dbPath + suffix)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try? fm.copyItem(at: src, to: dst)
    }
}

/// THE registry of one-shot repairs whose flag describes **the database**, not the install — and the
/// single place a restore re-arms them.
///
/// THE DEFECT THIS EXISTS FOR. Every one-shot store repair we ship is gated on a `UserDefaults` bool
/// that reads "I have already healed". It is USED as if it read "these rows have already been healed".
/// Those two are the same sentence only while the database stays put. A restore swaps the database and
/// leaves `UserDefaults` completely untouched — `BackupImport`'s Gate 8 is the only defaults write in the
/// entire restore path, and it applies whitelist-bounded key sets (`BackupSettings.whitelist`: 9
/// profile/display keys; `WmBackup.settingsWhitelist`: 28 app keys), neither of which contains a
/// `wm.heal.*` / `wm.maintenance.*` key or ever could. So the two go out of sync and the heal skips the
/// rows it exists to clear.
///
/// MEASURED against the user's real 422 MB `.wmbak` (17 nights, manifest `1.3.0 (18)`), driving the real
/// `BackupImport.restore` + the real heals:
///
///     backup store.sqlite, dailyMetric["my-whoop-computed"]: 18 rows, 17 at spo2Pct == 85.0, 17 with solMin
///     restore onto a FRESH install   (flags unset)  → Spo2Heal cleared 17, SleepHrvHeal cleared 17 → 0 left
///     restore onto a HEALED install  (flags true)   → Spo2Heal cleared  0, SleepHrvHeal not pending → 17 LEFT
///     restore onto a HEALED install  + this re-arm  → Spo2Heal cleared 17, SleepHrvHeal cleared 17 → 0 left
///     a bare-zip container behaves identically — that route is not "already covered" either
///     wm.maintenance.respSamplePurge.v1, healed install: `alreadyRun`, file stays 442,634,240 B;
///       re-armed it returns `purged(rows: 1_433_848, vacuumed: true)` and the file falls to 349,495,296 B
///
/// The stakes are higher than a stale number on screen: with the store heals blocked,
/// `AppRoot.dataDidChange(.rawHistory)` runs on to `healthExport.exportRecentIfEnabled()`, and
/// `writeVitals` re-publishes the restored 85.0 % SpO2 into Apple Health as 0.85 oxygenSaturation — a
/// severe-hypoxemia reading, below the < 88 % supplemental-oxygen threshold — while
/// `purgeFabricatedSpo2IfNeeded` is blocked by its OWN already-set flag.
///
/// WHY A BLANKET RESET AND NOT A VERSION CHECK. The container cannot carry the gate: a bare-zip backup has no
/// manifest at all, the user's own `.wmbak` is `formatVersion: 1` with no `wm-settings.json`, and
/// `schemaVersion` tracks StrapStore migrations, which did not move when these heals shipped. A vintage
/// check would therefore fall back to "reset everything" for exactly the files that exist, while adding a
/// comparison surface that can fail in the DANGEROUS direction (skipping a needed heal). The blanket
/// reset is cheap instead: each registered repair re-proves its own precondition against the landed rows
/// and consumes its one-shot again on a clean pass, so there is no re-heal loop.
///
/// THE BAR FOR REGISTERING HERE. A repair re-armed on every restore runs more than once over a user's
/// lifetime, so "one-shot, therefore safe" is no longer an argument for it. Each entry below must be
/// PROVABLY non-destructive when re-run against a store the current code wrote — see each heal's doc for
/// its proof. Anything that cannot clear that bar does not belong in this list.
enum RestoreHealReset {

    /// The store-scoped one-shots, each named by its owning type so a rename cannot orphan an entry.
    ///
    /// `HealthExport`'s two purge flags (`wm.health.spo2PurgeV1`, `wm.health.hrvSplicePurgeV1`) are
    /// deliberately ABSENT — that decision, and why completing the registry with them would silently
    /// destroy the user's Apple Health history, is recorded at their declaration.
    static let storeScopedOneShots = [
        Spo2Heal.doneKey,                        // wm.heal.spo2ClampPinned.v1
        SleepHrvHeal.doneKey,                    // wm.heal.sleepHrvSpliceAndDeep.v1
        StoreMaintenance.respPurgeDefaultsKey,   // wm.maintenance.respSamplePurge.v2
        // wm.heal.round4StagingAndSpread.v2 — the widened re-score. A restored store's hypnograms were
        // staged by whatever build wrote it, so they must be re-derived under the current stager default.
        // Clears the bar for registering: the pass only re-derives days from raw samples still present
        // and upserts, so re-running destroys nothing.
        ScoreEngine.round4RescoreDoneKey,
        // wm.heal.weedConfounder.v1 — 009's widened re-score. A restored store's nights were evaluated by
        // whatever build wrote it, so any night predating weed's arrival in `IllnessSignalEngine.Context`
        // still carries a `strain_level` computed without it. Clears the bar for the same reason round-4
        // does: the pass only re-derives days from raw samples still present and upserts.
        ScoreEngine.weedConfounderRescoreDoneKey,
    ]

    /// Marks that a restore re-armed the one-shots but the RESTORED store has not been opened yet, so the
    /// re-arm must be applied again on the next launch. Never rides into a `.wmbak` — both settings
    /// whitelists are strict allowlists.
    static let rearmPendingKey = "wm.restore.healRearmPending.v1"

    /// Re-arm every registered one-shot in `defaults`.
    ///
    /// `removeObject` rather than `set(false:)` so the key returns to its never-run state — the heals gate
    /// on `bool(forKey:)`, which reads false either way, but an absent key is what a fresh install has and
    /// keeps the two indistinguishable.
    ///
    /// Also raises `rearmPendingKey`, because clearing the flags here is NOT enough on its own. The doc
    /// used to assume "the user force-quits seconds later"; nothing enforces that. The live process still
    /// holds the pre-restore pool, so an `.idleTick` or a finished sync landing before the relaunch runs
    /// the re-armed heals against the OLD store and sets every flag straight back to done. After the
    /// relaunch the restored rows then read "already healed" and keep exactly the corruption Gate 9
    /// exists to clear.
    static func rearm(in defaults: UserDefaults) {
        for key in storeScopedOneShots { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: rearmPendingKey)
    }

    /// Re-apply a pending re-arm at launch, BEFORE anything opens the store.
    ///
    /// Order is load-bearing: clear the one-shots FIRST and the marker LAST, so a crash in between leaves
    /// the marker set and simply re-arms again next launch — harmless, since every entry in the registry
    /// is documented safe to re-run.
    static func applyPendingRearm(in defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: rearmPendingKey) else { return }
        for key in storeScopedOneShots { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: rearmPendingKey)
    }
}
