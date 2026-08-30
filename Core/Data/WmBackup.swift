import Foundation
import StrapStore
import ZIPFoundation

/// The `.wmbak` autobackup container + folder autobackup — whoopmaxx's twin of the original
/// `DataBackup.writeBackup` / `BackupSync` / `FolderBackup`, with one deliberate improvement over
/// the legacy format: an explicit `manifest.json` (format version, schema version, app version,
/// created-at) so future readers never have to infer versions from `grdb_migrations`.
///
/// Container: `whoopmaxx-backup-YYYYMMDD-HHMMSS.wmbak` (UTC stamp) = plain deflate ZIP
///   { `store.sqlite`      — the whole WAL-checkpointed GRDB store,
///     `manifest.json`     — `WmBackup.Manifest`,
///     `settings.json`     — `BackupSettings.snapshot` (omitted when nothing whitelisted is set),
///     `wm-settings.json`  — `WmBackup.snapshot`, whoopmaxx's OWN keys (omitted likewise) }.
/// The SQLite entry is FIRST, matching the legacy convention (importers stop at the first
/// `*.sqlite` entry) — so `BackupImport.restore` reads a `.wmbak` unchanged.
///
/// `WmBackup` holds the pure filename/selection logic (unit-tested, no I/O) plus the container
/// writer; the stateful folder I/O (security-scoped bookmark, on-launch daily catch-up, keep-10
/// prune) lives in `WmFolderBackup.swift` — the pattern ported from the original's `BackupSync.swift`.
enum WmBackup {

    // MARK: - Format constants

    static let prefix = "whoopmaxx-backup-"
    static let suffix = ".wmbak"
    static let dbEntryName = "store.sqlite"
    static let manifestEntryName = "manifest.json"
    /// Bumped only on a breaking container change (entry set/names/manifest shape). v2 added the
    /// `wm-settings.json` entry + the manifest's `settingsVersion` field.
    static let formatVersion = 2

    /// The `manifest.json` payload. `createdAtUTC` is ISO-8601 with seconds ("2026-07-15T09:30:00Z").
    struct Manifest: Codable, Equatable {
        let formatVersion: Int
        /// The store's migration count at export (`StrapStoreInfo.schemaVersion` — bumped with every
        /// migration the vendored StrapStore gains).
        let schemaVersion: Int
        let appVersion: String
        let createdAtUTC: String
        /// The vintage of `settingsWhitelist` the `wm-settings.json` entry was written against
        /// (`WmBackup.settingsVersion`), so a future reader never has to infer it from the key set.
        let settingsVersion: Int
    }

    // MARK: - whoopmaxx's own settings (`wm-settings.json`)

    /// Canonical entry name for whoopmaxx's OWN settings payload — a SECOND flat JSON object written
    /// alongside (never instead of) the vendored `settings.json`.
    ///
    /// WHY A SECOND ENTRY: `BackupSettings` lives in the frozen StrapStore package and is the original
    /// 9-key CROSS-PLATFORM contract — its own doc says it is "defined once per platform and mirrored
    /// byte-for-byte by Android's `BackupSettingsCodec`" — so it can never grow to carry
    /// whoopmaxx-only keys. Without this entry a restore after a phone wipe silently loses the
    /// smart-alarm window, quiet hours, the theme and every experiment toggle, with no error to see
    /// (unknown keys are dropped by design). Writing BOTH entries keeps an older reader — or an older build
    /// itself — restoring the profile/display half exactly as before.
    static let wmSettingsEntryName = "wm-settings.json"

    /// Bumped when `settingsWhitelist` gains or loses a key, or changes a key's `Kind`. Recorded in
    /// the manifest so a future reader never has to infer the whitelist vintage from the key set.
    static let settingsVersion = 1

    /// The value kind a whitelisted key round-trips as. Models `BackupSettings.Kind` (int/double/
    /// string) and adds the shapes whoopmaxx's own keys actually use: `.bool` — most of these keys
    /// ARE toggles and the vendored codec has no bool at all; `.stringArray` — the dismissed-workout
    /// span lists; `.data` — the wake-event ring, a JSON blob carried base64 because JSON has no
    /// binary. `.double` is kept for parity with the vendored vocabulary.
    enum Kind: Sendable {
        case bool, int, double, string, stringArray, data
    }

    /// THE whoopmaxx whitelist — the only keys `wm-settings.json` may carry, keyed by their
    /// UserDefaults STORAGE key. No canonical-name indirection (unlike the vendored contract): this
    /// entry is whoopmaxx-only, so there is no second platform to map onto. Seeded from each key's
    /// owning constant wherever an accessible one exists, so a rename can't silently orphan its
    /// backup entry.
    ///
    /// Deliberately EXCLUDED — restoring any of these onto another device would be WRONG, not merely
    /// useless:
    ///  - `wm.alarm.deadlineEpoch` / `.windowStartEpoch` / `.firedDeadlineEpoch` — per-night state the
    ///    coordinator rewrites on each arm; a restored fired-deadline marker would suppress tonight's
    ///    wake, and a restored window would arm against a month-old instant.
    ///  - `wm.backup.folderBookmark` — a security-scoped bookmark, meaningless off this device.
    ///  - `wm.pairedPeripheralUUID` — CoreBluetooth's per-device identifier for the strap.
    ///  - `wm.widget.snapshot` — regenerated from the store on the next refresh.
    ///  - `wm.health.sleepFp.*` / `wm.health.vitalsFp.*` — per-install HealthKit dedup fingerprints;
    ///    restoring them would make the bridge skip re-exporting into a fresh HealthKit store. (They must
    ///    equally not be CLEARED on the target install: `writeVitals`' present→nil eviction needs a stored
    ///    fingerprint to act on, so clearing them would strand our samples in Health forever for any day
    ///    the restored — possibly shorter — store no longer has.)
    ///  - every one-shot repair flag (`wm.heal.*`, `wm.maintenance.*`, `wm.health.*PurgeV1`) — these say
    ///    "already done", and carrying one into a backup would suppress the repair on the machine that
    ///    imports it. NOTE that excluding them is necessary but NOT sufficient: exclusion leaves the
    ///    IMPORTING install's own flags in place, which is a defect for the store-scoped ones, so the
    ///    restore re-arms those explicitly — see `RestoreHealReset` and `BackupImport`'s Gate 9.
    static let settingsWhitelist: [String: Kind] = [
        // Smart alarm (W9): the window + insistence the user set, plus the forward-only wake-event
        // ring the Rest "This morning's wake" panel explains from. The three *Epoch keys are
        // per-night state — see the exclusion list above.
        SmartAlarmSettings.Key.enabled: .bool,
        SmartAlarmSettings.Key.earliestMin: .int,
        SmartAlarmSettings.Key.latestMin: .int,
        SmartAlarmSettings.Key.buzzLoops: .int,
        SmartAlarmSettings.Key.wakeEvents: .data,

        // Preferences the More screen owns.
        HealthExport.exportEnabledKey: .bool,
        LiveActivityController.autoStartKey: .bool,
        StrapAlerts.lowBatteryKey: .bool,
        // No named owner — LiveScreen binds the literal via @AppStorage.
        "wm.live.smooth5s": .bool,

        // Breathe: last-used preset + haptic pacing.
        BreathePrefs.Key.preset: .string,
        BreathePrefs.Key.haptics: .bool,

        // Appearance override ("system" / "light" / "dark"). Restored into the app's own domain; the
        // App-Group mirror is re-established by `WMAppearance.mirror` on the next launch (and an
        // import always requires one).
        WMAppearance.storageKey: .string,

        // Notifications: the master / only-when-worn gates and quiet hours. `InactivityPrefs.NotifK`
        // is private and nothing else owns the three gate keys, so those stay literals; the
        // quiet-hours pair does have an accessible owner (ContinuousHrvSchedule reuses the same
        // window byte-for-byte).
        "notif.masterEnabled": .bool,
        "notif.onlyWhenWorn": .bool,
        "notif.quietHoursEnabled": .bool,
        ContinuousHrvSchedule.quietStartKey: .int,
        ContinuousHrvSchedule.quietEndKey: .int,

        // The strap model the pickers wrote (BLEManager writes the bare literal this constant tracks).
        WhoopModel.persistedKey: .string,

        // Dismissed workout suggestions — "startTs:endTs" span lists. Durable user intent: without
        // them a restore re-prompts every bout the user already waved away.
        WorkoutSource.dismissedDefaultsKey: .stringArray,
        // `WorkoutRepository.autoDetectDismissedKey` is private.
        "workouts.autoDetectDismissed": .stringArray,

        // The opt-in experiment / capture toggles (all `wm*`-named, carried over from the original).
        PuffinExperiment.defaultsKey: .bool,
        PuffinExperiment.deepDataKey: .bool,
        PuffinExperiment.broadcastHrKey: .bool,
        PuffinExperiment.keepRealtimeForDataKey: .bool,
        PuffinExperiment.continuousHrvOvernightOnlyKey: .bool,
        PuffinExperiment.experimentalSleepV2Key: .bool,
        PuffinExperiment.autoDetectWorkoutsKey: .bool,
        PuffinFrameRecorder.enabledKey: .bool,
    ]

    /// The whitelisted values currently SET in `defaults` — the export-side snapshot. Keys the user
    /// never touched are omitted (not defaulted), so restoring only overwrites what was genuinely set
    /// here and leaves the rest of the target's settings alone. Same rule as `BackupSettings.snapshot`.
    static func snapshot(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, kind) in settingsWhitelist {
            guard let raw = defaults.object(forKey: key),
                  let coerced = coerce(raw, to: kind) else { continue }
            out[key] = coerced
        }
        return out
    }

    /// Encode the whitelisted subset of `values` as the flat `wm-settings.json` object. Returns nil
    /// when nothing whitelisted is present — the exporter then omits the entry entirely, which reads
    /// identically to a pre-v2 `.wmbak`. `.sortedKeys` keeps the bytes deterministic.
    static func encode(_ values: [String: Any]) -> Data? {
        var filtered: [String: Any] = [:]
        for (key, kind) in settingsWhitelist {
            guard let raw = values[key], let coerced = coerce(raw, to: kind) else { continue }
            filtered[key] = coerced
        }
        guard !filtered.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decode a `wm-settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
    /// JSON, a non-object root, unknown keys and wrong-typed values all degrade to "fewer keys" —
    /// never an error, because a bad settings entry must not fail a restore whose DB half is fine.
    static func decode(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, kind) in settingsWhitelist {
            guard let raw = obj[key], let coerced = coerce(raw, to: kind) else { continue }
            out[key] = coerced
        }
        return out
    }

    /// Write the whitelisted `values` into `defaults` — the restore-side apply. Non-whitelisted keys
    /// and wrong-typed values are ignored. The caller decides WHEN (`BackupImport` applies only after a
    /// landed, verified DB swap, never on a failed or rolled-back restore).
    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (key, kind) in settingsWhitelist {
            guard let raw = values[key], let coerced = coerce(raw, to: kind) else { continue }
            if case .data = kind {
                // `.data` travels as base64 (JSON has no binary); land it back as real `Data`.
                guard let b64 = coerced as? String, let blob = Data(base64Encoded: b64) else { continue }
                defaults.set(blob, forKey: key)
            } else {
                defaults.set(coerced, forKey: key)
            }
        }
    }

    /// Coerce a value (UserDefaults-side or JSON-decoded) to the whitelist's declared kind, or nil if
    /// it can't represent one. The canonical in-dictionary form is always JSON-serializable, so
    /// `.data` normalises to a base64 string at this boundary in BOTH directions.
    ///
    /// Booleans and numbers are kept strictly apart, in both directions: JSON `true` arrives as an
    /// `NSNumber` too, so a numeric kind must refuse it (`true` must never become 1 minute), and a
    /// `.bool` key must equally refuse a plain `1` rather than silently enabling a feature.
    private static func coerce(_ value: Any, to kind: Kind) -> Any? {
        switch kind {
        case .bool:
            guard let n = value as? NSNumber, isBoolean(n) else { return nil }
            return n.boolValue
        case .int:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.intValue
        case .double:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.doubleValue
        case .string:
            return value as? String
        case .stringArray:
            // A mixed/nested array fails the cast whole — better than half-restoring a span list.
            return value as? [String]
        case .data:
            if let blob = value as? Data { return blob.base64EncodedString() }
            if let s = value as? String, Data(base64Encoded: s) != nil { return s }
            return nil
        }
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    enum WriteResult: Equatable {
        case written(URL)
        case failure(String)
    }

    // MARK: - Pure filename helpers (mirror the original BackupSync; unit-tested)

    /// A fresh UTC second-resolution formatter — created per call so there is no shared mutable
    /// `DateFormatter` to data-race.
    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.isLenient = false
        return f
    }

    /// Canonical snapshot filename for an instant (ms since epoch):
    /// `whoopmaxx-backup-YYYYMMDD-HHMMSS.wmbak` (UTC).
    static func snapshotName(_ epochMs: Int) -> String {
        prefix + stampFormatter().string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0)) + suffix
    }

    /// The UTC instant (ms) encoded in a snapshot filename, or nil if `name` is not one of ours.
    static func snapshotTimeMs(_ name: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let d = stampFormatter().date(from: stamp) else { return nil }
        return Int((d.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func isSnapshot(_ name: String) -> Bool { snapshotTimeMs(name) != nil }

    /// Snapshot names sorted newest-first (non-snapshots dropped).
    static func snapshotsNewestFirst(_ names: [String]) -> [String] {
        names.filter(isSnapshot).sorted { (snapshotTimeMs($0) ?? 0) > (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshots to DELETE to keep only the `keep` newest (oldest-first). Strict on purpose: only
    /// canonically named snapshots are prune candidates, so a hand-named `.wmbak` in the folder is
    /// never auto-deleted.
    static func snapshotsToPrune(_ names: [String], keep: Int) -> [String] {
        let snaps = snapshotsNewestFirst(names)
        return snaps.count <= keep ? [] : Array(snaps.dropFirst(keep))
    }

    // MARK: - Container writer

    /// Write one `.wmbak` snapshot of the LIVE store into `folder` (a plain destination directory —
    /// the caller owns any security-scoped access). Checkpoints the WAL first via `checkpoint` (pass
    /// a closure that awaits `StrapStore.checkpointWAL()`; a single-file ZIP has no sidecar
    /// fallback, so committed pages still in the WAL would otherwise be silently absent). Never
    /// presents UI; safe off the main actor.
    static func writeBackup(checkpoint: () async -> Bool, drain: () async -> Bool = { true },
                            into folder: URL,
                            now: Date = Date(),
                            defaults: UserDefaults = .standard) async -> WriteResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the whoopmaxx database. \(error.localizedDescription)") }
        return await writeBackup(databaseAt: dbPath, checkpoint: checkpoint, drain: drain, into: folder,
                                 now: now, defaults: defaults)
    }

    /// Injectable core (unit-testable against a throwaway store + suite defaults): checkpoint,
    /// verify the source with `PRAGMA quick_check` (#1014 export-side armour — archiving an
    /// already-corrupt DB writes a backup that only fails months later), then zip
    /// {store.sqlite, manifest.json, settings.json, wm-settings.json} under the canonical UTC name.
    static func writeBackup(databaseAt dbPath: String, checkpoint: () async -> Bool,
                            drain: () async -> Bool = { true },
                            into folder: URL, now: Date = Date(),
                            defaults: UserDefaults = .standard) async -> WriteResult {
        let fm = FileManager.default
        let dbURL = URL(fileURLWithPath: dbPath)
        guard fm.fileExists(atPath: dbPath) else {
            return .failure("There's no whoopmaxx data to back up yet.")
        }
        // DRAIN BEFORE CHECKPOINT: the checkpoint only moves what SQLite already holds out of the WAL.
        // Samples still sitting in the Collector's RAM buffers were never handed to SQLite at all, so
        // without this step every snapshot silently omitted up to a full flush window of just-recorded
        // HR/R-R. Failing here (rather than shipping short) is deliberate — a store write that failed
        // is transient and retried on the next cadence, whereas an incomplete backup only reveals
        // itself on restore, months later.
        guard await drain() else {
            return .failure("Couldn't safely back up right now. Some just-recorded samples haven't reached the database yet — try again in a moment.")
        }
        guard await checkpoint() else {
            return .failure("Couldn't safely back up right now. Recent changes are still in the write-ahead log.")
        }
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbPath) {
            return .failure("The whoopmaxx database failed its integrity check (SQLite reports: \(complaint)). A backup of it would not restore.")
        }

        let nowMs = Int(now.timeIntervalSince1970 * 1000.0)
        let dest = folder.appendingPathComponent(snapshotName(nowMs))
        // ATOMIC PUBLISH: stage under a name that is NOT a snapshot, then rename. The `catch` below only
        // runs when the zip THROWS — it cannot run when the process is force-quit or jetsammed mid-write,
        // and a multi-second write over a ~500MB store gives that a real window. Streaming straight to
        // `dest` left the corpse under a canonical name, where `isSnapshot` (filename-only, deliberately)
        // counts it as a real backup: being newest it always survives `snapshotsToPrune`, so every
        // interrupted write permanently burned one of the keep-10 slots and evicted a GOOD snapshot.
        // Staged in the DESTINATION folder, never `temporaryDirectory` — a cross-volume `moveItem` into a
        // security-scoped/iCloud folder silently degrades to a full copy (2x space, longer exposure);
        // within one directory it is `rename(2)`.
        let staging = folder.appendingPathComponent(stagingPrefix + UUID().uuidString + stagingSuffix)
        do {
            sweepStaleStaging(in: folder, now: now)
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try writeBackupZip(dbURL: dbURL, to: staging,
                               manifestJSON: manifestJSON(createdAt: now),
                               settingsJSON: BackupSettings.encode(BackupSettings.snapshot(from: defaults)),
                               wmSettingsJSON: encode(snapshot(from: defaults)))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staging, to: dest)
            return .written(dest)
        } catch {
            // A half-written archive must not survive as a plausible-looking backup.
            try? fm.removeItem(at: staging)
            return .failure("Backup failed: \(error.localizedDescription)")
        }
    }

    /// Staging names deliberately fail `isSnapshot` (no `prefix`, no `suffix`), so a corpse can never be
    /// counted by `snapshotsNewestFirst` nor deleted by `snapshotsToPrune`.
    static let stagingPrefix = ".wm-writing-"
    static let stagingSuffix = ".part"

    static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(stagingPrefix) && name.hasSuffix(stagingSuffix)
    }

    /// Best-effort removal of staging residue left by an interrupted write. Because prune only ever
    /// touches canonical names, `.part` files would otherwise accumulate in the user's folder forever.
    /// Conservative on purpose: exact prefix AND suffix AND older than a day, with an `isSnapshot`
    /// belt-and-braces check so a bug here can never touch a real `.wmbak`.
    static func sweepStaleStaging(in folder: URL, now: Date, olderThan: TimeInterval = 24 * 3_600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where isStagingName(name) && !isSnapshot(name) {
            let url = folder.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            guard let modified, now.timeIntervalSince(modified) > olderThan else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// The manifest payload for a backup created at `createdAt`. `.sortedKeys` keeps the bytes
    /// deterministic for identical inputs.
    static func manifestJSON(createdAt: Date) -> Data {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let manifest = Manifest(formatVersion: formatVersion,
                                schemaVersion: StrapStoreInfo.schemaVersion,
                                appVersion: "\(version) (\(build))",
                                createdAtUTC: iso.string(from: createdAt),
                                settingsVersion: settingsVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Manifest is five scalar fields; encoding cannot realistically fail, but degrade to "{}"
        // rather than crash a backup over it.
        return (try? encoder.encode(manifest)) ?? Data("{}".utf8)
    }

    /// Assemble the deflate ZIP: DB entry FIRST (importer convention), then manifest, then the two
    /// optional settings entries. JSON entries are staged through temp files so every entry uses the
    /// exact same file-URL `addEntry` idiom as the DB (one container code path — the original
    /// `DataBackup` lesson).
    private static func writeBackupZip(dbURL: URL, to dest: URL, manifestJSON: Data,
                                       settingsJSON: Data?, wmSettingsJSON: Data?) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: dbEntryName, fileURL: dbURL, compressionMethod: .deflate)
        try addJSONEntry(manifestJSON, named: manifestEntryName, to: archive)
        if let settingsJSON {
            try addJSONEntry(settingsJSON, named: BackupSettings.entryName, to: archive)
        }
        if let wmSettingsJSON {
            try addJSONEntry(wmSettingsJSON, named: wmSettingsEntryName, to: archive)
        }
    }

    private static func addJSONEntry(_ data: Data, named name: String, to archive: Archive) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).json")
        try data.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        try archive.addEntry(with: name, fileURL: tmp, compressionMethod: .deflate)
    }
}
