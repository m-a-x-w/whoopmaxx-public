import Foundation

/// The folder destination: a security-scoped bookmark of a user-chosen folder, plus write/prune and
/// an on-launch daily catch-up. Ported from the original's `FolderBackup` (iOS branch only).
///
/// iOS gives no reliable unattended background DB write (a whole-DB ZIP can be 100 MB+ and the OS
/// kills long background tasks), so the "schedule" is a deferred on-launch catch-up: if a folder is
/// chosen and at least a day has passed, the next foreground launch writes one snapshot — off the
/// main actor and off the launch-critical path. Point the folder at an iCloud/Drive-synced
/// directory and the sync client does the off-device upload; whoopmaxx only writes a local file.
///
/// Choosing a folder IS the opt-in: autobackup runs whenever a bookmark is stored, and clearing the
/// folder (`clearFolder`) turns it off. (the original carried a separate `auto` toggle; whoopmaxx's More
/// screen keeps one switch — the folder itself.)
enum WmFolderBackup {
    static let bookmarkKey = "wm.backup.folderBookmark"
    static let lastKey = "wm.backup.lastMs"
    /// When the most recent AUTOMATIC attempt failed (ms), else 0. The manual "Back up now" row learns
    /// of its own failure from the return value; the launch catch-up has no one to tell, so without this
    /// a snapshot that keeps being refused — e.g. the WAL checkpoint never coming back complete under a
    /// long-running reader — would leave the More screen showing an ageing "Last: …" and nothing else.
    static let lastFailKey = "wm.backup.lastFailMs"

    /// Keep the latest N canonical snapshots in the folder; older ones are pruned. Matches the original.
    static let keepCount = 10
    private static let dayMs = 24 * 60 * 60 * 1000

    // MARK: - Persisted state

    static var lastBackupMs: Int { UserDefaults.standard.integer(forKey: lastKey) }
    static var lastFailureMs: Int { UserDefaults.standard.integer(forKey: lastFailKey) }
    static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// A short, human label for the chosen folder (its last path component), or nil if none chosen.
    static func folderLabel() -> String? { resolveFolder()?.lastPathComponent }

    /// Persist a security-scoped bookmark for `url` (the More screen calls this with the
    /// folder-picker result). iOS bookmarks need no `.withSecurityScope` option — the document
    /// picker's grant is implicit in the bookmark.
    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    /// Forget the folder (turns autobackup off). Existing snapshots in the folder are untouched.
    static func clearFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                           bookmarkDataIsStale: &stale)
        // A stale bookmark still resolves; refresh it opportunistically so it keeps working.
        if stale, let url { saveFolder(url) }
        return url
    }

    // MARK: - Backup / prune

    /// Write one snapshot into the bookmarked folder, stamp the last-backup time, then prune to
    /// `keepCount`. Returns true on success. Never touches UI; safe off the main actor.
    @discardableResult
    static func backupNow(checkpoint: () async -> Bool,
                          drain: () async -> Bool = { true }) async -> Bool {
        guard let folder = resolveFolder() else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        guard case .written = await WmBackup.writeBackup(checkpoint: checkpoint, drain: drain,
                                                         into: folder) else {
            UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000.0), forKey: lastFailKey)
            return false
        }
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000.0), forKey: lastKey)
        UserDefaults.standard.removeObject(forKey: lastFailKey)
        prune(in: folder)
        return true
    }

    /// On-launch catch-up: if a folder is set and it's been at least a day since the last backup,
    /// write one. The caller MUST invoke this off the launch-critical path (AppRoot does).
    static func catchUpIfDue(checkpoint: () async -> Bool,
                             drain: () async -> Bool = { true }) async {
        guard hasFolder else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        let last = lastBackupMs
        // A stamp in the FUTURE is impossible and must be REPAIRED, not merely tolerated. If the clock
        // moves backward past a stamp, `nowMs - last` goes negative and only grows more so, and this
        // guard then returns on every launch forever — autobackup, the only off-device durability this
        // offline app has, silently stops. It stays invisible too: the More caption only flags a problem
        // when a failure is newer than a success, which a future stamp never is; it just reads
        // "Last: in 3 weeks". Rolling the device date back is routine here (it is the standard workaround
        // for an expired free-signed sideload). Same reasoning and shape as `sweepRetentionIfDue`.
        //
        // Clamp to `nowMs - dayMs`, never to `nowMs`: clamping to now would sit the repaired install out
        // another full day. The one-day threshold (rather than a bare `last > now`) keeps a sub-second
        // NTP nudge landing just after a snapshot from forcing a redundant full-DB rewrite.
        if last - nowMs > dayMs {
            UserDefaults.standard.set(nowMs - dayMs, forKey: lastKey)
        } else if nowMs - last < dayMs {
            return
        }
        await backupNow(checkpoint: checkpoint, drain: drain)
    }

    /// Best-effort retention: delete canonical snapshots beyond `keepCount`. Listing failures are
    /// ignored; non-snapshot files in the folder are never touched.
    private static func prune(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let toDelete = Set(WmBackup.snapshotsToPrune(names, keep: keepCount))
        for name in names where toDelete.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
