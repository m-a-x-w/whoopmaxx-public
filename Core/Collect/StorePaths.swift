import Foundation

/// Where the database lives.
enum StorePaths {
    /// The store path, creating its directory if needed.
    ///
    /// The folder name is load-bearing and must not be tidied: an install already has its database
    /// there, and renaming it silently orphans every night the user has recorded.
    static func defaultDatabasePath() throws -> String {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let base = appSupport.appendingPathComponent("OpenWhoop", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("whoop.sqlite")

        #if os(iOS)
        // iOS protects new files at `complete`, which makes the database and its -wal/-shm sidecars
        // unreadable while the phone is LOCKED. This app collects in the background: the strap
        // reconnects behind a locked screen, the store open fails, and the strap never syncs —
        // while imported data looks like it vanished, because every handle hits the same wall.
        //
        // `completeUntilFirstUserAuthentication` is the right level for background collection:
        // readable after the first unlock since boot, still encrypted at rest.
        //
        // Applied to the DIRECTORY so files SQLite creates inherit it, and to any existing files
        // from an install made before this was fixed. Those writes only succeed while unlocked,
        // which a foreground launch provides — and from then on the files stay reachable.
        let attrs: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(attrs, ofItemAtPath: base.path)
        for suffix in ["", "-wal", "-shm"] {
            let p = dbURL.path + suffix
            if fm.fileExists(atPath: p) { try? fm.setAttributes(attrs, ofItemAtPath: p) }
        }
        #endif

        return dbURL.path
    }
}
