import Foundation

/// The databases previous imports replaced: enumerate them, size them, order them — and, only ever on
/// an explicit tap, delete one.
///
/// WHY THIS EXISTS. `BackupImport`'s Gate 5 copies the live database aside to
/// `whoopmaxx-replaced-<yyyy-MM-dd-HHmmss>.sqlite` before Gate 6 removes it, "so the user can roll
/// back", and `.needsRelaunch(sidecar:)` hands the URL out. Nothing ever read it back: the UI matched
/// the case and discarded the URL, and a grep for readers across `App/` and `Core/` found none. So every
/// import stranded a FULL store copy — ~560–675 MB at the documented steady state
/// (`SampleRetention`) — forever, in Application Support, which the app publishes no
/// `UIFileSharingEnabled` for. Three imports could silently cost two gigabytes behind a surface that
/// never admitted they existed.
///
/// NOTHING HERE PRUNES (013 decision 4). These files are the only copies of the data an import
/// replaced. There is deliberately no age rule, no cap and no "keep the newest N": a timer the user
/// never agreed to must not be what removes their last copy of a year of history. The list makes them
/// visible and `delete` makes them removable, and that is the whole of it.
///
/// Pure and directory-injected, so the enumeration, the sizing and the ordering are testable against a
/// throwaway directory rather than the install's real Application Support.
enum ReplacedStores {

    // MARK: - The name Gate 5 writes

    /// KEEP IN SYNC with `BackupImport`'s Gate 5, which writes
    /// `whoopmaxx-replaced-\(timestamp()).sqlite` beside the live database, and with the `timestamp()`
    /// format below it. A drift in either makes this list silently EMPTY — every snapshot still on
    /// disk, none of them visible — which is the exact failure this type exists to end.
    /// `ReplacedStoresTests` pins the contract by running a real restore and reading its sidecar back.
    static let namePrefix = "whoopmaxx-replaced-"
    static let nameExtension = "sqlite"
    static let stampFormat = "yyyy-MM-dd-HHmmss"

    /// The siblings Gate 5's `copyDatabaseWithSidecars` copies beside the main file. They belong to
    /// their parent snapshot: counted into its size, removed with it, never listed as stores of their
    /// own (which requiring the `.sqlite` extension already prevents — `store.sqlite-wal`'s path
    /// extension is `sqlite-wal`).
    static let siblingSuffixes = ["-wal", "-shm"]

    // MARK: - One preserved database

    struct Entry: Equatable, Identifiable {
        /// The snapshot's main `.sqlite` file.
        let url: URL
        /// When the import that wrote it ran, read from the file NAME; nil when the name carries no
        /// timestamp in the shape this app writes. Deliberately never taken from the file's
        /// modification date — that is when the bytes landed, a different measurement wearing this
        /// one's clothes (013 decision 9).
        let created: Date?
        /// Main file + `-wal` + `-shm`. nil when a size could not be read — shown as "not recorded",
        /// never as 0.
        let sizeBytes: Int?

        /// The raw file name. It is the row's identity whenever there is no date to name it by, and it
        /// is shown verbatim rather than hidden: an unparseable name is still a whole database.
        var name: String { url.lastPathComponent }

        var id: String { url.path }
    }

    // MARK: - Enumeration

    /// Where Gate 5 writes: beside the live database.
    static func directory(forDatabaseAt dbPath: String) -> URL {
        URL(fileURLWithPath: dbPath).deletingLastPathComponent()
    }

    /// This install's own snapshots.
    ///
    /// Empty when the store path won't resolve or the directory won't list. The row that renders this
    /// simply does not appear in that case — "nothing could be enumerated" is not "there are zero", and
    /// it is never printed as a number.
    static func entries() -> [Entry] {
        guard let dbPath = try? StorePaths.defaultDatabasePath() else { return [] }
        return entries(in: directory(forDatabaseAt: dbPath))
    }

    /// Every snapshot in `directory`, newest first.
    ///
    /// The identity test is the NAME — Gate 5's prefix plus a `.sqlite` extension — and nothing else.
    /// That is what keeps the LIVE database (`whoop.sqlite`, in this very directory) and any other
    /// neighbour out of a list whose only control is a delete.
    static func entries(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let found: [Entry] = names.compactMap { name in
            guard isSnapshotName(name) else { return nil }
            let url = directory.appendingPathComponent(name)
            return Entry(url: url, created: created(fromName: name), sizeBytes: totalSize(of: url))
        }
        return sorted(found)
    }

    /// Does this file name belong to a snapshot Gate 5 wrote? Prefix AND extension, both required.
    static func isSnapshotName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && (name as NSString).pathExtension == nameExtension
    }

    /// The instant in a snapshot's file name, or nil when the name does not carry one.
    ///
    /// STRICT BY ROUND-TRIP. `DateFormatter.date(from:)` parses a matching PREFIX and ignores whatever
    /// follows, so `whoopmaxx-replaced-2026-08-05-093000-copy.sqlite` would otherwise read as a genuine
    /// stamp and sort as if it were one. Re-formatting the parsed date and demanding the original string
    /// back rejects that without a second parser.
    ///
    /// Format and zone match `BackupImport.timestamp()` exactly (POSIX locale, device zone), so a name
    /// this app wrote round-trips. A name written in another zone still displays the wall-clock reading
    /// the name itself carries — the digits are shown, not re-derived — and the parsed instants stay in
    /// the same order as the strings either way.
    static func created(fromName name: String) -> Date? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let stamp = (String(name.dropFirst(namePrefix.count)) as NSString).deletingPathExtension
        guard !stamp.isEmpty,
              let date = stampFormatter.date(from: stamp),
              stampFormatter.string(from: date) == stamp else { return nil }
        return date
    }

    /// Newest first. An entry whose name carries no parseable timestamp cannot be placed in that order
    /// at all, so it goes last, by name — listed (never hidden), but never allowed to take the top slot,
    /// which is the one the UI names as the rollback.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            switch (a.created, b.created) {
            case let (x?, y?): return x == y ? a.name < b.name : x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.name < b.name
            }
        }
    }

    // MARK: - Sizes

    /// Main file + `-wal` + `-shm`, because that is what Gate 5 copied and what `delete` removes. A size
    /// that ignored the siblings would under-report what a snapshot really costs — the entire reason
    /// this list exists.
    ///
    /// nil rather than 0 when anything that IS there won't stat: an unreadable number says so (013
    /// decision 9). Same continue/return-nil shape as `BackupImport.requiredFreeBytes`, over the same
    /// three files.
    private static func totalSize(of url: URL) -> Int? {
        let fm = FileManager.default
        guard var total = fileSize(atPath: url.path) else { return nil }
        for suffix in siblingSuffixes {
            let path = url.path + suffix
            guard fm.fileExists(atPath: path) else { continue }
            guard let bytes = fileSize(atPath: path) else { return nil }
            total += bytes
        }
        return total
    }

    /// What the whole list costs, or nil when ANY entry's size could not be read. A total assembled
    /// from a partial sum would be a number the app did not measure, and it would under-report — the
    /// dangerous direction for a figure whose job is to justify deleting something.
    static func totalBytes(_ entries: [Entry]) -> Int? {
        var total = 0
        for entry in entries {
            guard let bytes = entry.sizeBytes else { return nil }
            total += bytes
        }
        return total
    }

    /// The snapshot that is the rollback for the MOST RECENT import — the newest, and only when the
    /// whole set could be ordered.
    ///
    /// One undatable name and this returns nil, on purpose: with an entry that cannot be placed, the
    /// top of the list is no longer provably the newest, and labelling an older copy "the rollback for
    /// the most recent import" would be a claim the app did not measure — in the copy of a delete
    /// confirmation, which is the worst possible place for one.
    static func rollback(of entries: [Entry]) -> Entry? {
        guard entries.allSatisfy({ $0.created != nil }) else { return nil }
        return entries.first
    }

    // MARK: - The one destructive control

    /// Delete one snapshot and its `-wal`/`-shm` siblings. The ONLY destructive operation 013 adds, and
    /// the UI reaches it exclusively through a two-step confirm (decision 6).
    ///
    /// The name guard is not belt-and-braces: it is what makes it impossible for this function to remove
    /// the LIVE database, which sits in the same directory under a different name. No `Entry` a caller
    /// can build talks it into another path, and the directory check keeps `removeItem` — which deletes
    /// a tree — pointed at a regular file.
    ///
    /// Siblings first, main file LAST: if a removal fails, the entry is still listed (with a smaller,
    /// still-measured size) rather than vanishing from the list while its bytes stay on disk. Invisible
    /// stranded copies are precisely the defect this type exists to end.
    ///
    /// Returns whether the main file is gone afterwards. Callers re-read the list either way.
    @discardableResult
    static func delete(_ entry: Entry) -> Bool {
        let fm = FileManager.default
        guard isSnapshotName(entry.url.lastPathComponent) else { return false }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: entry.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }

        for suffix in siblingSuffixes {
            let path = entry.url.path + suffix
            if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        }
        try? fm.removeItem(at: entry.url)
        return !fm.fileExists(atPath: entry.url.path)
    }

    // MARK: - Small helpers

    private static func fileSize(atPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.intValue
    }

    /// Built once — `DateFormatter` construction is expensive (the `WMFormat` / `DayKey.formatter`
    /// precedent) and this runs once per file in the directory.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = stampFormat
        return f
    }()
}
